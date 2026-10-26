# =============================================================================
# Step 06: Calculate Total Tariff Rates
# =============================================================================
#
# Calculates total effective tariff rate for each HTS10 x country combination
# using stacking rules from Tariff-ETRs.
#
# PUBLIC API:
#   calculate_rates_for_revision() — Entry point for per-revision rate calculation.
#     Called by 00_build_timeseries.R.
#
# INTERNAL:
#   calculate_rates_fast() — Footnote-based rate calculation (vectorized)
#   check_country_applies() — Country applicability check
#   apply_232_derivatives() — Section 232 derivative products + metal scaling
#
# Pipeline steps inside calculate_rates_for_revision():
#   1. Footnote-based rates (301, fentanyl, other via Ch99 refs)
#   1b. IEEPA collection-end check (CBP entry boundary)
#   2. IEEPA reciprocal (blanket, country-level)
#   2b. Post-IEEPA grid expansion (stabilize product-country grid when invalidated)
#   3. IEEPA fentanyl (blanket, CA/MX/CN)
#   4. Section 232 base (blanket, chapter/heading, with config country exemptions)
#   5. Section 232 derivatives (blanket, product list + metal scaling)
#   6. Section 301 (blanket, China product list)
#   6b. Section 122 (blanket, all countries, Annex II exempt)
#   6c. MFN exemption shares (FTA/GSP preference adjustment to base_rate)
#   6d. Floor recomputation (recompute IEEPA floor against post-MFN base_rate)
#   7. USMCA exemptions (CA/MX eligible products)
#   8. Stacking rules (mutual exclusion, nonmetal share)
#   9. Schema enforcement + metadata
#
# Output: rates_{revision}.rds with columns per RATE_SCHEMA (see helpers.R)
#
# =============================================================================

library(tidyverse)

# NOTE: classify_authority(), apply_stacking_rules(), enforce_rate_schema(),
# and RATE_SCHEMA are defined in helpers.R.

# Phase 2 dual-write emitter (normalized layers 1-5). Sourced lazily so
# existing pipelines that pre-date Phase 2 still run if the file is missing.
.emit_normalized_sourced <- FALSE
.source_emit_normalized <- function() {
  if (.emit_normalized_sourced) return(invisible(TRUE))
  candidate <- tryCatch(
    if (requireNamespace('here', quietly = TRUE))
      here::here('src', '07_emit_normalized.R')
    else
      file.path('src', '07_emit_normalized.R'),
    error = function(e) file.path('src', '07_emit_normalized.R')
  )
  if (file.exists(candidate)) {
    source(candidate, local = FALSE)
    .emit_normalized_sourced <<- TRUE
  }
  invisible(.emit_normalized_sourced)
}

# Policy params — needed throughout for IEEPA, 232, floor, MFN, etc.
.pp <- tryCatch(
  load_policy_params(),
  error = function(e) {
    # Graceful fallback when sourced before helpers.R sets working dir
    NULL
  }
)

# Forward provenance ledger. Sourced here rather than relying on the caller,
# because tests source this file directly (tests/run_tests_daily_series.R:741)
# without going through 00_build_timeseries.R. Guarded so re-sourcing is a no-op.
if (!exists('record_duty', mode = 'function')) {
  source(here::here('src', 'duty_ledger.R'))
}
if (!exists('resolve_product_scope_hierarchical', mode = 'function')) {
  try(source(here::here('src', 'resolve_product_scope.R')), silent = TRUE)
}

# Country code constants — centralized in helpers.R, loaded from YAML with fallback
.cc <- get_country_constants(.pp)
CTY_CHINA  <- .cc$CTY_CHINA
CTY_CANADA <- .cc$CTY_CANADA
CTY_MEXICO <- .cc$CTY_MEXICO
CTY_JAPAN  <- .cc$CTY_JAPAN
CTY_UK     <- .cc$CTY_UK
CTY_HK     <- .cc$CTY_HK
STEEL_CHAPTERS <- .cc$STEEL_CHAPTERS
ALUM_CHAPTERS  <- .cc$ALUM_CHAPTERS
ISO_TO_CENSUS  <- .cc$ISO_TO_CENSUS


# =============================================================================
# Vectorized Rate Calculation (footnote-based)
# =============================================================================

#' Fast vectorized rate calculation (for large datasets)
#'
#' @param products Product data
#' @param ch99_data Chapter 99 data
#' @param countries Vector of country codes
#' @return Tibble with rates
calculate_rates_fast <- function(products, ch99_data, countries, stacking_method = 'mutual_exclusion') {
  message('Calculating rates (fast mode)...')

  # Expand products to product x country
  products_expanded <- products %>%
    filter(n_ch99_refs > 0) %>%
    select(hts10, base_rate, ch99_refs) %>%
    crossing(country = countries)

  message('  Product-country combinations: ', nrow(products_expanded))

  # Pre-process Chapter 99 data for faster lookup
  ch99_lookup <- ch99_data %>%
    filter(!is.na(rate)) %>%
    mutate(authority = map_chr(ch99_code, classify_authority)) %>%
    select(ch99_code, rate, authority, country_type, countries, exempt_countries)

  # Unnest product Chapter 99 refs
  product_refs <- products %>%
    filter(n_ch99_refs > 0) %>%
    select(hts10, ch99_refs) %>%
    unnest(ch99_refs) %>%
    rename(ch99_code = ch99_refs)

  message('  Product-Ch99 ref pairs: ', nrow(product_refs))

  # Join with Chapter 99 rates
  product_ch99_rates <- product_refs %>%
    left_join(ch99_lookup, by = 'ch99_code') %>%
    filter(!is.na(rate))

  message('  Product-Ch99 pairs with rates: ', nrow(product_ch99_rates))

  # For each product-country, determine applicable rates
  # This requires checking country applicability for each Ch99 entry

  # Rename list columns to avoid name collision with the 'countries' argument
  product_ch99_rates <- product_ch99_rates %>%
    rename(ch99_countries = countries, ch99_exempt = exempt_countries)

  # Create full expansion: product x ch99 x country
  country_vec <- countries  # local copy to avoid any ambiguity
  full_expansion <- product_ch99_rates %>%
    tidyr::expand_grid(country = country_vec)

  message('  Full expansion: ', nrow(full_expansion))

  # Check country applicability (vectorized where possible)
  full_expansion <- full_expansion %>%
    rowwise() %>%
    mutate(
      applies = check_country_applies(country, country_type, ch99_countries, ch99_exempt)
    ) %>%
    ungroup() %>%
    filter(applies)

  message('  After country filtering: ', nrow(full_expansion))

  # Aggregate by product x country x authority (take max within authority)
  by_authority <- full_expansion %>%
    group_by(hts10, country, authority) %>%
    summarise(
      rate = max(rate),
      .groups = 'drop'
    )

  # Pivot to wide format
  rates_wide <- by_authority %>%
    pivot_wider(
      names_from = authority,
      values_from = rate,
      values_fill = 0,
      names_prefix = 'rate_'
    )

  # Ensure all columns exist
  for (col in c('rate_section_232', 'rate_section_301', 'rate_ieepa_reciprocal',
                'rate_ieepa_fentanyl', 'rate_section_122', 'rate_section_201', 'rate_other')) {
    if (!(col %in% names(rates_wide))) {
      rates_wide[[col]] <- 0
    }
  }

  # Join base rates. Also carry base_rate_source (rate-line resolution provenance:
  # own / inherited:<parent> / unresolved) from the product parse through to the
  # per-country rate rows, so it lands in the parquet and emit_rate_validation's
  # Q4 can audit it. Guarded for older product caches that predate the column.
  prod_base_cols <- intersect(c('hts10', 'base_rate', 'base_rate_source'), names(products))
  rates_wide <- rates_wide %>%
    left_join(
      products %>% select(dplyr::all_of(prod_base_cols)),
      by = 'hts10',
      relationship = 'many-to-one'
    ) %>%
    mutate(base_rate = coalesce(base_rate, 0))

  # Rename columns for clarity
  rates_wide <- rates_wide %>%
    rename(
      rate_232 = rate_section_232,
      rate_301 = rate_section_301,
      rate_ieepa_recip = rate_ieepa_reciprocal,
      rate_ieepa_fent = rate_ieepa_fentanyl,
      rate_s122 = rate_section_122
    )

  # Apply stacking rules (vectorized, from helpers.R)
  rates_final <- apply_stacking_rules(rates_wide, CTY_CHINA, stacking_method = stacking_method)

  return(rates_final)
}


#' Check if country applies to a Chapter 99 entry
#'
#' @param country Census country code
#' @param country_type Type from Ch99 data
#' @param countries List of applicable countries
#' @param exempt List of exempt countries
#' @return Logical
check_country_applies <- function(country, country_type, countries, exempt) {
  # Defensive checks
  if (length(country) == 0 || is.na(country)) return(FALSE)
  if (length(country_type) == 0 || is.na(country_type)) return(FALSE)

  # Convert Census to ISO for matching
  country_iso <- names(ISO_TO_CENSUS)[match(country, ISO_TO_CENSUS)]
  if (length(country_iso) == 0 || is.na(country_iso)) country_iso <- country

  switch(
    country_type,
    'all' = TRUE,
    'all_except' = !(country_iso %in% exempt),
    'specific' = country_iso %in% countries || country %in% countries,
    'unknown' = FALSE,  # Fail-closed: parser miss should not promote to global
    FALSE
  )
}


# =============================================================================
# Section 232 Derivative Products
# =============================================================================

#' Apply Section 232 derivative tariff and metal content scaling
#'
#' Derivative products include both aluminum-containing articles outside
#' chapter 76 (9903.85.04/.07/.08) and steel-containing articles outside
#' chapters 72-73 (9903.81.89-93, added via Section 232 Inclusions Process,
#' FR 2025-15819). The tariff applies only to the metal content portion
#' of customs value. This function:
#'   1. Loads the product list from resources/s232_derivative_products.csv
#'   2. Matches products by prefix, split by derivative_type (steel/aluminum)
#'   3. Applies derivative 232 rates per type (update existing + add new pairs)
#'   4. Joins metal content shares and scales rate_232 by per-type share
#'   5. Tags products with deriv_type for use in stacking rules
#'
#' @param rates Current rates tibble
#' @param products Product data from parse_products()
#' @param ch99_data Chapter 99 data (to check for derivative Ch99 entries)
#' @param s232_rates Section 232 rates from extract_section232_rates()
#' @param countries Vector of Census country codes
#' @return List with 'rates' (updated tibble) and 'deriv_matched' (character vector)
apply_232_derivatives <- function(rates, products, ch99_data, s232_rates, countries,
                                  heading_products = character(0),
                                  policy_params = NULL,
                                  effective_date = NULL, source_derivatives = NULL) {
  deriv_products <- source_derivatives %||% load_232_derivative_products(effective_date = effective_date)
  deriv_matched <- character(0)

  # Per-action §232 rates. These carry the UNSCALED action rate at assignment
  # time; metal-content scaling is applied to each with its own share below, so
  # a dual-content article can owe duty on both contents per EO 14289
  # sec. 3(a)(iii). rate_232 remains the resolved total.
  rates <- zero_fill_authority_rates(rates, S232_ACTION_RATE_COLS)

  # Initialize deriv_type column (used by stacking rules to select per-type share)
  if (!'deriv_type' %in% names(rates)) {
    rates <- rates %>% mutate(deriv_type = NA_character_)
  }
  # Per-product Ch. 99 derivative code (US Note 16/19 subdivision membership,
  # from the CSV). Consumed by resolve_ch99_codes() so each product carries
  # its legally correct heading instead of a single pooled code.
  if (!'deriv_ch99_code' %in% names(rates)) {
    rates <- rates %>% mutate(deriv_ch99_code = NA_character_)
  }
  # Legal duty-basis marker: TRUE for true derivatives outside the primary
  # metal chapters, which owe 232 duty on the declared value of the metal
  # content (US Notes 16(a)/19(a)); primary-chapter and heading-program
  # products owe on the full entered value. Consumed by the duty_basis_232
  # computation after ch99 resolution.
  if (!'deriv_content_scaled' %in% names(rates)) {
    rates <- rates %>% mutate(deriv_content_scaled = FALSE)
  }

  if (!is.null(deriv_products) && nrow(deriv_products) > 0 && s232_rates$has_232) {
    # Check if derivative Ch99 entries exist in this revision (either type).
    # Heading sets come from the reviewed CSV, not hardcoded lists.
    alum_deriv_ch99 <- unique(na.omit(
      deriv_products$ch99_code[deriv_products$derivative_type == 'aluminum']))
    steel_deriv_ch99 <- unique(na.omit(
      deriv_products$ch99_code[deriv_products$derivative_type == 'steel']))
    has_alum_deriv <- any(ch99_data$ch99_code %in% alum_deriv_ch99)
    has_steel_deriv <- any(ch99_data$ch99_code %in% steel_deriv_ch99)

    if (has_alum_deriv || has_steel_deriv) {
      # Split product list by derivative type
      alum_products <- deriv_products %>% filter(derivative_type == 'aluminum')
      steel_products <- deriv_products %>% filter(derivative_type == 'steel')

      # --- Aluminum derivatives ---
      alum_matched <- character(0)
      if (has_alum_deriv && nrow(alum_products) > 0) {
        alum_prefixes <- alum_products$hts_prefix
        alum_pattern <- paste0('^(', paste(alum_prefixes, collapse = '|'), ')')
        alum_matched <- products %>%
          filter(grepl(alum_pattern, hts10)) %>% pull(hts10)

        if (length(alum_matched) > 0) {
          country_alum <- tibble(country = countries) %>%
            mutate(
              deriv_exempt = map_lgl(country, ~is_232_exempt(.x, s232_rates$aluminum_derivative_exempt)),
              deriv_rate = derivative_country_rates(country,
                                               s232_rates$aluminum_derivative_exempt,
                                               s232_rates$aluminum_derivative_rate,
                                               s232_rates$aluminum_country_overrides)
            )
          rates <- rates %>%
            left_join(country_alum %>% select(country, .alum_deriv_rate = deriv_rate), by = 'country', relationship = 'many-to-one') %>%
            mutate(
              .alum_deriv_rate = coalesce(.alum_deriv_rate, 0),
              rate_232 = if_else(hts10 %in% alum_matched & .alum_deriv_rate > 0,
                                 pmax(rate_232, .alum_deriv_rate), rate_232),
              # Unscaled aluminum-action rate, kept separately so it survives the
              # steel pass below rather than being overwritten by it.
              rate_232_aluminum = if_else(hts10 %in% alum_matched & .alum_deriv_rate > 0,
                                          .alum_deriv_rate, rate_232_aluminum),
              deriv_type = if_else(hts10 %in% alum_matched & .alum_deriv_rate > 0,
                                   'aluminum', deriv_type)
            ) %>% select(-.alum_deriv_rate)
          blanket_alum <- country_alum %>% select(country, blanket_rate = deriv_rate)
          rates <- add_blanket_pairs(rates, products, alum_matched, blanket_alum,
                                     'rate_232', '232 aluminum derivative duties')
          # Tag newly added pairs
          rates <- rates %>%
            mutate(deriv_type = if_else(hts10 %in% alum_matched & is.na(deriv_type) & rate_232 > 0,
                                         'aluminum', deriv_type))
          message('  Aluminum derivative coverage: ', length(alum_matched), ' products')
        }
      }

      # --- Steel derivatives ---
      steel_matched <- character(0)
      if (has_steel_deriv && nrow(steel_products) > 0) {
        steel_prefixes <- steel_products$hts_prefix
        steel_pattern <- paste0('^(', paste(steel_prefixes, collapse = '|'), ')')
        steel_matched <- products %>%
          filter(grepl(steel_pattern, hts10)) %>% pull(hts10)

        if (length(steel_matched) > 0) {
          country_steel <- tibble(country = countries) %>%
            mutate(
              deriv_exempt = map_lgl(country, ~is_232_exempt(.x, s232_rates$steel_derivative_exempt)),
              deriv_rate = derivative_country_rates(country,
                                               s232_rates$steel_derivative_exempt,
                                               s232_rates$steel_derivative_rate,
                                               s232_rates$steel_country_overrides)
            )
          rates <- rates %>%
            left_join(country_steel %>% select(country, .steel_deriv_rate = deriv_rate), by = 'country', relationship = 'many-to-one') %>%
            mutate(
              .steel_deriv_rate = coalesce(.steel_deriv_rate, 0),
              rate_232 = if_else(hts10 %in% steel_matched & .steel_deriv_rate > 0,
                                 pmax(rate_232, .steel_deriv_rate), rate_232),
              rate_232_steel = if_else(hts10 %in% steel_matched & .steel_deriv_rate > 0,
                                       .steel_deriv_rate, rate_232_steel),
              # deriv_type is single-valued and steel wins it, which is fine for
              # provenance but must NOT decide the rate: an article containing
              # both metals owes duty on BOTH contents (EO 14289 sec. 3(a)(iii)).
              # rate_232_aluminum above is preserved through this pass and the
              # two are combined in the metal-scaling block.
              deriv_type = if_else(hts10 %in% steel_matched & .steel_deriv_rate > 0,
                                   'steel', deriv_type)
            ) %>% select(-.steel_deriv_rate)
          blanket_steel <- country_steel %>% select(country, blanket_rate = deriv_rate)
          rates <- add_blanket_pairs(rates, products, steel_matched, blanket_steel,
                                     'rate_232', '232 steel derivative duties')
          rates <- rates %>%
            mutate(deriv_type = if_else(hts10 %in% steel_matched & is.na(deriv_type) & rate_232 > 0,
                                         'steel', deriv_type))
          message('  Steel derivative coverage: ', length(steel_matched), ' products')
        }
      }

      deriv_matched <- union(alum_matched, steel_matched)
      message('  Section 232 derivative coverage (total): ', length(deriv_matched), ' products')

      # Record each matched product's own Ch. 99 heading from the CSV,
      # keyed on (hts10, deriv_type) so a product in both lists gets the
      # code for the type that won deriv_type (steel takes precedence above).
      deriv_code_map <- bind_rows(
        build_deriv_ch99_map(alum_matched, alum_products, 'aluminum'),
        build_deriv_ch99_map(steel_matched, steel_products, 'steel')
      )
      if (nrow(deriv_code_map) > 0) {
        rates <- rates %>%
          left_join(deriv_code_map %>% rename(.deriv_code = deriv_ch99_code),
                    by = c('hts10', 'deriv_type'), relationship = 'many-to-one') %>%
          mutate(deriv_ch99_code = coalesce(.deriv_code, deriv_ch99_code)) %>%
          select(-.deriv_code)
      }
    }
  }

  # Update statutory_rate_232 for derivative products only (pre-metal-scaling).
  # Non-derivative products already have statutory_rate_232 set after step 4c.
  if (length(deriv_matched) > 0) {
    rates <- rates %>%
      mutate(
        statutory_rate_232 = if_else(
          hts10 %in% deriv_matched,
          pmax(coalesce(statutory_rate_232, 0), rate_232),
          statutory_rate_232
        )
      )
  }

  # Join metal content shares and scale derivative 232 rates.
  # For derivative products, rate_232 was set to the full rate above;
  # now scale by metal_share so that the rate reflects metal-content-only.
  pp_local <- policy_params %||% .pp
  metal_cfg <- if (!is.null(pp_local)) pp_local$metal_content else NULL
  metal_shares <- load_metal_content(metal_cfg, unique(rates$hts10), deriv_matched)
  if ('metal_share' %in% names(rates)) {
    rates <- rates %>% select(-metal_share)
  }
  rates <- rates %>%
    left_join(metal_shares, by = 'hts10', relationship = 'many-to-one') %>%
    mutate(metal_share = coalesce(metal_share, 1.0))
  n_missing_share <- sum(is.na(metal_shares$metal_share[metal_shares$hts10 %in% deriv_matched]))
  if (n_missing_share > 0) {
    warning(n_missing_share, ' derivative products have no metal_share data — defaulting to 1.0 (no scaling)')
  }

  if (length(deriv_matched) > 0) {
    # Scale by per-type share: aluminum derivatives use aluminum_share,
    # steel derivatives use steel_share. The derivative tariff only applies to
    # the relevant metal content; the other metal fractions are covered by IEEPA
    # via nonmetal_share in stacking. This matches ETRs' per-type scaling.
    #
    # Skip scaling for derivatives that also have a heading rate (e.g., auto parts
    # that are also aluminum derivatives). The heading rate dominates and shouldn't
    # be metal-scaled — ETRs handles this via per-program pmax.
    # Gate per-type scaling on method=='bea': flat/CBO now zero-fill the per-type
    # columns for schema stability, but scaling by zero shares would null out
    # rate_232 on every derivative. Only BEA produces meaningful per-type values.
    metal_method <- if (!is.null(metal_cfg)) metal_cfg$method %||% 'flat' else 'flat'
    has_per_type <- identical(metal_method, 'bea') &&
      all(c('steel_share', 'aluminum_share') %in% names(rates))

    # Exclude primary chapter products (72/73/76) and heading products from
    # derivative metal scaling. Primary chapters get blanket 232 rates (full product);
    # heading products get heading rates (full product). Only true derivatives
    # (outside primary chapters, not heading-matched) should be metal-scaled.
    p_chapters <- if (!is.null(pp_local)) unlist(pp_local$metal_content$primary_chapters) else c('72', '73', '76')
    primary_hts10 <- rates %>% distinct(hts10) %>%
      filter(substr(hts10, 1, 2) %in% p_chapters) %>% pull(hts10)
    deriv_only <- setdiff(deriv_matched, c(heading_products, primary_hts10))

    if (has_per_type) {
      # Per-type scaling: aluminum derivatives by aluminum_share, steel by steel_share
      #
      # Dual-content articles (on BOTH the steel and aluminum derivative lists —
      # 100 prefixes, largely the Aug-2025 expansion into goods in metal
      # packaging) owe duty on EACH metal's content. EO 14289 sec. 3(a)(iii) is
      # explicit that the steel and aluminum actions stack with one another.
      # Previously deriv_type was single-valued, steel won it, and the aluminum
      # content went uncollected.
      rates <- rates %>%
        mutate(
          .scale_share = case_when(
            hts10 %in% deriv_only & deriv_type == 'steel'    ~ steel_share,
            hts10 %in% deriv_only & deriv_type == 'aluminum' ~ aluminum_share,
            hts10 %in% deriv_only                            ~ metal_share,  # fallback
            TRUE ~ 1.0
          )
        )
      .contrib <- resolve_s232_metal_contributions(
        rate_232          = rates$rate_232,
        rate_232_steel    = rates$rate_232_steel,
        rate_232_aluminum = rates$rate_232_aluminum,
        steel_share       = rates$steel_share,
        aluminum_share    = rates$aluminum_share,
        scale_share       = rates$.scale_share,
        is_deriv_only     = rates$hts10 %in% deriv_only
      )
      rates$rate_232          <- .contrib$rate_232
      rates$rate_232_steel    <- .contrib$rate_232_steel
      rates$rate_232_aluminum <- .contrib$rate_232_aluminum

      n_dual <- sum(.contrib$dual, na.rm = TRUE)
      if (n_dual > 0) {
        message('  Dual-content derivatives: ', n_dual,
                ' rows owe both steel and aluminum content duty (EO 14289 3(a)(iii))')
      }
      rates <- rates %>% select(-.scale_share)
    } else {
      # Without per-metal shares the two contents cannot be separated, so a
      # dual-content article is still scaled by one aggregate share. Say so
      # rather than let it look resolved.
      n_dual_unsplit <- sum(rates$rate_232_steel > 0 & rates$rate_232_aluminum > 0 &
                              rates$hts10 %in% deriv_only, na.rm = TRUE)
      if (n_dual_unsplit > 0) {
        warning(n_dual_unsplit, ' dual-content derivative rows cannot be split: ',
                'metal_content method is "', metal_method,
                '" (per-metal shares require method: bea). Aluminum content is ',
                'not separately collected on these rows.')
      }
      # Fallback: aggregate metal_share (backward compat for flat/cbo methods)
      rates <- rates %>%
        mutate(rate_232 = if_else(
          hts10 %in% deriv_only & metal_share < 1.0,
          rate_232 * metal_share,
          rate_232
        ))
    }

    # Reset metal_share to 1.0 for heading products excluded from scaling.
    # Their rate_232 applies to the full product value (heading rate dominates),
    # not the metal portion. Without this, stacking incorrectly computes
    # nonmetal_share > 0 and lets IEEPA fill the "non-metal" portion.
    heading_derivs <- intersect(deriv_matched, heading_products)
    if (length(heading_derivs) > 0) {
      rates <- rates %>%
        mutate(metal_share = if_else(hts10 %in% heading_derivs, 1.0, metal_share))
      if (has_per_type) {
        rates <- rates %>%
          mutate(
            steel_share       = if_else(hts10 %in% heading_derivs, 0, steel_share),
            aluminum_share    = if_else(hts10 %in% heading_derivs, 0, aluminum_share),
            copper_share      = if_else(hts10 %in% heading_derivs, 0, copper_share),
            other_metal_share = if_else(hts10 %in% heading_derivs, 0, other_metal_share)
          )
      }
      message('  Reset metal_share=1.0 for ', length(heading_derivs),
              ' heading/derivative overlap products')
    }

    # Mark the metal-content-value population (= the metal-scaled set).
    rates <- rates %>%
      mutate(deriv_content_scaled = coalesce(deriv_content_scaled, FALSE) |
               hts10 %in% deriv_only)

    n_deriv_with_232 <- sum(rates$hts10 %in% deriv_matched & rates$rate_232 > 0)
    message('  Derivative 232 after metal scaling: ', n_deriv_with_232,
            ' product-country pairs')
  }

  # ---- Phase 2 normalized emit: capture ALL non-scaled derivative products ----
  #
  # The denorm logic at lines 395-450 above computes:
  #   deriv_only = setdiff(deriv_matched, c(heading_products, primary_hts10))
  # Only `deriv_only` gets metal-scaled. Products in heading_products OR
  # primary_hts10 that also match derivative prefixes get:
  #   rate_232 = pmax(blanket/heading rate, derivative full rate)
  # with NO scaling and metal_share reset to 1.0.
  #
  # The normalized emitter needs one override row per such product so the
  # resolver never applies metal scaling to them. The full non-scaled set
  # is `setdiff(deriv_matched, deriv_only)` = the complement of
  # deriv_only within deriv_matched. We capture the already-computed
  # per-hts10 rate_232 directly from the post-step-5 rates tibble (the
  # pmax value) rather than re-deriving it, so any future change to the
  # denorm formula propagates automatically.
  #
  # This covers TWO populations that the first version missed:
  #   (a) heading_derivs = intersect(deriv_matched, heading_products)
  #       — auto parts, copper, wood, MHD products that also match derivatives
  #   (b) primary_derivs = intersect(deriv_matched, primary_hts10)
  #       — ch72/73 steel and ch76 aluminum products that also match derivatives
  # Both get the same treatment: precedence-7 override, scaling=none.
  non_scaled_derivs <- character(0)
  if (exists('deriv_only', inherits = FALSE) && length(deriv_matched) > 0) {
    non_scaled_derivs <- setdiff(deriv_matched, deriv_only)
  } else if (exists('heading_derivs', inherits = FALSE)) {
    non_scaled_derivs <- heading_derivs  # fallback if deriv_only doesn't exist
  }
  heading_overlap <- tibble(hts10 = character(0),
                             rate_232 = numeric(0),
                             deriv_type = character(0))
  if (length(non_scaled_derivs) > 0) {
    # Use MEDIAN(rate_232) instead of max. The pmax(blanket, deriv)
    # value is the same for the vast majority of countries, but outlier
    # countries (Belarus/Russia with sanctions-elevated 200% 232) skew
    # max() far above the typical blanket. Median is robust to these
    # outliers and correctly returns the blanket-pmax value (e.g. 0.5
    # for aluminum, 0.25 for auto heading) that the override row
    # should carry.
    heading_overlap <- rates %>%
      filter(hts10 %in% non_scaled_derivs, rate_232 > 0) %>%
      group_by(hts10) %>%
      summarise(
        rate_232   = median(rate_232, na.rm = TRUE),
        deriv_type = first(na.omit(deriv_type)),
        .groups    = 'drop'
      )
  }

  return(list(rates = rates, deriv_matched = deriv_matched,
              heading_overlap = heading_overlap))
}


# =============================================================================
# Per-Revision Rate Calculator
# =============================================================================

#' Calculate rates for a single HTS revision
#'
#' Wraps calculate_rates_fast() but applies blanket tariffs that are NOT
#' referenced via product footnotes:
#'   - IEEPA reciprocal: blanket on all products for applicable countries
#'   - IEEPA fentanyl: blanket on all products for CA/MX/CN
#'   - Section 232: blanket on steel/aluminum/auto/copper/derivative products
#'   - Section 301: blanket on China products from product list
#'   - USMCA exemptions: eligible products exempt from IEEPA for CA/MX
#'
#' @param products Product data from parse_products()
#' @param ch99_data Chapter 99 data from parse_chapter99()
#' @param ieepa_rates IEEPA rates from extract_ieepa_rates() (or NULL)
#' @param usmca USMCA eligibility from extract_usmca_eligibility() (or NULL)
#' @param countries Vector of Census country codes
#' @param revision_id Revision identifier (e.g., 'rev_7')
#' @param effective_date Date the revision took effect
#' @param s232_rates Section 232 rates from extract_section232_rates() (or NULL)
#' @param fentanyl_rates Fentanyl rates from extract_ieepa_fentanyl_rates() (or NULL)
#' @return Tibble with rate columns + revision, effective_date, usmca_eligible
calculate_rates_for_revision <- function(
  products, ch99_data, ieepa_rates, usmca,
  countries, revision_id, effective_date,
  s232_rates = NULL,
  fentanyl_rates = NULL,
  stacking_method = 'mutual_exclusion',
  policy_params = NULL,
  ch99_other = NULL,
  s301_exclusions = NULL,
  normalized_output_dir = NULL,
  normalized_valid_until = NULL
) {
  message('Calculating rates for revision: ', revision_id, ' (', effective_date, ')')

  # Forward provenance. Every write to an authority rate is recorded with the
  # step that made it and the legal provision behind it, so "why does this row
  # owe X" is a lookup rather than an attempt to invert ~175 sequential
  # mutations from their output. Per-row capture is opt-in via the
  # DUTY_TRACE_ROWS env var ("hts10:country,hts10:country"); the aggregate tier
  # is always on and costs one vectorised comparison per site.
  .trace_rows <- NULL
  .tr_env <- Sys.getenv('DUTY_TRACE_ROWS', '')
  if (nzchar(.tr_env)) {
    .parts <- strsplit(trimws(strsplit(.tr_env, ',')[[1]]), ':')
    .parts <- .parts[lengths(.parts) == 2]
    if (length(.parts) > 0) {
      .trace_rows <- tibble(
        hts10   = vapply(.parts, `[`, character(1), 1),
        country = vapply(.parts, `[`, character(1), 2))
      message('  Duty trace: recording ', nrow(.trace_rows), ' row(s) in full')
    }
  }
  duty_ledger_init(trace_rows = .trace_rows, revision = revision_id,
                   effective_date = effective_date)

  # Date-gate Ch99 entries: drop rows whose legal effective_date_offset is
  # AFTER this revision's effective_date. The HTS publishes new authorities
  # before they become legally collectible (e.g., 9903.94.01 added at rev_6,
  # 2025-03-12, with description specifying entries on or after 2025-04-03).
  # See upstream eval s232_auto_effective_date_2026-04-28.
  # Legal candidate windows are independent of revision publication. Proc. 11051
  # starts during rev_16; filtering first would lose its scope until rev_17.
  s201_quartz <- build_s201_quartz_candidates(ch99_data, effective_date)
  ch99_data <- filter_active_ch99(ch99_data, as.Date(effective_date))

  # If s232_rates was extracted upstream from unfiltered ch99_data
  # (00_build_timeseries.R and 09_daily_series.R both pre-extract), re-extract
  # so heading gates downstream see the gated state.
  if (!is.null(s232_rates)) {
    s232_rates <- extract_section232_rates(ch99_data,effective_date=effective_date)
  }

  # §301 exclusion-heading candidates (date-windowed per revision). Callers
  # may pass them pre-built (00_build_timeseries does, mirroring ch99_other);
  # default-build here so every entry point emits the candidate rules. These
  # feed ch99_rules_json ONLY — rate_301 is never modified.
  if (is.null(s301_exclusions)) {
    s301_exclusions <- build_s301_exclusion_candidates(ch99_data, effective_date)
  }

  # §201 quartz TRQ (9903.45.30/.31, U.S. note 41): determination only — both
  # tiers emitted in ch99_rules_json; rate_section_201 is NEVER set for quartz
  # (the owed rate depends on quota standing, a fact we do not hold).
  # Candidates were extracted above before revision-date filtering.

  pp <- policy_params %||% load_policy_params()
  cc <- get_country_constants(pp)
  CTY_CHINA  <- cc$CTY_CHINA
  CTY_CANADA <- cc$CTY_CANADA
  CTY_MEXICO <- cc$CTY_MEXICO
  STEEL_CHAPTERS <- cc$STEEL_CHAPTERS
  ALUM_CHAPTERS  <- cc$ALUM_CHAPTERS
  ISO_TO_CENSUS  <- cc$ISO_TO_CENSUS

  s232_legacy_source <- NULL
  s232_legacy_memberships <- NULL
  if(grepl('^202[56]_',revision_id) && as.Date(effective_date)>=as.Date('2025-01-01') &&
     as.Date(effective_date)<as.Date('2026-04-06')) {
    source(here('src','section232_legacy.R'))
    s232_legacy_source <- load_s232_legacy_source(revision_id)
    if(!s232_legacy_source$regime %in% c('march_2025_metals','pre_march_2025'))
      stop('Applicable historical metal notes unavailable in revision source')
    s232_legacy_memberships <- s232_legacy_matches(s232_legacy_source,products$hts10,effective_date)
  }

  # 1. Get footnote-based rates from calculate_rates_fast()
  #    This captures 232, 301, fentanyl, other — but NOT IEEPA reciprocal,
  #    which is a blanket tariff not referenced via product footnotes.
  footnote_ch99 <- ch99_data
  if(!is.null(s232_legacy_source)) {
    # Notes 16/19 determine metal membership independently below. A broad or
    # stale chapter footnote cannot seed a rate that pmax would later retain.
    footnote_ch99 <- ch99_data[!grepl('^9903\\.(80|81|85)\\.',ch99_data$ch99_code),,drop=FALSE]
  }
  rates <- calculate_rates_fast(products, footnote_ch99, countries, stacking_method = stacking_method)

  if (nrow(rates) == 0) {
    message('  No footnote-linked rates for ', revision_id, ' — blanket authorities will seed rows')
    rates <- enforce_rate_schema(tibble())
  }

  # FORWARD Chapter 99 provenance columns, initialised once so every authority
  # can record into them without existence checks, and so bind_rows() of
  # authority-seeded pairs cannot produce a ragged frame.
  #
  # These carry the heading that SUPPLIED each duty, written where the duty is
  # applied. resolve_ch99_codes() then projects them into ch99_code_*, instead
  # of inferring a heading afterwards by matching the computed rate — inference
  # that cannot separate two headings sharing a rate and resolved ties
  # alphabetically (auto PARTS -> 9903.94.01, the vehicles heading; every §201
  # row -> 9903.41.05, a Japanese-leather heading).
  for (.c in c('ch99_src_232', 'ch99_src_s201', 'ch99_src_ieepa_recip',
               'ch99_src_301', 'ch99_src_s338')) {
    if (!.c %in% names(rates)) rates[[.c]] <- NA_character_
  }

  # 1a. Resolve the BASE duty tier — Column 2 replaces Column 1 for non-NTR origins
  #     HTSUS General Note 3(b). This must run BEFORE any authority arithmetic:
  #     §232 annex floors and §301 forced-labor caps are computed as
  #     max(target - base_rate, 0), so substituting the base afterwards would
  #     leave those additional rates desynced from the base they were derived
  #     against. Column 2 REPLACES Column 1 — it is never additional.
  non_ntr <- tryCatch(
    load_non_ntr_countries(revision_id, effective_date, strict = FALSE),
    error = function(e) { warning('Column 2 origins unavailable: ', conditionMessage(e)); character(0) })

  if (length(non_ntr) > 0 && nrow(rates) > 0 &&
      all(c('rate_column2', 'rate_column2_raw') %in% names(products))) {
    rates <- rates %>%
      left_join(products %>% select(hts10, .c2 = rate_column2, .c2raw = rate_column2_raw),
                by = 'hts10', relationship = 'many-to-one')
    tier <- resolve_base_rate_tier(
      base_rate        = rates$base_rate,
      rate_column2     = rates$.c2,
      rate_column2_raw = rates$.c2raw,
      is_non_ntr       = rates$country %in% non_ntr
    )
    # These columns are merged into below, so they must EXIST first.
    # calc_status is not on the frame at this point — it arrives with the
    # product tier join at step 9b — and ifelse(cond, NULL, x) fails with
    # "replacement has length zero", which is what broke the build here.
    if (!'base_rate_source' %in% names(rates)) rates$base_rate_source <- NA_character_
    if (!'calc_status'      %in% names(rates)) rates$calc_status      <- NA_character_

    rates$base_rate        <- tier$base_rate
    rates$column2_status   <- tier$column2_status
    # Preserve any existing provenance on rows Column 2 does not touch.
    rates$base_rate_source <- ifelse(is.na(tier$base_rate_source),
                                     rates$base_rate_source, tier$base_rate_source)
    rates$calc_status      <- ifelse(is.na(tier$calc_status),
                                     rates$calc_status, tier$calc_status)
    rates <- rates %>% select(-.c2, -.c2raw)

    n_rep <- sum(tier$replaced, na.rm = TRUE)
    n_exp <- sum(tier$exposed,  na.rm = TRUE)
    message('  Column 2 (GN 3(b)): ', n_rep, ' rows re-based across ',
            length(non_ntr), ' non-NTR origin(s); ', n_exp,
            ' flagged for review (partial or non-derivable)')
    if (n_exp > 0) {
      brk <- sort(table(tier$column2_status[tier$exposed]), decreasing = TRUE)
      message('    exposure by reason: ',
              paste(names(brk), brk, sep = '=', collapse = ', '))
    }
  }

  # 1b. At-entry collection follows CBP CSMS 67834313, not the earlier
  # ruling date. Preserve source actions even after collection ceases.
  denorm_ieepa_evidence <- ieepa_rates
  denorm_fentanyl_evidence <- fentanyl_rates
  ieepa_was_invalidated <- has_ieepa_collection_ended(effective_date)
  if(ieepa_was_invalidated) {
    message('  IEEPA collection ended at this entry date: ',revision_id)
    ieepa_rates <- NULL
    fentanyl_rates <- NULL
  }

  # 2. Apply IEEPA reciprocal (blanket, country-level)
  #    IEEPA reciprocal is a BLANKET tariff — it applies to all products for
  #    applicable countries, not just products with IEEPA footnotes. The country-
  #    specific rates from 9903.01/02.xx define the rate per country.
  #
  #    Product-level exemptions (Annex A / US Note 2 subdivision (v)(iii)):
  #    ~1,087 products are exempt from IEEPA reciprocal. These are defined by
  #    executive order, not by HTS footnotes, so we load from a resource file.
  has_active_ieepa <- !is.null(ieepa_rates) &&
    (nrow(ieepa_rates)>0 || !is.null(attr(ieepa_rates,'universal_baseline')))

  # Duty-free treatment: 'all' (default) applies IEEPA to all products;
  # 'nonzero_base_only' skips products with 0% MFN base rate (matches TPC).
  duty_free_treatment <- pp$ieepa_duty_free_treatment %||% 'all'
  if (duty_free_treatment != 'all') {
    message('  IEEPA duty-free treatment: ', duty_free_treatment)
  }

  # IEEPA Annex II exempt-list scope: 'all' (default, legally correct per
  # EO 14326 §3 + CBP CSMS #65829726) zeros listed products across baseline
  # + Phase 1/2 surcharges + floor; 'baseline_only' is a diagnostic that
  # zeros only the universal 10% baseline. See policy_params.yaml warning.
  ieepa_exempt_scope <- pp$ieepa_exempt_scope %||% 'all'
  if (ieepa_exempt_scope != 'all') {
    message('  IEEPA exempt scope: ', ieepa_exempt_scope,
            ' (DIAGNOSTIC — produces legally-incorrect output)')
  }

  # Universal Annex II scope comes from original legal annexes, reconciled
  # against this revision's notes. Country-alignment annexes, claims, and
  # description-limited exemptions are not unconditional product exemptions.
  reciprocal_scope_source <- NULL
  reciprocal_scope_matches <- data.frame()
  ieepa_exempt_tbl <- data.frame(hts10=character(),source=character())
  if(grepl('^202[56]_',revision_id)) {
    if(!exists('load_reciprocal_scope',mode='function')) source(here('src','ieepa_reciprocal_revision.R'))
    reciprocal_scope_source <- load_reciprocal_scope(revision_id)
    reciprocal_scope_matches <- reciprocal_scope_decisions(reciprocal_scope_source,products$hts10,effective_date,daily_model=TRUE)
    ieepa_exempt_tbl <- reciprocal_exempt_projection(reciprocal_scope_matches)
  } else if(has_active_ieepa) stop('Unsupported reciprocal exemption source revision')
  ieepa_exempt_products <- ieepa_exempt_tbl$hts10
  ieepa_exempt_source_map <- setNames(ieepa_exempt_tbl$source,ieepa_exempt_tbl$hts10)
  message('  Source-backed unconditional reciprocal exemptions: ',length(ieepa_exempt_products))

  # Load country-specific EO product exemptions.
  # Country EOs (Brazil 9903.01.77, India 9903.01.84, etc.) carry their own
  # exempt lists separate from the universal EO 14257 Annex A above. Without
  # this, the country-EO surcharge is wrongly suppressed by Annex A.
  country_eo_exempt_path <- here('resources', 'country_eo_exempt_products.csv')
  country_eo_exempt <- if (file.exists(country_eo_exempt_path)) {
    raw <- read_csv(country_eo_exempt_path, comment = '#',
                    col_types = cols(.default = col_character()))
    rev_date_chr <- as.character(effective_date)
    raw %>%
      mutate(
        effective_date_start = if_else(is.na(effective_date_start) | effective_date_start == '',
                                        '1900-01-01', effective_date_start),
        effective_date_end   = if_else(is.na(effective_date_end)   | effective_date_end == '',
                                        '2099-12-31', effective_date_end)
      ) %>%
      filter(rev_date_chr >= effective_date_start, rev_date_chr <= effective_date_end) %>%
      mutate(hts8_prefix = substr(gsub('\\.', '', hts10), 1, 8)) %>%
      distinct(ch99_code, hts8_prefix)
  } else {
    if(has_active_ieepa && any(ieepa_rates$phase=='country_eo' & !ieepa_rates$terminated))
      stop('Missing country EO exemption source')
    tibble(ch99_code = character(), hts8_prefix = character())
  }
  if (nrow(country_eo_exempt) > 0) {
    message('  Country-EO exempt products active at ', effective_date, ': ',
            nrow(country_eo_exempt), ' (HS8, ch99) pairs across ',
            n_distinct(country_eo_exempt$ch99_code), ' EOs')
  }

  # Load floor country product exemptions (EU/Japan/Korea/Swiss)
  # Products exempt from the 15% tariff floor — defined by US Note 2
  # subdivisions (v)(xx)-(xxiv) and Note 3. These are distinct from the
  # general IEEPA Annex A exemptions above.
  # Per-revision file takes priority; falls back to static resource.
  floor_exempt_products <- load_revision_floor_exemptions(revision_id)

  # Load product-level USMCA utilization shares from DataWeb SPI data (S/S+).
  # Year configured in policy_params.yaml (usmca_shares.year). Falls back to binary eligibility.
  usmca_product_shares <- load_usmca_product_shares(policy_params = pp, effective_date = effective_date)

  # Load MFN exemption shares (FTA/GSP preference utilization at HS2 x country level).
  # Adjusts statutory base_rate down before stacking. Sourced from Tariff-ETRs.
  mfn_exemption_shares <- if (pp$MFN_EXEMPTION$method == 'hs2') {
    load_mfn_exemption_shares()
  } else {
    NULL
  }

  if (has_active_ieepa) {
    source(here('src','ieepa_actions.R'))
    # EO 14266 secs. 2-3 and note 2(v): select operative headings, preserve
    # independent country EOs, and do not choose an arbitrary maximum/floor.
    # Heading 9903.01.29 excludes the revision's GN 3(b) origins.
    recip_exempt <- c(pp$country_codes$CTY_CANADA,pp$country_codes$CTY_MEXICO,non_ntr)
    country_ieepa <- select_ieepa_country_actions(ieepa_rates,countries,recip_exempt)
    if (nrow(country_ieepa)>0) {
      has_floor_exempts <- nrow(floor_exempt_products)>0
      if(has_floor_exempts) {
        floor_country_group_map <- bind_rows(
          tibble(country=pp$EU27_CODES,country_group='eu'),
          tibble(country=pp$country_codes$CTY_JAPAN,country_group='japan'),
          tibble(country=pp$country_codes$CTY_SKOREA,country_group='korea'),
          tibble(country=c(pp$country_codes$CTY_SWITZERLAND,pp$country_codes$CTY_LIECHTENSTEIN),country_group='swiss'))
      }

      # ---- Capture for Phase 2 normalized emit ----
      # The post-baseline country_ieepa tibble is the SINGLE source of truth
      # for IEEPA reciprocal at the (country) level. The emitter consumes
      # this directly so its output matches denorm exactly — no parallel
      # re-implementation of the aggregation, floor override, or baseline
      # logic. See src/07_emit_normalized.R::emit_authority_country_rates.
      denorm_state_country_ieepa <- country_ieepa

      # Apply IEEPA reciprocal to ALL products for applicable countries
      # EXCEPT products on the exemption list (Annex A / US Note 2)
      # and floor country product exemptions (EU/Swiss/Japan/Korea)

      # Build floor exemption lookup: a set of "hts8|country_group" keys
      if (has_floor_exempts) {
        floor_exempt_keys <- floor_exempt_products %>%
          select(hts8, country_group) %>%
          distinct() %>%
          mutate(key = paste0(hts8, '|', country_group)) %>%
          pull(key)
      } else {
        floor_exempt_keys <- character(0)
      }

      rates <- rates %>%
        select(-any_of(setdiff(names(country_ieepa),'census_code'))) %>%
        left_join(
          country_ieepa %>% rename(country = census_code),
          by = 'country',
          relationship = 'many-to-one'
        )

      # Compute floor exemption flag via vectorized lookup
      if (has_floor_exempts) {
        rates <- rates %>%
          left_join(floor_country_group_map, by = 'country', relationship = 'many-to-one') %>%
          mutate(
            floor_exempt = !is.na(country_group) &
              paste0(substr(hts10, 1, 8), '|', country_group) %in% floor_exempt_keys
          ) %>%
          select(-country_group)
      } else {
        rates <- rates %>% mutate(floor_exempt = FALSE)
      }

      # Build a country-EO exempt key set for fast lookup. Each entry pairs
      # (country EO ch99 code) with (HS8 prefix). A product is exempt from
      # the country EO surcharge when both its 8-digit HS prefix and the
      # active EO ch99 code for that country match an entry.
      country_eo_exempt_keys <- if (nrow(country_eo_exempt) > 0) {
        paste(country_eo_exempt$ch99_code, country_eo_exempt$hts8_prefix, sep = '|')
      } else {
        character(0)
      }

      rates <- rates %>%
        mutate(
          # Universal Annex II applies to baseline + phase1 + phase2 surcharges
          # AND the floor structure; country_eo bypasses it but uses its own
          # per-EO exempt list. ieepa_exempt_scope = 'baseline_only' (diagnostic)
          # narrows the universal exempt list to baseline-only countries.
          is_universally_exempt = hts10 %in% ieepa_exempt_products,
          is_country_eo_exempt  = !is.na(country_eo_ch99) &
            paste(country_eo_ch99, substr(hts10, 1, 8), sep = '|') %in% country_eo_exempt_keys,
          exempt_active = is_universally_exempt & (
            ieepa_exempt_scope == 'all' |
            (ieepa_exempt_scope == 'baseline_only' &
             coalesce(is_universal_baseline_country, FALSE))
          ),
          modeled_ieepa_reciprocal_parameter = ieepa_country_rate-country_eo_rate,
          modeled_ieepa_reciprocal_exempt = floor_exempt | exempt_active,
          modeled_ieepa_duty_free = duty_free_treatment=='nonzero_base_only' &
            !is.na(base_rate) & base_rate<0.001,
          modeled_ieepa_reciprocal_rate = ieepa_reciprocal_increment(
            modeled_ieepa_reciprocal_parameter,ieepa_type,base_rate,
            modeled_ieepa_reciprocal_exempt | modeled_ieepa_duty_free),
          modeled_ieepa_country_eo_rate = if_else(is_country_eo_exempt | modeled_ieepa_duty_free,
            0,country_eo_rate),
          rate_ieepa_recip = modeled_ieepa_reciprocal_rate+modeled_ieepa_country_eo_rate,
          ch99_src_ieepa_country_eo = country_eo_ch99,
          # FORWARD attribution. Both candidate headings are already resolved
          # per origin above; previously they were dropped here and the code was
          # reconstructed downstream by taking the HIGHEST-rate heading for the
          # country, which is not necessarily the one charged.
          #
          # A country-specific EO surcharge (Brazil 9903.01.77 and the like) is
          # the operative provision for that origin whenever it actually
          # contributes, so it wins; otherwise the reciprocal floor/surcharge
          # heading carries the duty.
          #
          # Recorded even when the increment is 0 AT THIS STEP: step 6d
          # recomputes the floor against the post-MFN base_rate and resurrects
          # duty on rows that were 0 here — gating the source on the momentary
          # rate orphaned every such row (59% of rated recip rows fell back to
          # the highest-rate-heading guess). Consumption (ch99_code_ieepa_recip)
          # is gated on the FINAL rate > 0, so a would-apply source on a 0-rate
          # row is never asserted downstream.
          ch99_src_ieepa_recip = case_when(
            !is.na(country_eo_ch99) & country_eo_rate > 0 &
              !is_country_eo_exempt ~ country_eo_ch99,
            TRUE ~ ieepa_recip_ch99
          )
        ) %>%
        select(-ieepa_country_rate, -country_eo_rate, -country_eo_ch99,
               -is_universally_exempt, -is_country_eo_exempt, -floor_exempt,
               -is_universal_baseline_country, -is_reciprocal_country_excluded, -exempt_active)

      # Also add IEEPA rows for products NOT currently in rates
      # (products with no other Ch99 duties but still subject to IEEPA)
      ieepa_country_codes <- country_ieepa$census_code
      ieepa_countries_in_scope <- intersect(ieepa_country_codes, countries)

      existing_pairs <- rates %>%
        filter(country %in% ieepa_countries_in_scope) %>%
        select(hts10, country)

      all_products_base <- products %>% select(hts10, base_rate)

      new_pairs <- all_products_base %>%
        tidyr::expand_grid(country = ieepa_countries_in_scope) %>%
        anti_join(existing_pairs, by = c('hts10', 'country')) %>%
        left_join(
          country_ieepa %>% rename(country = census_code),
          by = 'country',
          relationship = 'many-to-one'
        )

      # Apply floor exemption flag to new_pairs
      if (has_floor_exempts) {
        new_pairs <- new_pairs %>%
          left_join(floor_country_group_map, by = 'country', relationship = 'many-to-one') %>%
          mutate(
            floor_exempt = !is.na(country_group) &
              paste0(substr(hts10, 1, 8), '|', country_group) %in% floor_exempt_keys
          ) %>%
          select(-country_group)
      } else {
        new_pairs <- new_pairs %>% mutate(floor_exempt = FALSE)
      }

      new_pairs <- new_pairs %>%
        mutate(
          rate_232 = 0, rate_301 = 0, rate_ieepa_fent = 0, rate_s122 = 0,
          rate_section_201 = 0, rate_other = 0,
          is_universally_exempt = hts10 %in% ieepa_exempt_products,
          is_country_eo_exempt  = !is.na(country_eo_ch99) &
            paste(country_eo_ch99, substr(hts10, 1, 8), sep = '|') %in% country_eo_exempt_keys,
          exempt_active = is_universally_exempt & (
            ieepa_exempt_scope == 'all' |
            (ieepa_exempt_scope == 'baseline_only' &
             coalesce(is_universal_baseline_country, FALSE))
          ),
          modeled_ieepa_reciprocal_parameter = ieepa_country_rate-country_eo_rate,
          modeled_ieepa_reciprocal_exempt = floor_exempt | exempt_active,
          modeled_ieepa_duty_free = duty_free_treatment=='nonzero_base_only' &
            !is.na(base_rate) & base_rate<0.001,
          modeled_ieepa_reciprocal_rate = ieepa_reciprocal_increment(
            modeled_ieepa_reciprocal_parameter,ieepa_type,base_rate,
            modeled_ieepa_reciprocal_exempt | modeled_ieepa_duty_free),
          modeled_ieepa_country_eo_rate = if_else(is_country_eo_exempt | modeled_ieepa_duty_free,
            0,country_eo_rate),
          rate_ieepa_recip = modeled_ieepa_reciprocal_rate+modeled_ieepa_country_eo_rate,
          ch99_src_ieepa_country_eo = country_eo_ch99,
          # Same forward attribution as the existing-rows branch above (rows
          # here are filtered to rate > 0 below, so no momentary-rate gate is
          # needed either).
          ch99_src_ieepa_recip = case_when(
            !is.na(country_eo_ch99) & country_eo_rate > 0 &
              !is_country_eo_exempt ~ country_eo_ch99,
            TRUE ~ ieepa_recip_ch99
          )
        ) %>%
        select(-ieepa_country_rate, -country_eo_rate, -country_eo_ch99,
               -is_universally_exempt, -is_country_eo_exempt, -floor_exempt,
               -is_universal_baseline_country, -is_reciprocal_country_excluded, -exempt_active)

      if (nrow(new_pairs) > 0) {
        message('  Adding ', nrow(new_pairs), ' product-country pairs for IEEPA-only duties')
        rates <- bind_rows(rates, new_pairs)
      }
    } else {
      # No usable IEEPA entries (all missing rate or census_code)
      rates <- rates %>% mutate(rate_ieepa_recip = 0)
    }
  } else {
    # No IEEPA in this revision — zero out
    rates <- rates %>% mutate(rate_ieepa_recip = 0)
  }

  # 3. Apply IEEPA fentanyl/initial rates with product-level carve-outs
  #    9903.01.01-24: Mexico (+25%), Canada (+35%), China (+10%)
  #    These STACK with reciprocal tariffs for CA/MX.
  #    China/HK included: fentanyl (9903.01.20/24) is NOT captured via
  #    product footnotes for China. The 9903.90.xx entries are Russia only.
  #
  #    Carve-outs: Certain product categories receive a lower fentanyl rate:
  #      - 9903.01.13 (CA): Energy, minerals, critical minerals → +10%
  #      - 9903.01.15 (CA): Potash → +10%
  #      - 9903.01.05 (MX): Potash → +10%
  #    Product lists from resources/fentanyl_carveout_products.csv.
  has_fentanyl <- !is.null(fentanyl_rates) && nrow(fentanyl_rates) > 0

  if (has_fentanyl) {
    # Chronology and conditional replacements are resolved before joining.
    # A larger rate is never proof that an ordinary action supersedes another.
    general_fent <- ordinary_emergency_parameters(fentanyl_rates) %>% select(-fent_ch99)

    carveout_fent <- fentanyl_rates %>%
      filter(entry_type == 'carveout') %>%
      select(ch99_code, census_code, carveout_rate = rate)

    # Load carve-out product lists and build lookup (once, reused below)
    carveout_products <- load_fentanyl_carveouts()
    has_carveouts <- !is.null(carveout_products) && nrow(carveout_fent) > 0

    carveout_lookup <- NULL
    if (has_carveouts) {
      # HTS8 × country → carve-out rate (join product list to parsed ch99 entries)
      carveout_lookup <- carveout_products %>%
        inner_join(carveout_fent, by = 'ch99_code') %>%
        distinct(hts8, census_code, carveout_rate, ch99_code) %>%
        rename(carveout_ch99=ch99_code)
      if(anyDuplicated(carveout_lookup[c('hts8','census_code')]))
        stop('Conflicting emergency product carve-outs require source reconciliation')

    }

    # Apply fentanyl to existing rows: general rate with carve-out overrides
    if (has_carveouts) {
      rates <- rates %>%
        mutate(.hts8 = substr(hts10, 1, 8)) %>%
        left_join(general_fent, by = c('country' = 'census_code'), relationship = 'many-to-one') %>%
        left_join(carveout_lookup,
                  by = c('.hts8' = 'hts8', 'country' = 'census_code'), relationship = 'many-to-one') %>%
        mutate(
          rate_ieepa_fent = coalesce(carveout_rate, fent_rate, 0)
        ) %>%
        select(-fent_rate, -carveout_rate, -carveout_ch99, -.hts8)

      n_carveout <- sum(rates$rate_ieepa_fent > 0 &
                        rates$rate_ieepa_fent < max(general_fent$fent_rate, na.rm = TRUE))
      message('  Fentanyl carve-outs applied: ', n_carveout, ' product-country pairs')
    } else {
      rates <- rates %>%
        left_join(general_fent, by = c('country' = 'census_code'), relationship = 'many-to-one') %>%
        mutate(rate_ieepa_fent = coalesce(fent_rate, 0)) %>%
        select(-fent_rate)
    }

    # Add fentanyl-only rows for products not yet in rates
    # (uses general rate; carve-outs applied in the next block)
    fent_country_rates <- general_fent %>%
      rename(country = census_code, blanket_rate = fent_rate) %>%
      filter(country %in% countries)
    all_product_hts10 <- products$hts10
    rates <- add_blanket_pairs(rates, products, all_product_hts10, fent_country_rates,
                               'rate_ieepa_fent', 'fentanyl-only duties')

    # Apply carve-outs to newly added rows (blanket_pairs got the general rate)
    if (has_carveouts) {
      rates <- rates %>%
        mutate(.hts8 = substr(hts10, 1, 8)) %>%
        left_join(carveout_lookup,
                  by = c('.hts8' = 'hts8', 'country' = 'census_code'), relationship = 'many-to-one') %>%
        mutate(
          rate_ieepa_fent = if_else(!is.na(carveout_rate), carveout_rate, rate_ieepa_fent)
        ) %>%
        select(-carveout_rate, -carveout_ch99, -.hts8)
    }

    # Preserve the selected action before rollups and modeled claim shares.
    # Energy and potash use their own heading, never the general country code.
    general_codes <- ordinary_emergency_parameters(fentanyl_rates)
    rates$ch99_src_ieepa_fent <- general_codes$fent_ch99[match(rates$country,general_codes$census_code)]
    if(has_carveouts) {
      ix <- match(paste(substr(rates$hts10,1,8),rates$country),
        paste(carveout_lookup$hts8,carveout_lookup$census_code))
      rates$ch99_src_ieepa_fent[!is.na(ix)] <- carveout_lookup$carveout_ch99[ix[!is.na(ix)]]
    }

    # Chapter 98 entitlement and valuation belong to the source-backed
    # shipment rules. Annex II product membership cannot establish that claim
    # or suppress a separate emergency action.

    n_with_fent <- sum(rates$rate_ieepa_fent > 0)
    message('  With IEEPA fentanyl: ', n_with_fent)
  rates <- record_duty(rates, '3', 'ieepa_fent', 'rate_ieepa_fent',
                       'ieepa_fentanyl_country_rate',
                       citation_key = 'eo_14195_china_fentanyl',
                       ch99_code_col = 'ch99_code_ieepa_fent')
  } else {
    rates <- rates %>% mutate(rate_ieepa_fent = coalesce(rate_ieepa_fent, 0))
  }

  # 2b. Grid expansion for post-IEEPA invalidation
  #     When IEEPA is invalidated (SCOTUS ruling), both the reciprocal and
  #     fentanyl blocks above are skipped — which also skips the all-products
  #     x all-countries grid expansion that those blocks normally perform.
  #     Without that grid, many product-country pairs lose their base_rate
  #     representation, causing matched_imports to drop discontinuously and
  #     the weighted ETR to undercount base MFN contributions.
  #
  #     Fix: expand the grid to all products x all countries with zero
  #     additional rates. Downstream blanket tariffs (232, 301, s122) then
  #     fill in their rates on this complete grid.

  if (ieepa_was_invalidated) {
    existing_pairs <- rates %>% select(hts10, country)

    all_products_base <- products %>%
      select(hts10, base_rate) %>%
      mutate(base_rate = coalesce(base_rate, 0))

    new_grid_pairs <- all_products_base %>%
      tidyr::expand_grid(country = countries) %>%
      anti_join(existing_pairs, by = c('hts10', 'country')) %>%
      mutate(
        rate_232 = 0, rate_301 = 0, rate_ieepa_recip = 0,
        rate_ieepa_fent = 0, rate_s122 = 0, rate_section_201 = 0, rate_other = 0
      )

    if (nrow(new_grid_pairs) > 0) {
      message('  Post-IEEPA grid expansion: adding ', nrow(new_grid_pairs),
              ' product-country pairs (base rate only)')
      rates <- bind_rows(rates, new_grid_pairs)
    }
  }

  # 4. Apply Section 232 base tariff (blanket, chapter/heading)
  #    232 is defined by US Notes, not via product footnotes.
  #    Steel: chapters 72-73 (US Note 16, 9903.80-84)
  #    Aluminum: chapter 76 (US Note 19, 9903.85)
  #    Autos: heading 8703 + specific subheadings (US Note 25, 9903.94)
  #    Copper: specific headings in chapter 74
  if (is.null(s232_rates)) {
    s232_rates <- extract_section232_rates(ch99_data,effective_date=effective_date)
  }

  # Load heading-level 232 config from policy params
  s232_headings <- if (!is.null(pp)) pp$section_232_headings else NULL

  # Heading-program product lists are consumed by steps that run even when this
  # revision has no active 232 program (auto rebate 4b, deal overrides 4c,
  # annex guard, semiconductor carve-out) — initialize them OUTSIDE the guard
  # or a has_232=FALSE revision dies on "object 'auto_products' not found".
  auto_products <- character(0)
  copper_products <- character(0)
  wood_products <- character(0)
  mhd_products <- character(0)
  semi_products <- character(0)

  if (s232_rates$has_232) {
    # --- Identify covered products by prefix matching ---
    # Chapter-level: steel (72-73), aluminum (76)
    steel_products <- products %>%
      filter(substr(hts10, 1, 2) %in% STEEL_CHAPTERS) %>%
      pull(hts10)
    aluminum_products <- products %>%
      filter(substr(hts10, 1, 2) %in% ALUM_CHAPTERS) %>%
      pull(hts10)
    if(!is.null(s232_legacy_memberships)) {
      # U.S. notes 16(j)/(q) and 19(g)/(o) enumerate the primary products.
      # Being in chapter 72, 73 or 76 does not establish membership.
      primary <- s232_legacy_memberships[!s232_legacy_memberships$derivative,]
      steel_products <- unique(primary$hts10[primary$metal=='steel'])
      aluminum_products <- unique(primary$hts10[primary$metal=='aluminum'])
    }

    # Heading-level: autos, copper, etc.
    heading_product_lists <- list()

    if (!is.null(s232_headings)) {
      # Gate each heading config on whether its Ch99 program exists in this revision.
      # Programs added progressively: assembled autos at rev_6, parts at rev_11,
      # copper at rev_17, MHD/wood later. Check extracted rates + specific Ch99 codes.
      has_auto_parts_ch99 <- any(grepl('^9903\\.94\\.0[5-9]', ch99_data$ch99_code))
      heading_gates <- list(
        autos_passenger  = s232_rates$auto_rate > 0 || s232_rates$auto_has_deals,
        autos_light_trucks = s232_rates$auto_rate > 0 || s232_rates$auto_has_deals,
        auto_parts       = has_auto_parts_ch99,
        copper           = s232_rates$copper_rate > 0,
        softwood         = s232_rates$wood_rate > 0 || s232_rates$wood_furniture_rate > 0,
        wood_furniture   = s232_rates$wood_rate > 0 || s232_rates$wood_furniture_rate > 0,
        kitchen_cabinets = s232_rates$wood_rate > 0 || s232_rates$wood_furniture_rate > 0,
        mhd_vehicles     = s232_rates$mhd_rate > 0,
        mhd_parts        = s232_rates$mhd_rate > 0,
        buses            = s232_rates$mhd_rate > 0,
        semiconductors   = s232_rates$semi_rate > 0
      )

      for (tariff_name in names(s232_headings)) {
        # Check if this heading's Ch99 program is active in this revision
        gate_val <- heading_gates[[tariff_name]]
        if (!is.null(gate_val) && !gate_val) {
          message('  Skipping 232 heading "', tariff_name, '" — Ch99 entries not in this revision')
          next
        }

        cfg <- s232_headings[[tariff_name]]

        scope_evidence <- match_s232_heading_products(products, cfg, here())
        matched <- scope_evidence$products

        heading_product_lists[[tariff_name]] <- list(
          products = matched,
          scope_matches = scope_evidence$matches,
          scope_source = scope_evidence$source_path,
          scope_sha256 = scope_evidence$source_sha256,
          rate = cfg$default_rate %||% s232_rates$auto_rate,
          usmca_exempt = cfg$usmca_exempt %||% FALSE
        )

        if (grepl('auto|passenger|light_truck|auto_parts', tariff_name, ignore.case = TRUE)) {
          auto_products <- c(auto_products, matched)
        } else if (grepl('copper', tariff_name, ignore.case = TRUE)) {
          copper_products <- c(copper_products, matched)
        } else if (grepl('softwood|furniture|cabinet', tariff_name, ignore.case = TRUE)) {
          wood_products <- c(wood_products, matched)
        } else if (grepl('mhd|bus|mhd_parts', tariff_name, ignore.case = TRUE)) {
          mhd_products <- c(mhd_products, matched)
        } else if (grepl('semi', tariff_name, ignore.case = TRUE)) {
          semi_products <- c(semi_products, matched)
        }
      }
    }
    auto_products <- unique(auto_products)
    copper_products <- unique(copper_products)
    wood_products <- unique(wood_products)
    mhd_products <- unique(mhd_products)
    semi_products <- unique(semi_products)

    # Preserve extraction candidates before aggregate assumptions suppress them.
    heading_candidate_lists <- heading_product_lists

    # Note 39(a)(1)-(9) excludes semi articles from stacking with 232 autos,
    # auto parts, MHD, MHD parts, copper, aluminum, and steel. The auto_parts
    # HTS list (per US Note 33(g)) includes heading 8471 at the 4-digit level,
    # which overlaps with Note 39(b) scope (8471.50, 8471.80, 8473.30). Strip
    # semi products from non-semi heading lists so only the 25% semi rate
    # applies, and so auto_rebate doesn't inappropriately reduce semi rates.
    if (length(semi_products) > 0) {
      auto_products <- setdiff(auto_products, semi_products)
      copper_products <- setdiff(copper_products, semi_products)
      wood_products <- setdiff(wood_products, semi_products)
      mhd_products <- setdiff(mhd_products, semi_products)
      for (nm in setdiff(names(heading_product_lists), 'semiconductors')) {
        heading_product_lists[[nm]]$products <- setdiff(
          heading_product_lists[[nm]]$products,
          semi_products
        )
      }
    }

    # Exclude blanket chapter products from heading lists — a Ch73 steel spring
    # that matches auto_parts prefixes is still a steel product (gets blanket 232
    # rate, not auto rebate/USMCA auto content share).
    blanket_chapters <- c(STEEL_CHAPTERS, ALUM_CHAPTERS)
    n_auto_pre <- length(auto_products)
    auto_products <- auto_products[!substr(auto_products, 1, 2) %in% blanket_chapters]
    if (length(auto_products) < n_auto_pre) {
      message('  Excluded ', n_auto_pre - length(auto_products),
              ' blanket chapter products from auto_products')
    }
    # Same strip for MHD parts (upstream fix, Budget-Lab-Yale: Russia steel-
    # surcharge leak): ch73 steel springs listed in mhd_parts otherwise
    # survive into heading_program_products and the annex override's
    # "keep prior rate for heading-program products" arm preserves a stale
    # blanket rate (e.g. Russia 200%) instead of annex treatment.
    n_mhd_pre <- length(mhd_products)
    mhd_products <- mhd_products[!substr(mhd_products, 1, 2) %in% blanket_chapters]
    if (length(mhd_products) < n_mhd_pre) {
      message('  Excluded ', n_mhd_pre - length(mhd_products),
              ' blanket chapter products from mhd_products')
    }

    n_steel <- length(steel_products)
    n_alum <- length(aluminum_products)
    n_auto <- length(auto_products)
    n_copper <- length(copper_products)
    n_wood <- length(wood_products)
    n_mhd <- length(mhd_products)
    n_semi <- length(semi_products)
    message('  Section 232 coverage: ', n_steel, ' steel + ', n_alum,
            ' aluminum + ', n_auto, ' auto + ', n_copper, ' copper + ',
            n_wood, ' wood + ', n_mhd, ' MHD + ', n_semi, ' semi products')

    # --- Build product-level 232 rate lookup from heading configs ---
    # Each heading config specifies its own rate. Build an hts10 -> rate mapping.
    heading_product_rate <- map_dfr(names(heading_product_lists), function(nm) {
      cfg <- heading_product_lists[[nm]]
      if (length(cfg$products) == 0) return(tibble())
      tibble(
        hts10 = cfg$products,
        heading_232_rate = cfg$rate,
        heading_usmca_exempt = isTRUE(cfg$usmca_exempt),
        # Which §232 ACTION this heading belongs to. EO 14289 discriminates
        # between actions (auto excludes steel/aluminum), so the program name has
        # to survive the max() collapse below rather than being discarded.
        heading_program = nm
      )
    })
    # If a product appears in multiple heading tariffs, take the max rate
    if (nrow(heading_product_rate) > 0) {
      heading_product_rate <- heading_product_rate %>%
        group_by(hts10) %>%
        summarise(
          # Keep the program that supplied the winning rate, so attribution
          # follows the rate actually applied.
          heading_program = heading_program[which.max(heading_232_rate)],
          heading_232_rate = max(heading_232_rate),
          heading_usmca_exempt = any(heading_usmca_exempt),
          .groups = 'drop'
        )
    }

    # --- Semi per-HTS10 qualifying_share and end-use blending (Note 39(b), (d)) ---
    # Note 39(b) scopes semi articles via three HTS headings plus a per-article
    # TPP/DRAM tech gate; qualifying_share approximates the fraction of each
    # HTS10's imports meeting the gate. Note 39(d) enumerates end-use carve-outs
    # (9903.79.03-.09) that can't be HTS-scoped; end_use_exemption_share
    # approximates the dutied fraction. Both default to uncalibrated upper
    # bounds (qualifying_share = 1.0, end_use_exemption_share = 0).
    if (length(semi_products) > 0 && nrow(heading_product_rate) > 0 &&
        !is.null(s232_headings) && !is.null(s232_headings$semiconductors)) {
      semi_cfg <- s232_headings$semiconductors
      end_use_share <- semi_cfg$end_use_exemption_share %||% 0

      qs_data <- tibble(hts10 = character(), qualifying_share = numeric())
      qs_path <- semi_cfg$qualifying_shares_file %||% ''
      if (nchar(qs_path) > 0) {
        qs_full <- here(qs_path)
        if (file.exists(qs_full)) {
          qs_data <- suppressMessages(
            read_csv(qs_full, col_types = cols(
              hts10 = col_character(),
              qualifying_share = col_double()
            ))
          ) %>% select(hts10, qualifying_share)
        } else {
          stop('Configured semiconductor qualifying-share source missing: ', qs_full)
        }
      }

      heading_product_rate <- model_s232_semiconductors(
        heading_product_rate, semi_products, qs_data, end_use_share)

      message('  Semi scaling: ', nrow(qs_data), ' per-HTS10 shares loaded; ',
              'end_use_exemption_share = ', end_use_share)
    }

    # --- Build per-country rate lookup ---
    country_232 <- tibble(country = countries) %>%
      mutate(
        steel_exempt = map_lgl(country, ~is_232_exempt(.x, s232_rates$steel_exempt)),
        alum_exempt = map_lgl(country, ~is_232_exempt(.x, s232_rates$aluminum_exempt)),
        auto_exempt = map_lgl(country, ~is_232_exempt(.x, s232_rates$auto_exempt)),
        steel_rate = if_else(steel_exempt, 0, s232_rates$steel_rate),
        aluminum_rate = if_else(alum_exempt, 0, s232_rates$aluminum_rate),
        auto_rate = if_else(auto_exempt, 0, s232_rates$auto_rate),
        # The heading that supplied each rate, carried beside it from extraction.
        # An exempt country owes nothing, so it cites nothing.
        steel_ch99 = if_else(steel_exempt, NA_character_,
                             s232_rates$steel_rate_ch99 %||% NA_character_),
        alum_ch99  = if_else(alum_exempt, NA_character_,
                             s232_rates$aluminum_rate_ch99 %||% NA_character_)
      )

    # --- Apply HTS-extracted 232 country overrides (e.g., UK deal rates) ---
    # These come from country-specific ch99 entries (e.g., 9903.81.94 UK steel 25%)
    # The heading moves WITH the rate — a country on a deal rate must cite the
    # deal heading, not the blanket one it no longer pays.
    for (cty in names(s232_rates$steel_country_overrides)) {
      idx <- country_232$country == cty
      if (any(idx)) {
        country_232$steel_rate[idx] <- s232_rates$steel_country_overrides[[cty]]
        country_232$steel_ch99[idx] <-
          s232_rates$steel_country_override_ch99[[cty]] %||% NA_character_
      }
    }
    for (cty in names(s232_rates$aluminum_country_overrides)) {
      idx <- country_232$country == cty
      if (any(idx)) {
        country_232$aluminum_rate[idx] <- s232_rates$aluminum_country_overrides[[cty]]
        country_232$alum_ch99[idx] <-
          s232_rates$aluminum_country_override_ch99[[cty]] %||% NA_character_
      }
    }

    # --- Apply config-level 232 country exemptions (TRQ/quota agreements) ---
    # These override rates for countries with trade agreements not encoded in HTS JSON.
    # Date-bounded: only apply if this revision's effective_date is before the expiry.
    rev_date <- as.Date(effective_date)
    n_config_overrides <- 0L
    for (exemption in pp$S232_COUNTRY_EXEMPTIONS) {
      # Check if exemption is active for this revision date
      is_active <- is.null(exemption$expiry_date) || rev_date < exemption$expiry_date
      if (!is_active) next

      affected <- country_232$country %in% exemption$countries
      if (!any(affected)) next
      if(!is.null(s232_legacy_source$pre_march) && rev_date<as.Date('2025-03-12') && exemption$rate==0) {
        for(metal in exemption$applies_to) {
          allowed<-unlist(s232_legacy_source$pre_march$model_zero_country_candidates[[metal]])
          if(any(!country_232$country[affected] %in% allowed))
            stop('Configured zero model rate lacks a source-backed ',metal,' country/quota exception')
        }
      }

      if ('steel' %in% exemption$applies_to) {
        country_232$steel_rate[affected] <- exemption$rate
      }
      if ('aluminum' %in% exemption$applies_to) {
        country_232$aluminum_rate[affected] <- exemption$rate
      }
      n_config_overrides <- n_config_overrides + sum(affected)
    }
    if (n_config_overrides > 0) {
      message('  232 country exemptions (config): ', n_config_overrides,
              ' country overrides applied for ', effective_date)
    }

    n_steel_countries <- sum(country_232$steel_rate > 0)
    n_alum_countries <- sum(country_232$aluminum_rate > 0)
    n_auto_countries <- sum(country_232$auto_rate > 0)
    # "Steel: 0 countries" reads like missing duty but is expected from
    # 2026-04-06: the annex proclamation moved steel and aluminum off the
    # blanket per-country path onto the annex tiers, so this counter goes to
    # zero while the duty is applied by the annex override further down. Say
    # which path is carrying it rather than leave a bare zero to be misread.
    .blanket_metals_empty <- n_steel_countries == 0 && n_alum_countries <= 1
    message('  Steel: ', n_steel_countries, ' countries, aluminum: ',
            n_alum_countries, ', auto: ', n_auto_countries,
            if (.blanket_metals_empty)
              ' (blanket metal path empty — annex regime carries steel/aluminum)'
            else '')

    # --- Resolve each heading program to its Chapter 99 heading, and CHECK it ---
    # The declaration lives in config and is therefore capable of going stale, so
    # it is validated against the schedule this revision actually publishes: the
    # heading must exist, and its published rate must equal the configured rate.
    # Anything else is reported here and contributes no attribution.
    #
    # This is where a retired heading surfaces. 9903.78.01 (copper, note 36) was
    # withdrawn when the April 2026 annex proclamation folded copper into the
    # 9903.82 range, but resources/s232_copper_products.csv still names it — so
    # in 2026 revisions copper resolves to 'absent_in_revision' and is reported,
    # rather than citing a heading that no longer exists.
    .s232_program_headings <- resolve_s232_program_headings(
      s232_headings, ch99_data, params = pp)
    if (nrow(.s232_program_headings) > 0) {
      .ph_bad <- .s232_program_headings %>%
        filter(status != 'ok') %>%
        # Keep `country`: dropping it made a Taiwan-only heading absence print
        # as "wood_furniture unusable" while the program's default heading was
        # present and fully applied — a false contradiction with the extractor's
        # own "Wood furniture/cabinets 232: 25%" line.
        distinct(program, country, ch99_code, config_rate, published_rate, status)
      # Programs already gated OFF for this revision (e.g. semiconductors before
      # 2026-01-16) are skipped by the apply loop with their own message —
      # re-reporting their headings as unusable is noise.
      if (exists('heading_gates', inherits = FALSE)) {
        .gated_off <- names(heading_gates)[!vapply(heading_gates, isTRUE, logical(1))]
        .ph_bad <- .ph_bad %>% filter(!program %in% .gated_off)
      }
      if (nrow(.ph_bad) > 0) {
        message('  ch99_src_232: ', nrow(.ph_bad),
                ' §232 program heading(s) unusable in this revision — ',
                paste(sprintf('%s%s->%s (%s)', .ph_bad$program,
                              ifelse(is.na(.ph_bad$country), '',
                                     paste0('[', .ph_bad$country, ']')),
                              .ph_bad$ch99_code %||% 'NA', .ph_bad$status),
                      collapse = '; '))
      }
    }

    # --- Update rate_232 for products already in rates ---
    # Join heading-level rates for auto/copper/etc products
    if (nrow(heading_product_rate) > 0) {
      rates <- rates %>%
        left_join(heading_product_rate, by = 'hts10', relationship = 'many-to-one')
    } else {
      rates$heading_232_rate <- 0
      rates$heading_usmca_exempt <- FALSE
      rates$heading_program <- NA_character_
    }

    rates <- rates %>%
      left_join(
        country_232 %>% select(country, steel_rate_232 = steel_rate,
                               alum_rate_232 = aluminum_rate,
                               steel_ch99_232 = steel_ch99,
                               alum_ch99_232 = alum_ch99),
        by = 'country',
        relationship = 'many-to-one'
      ) %>%
      mutate(
        chapter = substr(hts10, 1, 2),
        # Heading-level 232 rate (auto/MHD/copper/wood). USMCA share-based
        # reduction for CA/MX applied later in step 7, not zeroed here.
        heading_rate_adj = case_when(
          is.na(heading_232_rate) | heading_232_rate == 0 ~ 0,
          TRUE ~ heading_232_rate
        ),
        blanket_232 = case_when(
          hts10 %in% steel_products ~ coalesce(steel_rate_232, 0),
          hts10 %in% aluminum_products ~ coalesce(alum_rate_232, 0),
          heading_rate_adj > 0 ~ heading_rate_adj,
          TRUE ~ 0
        ),
        rate_232 = pmax(rate_232, blanket_232),
        # Attribute the blanket duty to its §232 ACTION. Primary-chapter metal
        # duty is steel or aluminum by chapter; heading duty follows the program
        # that supplied the rate. Without this the action columns stay 0 on
        # primary-chapter rows and EO 14289 precedence cannot be evaluated.
        .action_col = case_when(
          blanket_232 <= 0                ~ NA_character_,
          hts10 %in% steel_products     ~ 'rate_232_steel',
          hts10 %in% aluminum_products      ~ 'rate_232_aluminum',
          TRUE ~ unname(S232_HEADING_PROGRAM_ACTION[heading_program])
        ),
        rate_232_steel = if_else(!is.na(.action_col) & .action_col == 'rate_232_steel',
                                 pmax(rate_232_steel, blanket_232), rate_232_steel),
        rate_232_aluminum = if_else(!is.na(.action_col) & .action_col == 'rate_232_aluminum',
                                    pmax(rate_232_aluminum, blanket_232), rate_232_aluminum),
        rate_232_auto = if_else(!is.na(.action_col) & .action_col == 'rate_232_auto',
                                pmax(rate_232_auto, blanket_232), rate_232_auto),
        rate_232_copper = if_else(!is.na(.action_col) & .action_col == 'rate_232_copper',
                                  pmax(rate_232_copper, blanket_232), rate_232_copper),
        # Unmapped heading programs land in _other rather than vanishing, so a
        # newly added §232 action is still carried and visibly attributed.
        rate_232_other = if_else(
          blanket_232 > 0 & (is.na(.action_col) | .action_col == 'rate_232_other') &
            !(hts10 %in% c(steel_products, aluminum_products)),
          pmax(rate_232_other, blanket_232), rate_232_other),
        # Track which products have USMCA-eligible 232 headings (for step 7).
        # Only when the heading rate is actually used — blanket chapter products
        # (steel/aluminum) get their rate from the blanket, not the heading,
        # so they should NOT inherit the heading's USMCA eligibility.
        s232_usmca_eligible = coalesce(heading_usmca_exempt, FALSE) & heading_rate_adj > 0 &
          !(hts10 %in% c(steel_products, aluminum_products))
      ) %>%
      # FORWARD Chapter 99 attribution. Record the heading that carries this
      # program's duty at the moment the duty is applied, while the program is
      # still known. Downstream, resolve_ch99_codes() reads this instead of
      # searching for a heading whose published rate happens to match the number
      # it computed — the inference that put the vehicles heading 9903.94.01 on
      # auto PARTS rows, since 9903.94.05 carries the same 25%.
      #
      # Only programs whose declared heading was VALIDATED against this
      # revision's schedule contribute (see resolve_s232_program_headings); a
      # program whose heading is absent or repriced yields NA and is reported,
      # never guessed. Steel and aluminum are excluded here because their rate
      # comes from the country blanket, not from a heading program.
      mutate(
        ch99_src_232 = case_when(
          blanket_232 <= 0            ~ NA_character_,
          hts10 %in% steel_products ~ steel_ch99_232,
          hts10 %in% aluminum_products  ~ alum_ch99_232,
          !is.na(heading_program) ~
            s232_heading_for(heading_program, country, .s232_program_headings),
          TRUE                        ~ NA_character_)
      ) %>%
      select(-steel_rate_232, -alum_rate_232, -chapter, -blanket_232, -.action_col,
             -heading_232_rate, -heading_usmca_exempt, -heading_program,
             -heading_rate_adj, -steel_ch99_232, -alum_ch99_232)

    # --- Add rows for 232-covered products NOT yet in rates ---
    # Include countries with any active 232 program (steel/aluminum/auto + heading
    # programs like copper/wood/MHD that don't have per-country exemptions)
    s232_country_codes <- country_232 %>%
      filter(steel_rate > 0 | aluminum_rate > 0 | auto_rate > 0) %>%
      pull(country)
    if (nrow(heading_product_rate) > 0) {
      s232_country_codes <- unique(c(s232_country_codes, countries))
    }

    all_heading_products <- if (nrow(heading_product_rate) > 0) heading_product_rate$hts10 else character(0)
    all_232_products <- unique(c(steel_products, aluminum_products, all_heading_products))
    existing_pairs_232 <- rates %>%
      filter(hts10 %in% all_232_products, country %in% s232_country_codes) %>%
      select(hts10, country)

    new_232_base <- products %>%
      filter(hts10 %in% all_232_products) %>%
      select(hts10, base_rate) %>%
      mutate(base_rate = coalesce(base_rate, 0))

    if (nrow(heading_product_rate) > 0) {
      new_232_base <- new_232_base %>%
        left_join(heading_product_rate, by = 'hts10', relationship = 'many-to-one')
    } else {
      new_232_base$heading_232_rate <- 0
      new_232_base$heading_usmca_exempt <- FALSE
      new_232_base$heading_program <- NA_character_
    }

    new_232_pairs <- new_232_base %>%
      tidyr::expand_grid(country = s232_country_codes) %>%
      anti_join(existing_pairs_232, by = c('hts10', 'country')) %>%
      left_join(
        country_232 %>% select(country, steel_rate_232 = steel_rate,
                               alum_rate_232 = aluminum_rate,
                               steel_ch99_232 = steel_ch99,
                               alum_ch99_232 = alum_ch99),
        by = 'country',
        relationship = 'many-to-one'
      ) %>%
      mutate(
        chapter = substr(hts10, 1, 2),
        heading_rate_adj = case_when(
          is.na(heading_232_rate) | heading_232_rate == 0 ~ 0,
          TRUE ~ heading_232_rate
        ),
        rate_232 = case_when(
          hts10 %in% steel_products ~ coalesce(steel_rate_232, 0),
          hts10 %in% aluminum_products ~ coalesce(alum_rate_232, 0),
          heading_rate_adj > 0 ~ heading_rate_adj,
          TRUE ~ 0
        ),
        s232_usmca_eligible = coalesce(heading_usmca_exempt, FALSE) & heading_rate_adj > 0 &
          !(hts10 %in% c(steel_products, aluminum_products)),
        # Same action attribution as the existing-pairs branch above; these rows
        # are §232-only, so rate_232 IS the action rate.
        .action_col = case_when(
          rate_232 <= 0                   ~ NA_character_,
          hts10 %in% steel_products     ~ 'rate_232_steel',
          hts10 %in% aluminum_products      ~ 'rate_232_aluminum',
          TRUE ~ unname(S232_HEADING_PROGRAM_ACTION[heading_program])
        ),
        rate_232_steel    = if_else(!is.na(.action_col) & .action_col == 'rate_232_steel',    rate_232, 0),
        rate_232_aluminum = if_else(!is.na(.action_col) & .action_col == 'rate_232_aluminum', rate_232, 0),
        rate_232_auto     = if_else(!is.na(.action_col) & .action_col == 'rate_232_auto',     rate_232, 0),
        rate_232_copper   = if_else(!is.na(.action_col) & .action_col == 'rate_232_copper',   rate_232, 0),
        rate_232_other    = if_else(
          rate_232 > 0 & (is.na(.action_col) | .action_col == 'rate_232_other') &
            !(hts10 %in% c(steel_products, aluminum_products)), rate_232, 0),
        rate_301 = 0, rate_ieepa_recip = 0, rate_ieepa_fent = 0, rate_s122 = 0,
        rate_section_201 = 0, rate_other = 0,
        # Same forward attribution as the existing-pairs branch. These rows are
        # §232-only, so rate_232 IS the action rate and the heading follows the
        # same three sources: metal blanket, metal deal, or heading program.
        ch99_src_232 = case_when(
          rate_232 <= 0               ~ NA_character_,
          hts10 %in% steel_products ~ steel_ch99_232,
          hts10 %in% aluminum_products  ~ alum_ch99_232,
          !is.na(heading_program) ~
            s232_heading_for(heading_program, country, .s232_program_headings),
          TRUE                        ~ NA_character_)
      ) %>%
      filter(rate_232 > 0) %>%
      select(-steel_rate_232, -alum_rate_232, -chapter, -.action_col,
             -heading_232_rate, -heading_usmca_exempt, -heading_program,
             -heading_rate_adj, -steel_ch99_232, -alum_ch99_232)

    if (nrow(new_232_pairs) > 0) {
      message('  Adding ', nrow(new_232_pairs), ' product-country pairs for 232-only duties')
      rates <- bind_rows(rates, new_232_pairs)
    }
  }

  # statutory_rate_232 is set after step 4c (deal overrides) — see below.

  # 4b. Apply Section 232 auto rebate
  #     Reduces effective 232 rate on auto/vehicle products by a credit reflecting
  #     US assembly content: effective_rate -= rebate_rate * us_assembly_share.
  #     Applied before metal content scaling (step 5) and before USMCA (step 7).
  auto_rebate_cfg <- if (!is.null(pp)) pp$auto_rebate else NULL
  rebate_rate <- if (!is.null(auto_rebate_cfg)) auto_rebate_cfg$rebate_rate %||% 0 else 0
  assembly_share <- if (!is.null(auto_rebate_cfg)) auto_rebate_cfg$us_assembly_share %||% 0 else 0
  us_auto_content_share <- if (!is.null(auto_rebate_cfg)) auto_rebate_cfg$us_auto_content_share %||% 1 else 1
  rebate_deduction <- rebate_rate * assembly_share

  # Track the rebate per row so it can be added back when statutory_rate_232 is
  # captured at step 4c. The rebate is a MODELLED credit for US assembly content
  # — an importer-specific fact we approximate — not a published rate, so it
  # must not end up inside a column called "statutory". It was: statutory was
  # snapshotted AFTER this deduction, so autos carried 25% - 1.24pp = 23.76% as
  # their "statutory" rate. No Chapter 99 heading is published at 23.76%, so
  # heading matching failed on every auto row and fell through to the default.
  if (!'.auto_rebate_applied' %in% names(rates)) rates$.auto_rebate_applied <- 0

  if (rebate_deduction > 0 && length(auto_products) > 0) {
    rates <- rates %>%
      mutate(
        .auto_rebate_applied = if_else(
          hts10 %in% auto_products & rate_232 > 0,
          pmin(rebate_deduction, rate_232),   # pmax(0) below can clip it
          .auto_rebate_applied
        ),
        rate_232 = if_else(
          hts10 %in% auto_products & rate_232 > 0,
          pmax(rate_232 - rebate_deduction, 0),
          rate_232
        )
      )
    n_rebated <- sum(rates$hts10 %in% auto_products & rates$rate_232 > 0)
    message('  Auto rebate: -', round(rebate_deduction * 100, 2),
            'pp on ', n_rebated, ' auto product-country pairs',
            if (us_auto_content_share < 1) paste0(
              '; USMCA content share: ', us_auto_content_share * 100, '%') else '')
    # No citation_key: the rebate is a MODELLED credit for US assembly content,
    # not a published rate. Recording that absence is the point — it surfaces in
    # duty_ledger_uncited() rather than passing as though it were law.
    rates <- record_duty(rates, '4b', 's232', 'rate_232', 'auto_rebate_deduction',
                         ch99_code_col = 'ch99_code_232')
  }

  # 4c. Apply country-specific 232 deal rates (floor/surcharge)
  #     Auto deals: EU/Japan/Korea get 15% floor on vehicles; UK gets +7.5% surcharge.
  #     Wood deals: UK 10% floor on softwood, EU/Japan/Korea 15% floor on furniture/cabinets.
  #     Floor mechanism: effective_232 = max(floor_rate - base_rate, 0)
  #     Surcharge mechanism: effective_232 = surcharge_rate (flat)
  #     These override the blanket 232 rate set in step 4 for deal countries.
  n_deal_overrides <- 0L

  # Snapshot rate_232 before the deal overrides so the auto-rebate credit can be
  # invalidated on any row a deal REPLACES. See the clearing block after 4c.
  .rate_232_pre_deal <- rates$rate_232

  # Helper: convert ISO country code to Census code(s), expanding EU to 27 members
  iso_to_census_vec <- function(iso_code) {
    if (iso_code == 'EU') {
      return(if (!is.null(pp)) names(pp$eu27_codes) else EU27_CODES)
    }
    census <- ISO_TO_CENSUS[iso_code]
    if (is.na(census)) return(character(0))
    as.character(census)
  }

  # Captured for Phase 2 normalized emit. Each entry is a (program,
  # census_codes, deal_products, rate, rate_type) tuple — the same shape
  # the inline deal-application loop consumes. The emitter walks this
  # same list so layer-3 deal rows match denorm's coverage exactly with
  # no risk of drift in the product/country expansion logic.
  denorm_state_s232_deals <- list()

  # Apply auto deal rates
  if (nrow(s232_rates$auto_deal_rates) > 0 && length(auto_products) > 0) {
    for (i in seq_len(nrow(s232_rates$auto_deal_rates))) {
      deal <- s232_rates$auto_deal_rates[i, ]
      census_codes <- iso_to_census_vec(deal$country)
      if (length(census_codes) == 0) next

      # Determine which products this deal covers (vehicles vs parts)
      # Split auto_products into vehicles and parts using heading config prefixes
      auto_vehicles_cfg <- s232_headings[grepl('passenger|light_truck', names(s232_headings), ignore.case = TRUE)]
      vehicle_prefixes <- unlist(lapply(auto_vehicles_cfg, function(x) x$prefixes))
      deal_products <- if (deal$program == 'auto_parts') {
        # Parts: products NOT in passenger vehicle/light truck prefixes
        if (length(vehicle_prefixes) > 0) {
          veh_pattern <- paste0('^(', paste(vehicle_prefixes, collapse = '|'), ')')
          auto_products[!grepl(veh_pattern, auto_products)]
        } else {
          auto_products
        }
      } else {
        # Vehicles: only passenger vehicle/light truck prefix products
        if (length(vehicle_prefixes) > 0) {
          veh_pattern <- paste0('^(', paste(vehicle_prefixes, collapse = '|'), ')')
          auto_products[grepl(veh_pattern, auto_products)]
        } else {
          auto_products
        }
      }

      if (length(deal_products) > 0) {
        denorm_state_s232_deals[[length(denorm_state_s232_deals) + 1L]] <- list(
          program       = deal$program,
          census_codes  = census_codes,
          deal_products = deal_products,
          rate          = deal$rate,
          rate_type     = deal$rate_type
        )
      }

      if (deal$rate_type == 'floor') {
        rates <- rates %>%
          mutate(
            rate_232 = if_else(
              hts10 %in% deal_products & country %in% census_codes,
              pmax(deal$rate - base_rate, 0),
              rate_232
            )
          )
      } else {
        # surcharge: flat additional rate
        rates <- rates %>%
          mutate(
            rate_232 = if_else(
              hts10 %in% deal_products & country %in% census_codes,
              deal$rate,
              rate_232
            )
          )
      }
      n_affected <- sum(rates$hts10 %in% deal_products & rates$country %in% census_codes)
      n_deal_overrides <- n_deal_overrides + n_affected
    }
  }

  # Apply wood deal rates
  # Identify wood product sets by heading config
  wood_softwood_products <- character(0)
  wood_furn_products <- character(0)
  if (!is.null(s232_headings)) {
    for (nm in names(s232_headings)) {
      cfg <- s232_headings[[nm]]
      prefixes <- unlist(cfg$prefixes)
      if (length(prefixes) == 0) next
      pattern <- paste0('^(', paste(prefixes, collapse = '|'), ')')
      matched <- products %>% filter(grepl(pattern, hts10)) %>% pull(hts10)
      if (grepl('softwood', nm, ignore.case = TRUE)) {
        wood_softwood_products <- c(wood_softwood_products, matched)
      } else if (grepl('furniture|cabinet', nm, ignore.case = TRUE)) {
        wood_furn_products <- c(wood_furn_products, matched)
      }
    }
  }
  all_wood_products <- unique(c(wood_softwood_products, wood_furn_products))

  if (nrow(s232_rates$wood_deal_rates) > 0 && length(all_wood_products) > 0) {
    for (i in seq_len(nrow(s232_rates$wood_deal_rates))) {
      deal <- s232_rates$wood_deal_rates[i, ]
      census_codes <- iso_to_census_vec(deal$country)
      if (length(census_codes) == 0) next

      # Capture for emit (same shape as auto deals).
      denorm_state_s232_deals[[length(denorm_state_s232_deals) + 1L]] <- list(
        program       = deal$program %||% 'wood_deal',
        census_codes  = census_codes,
        deal_products = all_wood_products,
        rate          = deal$rate,
        rate_type     = deal$rate_type
      )

      # Wood deals apply to all wood products (softwood + furniture/cabinets)
      if (deal$rate_type == 'floor') {
        rates <- rates %>%
          mutate(
            rate_232 = if_else(
              hts10 %in% all_wood_products & country %in% census_codes,
              pmax(deal$rate - base_rate, 0),
              rate_232
            )
          )
      } else {
        rates <- rates %>%
          mutate(
            rate_232 = if_else(
              hts10 %in% all_wood_products & country %in% census_codes,
              deal$rate,
              rate_232
            )
          )
      }
      n_affected <- sum(rates$hts10 %in% all_wood_products & rates$country %in% census_codes)
      n_deal_overrides <- n_deal_overrides + n_affected
    }
  }

  if (n_deal_overrides > 0) {
    message('  232 deal rates (floor/surcharge): ', n_deal_overrides,
            ' product-country pairs overridden')
  }
  rates <- record_duty(rates, '4c', 's232', 'rate_232', 'country_deal_floor_or_surcharge',
                       citation_key = 'proc_10908_autos_2025', note_ref = 'note_33',
                       ch99_code_col = 'ch99_code_232')

  # A deal REPLACES rate_232 — `max(floor - base_rate, 0)` for a floor, or a flat
  # surcharge — so the auto-rebate credit computed against the step-4 auto rate
  # no longer describes anything in it. Adding it back below would produce a rate
  # that corresponds to no published heading AND would breach the floor the deal
  # exists to impose.
  #
  # Measured on 2025_rev_25 / 8482400000 / DE before this clearing:
  #   4b       rate_232           0.250000 -> 0.237625   (-1.2375pp rebate)
  #   4c       rate_232           0.237625 -> 0.092000   (EU 15% floor: 0.15 - 0.058)
  #   4c-post  statutory_rate_232 0.092000 -> 0.104375   <- stale credit re-added
  # giving a statutory total of 16.24% against a 15% ceiling. The deal rate IS
  # the statutory rate for these rows; there is nothing to add back.
  if ('.auto_rebate_applied' %in% names(rates)) {
    .deal_replaced <- abs(rates$rate_232 - .rate_232_pre_deal) > 1e-12 &
      rates$.auto_rebate_applied > 0
    if (any(.deal_replaced)) {
      rates$.auto_rebate_applied[.deal_replaced] <- 0
      message('  Auto rebate invalidated on ', sum(.deal_replaced),
              ' row(s) where a 232 deal replaced the rate it was computed against')
    }
  }
  rm(.rate_232_pre_deal)

  # Save the post-deal STATUTORY §232 rate.
  #
  # Deal rates (step 4c) are legal — the UK 25% override and the EU/JP/KR 15%
  # floors are published terms — so they belong in the statutory rate. The auto
  # rebate is NOT: it is a modelled credit for US assembly content, an
  # importer-specific fact we approximate. It is added back here so the column
  # holds a rate that a Chapter 99 heading can actually be published at.
  #
  # This is what made ch99_code_232 unresolvable for autos. statutory was
  # captured after the rebate, so it read 25% - 1.24pp = 23.76%; no heading is
  # published at 23.76%, so every auto row failed to match and took the default.
  # 36,960 rows in 2025_rev_14 and 38,992 in 2026_rev_13.
  #
  # rate_232 itself is unchanged — the rebate stays in the EFFECTIVE rate, which
  # is where it belongs. The generated other_params.yaml still sets
  # auto_rebate_rate = 0 so ETRs does not re-apply it.
  # Derivatives (set in step 5) update this column for their products.
  rates <- rates %>%
    mutate(statutory_rate_232 = rate_232 + coalesce(.auto_rebate_applied, 0),
           modeled_auto_credit = coalesce(.auto_rebate_applied, 0),
           modeled_auto_assembly_share = if_else(modeled_auto_credit > 0, assembly_share, 0),
           modeled_auto_credit_rate = if_else(modeled_auto_credit > 0, rebate_rate, 0)) %>%
    select(-.auto_rebate_applied)
  rates <- record_duty(rates, '4c-post', 's232', 'statutory_rate_232',
                       'auto_rebate_addback', ch99_code_col = 'ch99_code_232')

  # 5. Apply Section 232 derivative tariff + metal content scaling
  #    Aluminum derivatives (9903.85.04/.07/.08) and steel derivatives (9903.81.89-93)
  #    are metal-containing articles outside primary chapters. Tariff applies to
  #    metal content only; per-type scaling uses steel_share or aluminum_share.
  # Build heading product list from prefixes of ACTIVE headings only.
  # Products matching active heading prefixes are non-metal 232 programs
  # and should NOT be metal-scaled even if they also match derivative prefixes.
  # Inactive headings' products should be treated as pure derivatives.
  all_heading_hts10 <- character(0)
  if (!is.null(s232_headings)) {
    for (nm in names(s232_headings)) {
      # Skip inactive headings — their products are pure derivatives
      gate_val <- heading_gates[[nm]]
      if (!is.null(gate_val) && !gate_val) next
      cfg <- s232_headings[[nm]]
      # Reuse the same exact source resolver as the original heading pass.
      # An empty exact-list match must not widen to configured prefixes here.
      matched <- match_s232_heading_products(products, cfg, here())$products

      all_heading_hts10 <- c(all_heading_hts10, matched)
    }
    all_heading_hts10 <- unique(all_heading_hts10)
  }
  result <- apply_232_derivatives(rates, products, ch99_data, s232_rates, countries,
                                   heading_products = all_heading_hts10,
                                   policy_params = pp,
                                   effective_date = effective_date,
                                   source_derivatives = if(!is.null(s232_legacy_memberships))
                                     s232_legacy_derivative_projection(s232_legacy_memberships) else NULL)
  rates <- result$rates
  deriv_matched <- result$deriv_matched
  # Captured for Phase 2 normalized emit. See apply_232_derivatives() for
  # the semantics: one row per hts10 in the heading/derivative overlap,
  # carrying the post-pmax rate and the assigned deriv_type. The emitter
  # writes these as per-hts10 layer-3 override rows so the resolver
  # stops applying metal scaling to heading-overlap products.
  denorm_state_heading_overlap <- result$heading_overlap %||% tibble(
    hts10 = character(0), rate_232 = numeric(0), deriv_type = character(0)
  )

  # 5b. Scale copper heading products by copper content share.
  #     The copper proclamation applies the tariff "upon the value of the copper
  #     content," not the full customs value. This parallels ETRs' per-type metal
  #     scaling. After scaling, is_copper_heading flags these products so stacking
  #     rules use copper_share for nonmetal_share.
  if (length(copper_products) > 0 && 'copper_share' %in% names(rates)) {
    rates <- rates %>%
      mutate(
        is_copper_heading = hts10 %in% copper_products,
        rate_232 = if_else(
          is_copper_heading & rate_232 > 0,
          rate_232 * copper_share,
          rate_232
        )
      )
    n_scaled <- sum(rates$is_copper_heading & rates$rate_232 > 0)
    message('  Copper heading metal scaling: ', n_scaled, ' product-country pairs')
  } else {
    rates$is_copper_heading <- FALSE
  }

  # 5c. Section 232 annex rate override (April 2026 proclamation)
  #     Date-gated: only applies to revisions on/after the annex effective date.
  #     Overrides single-rate 232 with per-annex rates after the old pipeline has
  #     finished assigning rates. Scope and tier rates come from the selected
  #     revision PDF/JSON. Missing/unparsed source data stops this path.
  s232_note16_source <- NULL
  s232_note16_matches <- NULL
  s232_note16_projection <- NULL
  annex_cfg <- if (!is.null(pp)) pp$S232_ANNEXES else NULL
  if (!is.null(annex_cfg) && as.Date(effective_date) >= annex_cfg$effective_date) {
    # Proc. 11021 clauses (2)-(5), implemented in note 16(c): use the
    # selected revision's complete enumeration. Neither a whole-chapter guess
    # nor an old derivative list can fill an absent membership.
    source(here('src','section232_revision.R'))
    s232_note16_source <- load_s232_note16_source(revision_id)
    if (!isTRUE(s232_note16_source$active_regime)) stop('Annex-era note 16 headings missing')
    s232_note16_matches <- s232_note16_matches(s232_note16_source,products$hts10)
    s232_note16_projection <- s232_note16_projection(s232_note16_source,s232_note16_matches,products$hts10)
    annex_map <- s232_note16_projection
    message('  Revision note 16: ',nrow(s232_note16_matches),' list memberships; ',
      sum(annex_map$s232_note16_status=='candidate_requires_legal_predicates'),' products')
    # The source rates replace copied tier constants. Keep model parameters
    # (utilization, content and credits) in their existing separate pathway.
    for (tier in s232_note16_source$ordinary_tiers) {
      label <- c('9903.82.02'='annex_1a','9903.82.09'='annex_1b','9903.82.10'='annex_3')[[tier$reporting_code]]
      field <- if(tier$formula_kind=='column1_floor') 'floor_rate' else 'rate'
      annex_cfg$annexes[[label]][[field]] <- tier$rate
    }
    if (nrow(annex_map)>0) {
      # Include newly enumerated products even if every prior authority was
      # absent. Seed no duty: the source tier below assigns it explicitly.
      missing <- products %>% filter(hts10 %in% s232_note16_matches$hts10) %>%
        select(hts10,base_rate) %>% tidyr::expand_grid(country=countries) %>%
        anti_join(rates %>% select(hts10,country),by=c('hts10','country')) %>%
        zero_fill_authority_rates()
      if(nrow(missing)) rates <- bind_rows(rates,missing)
      .ki <- match(rates$hts10,annex_map$hts10)
      rates$s232_annex <- annex_map$s232_annex[.ki]
      rates$s232_metal <- annex_map$s232_metal[.ki]
      rates$s232_note16_lists_json <- annex_map$s232_note16_lists_json[.ki]
      rates$s232_note16_metals_json <- annex_map$s232_note16_metals_json[.ki]
      rm(.ki)

      # Override rate_232 by annex.
      #
      # Important scoping: the April 2026 proclamation governs Section 232
      # *steel / aluminum / copper* tariffs only — Annex II's "removed from
      # scope" language means removed from the metal-derivative tariff, not
      # from the auto (9903.94), MHD (9903.74), wood (9903.76), copper deal
      # (9903.78), or semiconductor (9903.79) authorities, which are separate.
      # The annex CSV lists 8703/8704/8708 (autos/parts), 74xx (copper), etc.
      # in Annex I-B/II because the proclamation removes them from the
      # *metal-derivative* tariff — but those products carry separate
      # heading-program rates set in step 4/4c. Guard heading-program products
      # so the annex override doesn't silently wipe their heading rate (e.g.
      # an EU passenger car under 9903.94.51 should keep max(0.15 - base, 0),
      # not be zeroed by the annex_2 catch-all).
      heading_program_products <- unique(c(auto_products, mhd_products,
                                           wood_products, semi_products))
      rates <- rates %>%
        mutate(rate_232 = case_when(
          hts10 %in% heading_program_products ~ rate_232,
          s232_annex == 'annex_2' ~ 0,
          s232_annex == 'annex_1a' ~ annex_cfg$annexes$annex_1a$rate,
          s232_annex == 'annex_1b' ~ annex_cfg$annexes$annex_1b$rate,
          s232_annex == 'annex_3' ~ pmax(0, annex_cfg$annexes$annex_3$floor_rate - base_rate),
          TRUE ~ rate_232
        ))

      # 9903.82.01 zero-metal-content carve-out (Note 16(a)):
      # Articles classified in subdivision (c) lists that do not contain any
      # aluminum, steel, or copper get "No change" — 0% additional 232 duty.
      # Modeled as an aggregate fraction of imports under each annex product
      # that contain zero metal. Dormant by default (aggregate_share = 0 in
      # policy_params.yaml); a non-zero share scales rate_232 down by
      # (1 - share). Calibration would require per-prefix metal-content
      # trade data (CBP entry summaries, industry surveys); none today.
      # heading_program_products are skipped (defined above for the override).
      zmc_cfg <- annex_cfg$exemptions$zero_metal_content
      zmc_share <- as.numeric(zmc_cfg$aggregate_share %||% 0)
      if (!is.na(zmc_share) && zmc_share > 0) {
        zmc_annexes <- paste0('annex_', unlist(zmc_cfg$applies_to %||% c('1a', '1b', '3')))
        rates <- rates %>%
          mutate(rate_232 = if_else(
            !(hts10 %in% heading_program_products) & s232_annex %in% zmc_annexes,
            rate_232 * (1 - zmc_share),
            rate_232
          ))
        message('  zero_metal_content exemption applied: share=', zmc_share,
                ', annexes=', paste(zmc_annexes, collapse = ','))
      }

      # Note 16(d) scope comes from its heading references, including mixed
      # metal list membership. The aggregate model retains its qualification
      # assumption; a UK origin alone does not establish the smelt/pour test.
      uk_code <- get_country_constants()$CTY_UK %||% '4120'
      rates$modeled_s232_uk_metal_origin_qualification <- 0
      for(code in c('9903.82.04','9903.82.05')) {
        h <- Filter(function(h) h$code==code,s232_note16_source$headings)[[1]]
        scope <- unique(s232_note16_matches$hts10[s232_note16_matches$list_id %in% unlist(h$list_ids)])
        hit <- rates$country==uk_code & rates$hts10 %in% scope & !rates$hts10 %in% heading_program_products
        rates$rate_232[hit] <- h$rate
        rates$modeled_s232_uk_metal_origin_qualification[hit] <- 1
      }

      # Country-specific 232 surcharges preserved under the annex regime.
      # Per the April 2026 proclamation, Russian aluminum remains subject to
      # the 200% rate from Proc 10522 across Annex I-A, I-B, and III. Annex II
      # is out of scope (products removed from S232 entirely).
      # Applied as pmax() so the surcharge wins over the annex tier rate.
      country_surcharges <- annex_cfg$country_surcharges %||% list()
      if (length(country_surcharges) > 0) {
        for (surcharge in country_surcharges) {
          countries_vec   <- as.character(surcharge$countries)
          applies_annexes <- surcharge$applies_to %||% c('annex_1a', 'annex_1b', 'annex_3')
          metal_types     <- surcharge$metal_types %||% c('steel', 'aluminum', 'copper')
          rate_s          <- surcharge$rate
          if (is.null(rate_s) || !is.finite(rate_s) || rate_s <= 0) next

          # Use every current list membership. Legacy derivative prefixes
          # and whole chapters cannot expand a source-specific surcharge.
          type_hts10 <- unique(s232_note16_matches$hts10[s232_note16_matches$metal %in% metal_types])
          if (length(type_hts10) == 0) next

          rates <- rates %>%
            mutate(rate_232 = if_else(
              country %in% countries_vec &
                s232_annex %in% applies_annexes &
                hts10 %in% type_hts10,
              pmax(rate_232, rate_s),
              rate_232
            ))

          n_applied <- sum(
            rates$country %in% countries_vec &
            rates$s232_annex %in% applies_annexes &
            rates$hts10 %in% type_hts10
          )
          message('  Annex country surcharge: ', paste(countries_vec, collapse = ','),
                  ' @ ', round(rate_s * 100, 0), '% on ', n_applied,
                  ' product-country pairs (', paste(metal_types, collapse = '/'),
                  ' × ', paste(applies_annexes, collapse = '/'), ')')
        }
      }

      # Annex III sunset: after sunset_date, products move to I-B rate
      sunset <- annex_cfg$annexes$annex_3$sunset_date
      if (!is.null(sunset) && as.Date(effective_date) > as.Date(sunset)) {
        # NA-safe gates: s232_annex is NA on non-annex products, and a bare
        # `s232_annex == 'annex_3'` yields NA (not FALSE) there — if_else() would
        # then return NA rate_232 for EVERY non-annex product, which poisons
        # stacking (total_additional -> NA) and used to be silently coalesced to 0
        # by enforce_rate_schema(). Same defect class as upstream 050f2acf
        # (their annex_1c framework gate); this block is dormant until the
        # 2027-12-31 sunset, so the bug was latent rather than shipped.
        rates <- rates %>%
          mutate(
            rate_232 = if_else(!is.na(s232_annex) & s232_annex == 'annex_3',
                                annex_cfg$annexes$annex_1b$rate, rate_232),
            s232_annex = if_else(!is.na(s232_annex) & s232_annex == 'annex_3',
                                 'annex_1b', s232_annex)
          )
        message('  Annex III sunset: reclassified to I-B')
      }

      # Update statutory_rate_232 to reflect annex overrides
      # Proc. 10908 clause (1), FR 2025-05930: the automobile heading rate
      # remains 25% unless a legal deal replaces it. The metals annex does not
      # replace a heading-program rate with its assembly-credit projection.
      rates <- rates %>%
        mutate(statutory_rate_232 = if_else(
          !is.na(s232_annex) & !(hts10 %in% heading_program_products),
          rate_232, statutory_rate_232))

      n_by_annex <- rates %>% filter(!is.na(s232_annex), rate_232 > 0) %>% count(s232_annex)
      if (nrow(n_by_annex) > 0) {
        message('  Annex rate override: ',
                paste(n_by_annex$s232_annex, n_by_annex$n, sep = '=', collapse = ', '))
      }

      # 5d. Subdivision (r) blend for EU/JP/KR certified auto parts.
      # Per US Note 33(r), EU/JP/KR auto parts not in subdivision (g) and not in
      # Note 38(i) MHD parts get a 15% floor (9903.94.45/.55/.65) when the
      # importer certifies them for US production/repair. Note 33(r)(1) carves
      # them out from the metals annex (9903.82.02/.04-.19). Without this blend
      # the post-annex tracker leaves the annex_1b 25% rate on these products
      # for EU/JP/KR (~10pp over the legal cap on the certified share).
      #
      # Three-way mix per import:
      #   1. fta_share  — qualifies under EO 14345 (Japan) or KORUS (Korea); per
      #      Note 33(r) line 35836-37 these are EXEMPT from .44/.45/.54/.55/.64/.65
      #      additional duty AND from the metals annex via the (r)(1) carve-out.
      #      rate_232 = 0; only base_rate (FTA-special) applies.
      #   2. certified_share × (1 - fta_share) — non-FTA but certified for US
      #      production. rate_232 = pmax(floor - base, 0).
      #   3. (1 - certified_share) × (1 - fta_share) — non-FTA, uncertified.
      #      Falls under annex_1b (or whatever rate_232 was set to in step 5c).
      #
      # All shares default to 0 (dormant). IEEPA reciprocal is left at the
      # existing annex-zeroed value, matching subdivision (g) treatment today.
      subdiv_r_cfg <- pp$auto_parts_subdivision_r
      certified_share <- subdiv_r_cfg$certified_share %||% 0
      fta_shares_cfg <- subdiv_r_cfg$fta_exempt_shares %||% list()
      any_fta_share <- any(unlist(fta_shares_cfg) > 0)

      if (!is.null(subdiv_r_cfg) && (certified_share > 0 || any_fta_share)) {
        subdiv_r_path <- here(subdiv_r_cfg$products_file)
        if (!file.exists(subdiv_r_path)) {
          stop('auto_parts_subdivision_r$products_file not found: ', subdiv_r_path)
        }
        subdiv_r <- read_csv(subdiv_r_path, col_types = cols(.default = col_character()))
        prefixes <- unique(subdiv_r$hts_prefix)
        if (length(prefixes) > 0) {
          eligible_pattern <- paste0('^(', paste(prefixes, collapse = '|'), ')')
          applies_iso <- subdiv_r_cfg$applies_to_iso %||% c('EU', 'JP', 'KR')
          floor_rate_r <- subdiv_r_cfg$floor_rate %||% 0.15

          # Build per-country fta_share lookup (census-coded)
          iso_to_census_vec <- function(iso) {
            if (iso == 'EU') {
              if (!is.null(pp)) names(pp$eu27_codes) else EU27_CODES
            } else {
              as.character(pp$ISO_TO_CENSUS[iso])
            }
          }
          fta_share_by_country <- map_dfr(applies_iso, function(iso) {
            cs <- iso_to_census_vec(iso)
            cs <- cs[!is.na(cs) & nchar(cs) > 0]
            tibble(country = cs,
                    fta_share = fta_shares_cfg[[iso]] %||% 0)
          })
          census_codes <- unique(fta_share_by_country$country)

          rates <- rates %>%
            left_join(fta_share_by_country, by = 'country',
                      relationship = 'many-to-one') %>%
            mutate(
              fta_share = coalesce(fta_share, 0),
              .subdiv_r = grepl(eligible_pattern, hts10) & country %in% census_codes,
              .floor_232 = pmax(floor_rate_r - base_rate, 0),
              .non_fta_blend = certified_share * .floor_232 +
                                (1 - certified_share) * rate_232,
              rate_232 = if_else(
                .subdiv_r,
                fta_share * 0 + (1 - fta_share) * .non_fta_blend,
                rate_232
              ),
              modeled_subdivision_r_certified_share = if_else(.subdiv_r, certified_share, 0),
              modeled_subdivision_r_fta_share = if_else(.subdiv_r, fta_share, 0)
            ) %>%
            select(-.subdiv_r, -.floor_232, -.non_fta_blend, -fta_share)

          n_blended <- sum(grepl(eligible_pattern, rates$hts10) & rates$country %in% census_codes)
          fta_summary <- paste(
            sprintf('%s=%.2f', names(fta_shares_cfg %||% list()),
                    unlist(fta_shares_cfg %||% list())),
            collapse = ', '
          )
          message('  Subdiv (r) blend: certified_share=', certified_share,
                  '; fta_exempt_shares=[', fta_summary,
                  '] applied to ', n_blended, ' product-country pairs (',
                  length(prefixes), ' prefixes × ', length(census_codes), ' countries)')
        }
      }
    } else {
      rates$s232_annex <- NA_character_
    }
  } else {
    rates$s232_annex <- NA_character_
  }

  # Captured for Phase 2 normalized emit. Annex classification is
  # per-hts10 (country-invariant — classification comes from hts8
  # prefix + downstream deriv-list fallback). Expose a distinct
  # (hts10, s232_annex) tibble so the emitter can attach the column
  # to products_base and the resolver sees the same value in its
  # wide tibble, letting apply_stacking_rules honor the post-annex
  # nonmetal_share=0 override uniformly across both code paths.
  # Capture BOTH the annex classification AND the post-annex rate_232.
  # Products with a non-NA s232_annex had their rate_232 overridden by
  # the annex block above (e.g., annex_1a → 0.25, annex_1b → 0.25,
  # annex_2 → 0, annex_3 → floor). The emitter needs the overridden
  # rate to emit layer-3 override rows — without this, the layer-3
  # derivative or blanket statutory_rate (set before the annex step)
  # would be used, giving the wrong rate for annex-era revisions.
  # We take max(rate_232) across countries so the non-exempt pmax value
  # wins (same approach as heading_overlap).
  # Use median(rate_232) for the same reason as heading_overlap — outlier
  # countries (Belarus/Russia sanctions) skew max() far above the typical
  # annex-overridden rate. Median returns the rate that >90% of countries
  # receive, which is the correct value for the layer-3 override row.
  denorm_state_product_annex <- rates %>%
    filter(rate_232 > 0 | !is.na(s232_annex)) %>%
    group_by(hts10) %>%
    summarise(
      s232_annex      = first(na.omit(s232_annex)),
      annex_rate_232  = median(rate_232, na.rm = TRUE),
      .groups = 'drop'
    ) %>%
    mutate(annex_rate_232 = if_else(is.na(s232_annex), NA_real_, annex_rate_232))

  # 6. Revision-specific China Section 301. Official note tables, exact-code
  # exceptions and entry windows replace the undated list/MAX path for the
  # audited 2025-2026 horizon. Missing or conflicting extraction stops a build.
  s301_source <- NULL
  s301_source_matches <- NULL
  if (grepl('^202[56]_', revision_id)) {
    source(here('src','section301_revision.R'))
    s301_source <- load_s301_revision_source(revision_id)
    s301_exclusions <- s301_exclusion_candidates(s301_source,products$hts10,
      paste0(as.Date(effective_date),'T23:59:59Z'))
    s301_source_matches <- s301_revision_matches(s301_source, products$hts10,
      paste0(as.Date(effective_date),'T23:59:59Z'))
    s301_lookup <- s301_revision_lookup(s301_source_matches %>% filter(program=='china_technology_transfer'))
    # Aggregate modeling assumes the described product condition is met. Emit
    # that assumption. A shipment result must establish the condition instead.
    existing_china <- rates$hts10[rates$country == CTY_CHINA]
    new_301_products <- setdiff(s301_lookup$hts10,existing_china)
    if(CTY_CHINA %in% countries && length(new_301_products)) {
      rates <- bind_rows(rates,products %>% filter(hts10 %in% new_301_products) %>%
        select(hts10,base_rate) %>% mutate(country=CTY_CHINA,
          rate_232=0,rate_301=0,rate_ieepa_recip=0,rate_ieepa_fent=0,
          rate_s122=0,rate_section_201=0,rate_other=0))
    }
    if(!'ch99_src_301' %in% names(rates)) rates$ch99_src_301 <- NA_character_
    rates <- rates %>% select(-any_of(c('s301_scope_requires_inputs','modeled_s301_scope_share'))) %>%
      left_join(s301_lookup,by='hts10',relationship='many-to-one') %>%
      mutate(rate_301=if_else(country==CTY_CHINA,coalesce(blanket_301,0),rate_301),
        ch99_src_301=if_else(country==CTY_CHINA,src_301,ch99_src_301),
        s301_scope_requires_inputs=country==CTY_CHINA & coalesce(s301_scope_requires_inputs,FALSE),
        modeled_s301_scope_share=if_else(country==CTY_CHINA & !is.na(blanket_301),modeled_s301_scope_share,NA_real_)) %>%
      select(-blanket_301,-src_301)
    rates <- record_duty(rates,'6a','s301','rate_301','s301_revision_note_scopes',
      citation_key='s301_active',ch99_code_col='ch99_src_301')
    message('  Section 301: ',nrow(s301_lookup),' exact products from ',revision_id,
      '; ',sum(s301_lookup$s301_scope_requires_inputs),' require product facts')
  } else {
  # Historical fixture path before the audited 2025-2026 horizon.
  # 6. Apply Section 301 as blanket tariff for China
  #     301 products are defined by US Note 20/21/31 product lists (Federal Register).
  #     Like 232, these are NOT referenced via product footnotes for most products.
  #     Source: USITC "China Tariffs" reference document (hts.usitc.gov).
  #
  #     Scope note: This blanket step is intentionally limited to the China
  #     Section 301 product lists maintained in resources/s301_product_lists.csv.
  #     It does not use 9903.89.xx, which belongs to the separate large civil
  #     aircraft dispute with the EU/UK and is assumed suspended from 2021 onward
  #     for the current series horizon.
  s301_products_path <- here('resources', 's301_product_lists.csv')
  if (!file.exists(s301_products_path)) {
    stop('s301_product_lists.csv not found at ', s301_products_path,
         '\nSection 301 is a major tariff authority — cannot build without product lists.')
  }
  if (file.exists(s301_products_path)) {
    s301_products <- read_csv(s301_products_path, col_types = cols(
      hts8 = col_character(), list = col_character(), ch99_code = col_character()
    ))

    # Get active 301 ch99 codes from this revision's Ch99 data
    # Use SECTION_301_RATES config for reliable rate values
    s301_rate_lookup <- if (!is.null(pp)) {
      pp$SECTION_301_RATES
    } else {
      tibble(ch99_pattern = character(), s301_rate = numeric())
    }

    # Filter to 301 codes present in this revision's Ch99 data, excluding any
    # that are marked as suspended (e.g. 9903.88.16 List 4B since rev_4).
    # The HTS JSON retains suspended entries with their original rate but adds
    # "[Compiler's note: provision suspended.]" to the description.
    active_301_codes <- ch99_data %>%
      filter(ch99_code %in% s301_rate_lookup$ch99_pattern) %>%
      filter(!grepl('provision suspended', description, ignore.case = TRUE)) %>%
      pull(ch99_code) %>%
      unique()

    suspended_301 <- setdiff(
      ch99_data$ch99_code[ch99_data$ch99_code %in% s301_rate_lookup$ch99_pattern],
      active_301_codes
    )
    if (length(suspended_301) > 0) {
      message('  Section 301: excluding suspended codes: ',
              paste(suspended_301, collapse = ', '))
    }

    if (length(active_301_codes) > 0) {
      # Build HTS8 -> 301 rate lookup:
      # Take MAX(s301_rate) across all ch99 codes per HTS8. For the 8 products
      # that appear on both Trump-era (9903.88.xx) and Biden-era (9903.91.xx)
      # lists, Biden rates are always >= the corresponding Trump rate, so MAX
      # achieves the correct supersession. This matches Tariff-ETRs, which
      # partitions products into exclusive rate buckets (one rate per HS10).
      s301_lookup <- s301_products %>%
        filter(ch99_code %in% active_301_codes) %>%
        inner_join(
          s301_rate_lookup,
          by = c('ch99_code' = 'ch99_pattern')
        ) %>%
        group_by(hts8) %>%
        # Keep the heading that SUPPLIES the max rate (forward attribution —
        # ch99_code_301 used to be NA on every rated row because this
        # summarise threw the heading away). Deterministic on rate ties.
        arrange(desc(s301_rate), ch99_code, .by_group = TRUE) %>%
        summarise(blanket_301 = first(s301_rate),
                  src_301 = first(ch99_code), .groups = 'drop')

      if (nrow(s301_lookup) > 0) {
        # Update rate_301 for existing China product-country pairs.
        # ch99_src_301 records the heading that supplied the applied rate at
        # the moment it is applied (forward attribution, same contract as
        # ch99_src_232) — set BEFORE the pmax so the comparison is against the
        # pre-blanket rate.
        if (!'ch99_src_301' %in% names(rates)) rates$ch99_src_301 <- NA_character_
        rates <- rates %>%
          mutate(hts8 = substr(hts10, 1, 8)) %>%
          left_join(s301_lookup, by = 'hts8', relationship = 'many-to-one') %>%
          mutate(
            blanket_301 = coalesce(blanket_301, 0),
            ch99_src_301 = if_else(
              country == CTY_CHINA & blanket_301 > 0 & blanket_301 >= rate_301,
              src_301, ch99_src_301
            ),
            rate_301 = if_else(
              country == CTY_CHINA,
              pmax(rate_301, blanket_301),
              rate_301
            )
          ) %>%
          select(-hts8, -blanket_301, -src_301)

        # Add 301-only rows for China products NOT yet in rates
        # (products with no other Ch99 duties but subject to 301)
        s301_hts8_codes <- s301_lookup$hts8
        s301_hts10 <- products %>%
          mutate(hts8 = substr(hts10, 1, 8)) %>%
          filter(hts8 %in% s301_hts8_codes) %>%
          pull(hts10)

        existing_china <- rates %>%
          filter(country == CTY_CHINA) %>%
          pull(hts10)

        new_301_products <- setdiff(s301_hts10, existing_china)

        if (CTY_CHINA %in% countries && length(new_301_products) > 0) {
          new_301_pairs <- products %>%
            filter(hts10 %in% new_301_products) %>%
            select(hts10, base_rate) %>%
            mutate(
              base_rate = coalesce(base_rate, 0),
              hts8 = substr(hts10, 1, 8),
              country = CTY_CHINA
            ) %>%
            left_join(s301_lookup, by = 'hts8', relationship = 'many-to-one') %>%
            mutate(
              rate_232 = 0, rate_ieepa_recip = 0,
              rate_ieepa_fent = 0, rate_s122 = 0, rate_section_201 = 0, rate_other = 0,
              rate_301 = coalesce(blanket_301, 0),
              ch99_src_301 = src_301
            ) %>%
            filter(rate_301 > 0) %>%
            select(-hts8, -blanket_301, -src_301)

          if (nrow(new_301_pairs) > 0) {
            message('  Adding ', nrow(new_301_pairs),
                    ' product-country pairs for 301-only duties')
            rates <- bind_rows(rates, new_301_pairs)
          }
        }

        n_301_total <- sum(rates$country == CTY_CHINA & rates$rate_301 > 0)
        message('  Section 301 blanket: ', nrow(s301_lookup), ' HTS8 codes, ',
                n_301_total, ' China product-country pairs with 301 rate')
        # §301 was the only duty-writing step with no ledger record at all.
        rates <- record_duty(rates, '6a', 's301', 'rate_301',
                             's301_blanket_lists',
                             citation_key = 's301_active',
                             ch99_code_col = 'ch99_src_301')
      }
    }
  }

  }

  # 6b. Apply Section 122 blanket tariff (non-discriminatory, all countries)
  #     Section 122 (Trade Act of 1974) is a uniform tariff applied after SCOTUS
  #     invalidated IEEPA. Product exemptions from Annex II list; 232 mutual
  #     exclusion handled by apply_stacking_rules().
  #     Section 122 has a 150-day statutory limit; gate on expiry unless finalized.
  s122_rates <- extract_section122_rates(ch99_data)

  s122_in_force <- TRUE
  if (!is.null(pp$SECTION_122) && !pp$SECTION_122$finalized) {
    s122_in_force <- (as.Date(effective_date) >= pp$SECTION_122$effective_date &&
                      as.Date(effective_date) <= pp$SECTION_122$expiry_date)
  }

  if (s122_rates$has_s122 && !s122_in_force) {
    message('  Section 122 expired (', pp$SECTION_122$expiry_date, ') — not applied')
  }

  # Captured for Phase 2 normalized emit. The s122 in_force flag, the
  # rate, and the exempt HTS8 list are the only inputs the emitter needs
  # to reconstruct layer 2 (per-country rate) + layer 3 (blanket) +
  # layer 4 (HTS8 exemptions) for section_122. Sourced from the same
  # extracted s122_rates and resources/s122_exempt_products.csv that
  # this block consumes — guaranteeing parity with the denorm rate path
  # without re-implementing the in_force gate or the exemption load.
  denorm_state_s122 <- list(
    in_force    = s122_rates$has_s122 && s122_in_force,
    rate        = if (s122_rates$has_s122) s122_rates$s122_rate else 0,
    exempt_hts8 = character(0)
  )

  if (s122_rates$has_s122 && s122_in_force) {
    s122_rate <- s122_rates$s122_rate

    # Identified production revisions use their full note, including exact
    # statistical suffixes. Legacy fixtures retain the explicit local source.
    if(grepl('^202[56]_',revision_id)) {
      s122_source <- load_s122_revision_source(revision_id)
      if(!identical(as.numeric(s122_source$rate),as.numeric(s122_rate)))
        stop('Section 122 PDF/heading rate mismatch')
      s122_exemptions <- s122_exemptions_from_source(s122_source)
      denorm_state_s122$source <- s122_source
    } else {
      s122_exempt_path <- here('resources','s122_exempt_products.csv')
      if(!file.exists(s122_exempt_path)) stop('Section 122 exemption source missing')
      s122_exemptions <- read_csv(s122_exempt_path,col_types=cols(.default=col_character()))
    }
    s122_exemptions <- s122_scope_rows(s122_exemptions)
    # CSMS 67844987: subdivision (iii) is description/use-limited; (iv) is
    # GN6-conditional. Preserve these predicates in normalized output. The
    # legacy model's shares are separate from shipment exemption eligibility.
    s122_exempt_hts8 <- s122_exemptions$scope_code
    denorm_state_s122$exempt_hts8 <- s122_exempt_hts8
    denorm_state_s122$exemptions <- s122_exemptions
    denorm_state_s122$modeled_exemptions <- tibble(
      hts10 = products$hts10,
      exemption_share = s122_exempt_share(products$hts10,exemptions=s122_exemptions)
    ) %>% filter(hts10 %in% s122_match_exemptions(products$hts10,s122_exemptions)$hts10)
    if (length(s122_exempt_hts8) > 0) {
      message('  Section 122 exempt products: ', length(s122_exempt_hts8), ' source product codes (precision preserved)')
    }

    # Set rate_s122 for all existing rows.
    #
    # Port of upstream cf0a709b: the exempt list is NOT uniformly unconditional.
    # Note 2(aa)(iv) (541 hts8, heading 9903.03.05) exempts civil aircraft and
    # parts only where they "otherwise meet the criteria of general note 6" — a USE
    # test. Applying it full-line, as this did, exempted every non-aviation entry
    # on those lines and understated §122 by ~$800M/month. s122_exempt_share()
    # returns 1.0 for the unconditional groups and the MEASURED per-HTS10
    # utilization share for the conditional one.
    rates <- rates %>%
      mutate(rate_s122 = s122_rate * (1 - s122_exempt_share(hts10,exemptions=s122_exemptions)))

    # Add s122-only rows for products not yet in rates.
    # Coverage is now "share < 1", not "not on the exempt list": a GN 6
    # conditional line is only PARTIALLY exempt, so it still owes duty on the
    # non-certified share and must get its pairs materialized. Filtering on list
    # membership (the old test) would have silently dropped those.
    s122_country_rates <- tibble(
      country = countries,
      blanket_rate = s122_rate
    )
    prod_share <- s122_exempt_share(products$hts10,exemptions=s122_exemptions)
    partial_hts10 <- products$hts10[prod_share < 1]
    rates <- add_blanket_pairs(rates, products, partial_hts10, s122_country_rates,
                               'rate_s122', 'Section 122 duties')
    # add_blanket_pairs assigns the flat blanket rate; re-apply the share so the
    # newly added GN 6 rows carry their partial rate rather than the full 10%.
    rates <- rates %>%
      mutate(rate_s122 = s122_rate * (1 - s122_exempt_share(hts10,exemptions=s122_exemptions)))

    n_with_s122 <- sum(rates$rate_s122 > 0)
    n_partial <- sum(prod_share > 0 & prod_share < 1)
    rates <- record_duty(rates, '6b', 's122', 'rate_s122', 's122_blanket',
                         citation_key = 'proc_s122_2026',
                         ch99_code_col = 'ch99_code_s122')
    message('  Section 122: ', round(s122_rate * 100), '% on ',
            format(n_with_s122, big.mark = ','), ' product-country pairs (',
            sum(prod_share >= 1), ' HTS10 fully exempt, ', n_partial,
            ' GN 6 use-conditional at measured utilization)')
  }

  # 6b1. Apply Section 201 (Trade Act §201 safeguard) tariffs.
  #      Currently models Solar 201 (Proc 9693 + Proc 10454, 9903.45.21–.25)
  #      on CSPV cells/modules. The 201 rate stacks on top of MFN, separate
  #      from 232/301/IEEPA. Canada is exempt under USMCA. Per-product
  #      coverage is in resources/s201_solar_products.csv.
  s201_results <- extract_section_201_rates(ch99_data, policy_params = pp,
                                            effective_date = effective_date)
  if (s201_results$has_s201) {
    s201_path <- here('resources', 's201_solar_products.csv')
    if (!file.exists(s201_path)) {
      message('  WARNING: s201_solar_products.csv not found — Section 201 rate not applied')
    } else {
      s201_products <- read_csv(s201_path,
                                 col_types = cols(hts10 = col_character()))

      # Coverage derived from the heading text, on top of the curated CSV.
      # Most §201 headings state their own reach — "provided for in subheading
      # 8450.11.00 or 8450.20.00" — usually on the unnumbered PARENT line while
      # the rate sits on the child. Reading only the CSV is why the safeguard
      # covered 3 HTS10s: solar, hand-listed. Solar's own scope is defined in
      # note 18 rather than the heading, so the CSV still carries it; the
      # extractor reports that as `by_note` instead of silently returning empty.
      if (exists('resolve_product_scope_hierarchical', mode = 'function') &&
          all(c('ch99_code', 'description') %in% names(ch99_data))) {
        derived <- tryCatch({
          sc <- resolve_product_scope_hierarchical(
            ch99_data %>%
              transmute(htsno = ch99_code,
                        indent = 1L,           # leaf rows; parents already merged
                        description = description),
            hts10 = unique(products$hts10))
          sc %>% filter(grepl('^9903\\.45\\.', htsno), n_products > 0)
        }, error = function(e) NULL)
        if (!is.null(derived) && nrow(derived) > 0) {
          extra <- unique(unlist(lapply(seq_len(nrow(derived)), function(i)
            covered_hts10(derived$description[i], unique(products$hts10)))))
          new_hts <- setdiff(extra, s201_products$hts10)
          if (length(new_hts) > 0) {
            s201_products <- bind_rows(
              s201_products,
              tibble(hts10 = new_hts, ch99_code = NA_character_))
            message('  §201 coverage from heading text: +', length(new_hts),
                    ' HTS10 beyond the curated list')
          }
        }
      }

      solar_rate <- s201_results$solar_rate
      s201_country_codes <- setdiff(countries, pp$country_codes$CTY_CANADA)

      # Set rate_section_201 for existing rows, and record WHICH §201 heading
      # covers each product while that is still known.
      #
      # ch99_code_s201 was previously sort(codes_s201)[1] — the alphabetically
      # first §201 heading in the revision, regardless of which one supplied the
      # rate. In 2025_rev_20 that is 9903.41.05, a Japanese-leather heading, so
      # every solar row was stamped with a leather provision. s201_products
      # already carries the covering heading per HTS10; use it.
      .s201_code_by_hts <- s201_products %>%
        filter(!is.na(ch99_code)) %>%
        distinct(hts10, .keep_all = TRUE) %>%
        select(hts10, .s201_code = ch99_code)
      rates <- rates %>%
        left_join(.s201_code_by_hts, by = 'hts10') %>%
        mutate(
          .s201_covered = hts10 %in% s201_products$hts10 &
            country %in% s201_country_codes,
          rate_section_201 = if_else(.s201_covered, solar_rate, rate_section_201),
          ch99_src_s201 = if_else(.s201_covered, .s201_code, ch99_src_s201)
        ) %>%
        select(-.s201_code, -.s201_covered)

      # Add 201-only rows for products not yet in rates
      s201_country_rates <- tibble(
        country = s201_country_codes,
        blanket_rate = solar_rate
      )
      rates <- add_blanket_pairs(rates, products, s201_products$hts10, s201_country_rates,
                                  'rate_section_201', 'Section 201 (solar)')

      # add_blanket_pairs creates NEW rows after the stamp above, so they carry
      # NA ch99_src_s201 — that was 2,193 of 2,910 rated §201 rows left without
      # a covering heading. Re-stamp the freshly added rows from the same map.
      rates <- rates %>%
        left_join(.s201_code_by_hts, by = 'hts10') %>%
        mutate(ch99_src_s201 = if_else(
          rate_section_201 > 0 & is.na(ch99_src_s201) & !is.na(.s201_code),
          .s201_code, ch99_src_s201)) %>%
        select(-.s201_code)

      n_with_s201 <- sum(rates$rate_section_201 > 0)
      message('  Section 201 (solar): ', round(solar_rate * 100, 1), '% on ',
              n_with_s201, ' product-country pairs (',
              nrow(s201_products), ' HTS10 covered, Canada exempt)')
      rates <- record_duty(rates, '6b2', 's201', 'rate_section_201', 's201_safeguard',
                           citation_key = 's201_safeguards', ch99_code_col = 'ch99_code_s201')
    }
  }

  # 6b2. Dense grid expansion for MFN-only pairs.
  #      After 232/301/s122/fent/IEEPA-recip passes, any (hts10, country) pair
  #      still missing is MFN-only. Surface them now so they receive the FTA/GSP
  #      utilization adjustment in step 6c and USMCA treatment in step 7,
  #      instead of being back-filled at step 9c with an unadjusted base_rate.
  #      Step 9c becomes a no-op in the common case; kept as defense-in-depth.
  local({
    existing_pairs <- rates %>% distinct(hts10, country)
    all_products_base <- products %>%
      select(hts10, base_rate) %>%
      mutate(base_rate = coalesce(base_rate, 0))
    new_pairs <- all_products_base %>%
      tidyr::expand_grid(country = countries) %>%
      anti_join(existing_pairs, by = c('hts10', 'country')) %>%
      mutate(
        rate_232 = 0, rate_301 = 0, rate_ieepa_recip = 0,
        rate_ieepa_fent = 0, rate_s122 = 0,
        rate_section_201 = 0, rate_other = 0,
        statutory_rate_232 = 0
      )
    if (nrow(new_pairs) > 0) {
      message('  Grid expansion (MFN-only): adding ', nrow(new_pairs),
              ' product-country pairs (base rate only)')
      rates <<- bind_rows(rates, new_pairs)
    }
  })

  # Save statutory rates for all non-232 authorities (pre-USMCA, pre-stacking).
  # 232 statutory rates are already saved as statutory_rate_232 in apply_232_derivatives().
  rates <- rates %>%
    mutate(
      statutory_rate_ieepa_recip = rate_ieepa_recip,
      statutory_rate_ieepa_fent  = rate_ieepa_fent,
      statutory_rate_301         = rate_301,
      # Note 2(aa)(iv), 9903.03.05; CSMS 67844987. GN6 utilization is
      # aggregate modeling, not evidence that this shipment meets GN6.
      statutory_rate_s122        = if (s122_rates$has_s122 && s122_in_force)
        s122_rates$s122_rate * (1 - s122_exempt_share(hts10, statutory = TRUE,exemptions=s122_exemptions)) else rate_s122,
      modeled_s122_exempt_share = if (s122_rates$has_s122 && s122_in_force)
        s122_exempt_share(hts10,exemptions=s122_exemptions) else 0,
      statutory_rate_section_201 = rate_section_201,
      statutory_rate_other       = rate_other
    )
  if ('s301_scope_requires_inputs' %in% names(rates)) {
    rates$s301_scope_requires_inputs <- coalesce(rates$s301_scope_requires_inputs,FALSE)
    rates$statutory_rate_301[rates$s301_scope_requires_inputs] <- NA_real_
  }
  # Maritime is independent of the China technology-transfer investigation.
  # Note 31(l)(i) expressly preserves 9903.92.10; 31(l)(ii)/(iii) can reach
  # other origins through Chinese components/ownership. The model assumes
  # product qualification; shipment statutory amounts remain unresolved.
  rates$rate_s301_maritime <- 0
  rates$statutory_rate_s301_maritime <- 0
  rates$modeled_s301_maritime_scope_share <- NA_real_
  rates$ch99_code_s301_maritime <- NA_character_
  if (!is.null(s301_source_matches)) {
    maritime <- s301_source_matches %>% filter(program=='maritime')
    for(code in unique(maritime$ch99_code)) {
      scope <- maritime %>% filter(ch99_code==code)
      applies <- rates$hts10 %in% scope$hts10 &
        (scope$country_scope[1]=='all' | rates$country==scope$country_scope[1])
      rates$rate_s301_maritime[applies] <- scope$rate[1]
      rates$statutory_rate_s301_maritime[applies] <- NA_real_
      rates$modeled_s301_maritime_scope_share[applies] <- 1
      rates$ch99_code_s301_maritime[applies] <- code
    }
  }

  # 6c. Apply MFN exemption shares (FTA/GSP preference adjustment)
  # Reduces statutory base_rate using HS2 x country exemption shares from Census
  # calculated duty data. Preserves statutory_base_rate for reference.
  # CA/MX excluded when USMCA product shares handle them at HTS10 level (step 7).
  rates <- rates %>%
    mutate(statutory_base_rate = base_rate)

  if (!is.null(mfn_exemption_shares) && nrow(mfn_exemption_shares) > 0) {
    exclude_usmca <- pp$MFN_EXEMPTION$exclude_usmca_countries
    usmca_countries <- c(CTY_CANADA, CTY_MEXICO)

    rates <- rates %>%
      mutate(hs2 = substr(hts10, 1, 2)) %>%
      left_join(
        mfn_exemption_shares %>% select(hs2, cty_code, exemption_share),
        by = c('hs2', 'country' = 'cty_code'),
        relationship = 'many-to-one'
      ) %>%
      mutate(
        exemption_share = coalesce(exemption_share, 0),
        # Skip CA/MX if configured (USMCA handles them in step 7)
        exemption_share = if_else(
          exclude_usmca & country %in% usmca_countries,
          0, exemption_share
        ),
        base_rate = base_rate * (1 - exemption_share),
        modeled_mfn_exemption_share = exemption_share
      ) %>%
      select(-hs2, -exemption_share)

    n_adjusted <- sum(rates$base_rate < rates$statutory_base_rate)
    message('  MFN exemption shares: adjusted base_rate for ', n_adjusted,
            ' product-country pairs')
    # TRADE-WEIGHTED discount, not a legal exemption. No citation_key by
    # design: it is a modelling adjustment, and the ledger must say so.
    rates <- record_duty(rates, '6c', 'base', 'base_rate',
                         'mfn_exemption_share_weighting')

    # 6d. Recompute IEEPA floor deduction against post-MFN base_rate.
    # Only for rows originally computed as floor-type (ieepa_type == 'floor').
    # Step 2 computed floor as max(0, floor_rate - statutory_base); now base_rate is
    # lower (after FTA/GSP preference in 6c), so the floor gap is wider.
    # Surcharge rows for floor countries (e.g. Swiss/LI outside framework window)
    # must NOT be recomputed — their rate is a flat surcharge, not a floor deduction.
    if ('modeled_ieepa_reciprocal_parameter' %in% names(rates) &&
        'ieepa_type' %in% names(rates)) {
      floor_mask <- coalesce(rates$ieepa_type=='floor',FALSE) &
        !coalesce(rates$modeled_ieepa_reciprocal_exempt,TRUE) &
        !coalesce(rates$modeled_ieepa_duty_free,TRUE) &
        coalesce(rates$base_rate<rates$statutory_base_rate,FALSE)
      if(any(floor_mask)) {
        rates$modeled_ieepa_reciprocal_rate[floor_mask] <- pmax(0,
          rates$modeled_ieepa_reciprocal_parameter[floor_mask]-rates$base_rate[floor_mask])
        rates$rate_ieepa_recip[floor_mask] <- rates$modeled_ieepa_reciprocal_rate[floor_mask]+
          rates$modeled_ieepa_country_eo_rate[floor_mask]
        message('  Floor recomputation: ',sum(floor_mask),' model rows using emitted action parameters')
      }
      rates <- record_duty(rates, '6d', 'ieepa_recip', 'rate_ieepa_recip',
        'floor_recompute_vs_weighted_base',citation_key='eo_14257_reciprocal',
        ch99_code_col='ch99_code_ieepa_recip')
    }

    # 6e. Recompute Annex III floor against post-MFN base_rate (same logic as 6d).
    if (!is.null(annex_cfg) && as.Date(effective_date) >= annex_cfg$effective_date &&
        's232_annex' %in% names(rates)) {
      annex3_mask <- !is.na(rates$s232_annex) & rates$s232_annex == 'annex_3' &
                     rates$base_rate < rates$statutory_base_rate
      if (any(annex3_mask)) {
        floor_val <- annex_cfg$annexes$annex_3$floor_rate
        # A floor says "total duty on this article is at least floor_val". It
        # must therefore be closed against the base it is expressed against:
        # the weighted base for the weighted rate, the STATUTORY base for the
        # statutory rate. Copying the weighted-derived value into the statutory
        # column (the previous behaviour) let the statutory total overshoot the
        # floor by up to 5.7pp on ~7,000 rows per revision, because the weighted
        # base is smaller and so leaves a wider gap to fill.
        #
        # Same defect class as the §232 auto-rebate credit at step 4c: a value
        # computed under one basis reused under another.
        rates$rate_232[annex3_mask] <-
          pmax(0, floor_val - rates$base_rate[annex3_mask])
        rates$statutory_rate_232[annex3_mask] <-
          pmax(0, floor_val - rates$statutory_base_rate[annex3_mask])
        message('  Annex III floor recomputation: updated ', sum(annex3_mask),
                ' pairs (weighted rate vs post-MFN base_rate; ',
                'statutory rate vs statutory_base_rate)')
      }
      # Writes a value derived from the TRADE-WEIGHTED base_rate into
      # statutory_rate_232 — a statutory column holding a weighted quantity.
      rates <- record_duty(rates, '6e', 's232', 'statutory_rate_232',
                           'annex3_floor_recompute_vs_weighted_base',
                           citation_key = 's232_annex_2026', note_ref = 'annex_3',
                           ch99_code_col = 'ch99_code_232')
    }

    # Drop transient ieepa_type column — not part of production output
    rates$ieepa_type <- NULL
  }

  # 7. Apply USMCA exemptions
  # TPC methodology: rate * (1 - usmca_share) for each CA/MX product.
  # If DataWeb SPI shares available (from download_usmca_dataweb.R), apply to ALL
  # CA/MX products — the share naturally handles eligibility (products that never
  # enter under USMCA have share ≈ 0, fully-claiming products have share ≈ 1).
  # Also applies to 232 auto/MHD products flagged s232_usmca_eligible (T1 fix).
  # Falls back to binary eligibility (S/S+ → zero rate) if shares not available.
  if (!is.null(usmca) && nrow(usmca) > 0) {
    rates <- rates %>%
      left_join(
        usmca %>% select(hts10, usmca_eligible),
        by = 'hts10',
        relationship = 'many-to-one'
      ) %>%
      mutate(usmca_eligible = coalesce(usmca_eligible, FALSE))

    # Refresh s232_usmca_eligible for annex-classified products (April 2026
    # proclamation). Step 4 set this flag from the pre-annex heading configs
    # (autos_passenger, autos_light_trucks, mhd_vehicles, auto_parts,
    # mhd_parts). Step 5c's annex restructuring pulls in additional products
    # outside those headings — without this refresh, an annex_1b product
    # that's S/S+ in the HTS special field but absent from the pre-annex
    # heading lists keeps s232_usmca_eligible = FALSE and gets the full
    # annex rate from CA/MX. Steel/aluminum chapters (72/73/76) are excluded
    # by design — they have no legal USMCA carve-out at any point. annex_2
    # zeros rate_232 entirely so eligibility is moot there.
    if ('s232_annex' %in% names(rates)) {
      rates <- rates %>%
        mutate(s232_usmca_eligible = if_else(
          coalesce(s232_annex %in% c('annex_1a', 'annex_1b', 'annex_3'), FALSE) &
            coalesce(usmca_eligible, FALSE) &
            !(substr(hts10, 1, 2) %in% c(STEEL_CHAPTERS, ALUM_CHAPTERS)),
          TRUE,
          coalesce(s232_usmca_eligible, FALSE)
        ))
    }

    if (!is.null(usmca_product_shares) && nrow(usmca_product_shares) > 0) {
      # Census SPI shares: apply to all CA/MX products.
      # Missing or zero-trade HTS10 pairs fall back to the HS8-level
      # value-weighted share (attr 'hs8_shares' from the value-weighted
      # loader branches) before defaulting to 0 — handles statistical
      # splits/concordance drift like 2709.00.20.10 (upstream extreme-eta
      # review item 6).
      hs8_shares <- attr(usmca_product_shares, 'hs8_shares')
      rates <- rates %>%
        left_join(
          usmca_product_shares,
          by = c('hts10', 'country' = 'cty_code'),
          relationship = 'many-to-one'
        )
      if (!is.null(hs8_shares) && nrow(hs8_shares) > 0) {
        n_na <- sum(is.na(rates$usmca_share) &
                      rates$country %in% c(CTY_CANADA, CTY_MEXICO))
        rates <- rates %>%
          mutate(.hs8 = substr(hts10, 1, 8)) %>%
          left_join(hs8_shares,
                    by = c('.hs8' = 'hts8', 'country' = 'cty_code'),
                    relationship = 'many-to-one') %>%
          mutate(usmca_share = coalesce(usmca_share, usmca_share_hs8)) %>%
          select(-.hs8, -usmca_share_hs8)
        n_filled <- n_na - sum(is.na(rates$usmca_share) &
                                 rates$country %in% c(CTY_CANADA, CTY_MEXICO))
        if (n_filled > 0) {
          message('  USMCA shares: HS8 fallback filled ', n_filled,
                  ' of ', n_na, ' missing CA/MX product shares')
        }
      }
      rates <- rates %>%
        mutate(
          usmca_share = if_else(
            country %in% c(CTY_CANADA, CTY_MEXICO),
            coalesce(usmca_share, 0), 0
          ),
          base_rate = base_rate * (1 - usmca_share),
          rate_ieepa_recip = rate_ieepa_recip * (1 - usmca_share),
          rate_ieepa_fent = rate_ieepa_fent * (1 - usmca_share),
          rate_s122 = rate_s122 * (1 - usmca_share),
          # Apply USMCA shares to 232 auto/MHD (heading products with usmca_exempt flag)
          # Steel/aluminum 232 are NOT USMCA-eligible — only heading-level tariffs
          # Auto/MHD products use adjusted USMCA share: usmca_share * us_auto_content_share
          # (only ~40% of USMCA-eligible vehicle value is US/USMCA-origin content)
          rate_232 = if_else(
            coalesce(s232_usmca_eligible, FALSE) & country %in% c(CTY_CANADA, CTY_MEXICO),
            if_else(
              hts10 %in% c(auto_products, mhd_products),
              rate_232 * (1 - usmca_share * us_auto_content_share),
              rate_232 * (1 - usmca_share)
            ),
            rate_232
          )
        )
    } else {
      # Fallback: binary USMCA from HTS special field
      rates <- rates %>%
        mutate(
          rate_ieepa_recip = if_else(
            country %in% c(CTY_CANADA, CTY_MEXICO) & usmca_eligible,
            0, rate_ieepa_recip
          ),
          rate_ieepa_fent = if_else(
            country %in% c(CTY_CANADA, CTY_MEXICO) & usmca_eligible,
            0, rate_ieepa_fent
          ),
          rate_s122 = if_else(
            country %in% c(CTY_CANADA, CTY_MEXICO) & usmca_eligible,
            0, rate_s122
          ),
          # Binary fallback: 232 for USMCA-eligible CA/MX auto/MHD
          # Auto/MHD: scale by (1 - us_auto_content_share); others: zero
          rate_232 = if_else(
            coalesce(s232_usmca_eligible, FALSE) &
              country %in% c(CTY_CANADA, CTY_MEXICO) & usmca_eligible,
            if_else(
              hts10 %in% c(auto_products, mhd_products),
              rate_232 * (1 - us_auto_content_share),
              0
            ),
            rate_232
          )
        )
    }
  } else {
    rates <- rates %>% mutate(usmca_eligible = FALSE)
  }

  # Redefine usmca_eligible at the (product, country) grain. It lands at this
  # step as a product-level flag (HTS special field has S / S+) broadcast across
  # every country by the hts10-only join. The rate math above gates 0-rate
  # application on country %in% c(CA, MX), so duties were correct — but the
  # emitted column is read by the frontend as a per-row "USMCA applies here"
  # signal, and without this narrowing it shows USMCA as active for Japan,
  # Korea, UK, etc. USMCA by statute only covers imports from CA or MX, so
  # any non-CA/MX row must be FALSE regardless of the HTS special field.
  rates <- rates %>%
    mutate(usmca_eligible = usmca_eligible & country %in% c(CTY_CANADA, CTY_MEXICO))

  # Clean up intermediate flag
  rates$s232_usmca_eligible <- NULL

  # Note 39(a)(7)-(9): semi articles are not subject to 232 aluminum/steel
  # derivative duties, and the April 2026 annex restructuring doesn't re-scope
  # them. Several upstream steps (apply_232_derivatives, annex overrides,
  # USMCA auto-content, etc.) can mutate rate_232 for semi HTS10s. Restore the
  # semi heading rate as the final step before stacking so the 25% is what
  # actually carries into the ETR. Setting deriv_type = NA keeps semi products
  # off the derivative path so nonmetal_share = 0 (IEEPA zeroed, Note 2(v)(xvi)).
  if (exists('semi_products') && length(semi_products) > 0 &&
      exists('heading_product_rate') && nrow(heading_product_rate) > 0) {
    rates <- restore_s232_semiconductor_model(rates, heading_product_rate,
      semi_products, s232_headings$semiconductors)
    message('  Semi: aggregate restored; technical scope/end use required on ',
      length(semi_products), ' HTS10s before a shipment total can be stated')
  }

  # 6b0. Apply Section 301 forced labor (60 economies; 91 FR 47318 / 91 FR 47717,
  #      effective 2026-07-24). Codified as U.S. note 52 + headings
  #      9903.05.20-9903.06.21 in 2026 HTS rev_13.
  #
  #      Config-driven rather than sourced from the HTS rate lines: the notice
  #      assigns four DISTINCT tier semantics (two flat, two total-duty caps) that
  #      the heading text does not distinguish — every line reads "+10%"/"+12.5%"
  #      regardless of whether it is additive or a cap — plus per-economy Annex
  #      I/II exclusion lists that are not in the HTS at all. The heading set is
  #      still validated: classify_resolution_status() marks 9903.05.20-.84
  #      handled_by_s301fl_config, so a heading appearing without config coverage
  #      trips the completeness gate.
  #
  #      Placed AFTER step 7 so the per-product-COUNTRY carve-outs can be
  #      evaluated: note 52(f) needs the §232 columns and note 52(g)/(h) needs the
  #      USMCA utilization share.
  fl_cfg <- pp$SECTION_301_FORCED_LABOR
  if (!is.null(fl_cfg)) {
    fl_eff <- as.Date(fl_cfg$effective_date)
    if (as.Date(effective_date) >= fl_eff) {
      fl_ctys <- intersect(as.character(fl_cfg$countries %||% character(0)), countries)
      if (length(fl_ctys) > 0) {
        # Materialize pairs for products of investigated economies that carry no
        # other additional duty, then score the whole frame in one pass so the
        # exemption logic applies uniformly to pre-existing and new rows.
        rates <- add_blanket_pairs(
          rates, products, products$hts10,
          tibble(country = fl_ctys,
                 blanket_rate = as.numeric(fl_cfg$rate_12_5 %||% 0.125)),
          'rate_s301fl', 'Section 301 forced-labor duties')
        .fl_mfn <- tryCatch(load_mfn_exemption_shares(), error = function(e) NULL)
        .fl_eff_date <- max(as.Date(effective_date), fl_eff)
        rates$rate_s301fl <- compute_s301fl_rates(
          rates, fl_cfg, effective_date = .fl_eff_date, mfn_shares = .fl_mfn)
        # Statutory = the tier/cap the notice imposes BEFORE Annex I/II exclusions,
        # the note-52(f) §232 carve-out and note-52(g)/(h) USMCA claims reduce it.
        rates$statutory_rate_s301fl <- compute_s301fl_rates(
          rates, fl_cfg, effective_date = .fl_eff_date, mfn_shares = .fl_mfn,
          statutory = TRUE)
        n_fl <- sum(rates$rate_s301fl > 0)
        message('  Section 301 forced labor: ', format(n_fl, big.mark = ','),
                ' product-country pairs across ',
                n_distinct(rates$country[rates$rate_s301fl > 0]), ' census origins',
                ' (§232 articles fully excluded per note 52(f); CA/MX USMCA-free',
                ' entries per note 52(g)/(h); aircraft/pharma exempt shares ',
                fl_cfg$aircraft_exempt_share %||% 0, '/',
                fl_cfg$pharma_exempt_share %||% 0, ' — ASSUMED, not measured)')
        rates <- record_duty(rates, '7b', 's301fl', 'rate_s301fl',
                             's301fl_note52', citation_key = 's301fl_active')
      }
    } else {
      message('  Section 301 forced labor not yet effective (',
              fl_cfg$effective_date, ') — not applied')
    }
  }

  # 6b0b. Apply Section 301 Brazil (91 FR 45516, duties effective 2026-07-22).
  #       Heading 9903.05.01 / U.S. note 50: 25% on all products of Brazil except
  #       the note-50(a)(ii)-(v) lists, with articles subject to §232 excluded
  #       ENTIRELY by note 50(a)(vi) / heading 9903.05.07.
  #
  #       Placed AFTER the §232 blocks so statutory_rate_232 and s232_annex are
  #       populated — the note-50(a)(vi) carve-out is a full per-article exclusion
  #       evaluated per product-country, not a content split.
  br_cfg <- pp$SECTION_301_BRAZIL
  if (!is.null(br_cfg)) {
    br_eff <- as.Date(br_cfg$effective_date)
    # Source of truth for the rate is the HTS heading; config is the fallback.
    br_hts_rate <- {
      h <- ch99_data %>% filter(ch99_code == '9903.05.01', !is.na(rate), rate > 0)
      if (nrow(h) > 0) max(h$rate) else NA_real_
    }
    # The shared builder recalculates on the legal activation day within
    # the revision; an earlier state's row must not preload this duty.
    br_in_force <- as.Date(effective_date) >= br_eff
    if (isTRUE(br_in_force)) {
      br_cty <- as.character(br_cfg$country %||% '3510')
      if (br_cty %in% countries) {
        # Materialize Brazil pairs for products that carry no other duty, then
        # compute the rate once over the whole frame so exemption share-scaling
        # and the §232 carve-out apply uniformly to old and new rows.
        rates <- add_blanket_pairs(
          rates, products, products$hts10,
          tibble(country = br_cty,
                 blanket_rate = coalesce(br_hts_rate, as.numeric(br_cfg$rate %||% 0))),
          'rate_s301br', 'Section 301 Brazil duties')
        .br_eff_date <- max(as.Date(effective_date), br_eff)
        rates$rate_s301br <- compute_s301br_rates(
          rates, br_cfg, effective_date = .br_eff_date, hts_rate = br_hts_rate)
        # Statutory = the 25% before the note-50(a)(ii)-(vi) exclusions.
        rates$statutory_rate_s301br <- compute_s301br_rates(
          rates, br_cfg, effective_date = .br_eff_date, hts_rate = br_hts_rate,
          statutory = TRUE)
        n_br <- sum(rates$rate_s301br > 0)
        message('  Section 301 Brazil: ', round(coalesce(br_hts_rate,
                  as.numeric(br_cfg$rate %||% 0)) * 100), '% on ',
                format(n_br, big.mark = ','), ' product-country pairs (rate from ',
                if (!is.na(br_hts_rate)) 'HTS 9903.05.01' else 'config fallback',
                '; §232-covered articles fully excluded per note 50(a)(vi);',
                ' aircraft/pharma exempt shares ', br_cfg$aircraft_exempt_share %||% 0,
                '/', br_cfg$pharma_exempt_share %||% 0, ' — ASSUMED, not measured)')
        rates <- record_duty(rates, '7c', 's301br', 'rate_s301br',
                             's301br_note50', citation_key = 's301br_active')
      }
    } else {
      message('  Section 301 Brazil not yet effective (', br_cfg$effective_date,
              ') — not applied')
    }
  }


  # 6b0c. Apply Section 338 Canada (19 U.S.C. 1338; 91 FR 46653 et seq.,
  #       effective 2026-08-22 after suspension). Three proclamations of 2026-07-20 — dairy, motor
  #       vehicles, alcoholic beverages — each 50% on an Annex II list.
  #
  #       Each legal state is recalculated at its entry date. A later action
  #       must never be preloaded into an earlier row of the same revision.
  s338_cfg <- pp$SECTION_338
  if (!is.null(s338_cfg)) {
    s338_eff <- as.Date(s338_cfg$effective_date)
    s338_cty <- as.character(s338_cfg$country %||% '1220')
    if (as.Date(effective_date) >= s338_eff &&
        s338_cty %in% countries) {
      rates <- add_blanket_pairs(
        rates, products, products$hts10,
        tibble(country = s338_cty, blanket_rate = as.numeric(s338_cfg$rate %||% 0)),
        'rate_s338', 'Section 338 Canada duties')
      .s338_eff_date <- max(as.Date(effective_date), s338_eff)
      .s338_model <- compute_s338_components(rates, s338_cfg, .s338_eff_date)
      .s338_stat <- compute_s338_components(rates, s338_cfg, .s338_eff_date, statutory = TRUE)
      rates$rate_s338 <- .s338_model$rate
      rates$statutory_rate_s338 <- .s338_stat$rate
      rates$ch99_src_s338 <- .s338_stat$reporting_codes
      # Preserve individual actions, including any cumulative overlap, before rollup.
      for (.action in names(.s338_stat$actions)) {
        rates[[paste0('statutory_rate_s338_', .action)]] <- .s338_stat$actions[[.action]]
        rates[[paste0('modeled_rate_s338_', .action)]] <- .s338_model$actions[[.action]]
      }
      n_338 <- sum(rates$rate_s338 > 0)

      message('  Section 338 Canada: ',round(as.numeric(s338_cfg$rate)*100),
        '% on ',format(n_338,big.mark=','),' product-country pairs at ',effective_date,
        ' (action-specific amendments; aggregate civil-aircraft assumption separately retained)')
      rates <- record_duty(rates, '7d', 's338', 'rate_s338',
                           's338_canada', citation_key = 's338_active')
    } else {
      message('  Section 338 Canada not applicable to this revision (effective ',
              s338_cfg$effective_date, ')')
    }
  }

  # 7c. EO 14289 non-stacking order (90 FR 18907 sec. 3(a); CBP CSMS #65054270).
  #     Runs BEFORE totals are computed, and only for eras that carry the order —
  #     it applies to entries on or after 2025-03-04, which precedes both the EO
  #     signature and its HTS implementation. Earlier revisions keep the legacy
  #     behavior untouched.
  #
  #     This is categorical exclusion between named actions, which is distinct
  #     from the metal-content splitting in apply_stacking_rules(): that governs
  #     how much of an article a §232 action reaches, this governs whether an
  #     action is owed at all.
  # 7b-bis. Park any §232 duty the per-action columns do not account for.
  #     Several earlier steps write rate_232 directly (the pmax against
  #     blanket_232 in step 4, country deal floors, annex overrides) without
  #     touching the action columns, leaving duty that no §232 action explains.
  #     Rate-neutral — it moves attribution, not money — but it must run BEFORE
  #     EO 14289, which decides precedence by reading those very columns.
  if (!is.null(s232_note16_projection)) {
    rates <- reconcile_s232_note16_model_actions(rates,s232_note16_projection,heading_program_products)
  }
  rates <- attribute_s232_residual(rates)

  rates$stacking_model_version <- as.integer(load_stacking_rules()$version)
  rates$stacking_era_id <- resolve_stacking_era(effective_date)$id
  .pre_stacking_actions <- rates %>% select(all_of(S232_ACTION_RATE_COLS))
  .era <- resolve_stacking_era(effective_date)
  .eo_applies <- !is.null(.era) && length(.era$non_stacking %||% list()) > 0
  .thr <- if (.eo_applies) .era$subject_to_threshold %||% 0 else 0
  if (.eo_applies) {
    .before <- sum(rates$rate_232, na.rm = TRUE)
    rates <- apply_stacking_precedence(rates, era = .era, threshold = .thr)
    .n_supp <- sum(!is.na(rates$s232_suppressed_json))
    message('  EO 14289 (', .era$id, '): ', .n_supp,
            ' row(s) had a lower-precedence action suppressed; ',
            'aggregate rate_232 ', sprintf('%+.4f', sum(rates$rate_232, na.rm = TRUE) - .before))
  }

  # 8. Re-apply stacking rules with updated IEEPA and 232 rates
  rates <- apply_stacking_rules(rates, CTY_CHINA, stacking_method = stacking_method)

  # 8a. Statutory-basis totals — the duty a single ENTRY owes, as distinct from
  #     total_rate, which is trade-weighted (step 6c scales base_rate by the MFN
  #     exemption share, step 7 scales base_rate/IEEPA/§122/rate_232 by the USMCA
  #     share). Both are wanted: the weighted total drives the effective-rate
  #     series, the statutory total answers "what do I owe on this shipment".
  #     Gated by the same era so the two differ only in weighting.
  # Note 33(g)/(h)(ii) requires actual parts use, not just the listed HTS.
  # Read candidates captured before semiconductor/model suppression.
  if (exists('heading_candidate_lists', inherits=FALSE)) {
    rates <- mark_s232_auto_parts_scope(rates,
      heading_candidate_lists$auto_parts$products %||% character(), s232_headings$auto_parts)
  }
  if (!is.null(s232_note16_projection)) {
    rates <- mark_s232_note16_scope(rates,s232_note16_projection)
  }
  if(!is.null(s232_legacy_memberships)) rates <- mark_s232_legacy_scope(rates,s232_legacy_memberships)
  # HTS alone cannot establish the November description-limited relief.
  # Do this after all model/stacking passes so an aggregate zero cannot fill it.
  if(nrow(reciprocal_scope_matches)) {
    conditional <- setdiff(reciprocal_scope_matches$hts10[reciprocal_scope_matches$condition!='none'],ieepa_exempt_products)
    exposed_countries <- if(exists('country_ieepa',inherits=FALSE))
      country_ieepa$census_code[country_ieepa$ieepa_country_rate>0] else character()
    rates$statutory_rate_ieepa_recip[rates$hts10 %in% conditional & rates$country %in% exposed_countries] <- NA_real_
  }
  rates <- compute_statutory_totals(rates, cty_china = CTY_CHINA,
                                    stacking_method = stacking_method,
                                    apply_eo = .eo_applies, threshold = .thr,
                                    cty_canada = CTY_CANADA,
                                    cty_mexico = CTY_MEXICO,
                                    stacking_era = .era,
                                    action_inputs = .pre_stacking_actions)
  message('  Statutory totals: mean statutory_total_rate ',
          sprintf('%.4f', mean(rates$statutory_total_rate, na.rm = TRUE)),
          ' vs trade-weighted total_rate ',
          sprintf('%.4f', mean(rates$total_rate, na.rm = TRUE)))

  # 8b. Resolve specific 8-digit Chapter 99 codes per authority per row.
  #     This replaces the static per-authority range labels ("9903.80-85, 9903.94")
  #     previously hardcoded in the frontend with actual codes driving each rate.
  #     deriv_products supplies the per-product subdivision headings so each
  #     derivative carries its legally correct code (US Note 16/19).
  # §201 safeguards whose country scope did not parse are dropped fail-closed
  # and contribute no duty. Record which, and how much, so the omission is
  # measurable per revision rather than invisible.
  report_unresolved_s201(ch99_data, revision_id)

  rates <- resolve_ch99_codes(rates, ch99_data,
                              ieepa_rates = ieepa_rates,
                              fentanyl_rates = fentanyl_rates,
                              deriv_products = load_232_derivative_products(
                                effective_date = effective_date))

  # 8c. Legal duty basis for the Section 232 amount (determination layer).
  #     Pre-annex true derivatives outside the primary metal chapters owe 232
  #     duty on the declared value of the metal content (US Notes 16(a)/19(a),
  #     Proclamation 10895 implementation, 90 FR 9807); the April 2026 annex
  #     restructure (Proclamation 11021, 91 FR 18201) collects on the full
  #     entered value, flagged by s232_annex. No dates are hardcoded — both
  #     signals derive from parsed data (derivative CSV + annex CSV).
  if (!'s232_annex' %in% names(rates)) rates$s232_annex <- NA_character_
  if (!'deriv_content_scaled' %in% names(rates)) rates$deriv_content_scaled <- FALSE
  rates <- rates %>%
    mutate(duty_basis_232 = case_when(
      rate_232 <= 0 ~ NA_character_,
      !is.na(s232_annex) ~ 'full_value',
      coalesce(deriv_content_scaled, FALSE) ~ 'metal_content_value',
      TRUE ~ 'full_value'
    ))
  if(!is.null(s232_legacy_memberships))
    rates$duty_basis_232[rates$hts10 %in% s232_legacy_memberships$hts10] <- NA_character_

  # 9a. Add revision metadata
  rates <- rates %>%
    mutate(
      revision = revision_id,
      effective_date = as.Date(effective_date)
    )

  # 9b. Join rate tier columns from products (special, column 2, duty basis, etc.)
  #
  # Note: reported_unit_1/2 are statistical reporting fields (nonlegal).
  # duty_basis_unit is the legally relevant unit from the rate text.
  # These are kept separate per U.S. HTSUS methodology — the statistical
  # reporting unit is NOT by itself the legal basis of duty.
  #
  # any_of() tolerates fixture/test inputs that only carry the minimum product
  # schema (hts10 + base_rate). Production parse_products() populates every
  # column listed below; when a column is absent it is simply not joined.
  tier_col_names <- c('rate_special', 'rate_special_raw', 'special_programs',
                      'rate_column2', 'rate_column2_raw',
                      'rate_basis', 'specific_amount', 'specific_rate_unit',
                      'reported_unit_1', 'reported_unit_2',
                      'duty_basis_unit', 'is_qty_duty_relevant', 'quantity_source',
                      'rounding_rule', 'calc_status')
  product_tier_cols <- products %>%
    select(hts10, any_of(tier_col_names))
  rates <- rates %>%
    left_join(product_tier_cols, by = 'hts10', relationship = 'many-to-one')

  # Serialize special_programs list-column to JSON string for Parquet compatibility
  if ('special_programs' %in% names(rates)) {
    rates$special_programs_json <- sapply(rates$special_programs, function(sp) {
      if (is.null(sp) || length(sp) == 0) return(NA_character_)
      # Strip the 'parsed' sub-element to keep JSON compact
      sp_clean <- lapply(sp, function(entry) {
        list(rate = entry$rate, rate_raw = entry$rate_raw,
             programs = entry$programs, entry_type = entry$entry_type)
      })
      jsonlite::toJSON(sp_clean, auto_unbox = TRUE)
    })
    rates$special_programs <- NULL  # Drop list-column before schema enforcement
  }

  # 9c. Fill the full (product × country) grid.
  #
  # The pipeline only materializes (hts10, country) pairs where at least
  # one authority produces a nonzero duty. Countries that attract no
  # additional duty for a given product are absent — the data model
  # conflates "no information" with "no duty." This step fills every
  # missing pair with a base-MFN-only row: all rate_* = 0, base_rate
  # from the product, total_rate = base_rate. The result is a complete
  # grid where every (product, country) has a row and any query against
  # the denormalized parquet returns data — no server-side synthesis
  # heuristics required.
  #
  # Approximately 16% of the grid (~776k pairs per revision) is typically
  # missing. The added rows are overwhelmingly zeros, which parquet's
  # dictionary + RLE encoding compresses to near-zero on-disk cost.
  existing_pairs <- rates %>%
    distinct(hts10, country)

  all_pairs <- tidyr::expand_grid(
    hts10   = unique(products$hts10),
    country = countries
  )

  missing_pairs <- anti_join(all_pairs, existing_pairs, by = c('hts10', 'country'))

  if (nrow(missing_pairs) > 0) {
    # Build base-MFN-only rows. Product metadata (base_rate, rate_special,
    # rate_column2, rate_basis, etc.) comes from the products tibble via
    # the same product_tier_cols join used in step 9b. All authority rates
    # are zero. total_rate = base_rate after stacking (trivial: no
    # authorities to stack).
    # Look up product base rates once (products doesn't have statutory_base_rate,
    # so we create it as a copy of base_rate).
    product_base <- products %>%
      transmute(hts10, product_base_rate = base_rate)

    fill_rows <- missing_pairs %>%
      left_join(product_base, by = 'hts10') %>%
      mutate(
        base_rate = coalesce(product_base_rate, 0),
        statutory_base_rate = base_rate,
        rate_232 = 0, rate_301 = 0, rate_ieepa_recip = 0,
        rate_ieepa_fent = 0, rate_s122 = 0, rate_section_201 = 0, rate_other = 0,
        metal_share = 1.0, total_additional = 0,
        total_rate = base_rate,
        usmca_eligible = FALSE,
        revision = revision_id, effective_date = as.Date(effective_date)
      ) %>%
      select(-product_base_rate) %>%
      # Join product tier columns (rate_special, rate_column2, etc.)
      left_join(product_tier_cols, by = 'hts10', relationship = 'many-to-one')

    # Serialize special_programs for the fill rows (same as step 9b)
    if ('special_programs' %in% names(fill_rows)) {
      fill_rows$special_programs_json <- vapply(fill_rows$special_programs, function(sp) {
        if (is.null(sp) || length(sp) == 0) return(NA_character_)
        sp_clean <- lapply(sp, function(entry) {
          list(rate = entry$rate, rate_raw = entry$rate_raw,
               programs = entry$programs, entry_type = entry$entry_type)
        })
        jsonlite::toJSON(sp_clean, auto_unbox = TRUE)
      }, character(1))
      fill_rows$special_programs <- NULL
    } else {
      fill_rows$special_programs_json <- NA_character_
    }

    rates <- bind_rows(rates, fill_rows)
    message('  Full grid: added ', nrow(fill_rows), ' base-MFN-only rows (',
            nrow(rates), ' total)')
  }

  # 9c. Enforce canonical schema
  rates <- enforce_rate_schema(rates)

  # 9c-bis. Attach per-authority duty provenance (status / reason / counterfactual
  #   / would-apply Ch99 code) so the frontend can cite the legal basis and tell
  #   an intentional exemption apart from a coverage gap. Pure post-processing of
  #   the final columns — never alters a computed rate. Reason codes resolve
  #   against config/duty_citations.yaml. country_ieepa may be absent for
  #   pre-2025 revisions (no IEEPA), so guard it.
  rates <- attach_duty_provenance(
    rates,
    country_ieepa = if (exists('country_ieepa', inherits = FALSE)) country_ieepa else NULL,
    ieepa_exempt_source_map = if (exists('ieepa_exempt_source_map', inherits = FALSE)) ieepa_exempt_source_map else NULL,
    ieepa_exempt_scope = if (exists('ieepa_exempt_scope', inherits = FALSE)) ieepa_exempt_scope else 'all',
    duty_free_treatment = if (exists('duty_free_treatment', inherits = FALSE)) duty_free_treatment else 'all_products',
    cc = if (exists('cc', inherits = FALSE)) cc else NULL,
    ch99_other = ch99_other,
    s301_exclusions = s301_exclusions,
    s201_quartz = if (exists('s201_quartz', inherits = FALSE)) s201_quartz else NULL
  )

  # 9d. Assemble and evaluate shipment rules after completing the aggregate
  # grid. Aggregate methodology is preserved; failure cannot expose the old
  # aggregate-backed statutory total as a shipment result.
  source(here('src','shipment_build.R'))
  shipment_projection <- NULL
  if(identical(Sys.getenv('SAIL_EMIT_NORMALIZED','1'),'0')&&identical(Sys.getenv('SAIL_REQUIRE_NORMALIZED','0'),'1'))
    stop('Required shipment contract cannot be built with normalized emission disabled')
  if (!identical(Sys.getenv('SAIL_EMIT_NORMALIZED', '1'), '0')) {
    tryCatch({
      .source_emit_normalized()
      # Source the denorm_state contract validator (lazy, idempotent).
      # See docs/adrs/001-denorm-state-pattern.md for why this is a
      # postcondition: missing slots silently drop a normalized layer,
      # so we fail loudly right before emit.
      contract_src <- here('src', 'denorm_state_contract.R')
      if (!exists('validate_denorm_state', mode = 'function') &&
          file.exists(contract_src)) {
        source(contract_src, local = FALSE)
      }
      if (!exists('emit_normalized_revision', mode = 'function') &&
          identical(Sys.getenv('SAIL_REQUIRE_NORMALIZED', '0'), '1'))
        stop('Required normalized emitter is unavailable')
      if (exists('emit_normalized_revision', mode = 'function')) {
        # Bundle every intermediate the denorm pipeline already computed
        # so the emitter can serialize the answer instead of re-deriving
        # it. This is the load-bearing interface that prevents drift —
        # any future change to the rate-construction logic flows through
        # the variables captured here without touching the emitter.
        denorm_state <- list(
          ieepa_evidence = denorm_ieepa_evidence,
          reciprocal_scope_source = reciprocal_scope_source,
          fentanyl_evidence = denorm_fentanyl_evidence,
          country_eo_exemptions = country_eo_exempt,
          s232_note16_source = s232_note16_source,
          s232_legacy_source = s232_legacy_source,
          s232_legacy_memberships = s232_legacy_memberships,
          s232_note16_matches = s232_note16_matches,
          s232_note16_projection = s232_note16_projection,
          s301_source = s301_source,
          s301_matches = s301_source_matches,
          heading_candidates = if (exists('heading_candidate_lists', inherits=FALSE)) heading_candidate_lists else list(),
          country_ieepa = if (exists('denorm_state_country_ieepa', inherits = FALSE))
                            denorm_state_country_ieepa else NULL,
          s232_deals    = if (exists('denorm_state_s232_deals', inherits = FALSE))
                            denorm_state_s232_deals else list(),
          auto_products = if (exists('auto_products', inherits = FALSE))
                            auto_products else character(0),
          mhd_products  = if (exists('mhd_products', inherits = FALSE))
                            mhd_products else character(0),
          wood_softwood_products = if (exists('wood_softwood_products', inherits = FALSE))
                                     wood_softwood_products else character(0),
          wood_furn_products     = if (exists('wood_furn_products', inherits = FALSE))
                                     wood_furn_products else character(0),
          s122          = if (exists('denorm_state_s122', inherits = FALSE))
                            denorm_state_s122 else NULL,
          heading_overlap = if (exists('denorm_state_heading_overlap', inherits = FALSE))
                              denorm_state_heading_overlap else NULL,
          product_annex   = if (exists('denorm_state_product_annex', inherits = FALSE))
                              denorm_state_product_annex else NULL
        )

        # Postcondition — runs inside the tryCatch so validator errors
        # surface as "[phase2 emit_normalized_revision skipped: ...]"
        # rather than killing the main pipeline. `strict = FALSE` during
        # Phase 2 bring-up so the emitter still writes layers for
        # partially-populated states; Phase 4a flips this to TRUE once
        # the contract is fully specified and the pipeline guarantees
        # every slot.
        if (exists('validate_denorm_state', mode = 'function')) {
          validate_denorm_state(denorm_state,
                                 revision_id = revision_id,
                                 strict = FALSE)
        }

        normalized_result <- emit_normalized_revision(
          products              = products,
          ch99_data             = ch99_data,
          ieepa_rates           = ieepa_rates,
          fentanyl_rates        = fentanyl_rates,
          s232_rates            = s232_rates,
          heading_product_lists = if (exists('heading_product_lists', inherits = FALSE))
                                    heading_product_lists else list(),
          deriv_matched         = if (exists('deriv_matched', inherits = FALSE))
                                    deriv_matched else character(0),
          ieepa_exempt_products = if (exists('ieepa_exempt_products', inherits = FALSE))
                                    ieepa_exempt_products else character(0),
          floor_exempt_products = if (exists('floor_exempt_products', inherits = FALSE))
                                    floor_exempt_products else NULL,
          usmca_product_shares  = if (exists('usmca_product_shares', inherits = FALSE))
                                    usmca_product_shares else NULL,
          countries             = countries,
          pp                    = pp,
          revision_id           = revision_id,
          effective_date        = effective_date,
          valid_from            = as.Date(effective_date),
          valid_until           = normalized_valid_until,
          output_dir            = normalized_output_dir,
          denorm_state          = denorm_state
        )
        if(!is.null(normalized_result$shipment)) {
          shipment_projection <- project_shipment_state(rates,normalized_result$shipment,normalized_result$revision_dir)
          arrow::write_parquet(shipment_projection$memberships,file.path(normalized_result$revision_dir,'shipment_decision_membership.parquet'))
          arrow::write_parquet(shipment_projection$classes,file.path(normalized_result$revision_dir,'shipment_decision_classes.parquet'))
        } else if(identical(Sys.getenv('SAIL_REQUIRE_NORMALIZED','0'),'1'))
          stop('Required executable shipment bundle is unavailable for this revision')
      }
    }, error = function(e) {
      # A shipment release cannot mix refreshed wide rows with missing/stale
      # normalized tables. Preserve opt-in legacy aggregate builds, but make
      # the required manual shipment rebuild fail before snapshot publication.
      if (identical(Sys.getenv('SAIL_REQUIRE_NORMALIZED', '0'), '1'))
        stop('Required normalized emission failed: ', conditionMessage(e), call. = FALSE)
      message('  [phase2 emit_normalized_revision skipped: ', conditionMessage(e), ']')
    })
  }

  rates <- if(is.null(shipment_projection))mark_shipment_contract_unavailable(rates,'ordinary_build_missing_verified_shipment_projection') else shipment_projection$rates

  # Summary
  n_with_ieepa <- sum(rates$rate_ieepa_recip > 0)
  n_with_232 <- sum(rates$rate_232 > 0)
  n_with_301 <- sum(rates$rate_301 > 0)
  n_with_s122 <- sum(rates$rate_s122 > 0)
  n_usmca <- sum(rates$usmca_eligible)
  message('  Products-countries: ', nrow(rates))
  message('  With IEEPA reciprocal: ', n_with_ieepa)
  message('  With Section 232: ', n_with_232)
  message('  With Section 301: ', n_with_301)
  message('  With Section 122: ', n_with_s122)
  message('  USMCA eligible: ', n_usmca)

  # Persist the forward provenance ledger — the build is its own process, so an
  # in-memory ledger would die with it. Failure here must never break a build:
  # provenance is diagnostic output, not a rate input.
  tryCatch(duty_ledger_save(revision = revision_id, entry_day = effective_date),
           error = function(e) message('  [duty ledger not saved: ',
                                       conditionMessage(e), ']'))

  return(rates)
}


# =============================================================================
# Main Execution
# =============================================================================

if (sys.nframe() == 0) {
  library(here)
  source(here('src', 'helpers.R'))

  # Load data
  ch99_data <- readRDS('data/processed/chapter99_rates.rds')
  products <- readRDS('data/processed/products_rev32.rds')

  # Load country codes
  census_codes <- read_csv('resources/census_codes.csv', col_types = cols(.default = col_character()))
  countries <- census_codes$Code

  message('Loaded ', length(countries), ' countries')

  # Calculate rates (use fast method)
  rates <- calculate_rates_fast(products, ch99_data, countries)

  # Summary
  cat('\n=== Rate Summary ===\n')
  cat('Total product-country pairs with duties: ', nrow(rates), '\n')

  cat('\nTop countries by mean additional rate:\n')
  rates %>%
    group_by(country) %>%
    summarise(
      n_products = n(),
      mean_additional = mean(total_additional),
      mean_total = mean(total_rate),
      .groups = 'drop'
    ) %>%
    arrange(desc(mean_additional)) %>%
    head(10) %>%
    print()

  # Save
  saveRDS(rates, 'data/processed/rates_rev32.rds')
  message('\nSaved rates to data/processed/rates_rev32.rds')

  # Also save CSV for inspection
  write_csv(rates, 'data/processed/rates_rev32.csv')
  message('Saved rates to data/processed/rates_rev32.csv')
}
