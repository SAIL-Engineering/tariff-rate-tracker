# =============================================================================
# Step 07: Emit normalized rate schema (Phase 2 dual-write)
# =============================================================================
#
# Writes the five-layer normalized schema documented in
# docs/normalized-schema.md alongside the existing denormalized parquet.
# This is an **additive** dual-write — nothing currently reads these files;
# they're built up in parallel so Phase 2c parity tests can validate them
# against the denormalized source of truth before any consumer cutover.
#
# PUBLIC API:
#   emit_normalized_revision(...)   — per-revision emitter, called from
#                                      calculate_rates_for_revision()
#   emit_normalized_statics(...)    — one-shot emitter for revisions,
#                                      product_metal_content, country groups
#
# OUTPUT LAYOUT (see docs/normalized-schema.md):
#   output/normalized/
#     revisions.parquet
#     product_metal_content.parquet
#     country_group_membership.parquet
#     {revision}/
#       products_base.parquet
#       authority_country_rates.parquet
#       authority_product_applicability.parquet
#       authority_exemptions.parquet
#
# The emitter reads the same intermediate data structures that
# calculate_rates_for_revision() uses procedurally — it does not derive
# from the final denormalized rates tibble. This keeps the normalized
# output independent of the denormalized bug (missing base-MFN rows) and
# makes each layer's provenance explicit.
# =============================================================================

suppressPackageStartupMessages({
  library(tidyverse)
  library(arrow)
})

# ---------------------------------------------------------------------------
# Authority enum normalization
# ---------------------------------------------------------------------------
# classify_authority() in helpers.R returns 'section_232', 'section_301',
# 'ieepa_reciprocal', 'ieepa_fentanyl', 'section_122', 'section_201', 'other'.
# RATE_SCHEMA uses abbreviated suffixes (rate_232, rate_ieepa_recip, etc.).
# Layer 2/3/4 use the LONG form for cross-authority clarity. Keep a single
# translation table so upstream changes surface as explicit errors.
.AUTHORITY_LONG <- c(
  section_232      = 'section_232',
  section_301      = 'section_301',
  ieepa_reciprocal = 'ieepa_reciprocal',
  ieepa_fentanyl   = 'ieepa_fentanyl',
  section_122      = 'section_122',
  section_201      = 'section_201',
  # Section 338 of the Tariff Act of 1930 (19 U.S.C. 1338), 2026 Canada
  # proclamations. classify_authority() returns this for 9903.03.12+; without an
  # entry here the normalized emit would drop or NA the authority for any such
  # heading, exactly the "surface as an explicit error" case this table exists for.
  # The two 2026 §301 actions (note 50 Brazil, note 52 forced labor) need no entry:
  # they roll up to 'section_301'.
  section_338      = 'section_338',
  other            = 'other'
)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
.ensure_dir <- function(path) {
  if (!dir.exists(path)) dir.create(path, recursive = TRUE, showWarnings = FALSE)
  path
}

.write_parquet_safe <- function(df, path) {
  .ensure_dir(dirname(path))
  if (is.null(df) || nrow(df) == 0) {
    # Still write an empty file with schema so downstream readers can union
    # across revisions without missing-file errors. Arrow handles empty tibbles.
    arrow::write_parquet(df %||% tibble(), path)
  } else {
    arrow::write_parquet(df, path)
  }
}

# Null-coalesce (base R has no built-in)
`%||%` <- function(a, b) if (!is.null(a)) a else b


# ---------------------------------------------------------------------------
# Layer 1 — products_base
# ---------------------------------------------------------------------------
#' Emit products_base for a revision.
#' Pure projection from the parsed products tibble — country-independent.
#'
#' @param products    Products tibble from parse_products()
#' @param revision_id Revision identifier string
#' @param effective_date Revision effective date (Date)
#' @param valid_from  Revision window start (Date, defaults to effective_date)
#' @param valid_until Revision window end (Date, defaults to NA/open)
emit_products_base <- function(products, revision_id, effective_date,
                                valid_from = NULL, valid_until = NULL,
                                output_dir,
                                denorm_state = NULL) {
  vf <- valid_from %||% as.Date(effective_date)
  vu <- valid_until %||% as.Date(NA)

  # Project from the products tibble. Columns present may vary slightly by
  # revision; select() with any_of() avoids hard failures on missing fields.
  required_cols <- c('hts10', 'base_rate')
  optional_cols <- c(
    'statutory_base_rate', 'rate_column2', 'rate_column2_raw',
    'rate_special', 'rate_special_raw', 'special_programs',
    'rate_basis', 'specific_amount', 'specific_rate_unit',
    'reported_unit_1', 'reported_unit_2',
    'duty_basis_unit', 'is_qty_duty_relevant', 'quantity_source',
    'rounding_rule', 'calc_status'
  )
  missing_required <- setdiff(required_cols, names(products))
  if (length(missing_required) > 0) {
    stop('emit_products_base: missing required columns: ',
         paste(missing_required, collapse = ', '))
  }

  df <- products %>%
    select(any_of(c(required_cols, optional_cols)))

  # Ensure every optional column is present (fill with sensible defaults so
  # the parquet schema is stable across revisions even if an older revision
  # is missing a column). Mirrors enforce_rate_schema() defaults.
  defaults <- list(
    statutory_base_rate = NA_real_,
    rate_column2 = NA_real_, rate_column2_raw = NA_character_,
    rate_special = NA_real_, rate_special_raw = NA_character_,
    rate_basis = 'unknown',
    specific_amount = NA_real_, specific_rate_unit = NA_character_,
    reported_unit_1 = NA_character_, reported_unit_2 = NA_character_,
    duty_basis_unit = NA_character_,
    is_qty_duty_relevant = FALSE, quantity_source = NA_character_,
    rounding_rule = '19cfr159.3_value',
    calc_status = 'ok'
  )
  for (col in names(defaults)) {
    if (!col %in% names(df)) df[[col]] <- defaults[[col]]
  }

  # Serialize special_programs list column to JSON string for parquet
  # compatibility. Mirrors the existing serialization in
  # calculate_rates_for_revision (L1945+ in 06_calculate_rates.R).
  if ('special_programs' %in% names(df)) {
    df$special_programs_json <- vapply(df$special_programs, function(sp) {
      if (is.null(sp) || length(sp) == 0) return(NA_character_)
      sp_clean <- lapply(sp, function(entry) {
        list(rate = entry$rate, rate_raw = entry$rate_raw,
             programs = entry$programs, entry_type = entry$entry_type)
      })
      as.character(jsonlite::toJSON(sp_clean, auto_unbox = TRUE))
    }, character(1))
    df$special_programs <- NULL
  } else {
    df$special_programs_json <- NA_character_
  }

  # Section 232 annex classification (from the denorm pipeline's
  # classify_annex_products step). This is a per-hts10 attribute — the
  # classification depends only on hts8 prefix + downstream derivative
  # fallback, so it's country-invariant and belongs on layer 1. The
  # resolver reads this column and sets s232_annex on the wide tibble
  # it passes to apply_stacking_rules, which reads s232_annex to apply
  # the post-annex nonmetal_share=0 override uniformly across the
  # denorm and normalized code paths. Missing or pre-annex revisions
  # get NA for every row (the stacking engine's if-column-present
  # guard handles this correctly).
  if (!is.null(denorm_state) && !is.null(denorm_state$product_annex) &&
      nrow(denorm_state$product_annex) > 0) {
    df <- df %>%
      left_join(
        denorm_state$product_annex %>%
          transmute(hts10 = as.character(hts10),
                    s232_annex = as.character(s232_annex)),
        by = 'hts10'
      )
  } else {
    df$s232_annex <- NA_character_
  }

  df <- df %>%
    mutate(
      revision       = revision_id,
      effective_date = as.Date(effective_date),
      valid_from     = vf,
      valid_until    = vu,
    ) %>%
    select(
      hts10, revision, base_rate, statutory_base_rate,
      rate_column2, rate_column2_raw,
      rate_special, rate_special_raw, special_programs_json,
      rate_basis, specific_amount, specific_rate_unit,
      reported_unit_1, reported_unit_2,
      duty_basis_unit, is_qty_duty_relevant, quantity_source,
      rounding_rule, calc_status, s232_annex,
      effective_date, valid_from, valid_until
    )

  .write_parquet_safe(df, file.path(output_dir, revision_id, 'products_base.parquet'))
  invisible(df)
}


# ---------------------------------------------------------------------------
# Layer 2 — authority_country_rates
# ---------------------------------------------------------------------------
#' Emit authority_country_rates for a revision.
#' Pulls per-country statutory rates from extraction outputs:
#'   - ieepa_rates       → ieepa_reciprocal
#'   - fentanyl_rates    → ieepa_fentanyl
#'   - s232_rates        → section_232 country overrides (deals)
#'   - s301              → section_301 blanket for China (via pp$SECTION_301_RATES)
#'   - pp$FLOOR_RATE     → section_122 blanket for non-excluded countries (if active)
emit_authority_country_rates <- function(ieepa_rates, fentanyl_rates, s232_rates,
                                          ch99_data, countries,
                                          revision_id, effective_date, pp,
                                          output_dir,
                                          valid_from = NULL, valid_until = NULL,
                                          denorm_state = NULL) {
  vf <- valid_from %||% as.Date(effective_date)
  vu <- valid_until %||% as.Date(NA)

  rows <- list()

  # ---- IEEPA reciprocal (country-specific surcharges and floors) ----
  #
  # SOURCE OF TRUTH: denorm_state$country_ieepa.
  #
  # The denormalized pipeline (calculate_rates_for_revision in
  # src/06_calculate_rates.R) builds country_ieepa via a multi-step
  # aggregation: per-phase max + cross-phase sum + floor-country override
  # + universal-baseline fill. That logic is order-sensitive and the only
  # place in the codebase that knows the rules. We deliberately do NOT
  # replicate it here — instead we receive the post-aggregation tibble
  # via denorm_state and serialize it as layer 2 directly. This keeps the
  # normalized output strictly downstream of denorm so any future regulatory
  # change (new phase, new floor mechanism, new baseline) flows through one
  # code path and propagates to the normalized output for free.
  #
  # If denorm_state is missing (a bare-emitter caller), we have nothing to
  # write — better to skip than to risk drift. The reemit-from-cache path
  # in 00_build_timeseries.R must persist denorm_state alongside the parse
  # caches; see Phase 4 cleanup notes.
  if (!is.null(denorm_state) && !is.null(denorm_state$country_ieepa) &&
      nrow(denorm_state$country_ieepa) > 0) {
    ci <- denorm_state$country_ieepa
    # country_ieepa may not carry a ch99_code column (the denorm pipeline
    # currently aggregates by census_code without retaining one). Default
    # to NA so the parquet schema is stable across revisions.
    if (!'ch99_code' %in% names(ci)) ci$ch99_code <- NA_character_
    rows[['ieepa_recip']] <- ci %>%
      transmute(
        revision       = revision_id,
        authority      = 'ieepa_reciprocal',
        program        = if_else(is.na(ch99_code), 'ieepa_recip_baseline',
                                  'ieepa_recip_country'),
        country        = as.character(census_code),
        ch99_code      = as.character(ch99_code),
        statutory_rate = as.numeric(ieepa_country_rate),
        rate_type      = as.character(ieepa_type),
        phase          = NA_character_,
        valid_from     = vf,
        valid_until    = vu
      )
  }

  # ---- IEEPA fentanyl (CA/MX/CN general + carve-outs) ----
  if (!is.null(fentanyl_rates) && nrow(fentanyl_rates) > 0) {
    fr <- fentanyl_rates %>%
      filter(!is.na(rate), !is.na(census_code), !is.na(ch99_code)) %>%
      transmute(
        revision       = revision_id,
        authority      = 'ieepa_fentanyl',
        program        = if ('entry_type' %in% names(.))
                           paste0('fent_', coalesce(entry_type, 'general'))
                         else 'fent_general',
        country        = as.character(census_code),
        ch99_code      = as.character(ch99_code),
        statutory_rate = as.numeric(rate),
        rate_type      = 'surcharge',
        phase          = NA_character_,
        valid_from     = vf,
        valid_until    = vu
      )
    rows[['fent']] <- fr
  }

  # ---- Section 232 country overrides (deals) ----
  # s232_rates carries *_country_overrides lists for steel, aluminum, and auto.
  # Each override is a (country → rate) mapping authorized by country-specific
  # note text. We emit each override as a layer-2 row; the ch99_code is the
  # blanket 9903.80/9903.85/9903.94 code for the relevant program since s232
  # overrides don't have their own 9903.xx entries — the rate lives in US notes.
  if (!is.null(s232_rates) && isTRUE(s232_rates$has_232)) {
    emit_overrides <- function(overrides, program, ch99_hint) {
      if (is.null(overrides) || length(overrides) == 0) return(NULL)
      codes <- names(overrides)
      rts <- unlist(overrides, use.names = FALSE)
      if (length(codes) == 0 || length(rts) == 0) return(NULL)
      tibble(
        revision       = revision_id,
        authority      = 'section_232',
        program        = program,
        country        = as.character(codes),
        ch99_code      = as.character(ch99_hint %||% NA_character_),
        statutory_rate = as.numeric(rts),
        rate_type      = 'override',
        phase          = NA_character_,
        valid_from     = vf,
        valid_until    = vu
      )
    }
    # Heuristic ch99 hints — layer-3 has the authoritative ch99 codes for
    # base programs; layer-2 override rows use these purely as audit tags.
    rows[['s232_steel_overrides']] <- emit_overrides(
      s232_rates$steel_country_overrides, 's232_steel_country_override',
      '9903.80.01'
    )
    rows[['s232_alum_overrides']] <- emit_overrides(
      s232_rates$aluminum_country_overrides, 's232_alum_country_override',
      '9903.85.01'
    )
    rows[['s232_auto_overrides']] <- emit_overrides(
      s232_rates$auto_country_overrides, 's232_auto_country_override',
      '9903.94.01'
    )
  }

  # ---- Section 301 (China-wide blanket from SECTION_301_RATES config) ----
  # S301 is unique: the rate varies per-ch99_code (List 1 25% vs List 4a 7.5%
  # etc.), but scoping is always China-only. Emit one layer-2 row per active
  # ch99 code — layer-3 provides the product list.
  if (!is.null(pp) && !is.null(pp$SECTION_301_RATES) && !is.null(ch99_data)) {
    active_s301 <- pp$SECTION_301_RATES %>%
      filter(ch99_pattern %in% unique(ch99_data$ch99_code))
    if (nrow(active_s301) > 0) {
      china_code <- pp$country_codes$CTY_CHINA %||% '5700'
      sr <- active_s301 %>%
        transmute(
          revision       = revision_id,
          authority      = 'section_301',
          program        = 's301_blanket_china',
          country        = china_code,
          ch99_code      = as.character(ch99_pattern),
          statutory_rate = as.numeric(s301_rate),
          rate_type      = 'surcharge',
          phase          = NA_character_,
          valid_from     = vf,
          valid_until    = vu
        )
      rows[['s301']] <- sr
    }
  }

  # ---- Section 122 (blanket flat rate when in force) ----
  #
  # SOURCE OF TRUTH: denorm_state$s122.
  #
  # The denorm pipeline at src/06_calculate_rates.R:1716-1768 extracts
  # s122_rates from ch99_data, gates on the policy-effective window in
  # pp$SECTION_122, and applies a flat rate to every product (with an
  # HTS8 exemption list). When in force, s122 is a single rate that
  # applies to every country. We emit one layer-2 row per country with
  # that flat rate so the resolver's layer-2 lookup can find it for any
  # product/country combination — same shape as the IEEPA recip rows.
  # Exemptions go to layer 4 by HTS8 (next pass).
  if (!is.null(denorm_state) && !is.null(denorm_state$s122) &&
      isTRUE(denorm_state$s122$in_force) &&
      !is.null(denorm_state$s122$rate) && denorm_state$s122$rate > 0 &&
      length(countries) > 0) {
    rows[['s122']] <- tibble(
      revision       = revision_id,
      authority      = 'section_122',
      program        = 's122_blanket',
      country        = as.character(countries),
      ch99_code      = NA_character_,
      statutory_rate = as.numeric(denorm_state$s122$rate),
      rate_type      = 'surcharge',
      phase          = NA_character_,
      valid_from     = vf,
      valid_until    = vu
    )
  }

  df <- bind_rows(rows)
  .write_parquet_safe(
    df,
    file.path(output_dir, revision_id, 'authority_country_rates.parquet')
  )
  invisible(df)
}


# ---------------------------------------------------------------------------
# Layer 3 — authority_product_applicability (FIRST PASS)
# ---------------------------------------------------------------------------
#' Emit authority_product_applicability for a revision.
#'
#' NOTE: first-pass implementation. Covers the blanket authorities and the
#' S301 per-HS8 buckets. Later passes will add:
#'   - 232 steel/alum/copper chapter rows (hts_prefix='72'/'73'/'76' etc.)
#'   - 232 auto/wood/MHD heading rows (from heading_product_lists)
#'   - 232 derivative products (per-HS10 rows from the CSV) with metal scaling
#'   - Fentanyl carve-out products (CA energy/minerals, CA/MX potash)
#'   - Section 201 safeguard product lists
#' Items marked TODO emit no rows in this pass; parity tests will fail against
#' the denormalized baseline for those products until filled in.
emit_authority_product_applicability <- function(products, ch99_data,
                                                  s232_rates, heading_product_lists,
                                                  deriv_matched, pp,
                                                  revision_id, effective_date,
                                                  output_dir,
                                                  valid_from = NULL, valid_until = NULL,
                                                  denorm_state = NULL) {
  vf <- valid_from %||% as.Date(effective_date)
  vu <- valid_until %||% as.Date(NA)
  here_fn <- if (requireNamespace('here', quietly = TRUE)) here::here else function(...) file.path(...)

  rows <- list()

  # ---- IEEPA reciprocal blanket (all products; rate from layer 2) ----
  # Single row with hts10=NULL, hts_prefix=NULL signals universal coverage.
  rows[['ieepa_recip_blanket']] <- tibble(
    revision          = revision_id,
    authority         = 'ieepa_reciprocal',
    program           = 'ieepa_recip_blanket',
    hts10             = NA_character_,
    hts_prefix        = NA_character_,
    ch99_code         = NA_character_,
    statutory_rate    = NA_real_,                # rate is country-specific, from layer 2
    rate_kind         = 'ad_valorem_full',
    scaling_dimension = 'none',
    deriv_type        = NA_character_,
    precedence        = 1L,
    usmca_exempt      = TRUE,  # USMCA is a layer-4 fractional exemption
    valid_from        = vf,
    valid_until       = vu
  )

  # ---- IEEPA fentanyl general (CA/MX/CN, rate from layer 2 per country) ----
  rows[['fent_general']] <- tibble(
    revision          = revision_id,
    authority         = 'ieepa_fentanyl',
    program           = 'fent_general',
    hts10             = NA_character_,
    hts_prefix        = NA_character_,
    ch99_code         = NA_character_,
    statutory_rate    = NA_real_,
    rate_kind         = 'ad_valorem_full',
    scaling_dimension = 'none',
    deriv_type        = NA_character_,
    precedence        = 1L,
    usmca_exempt      = TRUE,
    valid_from        = vf,
    valid_until       = vu
  )
  # Fentanyl carveouts — higher-precedence rows that beat the general row
  # for specific hts8 prefixes. 9903.01.05 (MX potash), 9903.01.13 (CA energy),
  # 9903.01.15 (CA potash). Each gets its own program row with precedence=10
  # so the query engine picks the carveout rate over the general 35%.
  if (exists('load_fentanyl_carveouts', mode = 'function')) {
    tryCatch({
      fcarve <- load_fentanyl_carveouts()
      if (!is.null(fcarve) && nrow(fcarve) > 0) {
        # Filter to carveouts whose ch99 code is present in this revision's
        # ch99_data — an inactive carveout doesn't belong in this revision's
        # layer 3 (it would be misleading).
        active_ch99 <- unique(ch99_data$ch99_code)
        fcarve_active <- fcarve %>% filter(ch99_code %in% active_ch99)
        if (nrow(fcarve_active) > 0) {
          rows[['fent_carveouts']] <- fcarve_active %>%
            transmute(
              revision          = revision_id,
              authority         = 'ieepa_fentanyl',
              program           = paste0('fent_', category),
              hts10             = NA_character_,
              hts_prefix        = as.character(hts8),
              ch99_code         = as.character(ch99_code),
              statutory_rate    = NA_real_,   # rate supplied by layer 2 per country
              rate_kind         = 'ad_valorem_full',
              scaling_dimension = 'none',
              deriv_type        = NA_character_,
              precedence        = 10L,
              usmca_exempt      = TRUE,
              valid_from        = vf,
              valid_until       = vu
            )
        }
      }
    }, error = function(e) {
      message('  emit: fent carveouts skipped: ', conditionMessage(e))
    })
  }

  # ---- Section 232 base programs ----
  if (!is.null(s232_rates) && isTRUE(s232_rates$has_232)) {
    steel_chapters <- pp$country_codes$STEEL_CHAPTERS %||% c('72', '73')
    alum_chapters  <- pp$country_codes$ALUM_CHAPTERS  %||% c('76')

    # Steel blanket — one row per chapter
    if (!is.null(s232_rates$steel_rate) && s232_rates$steel_rate > 0) {
      rows[['s232_steel']] <- tibble(
        revision          = revision_id,
        authority         = 'section_232',
        program           = 'steel_base',
        hts10             = NA_character_,
        hts_prefix        = steel_chapters,
        ch99_code         = '9903.80.01',   # heuristic tag; layer-3 doesn't strictly need
        statutory_rate    = as.numeric(s232_rates$steel_rate),
        rate_kind         = 'ad_valorem_full',
        scaling_dimension = 'none',
        deriv_type        = 'steel',
        precedence        = 1L,
        usmca_exempt      = FALSE,
        valid_from        = vf,
        valid_until       = vu
      )
    }

    # Aluminum blanket — one row per chapter
    if (!is.null(s232_rates$aluminum_rate) && s232_rates$aluminum_rate > 0) {
      rows[['s232_alum']] <- tibble(
        revision          = revision_id,
        authority         = 'section_232',
        program           = 'alum_base',
        hts10             = NA_character_,
        hts_prefix        = alum_chapters,
        ch99_code         = '9903.85.01',
        statutory_rate    = as.numeric(s232_rates$aluminum_rate),
        rate_kind         = 'ad_valorem_full',
        scaling_dimension = 'none',
        deriv_type        = 'aluminum',
        precedence        = 1L,
        usmca_exempt      = FALSE,
        valid_from        = vf,
        valid_until       = vu
      )
    }

    # Copper headings — from heading_product_lists when present
    if (!is.null(heading_product_lists$copper_heading) &&
        length(heading_product_lists$copper_heading$products) > 0) {
      rows[['s232_copper']] <- tibble(
        revision          = revision_id,
        authority         = 'section_232',
        program           = 'copper_base',
        hts10             = heading_product_lists$copper_heading$products,
        hts_prefix        = NA_character_,
        ch99_code         = '9903.78.01',
        statutory_rate    = as.numeric(heading_product_lists$copper_heading$rate %||%
                                       s232_rates$copper_rate %||% 0),
        rate_kind         = 'ad_valorem_full',
        scaling_dimension = 'none',
        deriv_type        = 'copper',
        precedence        = 1L,
        usmca_exempt      = FALSE,
        valid_from        = vf,
        valid_until       = vu
      )
    }

    # Auto programs — one row per program from heading_product_lists.
    #
    # The denorm pipeline at src/06_calculate_rates.R step 4b deducts a
    # flat assembly rebate from rate_232 BEFORE deal overrides:
    #   rate_232 -= pp$auto_rebate$rebate_rate * pp$auto_rebate$us_assembly_share
    # restricted to `hts10 %in% auto_products`. We bake that deduction
    # directly into the layer-3 statutory_rate so:
    #   (a) non-deal-country winners (precedence 1) match denorm exactly,
    #   (b) deal-country winners (precedence 10, set above) cleanly
    #       REPLACE the rebated value rather than compound on top of it,
    #       which is what denorm step 4c does (rate_232 = pmax(deal_rate
    #       - base_rate, 0) — no rebate factor).
    # We restrict the rebate to products that survive the denorm
    # blanket-chapter exclusion in denorm_state$auto_products, mirroring
    # `hts10 %in% auto_products` from step 4b.
    rebate_deduction <- 0
    if (!is.null(pp) && !is.null(pp$auto_rebate)) {
      rebate_deduction <- as.numeric(pp$auto_rebate$rebate_rate %||% 0) *
                          as.numeric(pp$auto_rebate$us_assembly_share %||% 0)
    }
    rebate_set <- if (!is.null(denorm_state)) {
      as.character(denorm_state$auto_products %||% character(0))
    } else character(0)
    for (pname in names(heading_product_lists)) {
      if (!grepl('auto|passenger|light_truck|heavy_truck', pname, ignore.case = TRUE)) next
      plist <- heading_product_lists[[pname]]
      if (is.null(plist) || length(plist$products) == 0) next
      base_auto_rate <- as.numeric(plist$rate %||% 0)
      hts10s <- as.character(plist$products)
      # Per-product post-rebate rate: subtract the deduction only for
      # products in the denorm-rebated set.
      rate_per_hts <- ifelse(
        hts10s %in% rebate_set,
        pmax(base_auto_rate - rebate_deduction, 0),
        base_auto_rate
      )
      rows[[paste0('s232_', pname)]] <- tibble(
        revision          = revision_id,
        authority         = 'section_232',
        program           = paste0('auto_', pname),
        hts10             = hts10s,
        hts_prefix        = NA_character_,
        ch99_code         = '9903.94.01',
        statutory_rate    = rate_per_hts,
        rate_kind         = 'ad_valorem_full',
        scaling_dimension = 'none',
        deriv_type        = NA_character_,
        precedence        = 1L,
        usmca_exempt      = isTRUE(plist$usmca_exempt),
        valid_from        = vf,
        valid_until       = vu
      )
    }

    # Wood / MHD — same pattern
    for (pname in names(heading_product_lists)) {
      if (!grepl('wood|furniture|cabinet|mhd|bus', pname, ignore.case = TRUE)) next
      plist <- heading_product_lists[[pname]]
      if (is.null(plist) || length(plist$products) == 0) next
      rows[[paste0('s232_', pname)]] <- tibble(
        revision          = revision_id,
        authority         = 'section_232',
        program           = pname,
        hts10             = plist$products,
        hts_prefix        = NA_character_,
        ch99_code         = NA_character_,
        statutory_rate    = as.numeric(plist$rate %||% 0),
        rate_kind         = 'ad_valorem_full',
        scaling_dimension = 'none',
        deriv_type        = NA_character_,
        precedence        = 1L,
        usmca_exempt      = isTRUE(plist$usmca_exempt),
        valid_from        = vf,
        valid_until       = vu
      )
    }

    # S232 derivative programs. One row per (hts_prefix, ch99_code) from
    # resources/s232_derivative_products.csv, filtered to rows whose
    # effective_date is on or before this revision's effective date and
    # whose ch99_code is active in this revision. Aluminum derivatives use
    # scaling_dimension='aluminum_share', steel derivatives use 'steel_share'.
    if (exists('load_232_derivative_products', mode = 'function')) {
      tryCatch({
        deriv_prods <- load_232_derivative_products(effective_date = as.Date(effective_date))
        if (!is.null(deriv_prods) && nrow(deriv_prods) > 0) {
          active_ch99 <- unique(ch99_data$ch99_code)
          dp <- deriv_prods %>% filter(ch99_code %in% active_ch99)
          if (nrow(dp) > 0) {
            # Derivative rates come from s232_rates — aluminum derivatives at
            # s232_rates$aluminum_derivative_rate, steel derivatives at
            # s232_rates$steel_derivative_rate. Fall back to 0 if missing.
            alum_rate  <- as.numeric(s232_rates$aluminum_derivative_rate %||% 0)
            steel_rate <- as.numeric(s232_rates$steel_derivative_rate %||% 0)
            rows[['s232_deriv']] <- dp %>%
              transmute(
                revision          = revision_id,
                authority         = 'section_232',
                program           = paste0(derivative_type, '_deriv'),
                hts10             = NA_character_,
                hts_prefix        = as.character(hts_prefix),
                ch99_code         = as.character(ch99_code),
                statutory_rate    = if_else(derivative_type == 'aluminum',
                                             alum_rate, steel_rate),
                rate_kind         = 'ad_valorem_metal_scaled',
                scaling_dimension = if_else(derivative_type == 'aluminum',
                                             'aluminum_share', 'steel_share'),
                deriv_type        = as.character(derivative_type),
                # Derivatives beat the chapter-blanket rows when both match
                # (e.g., a steel-containing product in a non-72/73 chapter):
                # no overlap by construction. Precedence=5 keeps us ahead of
                # any future blanket that might accidentally cover the same
                # product.
                precedence        = 5L,
                usmca_exempt      = FALSE,
                valid_from        = vf,
                valid_until       = vu
              )
          }
        }
      }, error = function(e) {
        message('  emit: s232 derivatives skipped: ', conditionMessage(e))
      })
    }
  }

  # ---- Section 301 buckets (per HS8, from resources/s301_product_lists.csv) ----
  s301_products_path <- here_fn('resources', 's301_product_lists.csv')
  if (file.exists(s301_products_path) && !is.null(pp) &&
      !is.null(pp$SECTION_301_RATES) && !is.null(ch99_data)) {
    s301_products <- tryCatch(
      readr::read_csv(s301_products_path, col_types = readr::cols(
        hts8 = readr::col_character(),
        list = readr::col_character(),
        ch99_code = readr::col_character()
      )),
      error = function(e) NULL
    )
    if (!is.null(s301_products) && nrow(s301_products) > 0) {
      active_301 <- ch99_data %>%
        filter(ch99_code %in% pp$SECTION_301_RATES$ch99_pattern) %>%
        filter(!grepl('provision suspended|provision terminated',
                      description %||% '', ignore.case = TRUE)) %>%
        pull(ch99_code) %>% unique()

      if (length(active_301) > 0) {
        # S301 is China-only (census code 5700) by statute — every list (1,
        # 2, 3, 4a) was issued under USTR authority against China imports.
        # Encode this at emit time via country_scope so the query engine
        # never hands an S301 rate to another country. Scope is a
        # '|'-delimited census code list (single country here, but the
        # format leaves room for multi-country authorities later).
        china_code <- pp$country_codes$CHINA_COUNTRY_CODE %||% '5700'
        s301_apa <- s301_products %>%
          filter(ch99_code %in% active_301) %>%
          inner_join(pp$SECTION_301_RATES,
                     by = c('ch99_code' = 'ch99_pattern')) %>%
          transmute(
            revision          = revision_id,
            authority         = 'section_301',
            program           = paste0('s301_list_', tolower(gsub('[^A-Za-z0-9]', '_', list))),
            hts10             = NA_character_,
            hts_prefix        = hts8,
            country_scope     = china_code,
            ch99_code         = ch99_code,
            statutory_rate    = as.numeric(s301_rate),
            rate_kind         = 'ad_valorem_full',
            scaling_dimension = 'none',
            deriv_type        = NA_character_,
            precedence        = 1L,
            usmca_exempt      = FALSE,
            valid_from        = vf,
            valid_until       = vu
          )
        rows[['s301']] <- s301_apa
      }
    }
  }

  # ---- Section 232 heading/derivative overlap override ----
  #
  # SOURCE OF TRUTH: denorm_state$heading_overlap.
  #
  # For an hts10 that's in BOTH a heading_product_lists entry AND a
  # derivative prefix, denorm at src/06_calculate_rates.R:430-444 takes
  # pmax(heading_rate, derivative_full_rate) and resets metal_share=1.0.
  # In layer 3 that means the winning row must:
  #   (a) have statutory_rate = the already-computed pmax value,
  #   (b) carry scaling_dimension='none' so the resolver never
  #       multiplies by a metal share, and
  #   (c) beat the prefix-level derivative row (precedence 5) so the
  #       scaled path is skipped — but still lose to country-deal
  #       floor rows (precedence 10) so deal-country winners replace
  #       the blanket correctly.
  # Precedence 7 satisfies both inequalities.
  #
  # The per-hts10 rate is captured directly from the post-step-5 rates
  # tibble (in apply_232_derivatives), not re-derived here — this
  # guarantees the pmax formula stays in one place.
  if (!is.null(denorm_state) && !is.null(denorm_state$heading_overlap) &&
      nrow(denorm_state$heading_overlap) > 0) {
    rows[['s232_heading_overlap']] <- denorm_state$heading_overlap %>%
      filter(!is.na(rate_232), rate_232 > 0) %>%
      transmute(
        revision          = revision_id,
        authority         = 'section_232',
        program           = paste0('s232_overlap_', coalesce(deriv_type, 'mixed')),
        hts10             = as.character(hts10),
        hts_prefix        = NA_character_,
        country_scope     = NA_character_,
        ch99_code         = NA_character_,
        statutory_rate    = as.numeric(rate_232),
        rate_kind         = 'ad_valorem_full',
        scaling_dimension = 'none',
        deriv_type        = as.character(deriv_type),
        precedence        = 7L,
        usmca_exempt      = FALSE,
        valid_from        = vf,
        valid_until       = vu,
        rate_type         = 'surcharge'
      )
  }

  # ---- Section 232 annex rate overrides (post-2026-04-06 revisions) ----
  #
  # SOURCE OF TRUTH: denorm_state$product_annex.
  #
  # The denorm pipeline at src/06_calculate_rates.R step 5c overrides
  # rate_232 for annex-classified products (annex_1a → primary rate,
  # annex_1b → derivative rate, annex_2 → 0, annex_3 → floor). The
  # pre-annex layer-3 rows carry the ORIGINAL statutory_rate (set in
  # step 4/5 before the annex block), so the resolver would use the
  # wrong value without explicit override rows. We emit one per
  # annex-classified hts10 at precedence 8 (beats heading_overlap at 7,
  # beats derivative at 5, loses to country deals at 10). Country
  # deals in annex era may override these further — precedence 10 wins.
  if (!is.null(denorm_state) && !is.null(denorm_state$product_annex) &&
      nrow(denorm_state$product_annex) > 0 &&
      'annex_rate_232' %in% names(denorm_state$product_annex)) {
    annex_rows <- denorm_state$product_annex %>%
      filter(!is.na(s232_annex), !is.na(annex_rate_232))
    if (nrow(annex_rows) > 0) {
      rows[['s232_annex_override']] <- annex_rows %>%
        transmute(
          revision          = revision_id,
          authority         = 'section_232',
          program           = paste0('s232_', s232_annex),
          hts10             = as.character(hts10),
          hts_prefix        = NA_character_,
          country_scope     = NA_character_,
          ch99_code         = NA_character_,
          statutory_rate    = as.numeric(annex_rate_232),
          rate_kind         = if_else(s232_annex == 'annex_3',
                                      'ad_valorem_floor', 'ad_valorem_full'),
          scaling_dimension = 'none',
          deriv_type        = NA_character_,
          precedence        = 8L,
          usmca_exempt      = FALSE,
          valid_from        = vf,
          valid_until       = vu,
          rate_type         = if_else(s232_annex == 'annex_3',
                                      'floor', 'surcharge')
        )
    }
  }

  # ---- Section 232 country deal rows (auto/wood floors and surcharges) ----
  #
  # SOURCE OF TRUTH: denorm_state$s232_deals.
  #
  # The denormalized pipeline at src/06_calculate_rates.R step 4c walks
  # s232_rates$auto_deal_rates / wood_deal_rates and expands each deal to
  # (program, census_codes, deal_products, rate, rate_type). We capture
  # that exact expansion in denorm_state and emit one layer-3 row per
  # (deal product) with country_scope set to the deal's census codes and
  # rate_type carried through to the resolver. Precedence is 10 — higher
  # than the auto-blanket row (1) and the 232 derivative rows (5) so a
  # country-eligible deal wins both selection passes.
  #
  # rate_type encoding: 'floor' means the resolver computes
  #   max(0, statutory_rate - base_rate)
  # and 'surcharge' means use statutory_rate verbatim. Same semantics as
  # the IEEPA rate_type field — see resolve_rate_normalized.R.
  if (!is.null(denorm_state) && !is.null(denorm_state$s232_deals) &&
      length(denorm_state$s232_deals) > 0) {
    deal_rows <- list()
    for (i in seq_along(denorm_state$s232_deals)) {
      deal <- denorm_state$s232_deals[[i]]
      if (length(deal$deal_products) == 0 || length(deal$census_codes) == 0) next
      scope <- paste(as.character(deal$census_codes), collapse = '|')
      deal_rows[[i]] <- tibble(
        revision          = revision_id,
        authority         = 'section_232',
        program           = paste0('s232_deal_', as.character(deal$program %||% 'unknown')),
        hts10             = as.character(deal$deal_products),
        hts_prefix        = NA_character_,
        country_scope     = scope,
        ch99_code         = NA_character_,
        statutory_rate    = as.numeric(deal$rate),
        rate_kind         = if (identical(deal$rate_type, 'floor'))
                              'ad_valorem_floor' else 'ad_valorem_full',
        scaling_dimension = 'none',
        deriv_type        = NA_character_,
        precedence        = 10L,
        usmca_exempt      = FALSE,
        valid_from        = vf,
        valid_until       = vu,
        rate_type         = as.character(deal$rate_type)
      )
    }
    deal_rows <- bind_rows(deal_rows)
    if (nrow(deal_rows) > 0) {
      rows[['s232_deals']] <- deal_rows
    }
  }

  # ---- Section 122 layer-3 blanket ----
  #
  # SOURCE OF TRUTH: denorm_state$s122.
  #
  # The denorm pipeline at src/06_calculate_rates.R:1716-1768 applies
  # Section 122 as a blanket rate for in-force revisions, with an HTS8
  # exemption list. Layer 3 carries the blanket scope (NA hts10 + NA
  # hts_prefix) and statutory_rate=NA, deferring to layer 2 for the
  # actual rate (so a future per-country s122 rate is supportable
  # without schema change). The HTS8 exemption list will be modeled as
  # layer-4 exemption rows in a follow-up; for now we keep parity by
  # emitting the layer-3 blanket only when in_force, and the layer-2
  # rate from emit_authority_country_rates picks up the value.
  if (!is.null(denorm_state) && !is.null(denorm_state$s122) &&
      isTRUE(denorm_state$s122$in_force)) {
    rows[['s122_blanket']] <- tibble(
      revision          = revision_id,
      authority         = 'section_122',
      program           = 's122_blanket',
      hts10             = NA_character_,
      hts_prefix        = NA_character_,
      country_scope     = NA_character_,
      ch99_code         = NA_character_,
      statutory_rate    = NA_real_,
      rate_kind         = 'ad_valorem_full',
      scaling_dimension = 'none',
      deriv_type        = NA_character_,
      precedence        = 1L,
      usmca_exempt      = TRUE,  # USMCA is a layer-4 fractional exemption
      valid_from        = vf,
      valid_until       = vu,
      rate_type         = 'surcharge'
    )
  }

  # TODO(phase2b-4): Section 201 safeguard product list (solar, washers).
  # The denormalized pipeline doesn't currently populate rate_section_201 via
  # blanket application — it only flows through footnote-based rates. Model
  # from resources/s201_products.csv when added.

  df <- bind_rows(rows)

  # Ensure column type consistency when binding rows from heterogenous sources.
  # country_scope is only set on country-restricted programs (S301, S232
  # deals); default NA = "all countries eligible". rate_type is set on
  # rows whose effective rate is computed at lookup time (floor formula);
  # default NA = use statutory_rate verbatim.
  if (nrow(df) > 0) {
    if (!'country_scope' %in% names(df)) df$country_scope <- NA_character_
    if (!'rate_type'     %in% names(df)) df$rate_type     <- NA_character_
    df <- df %>%
      mutate(
        revision          = as.character(revision),
        authority         = as.character(authority),
        program           = as.character(program),
        hts10             = as.character(hts10),
        hts_prefix        = as.character(hts_prefix),
        country_scope     = as.character(country_scope),
        ch99_code         = as.character(ch99_code),
        statutory_rate    = as.numeric(statutory_rate),
        rate_kind         = as.character(rate_kind),
        scaling_dimension = as.character(scaling_dimension),
        deriv_type        = as.character(deriv_type),
        precedence        = as.integer(precedence),
        usmca_exempt      = as.logical(usmca_exempt),
        rate_type         = as.character(rate_type)
      )
  }

  .write_parquet_safe(
    df,
    file.path(output_dir, revision_id, 'authority_product_applicability.parquet')
  )
  invisible(df)
}


# ---------------------------------------------------------------------------
# Layer 4 — authority_exemptions
# ---------------------------------------------------------------------------
#' Emit authority_exemptions for a revision.
#' First pass covers Annex A (IEEPA product exemptions), floor-country
#' product exemptions, USMCA per-product shares, and the Section 232 auto
#' assembly rebate.
emit_authority_exemptions <- function(ieepa_exempt_products, floor_exempt_products,
                                       usmca_product_shares,
                                       revision_id, effective_date,
                                       output_dir,
                                       valid_from = NULL, valid_until = NULL,
                                       heading_product_lists = NULL,
                                       pp = NULL,
                                       denorm_state = NULL) {
  vf <- valid_from %||% as.Date(effective_date)
  vu <- valid_until %||% as.Date(NA)

  rows <- list()

  # ---- Annex A (IEEPA reciprocal product exemptions) ----
  if (!is.null(ieepa_exempt_products) && length(ieepa_exempt_products) > 0) {
    rows[['annex_a']] <- tibble(
      revision        = revision_id,
      authority       = 'ieepa_reciprocal',
      program         = NA_character_,
      hts10           = as.character(ieepa_exempt_products),
      hts_prefix      = NA_character_,
      country         = NA_character_,
      country_group   = NA_character_,
      exemption_type  = 'annex_a',
      exemption_share = 1.0,
      rate_override   = NA_real_,
      source          = 'ieepa_exempt_products.csv',
      valid_from      = vf,
      valid_until     = vu
    )
  }

  # ---- Floor country product exemptions (EU/Japan/Korea/Swiss per US Note 2/3) ----
  if (!is.null(floor_exempt_products) && nrow(floor_exempt_products) > 0) {
    rows[['floor']] <- floor_exempt_products %>%
      transmute(
        revision        = revision_id,
        authority       = 'ieepa_reciprocal',
        program         = NA_character_,
        hts10           = NA_character_,
        hts_prefix      = as.character(hts8),
        country         = NA_character_,
        country_group   = as.character(country_group),
        exemption_type  = 'floor_country',
        exemption_share = 1.0,
        rate_override   = NA_real_,
        source          = 'floor_exempt_products',
        valid_from      = vf,
        valid_until     = vu
      )
  }

  # ---- USMCA per-product utilization shares ----
  #
  # The denorm pipeline at src/06_calculate_rates.R:1881-1899 applies
  # `usmca_share` to base_rate, rate_ieepa_recip, rate_ieepa_fent, and
  # rate_s122 with the same fractional reduction. For section_232 it
  # applies a REDUCED share `usmca_share * us_auto_content_share` only
  # to auto/MHD products (heading_product_lists with usmca_exempt). We
  # mirror this exactly: emit per-product/country layer-4 rows for each
  # affected authority, sourced from the SAME usmca_product_shares
  # input the denorm path consumes. The resolver applies them via
  # .compound_exemption_share. base_rate handling is special-cased in
  # the resolver (it's not an authority — see the base_rate USMCA path
  # in resolve_rate_normalized.R).
  #
  # Auto/MHD product set comes from denorm_state$auto_products and
  # mhd_products — captured AFTER the denorm pipeline applies the
  # blanket-chapter exclusion at src/06_calculate_rates.R:1062 — so
  # what the resolver sees matches what denorm computes.
  if (!is.null(usmca_product_shares) && nrow(usmca_product_shares) > 0) {
    cols <- names(usmca_product_shares)
    share_col <- intersect(c('usmca_share', 'share', 'utilization_share'), cols)[1]
    country_col <- intersect(c('cty_code', 'country', 'census_code'), cols)[1]
    if (!is.na(share_col) && !is.na(country_col) && 'hts10' %in% cols) {
      ups <- usmca_product_shares
      ups_clean <- tibble(
        hts10   = as.character(ups$hts10),
        country = as.character(ups[[country_col]]),
        share   = as.numeric(ups[[share_col]])
      ) %>% filter(!is.na(share), share > 0)

      if (nrow(ups_clean) > 0) {
        usmca_authorities <- c('ieepa_reciprocal', 'ieepa_fentanyl', 'section_122')
        for (auth in usmca_authorities) {
          rows[[paste0('usmca_', auth)]] <- ups_clean %>%
            transmute(
              revision        = revision_id,
              authority       = auth,
              program         = NA_character_,
              hts10           = hts10,
              hts_prefix      = NA_character_,
              country         = country,
              country_group   = NA_character_,
              exemption_type  = 'usmca_eligible',
              exemption_share = share,
              rate_override   = NA_real_,
              source          = paste0('dataweb_spi_', format(as.Date(effective_date), '%Y')),
              valid_from      = vf,
              valid_until     = vu
            )
        }

        # Section 232 auto/MHD: scaled share = share * us_auto_content_share
        # (US-origin content fraction). Restricted to the auto_products and
        # mhd_products lists captured from the denorm pipeline. This row is
        # ON TOP OF the country-agnostic auto assembly rebate emitted below
        # — both apply by the resolver's exemption compounding rule.
        auto_set <- character(0)
        if (!is.null(denorm_state)) {
          auto_set <- unique(c(
            as.character(denorm_state$auto_products %||% character(0)),
            as.character(denorm_state$mhd_products  %||% character(0))
          ))
        }
        us_auto_content_share <- as.numeric(
          pp$auto_rebate$us_auto_content_share %||% 1.0
        )
        if (length(auto_set) > 0 && us_auto_content_share < 1.0) {
          rows[['usmca_section_232_auto']] <- ups_clean %>%
            filter(hts10 %in% auto_set) %>%
            transmute(
              revision        = revision_id,
              authority       = 'section_232',
              program         = NA_character_,
              hts10           = hts10,
              hts_prefix      = NA_character_,
              country         = country,
              country_group   = NA_character_,
              exemption_type  = 'usmca_auto_content',
              exemption_share = pmin(1, pmax(0, share * us_auto_content_share)),
              rate_override   = NA_real_,
              source          = paste0('dataweb_spi_x_us_auto_content_',
                                       format(as.Date(effective_date), '%Y')),
              valid_from      = vf,
              valid_until     = vu
            )
        }
      }
    }
  }

  # ---- Section 122 HTS8 exemptions ----
  #
  # SOURCE OF TRUTH: denorm_state$s122$exempt_hts8.
  #
  # When S122 is in force, the denorm pipeline excludes specific HTS8
  # codes from the blanket rate (resources/s122_exempt_products.csv).
  # We mirror this as full layer-4 exemptions (share = 1.0) keyed by
  # hts_prefix so any product whose hts8 matches receives a 100%
  # exemption from section_122 in the resolver.
  if (!is.null(denorm_state) && !is.null(denorm_state$s122) &&
      isTRUE(denorm_state$s122$in_force) &&
      length(denorm_state$s122$exempt_hts8 %||% character(0)) > 0) {
    rows[['s122_exempt']] <- tibble(
      revision        = revision_id,
      authority       = 'section_122',
      program         = NA_character_,
      hts10           = NA_character_,
      hts_prefix      = as.character(denorm_state$s122$exempt_hts8),
      country         = NA_character_,
      country_group   = NA_character_,
      exemption_type  = 's122_exempt_hts8',
      exemption_share = 1.0,
      rate_override   = NA_real_,
      source          = 's122_exempt_products.csv',
      valid_from      = vf,
      valid_until     = vu
    )
  }

  # NOTE: the Section 232 auto assembly rebate is now baked directly into
  # the layer-3 statutory_rate of every auto/passenger/light_truck row
  # in emit_authority_product_applicability. Modeling it as a layer-4
  # exemption_share would compound incorrectly with the country-deal
  # floor rows (denorm step 4c REPLACES rate_232; multiplicative
  # composition would multiply the floor by the rebate factor). The
  # layer-3 bake matches denorm's order of operations exactly.
  #
  # The CA/MX auto USMCA content scaling is still emitted above as
  # rows[['usmca_section_232_auto']] — that one is product-and-country
  # specific so it lives at layer 4.

  df <- bind_rows(rows)
  .write_parquet_safe(
    df,
    file.path(output_dir, revision_id, 'authority_exemptions.parquet')
  )
  invisible(df)
}


# ---------------------------------------------------------------------------
# Per-revision orchestrator
# ---------------------------------------------------------------------------
#' Emit all four layers for a single revision. Called from
#' calculate_rates_for_revision() as a dual-write side effect.
#'
#' @param products               products tibble from parse_products()
#' @param ch99_data              ch99_data tibble from parse_chapter99()
#' @param ieepa_rates            extracted IEEPA reciprocal rates (may be NULL)
#' @param fentanyl_rates         extracted IEEPA fentanyl rates (may be NULL)
#' @param s232_rates             extracted Section 232 rates list
#' @param heading_product_lists  heading → {products, rate, usmca_exempt} list
#' @param deriv_matched          HTS10 vector of matched 232 derivative products
#' @param ieepa_exempt_products  Annex A HTS10 vector
#' @param floor_exempt_products  floor country exemption tibble
#' @param usmca_product_shares   USMCA utilization shares tibble
#' @param countries              character vector of Census country codes
#' @param pp                     policy_params
#' @param revision_id            revision identifier
#' @param effective_date         revision effective date
#' @param output_dir             root output directory
#'                                (defaults to output/normalized/)
#' @param denorm_state  Optional list of intermediate state captured from
#'   the denormalized pipeline. The emitter prefers these values over its
#'   own re-derivation, eliminating logic-drift between the two paths.
#'   Expected slots: country_ieepa, s232_deals, auto_products, mhd_products,
#'   wood_softwood_products, wood_furn_products, s122. See
#'   src/06_calculate_rates.R near the emit call site for the producer.
emit_normalized_revision <- function(
  products, ch99_data,
  ieepa_rates, fentanyl_rates, s232_rates,
  heading_product_lists = NULL, deriv_matched = character(0),
  ieepa_exempt_products = character(0),
  floor_exempt_products = NULL,
  usmca_product_shares = NULL,
  countries,
  pp,
  revision_id, effective_date,
  valid_from = NULL, valid_until = NULL,
  output_dir = NULL,
  denorm_state = NULL
) {
  output_dir <- output_dir %||% .default_normalized_dir()
  .ensure_dir(file.path(output_dir, revision_id))

  emit_products_base(products, revision_id, effective_date,
                     valid_from = valid_from, valid_until = valid_until,
                     output_dir = output_dir,
                     denorm_state = denorm_state)

  emit_authority_country_rates(
    ieepa_rates, fentanyl_rates, s232_rates, ch99_data, countries,
    revision_id, effective_date, pp, output_dir,
    valid_from = valid_from, valid_until = valid_until,
    denorm_state = denorm_state
  )

  emit_authority_product_applicability(
    products, ch99_data, s232_rates, heading_product_lists, deriv_matched,
    pp, revision_id, effective_date, output_dir,
    valid_from = valid_from, valid_until = valid_until,
    denorm_state = denorm_state
  )

  emit_authority_exemptions(
    ieepa_exempt_products, floor_exempt_products, usmca_product_shares,
    revision_id, effective_date, output_dir,
    valid_from = valid_from, valid_until = valid_until,
    heading_product_lists = heading_product_lists,
    pp = pp,
    denorm_state = denorm_state
  )

  # product_metal_content is revision-independent but this is the only path
  # where we have a list of valid hts10s to pass to load_metal_content().
  # Overwrite on each call — cheap, idempotent.
  emit_product_metal_content_rev(products, deriv_matched, pp, output_dir)

  invisible(TRUE)
}

#' Per-revision metal content emitter. Writes product_metal_content.parquet
#' at the top-level normalized dir, overwriting on each call. Silent no-op
#' if load_metal_content is unavailable.
emit_product_metal_content_rev <- function(products, deriv_matched, pp, output_dir) {
  if (!exists('load_metal_content', mode = 'function')) return(invisible(FALSE))
  if (is.null(products) || !('hts10' %in% names(products))) return(invisible(FALSE))
  metal_cfg <- tryCatch(pp$metal_content, error = function(e) NULL)
  tryCatch({
    mc <- load_metal_content(metal_cfg, unique(products$hts10),
                              deriv_matched %||% character(0))
    if (is.null(mc) || nrow(mc) == 0) return(invisible(FALSE))
    mc_out <- mc %>%
      transmute(
        hts10             = as.character(hts10),
        metal_share       = as.numeric(metal_share %||% 0),
        steel_share       = as.numeric(if ('steel_share' %in% names(.)) steel_share else 0),
        aluminum_share    = as.numeric(if ('aluminum_share' %in% names(.)) aluminum_share else 0),
        copper_share      = as.numeric(if ('copper_share' %in% names(.)) copper_share else 0),
        other_metal_share = as.numeric(if ('other_metal_share' %in% names(.)) other_metal_share else 0)
      )
    .write_parquet_safe(mc_out, file.path(output_dir, 'product_metal_content.parquet'))
  }, error = function(e) {
    message('  emit: product_metal_content skipped: ', conditionMessage(e))
  })
  invisible(TRUE)
}


# ---------------------------------------------------------------------------
# Static emitters (one-shot, revision-independent)
# ---------------------------------------------------------------------------
.default_normalized_dir <- function() {
  if (requireNamespace('here', quietly = TRUE)) {
    here::here('output', 'normalized')
  } else {
    file.path('output', 'normalized')
  }
}

#' Emit revisions.parquet, product_metal_content.parquet, and
#' country_group_membership.parquet. These are revision-independent but
#' this function is safe to call from within a per-revision loop (it
#' overwrites each call).
emit_normalized_statics <- function(revisions_df, pp, output_dir = NULL) {
  output_dir <- output_dir %||% .default_normalized_dir()
  .ensure_dir(output_dir)

  # ---- revisions ----
  if (!is.null(revisions_df) && nrow(revisions_df) > 0) {
    rev_out <- revisions_df %>%
      mutate(
        revision         = as.character(revision),
        effective_date   = as.Date(effective_date),
        valid_from       = as.Date(valid_from),
        valid_until      = as.Date(valid_until),
        policy_event     = if ('policy_event' %in% names(.)) as.character(policy_event)
                           else NA_character_,
        ieepa_invalidated = if ('ieepa_invalidated' %in% names(.)) as.logical(ieepa_invalidated)
                            else FALSE
      ) %>%
      select(revision, effective_date, valid_from, valid_until,
             policy_event, ieepa_invalidated)
    .write_parquet_safe(rev_out, file.path(output_dir, 'revisions.parquet'))
  }

  # ---- product_metal_content ----
  # load_metal_content() lives in helpers.R and expects (metal_cfg, hts10s, deriv).
  # For a revision-independent static table we pass all hts10s and an empty
  # deriv vector — scaling logic is applied at query time, not at emit time.
  if (exists('load_metal_content', mode = 'function') && !is.null(pp)) {
    tryCatch({
      metal_cfg <- pp$metal_content
      # Read the full BEA table directly if load_metal_content can handle NULL
      # hts10 filter; otherwise caller must pass a product list.
      mc <- load_metal_content(metal_cfg, character(0), character(0))
      if (!is.null(mc) && nrow(mc) > 0) {
        mc_out <- mc %>%
          transmute(
            hts10             = as.character(hts10),
            metal_share       = as.numeric(metal_share %||% 0),
            steel_share       = as.numeric(if ('steel_share' %in% names(.)) steel_share else 0),
            aluminum_share    = as.numeric(if ('aluminum_share' %in% names(.)) aluminum_share else 0),
            copper_share      = as.numeric(if ('copper_share' %in% names(.)) copper_share else 0),
            other_metal_share = as.numeric(if ('other_metal_share' %in% names(.)) other_metal_share else 0)
          )
        .write_parquet_safe(mc_out,
                            file.path(output_dir, 'product_metal_content.parquet'))
      }
    }, error = function(e) {
      message('emit_normalized_statics: product_metal_content skipped: ', e$message)
    })
  }

  # ---- mfn_exemption_shares ----
  # Static (hs2, cty_code) preference shares from Census calculated-duty data.
  # The denormalized pipeline applies these at 06_calculate_rates.R:1789-1808 as
  # base_rate *= (1 - share), preserving statutory_base_rate as the
  # pre-adjustment value. Re-emit as a parquet so the resolver can apply the
  # identical adjustment without re-reading the CSV. Rows are clamped to
  # [0, 1] by load_mfn_exemption_shares().
  #
  # When pp$MFN_EXEMPTION$exclude_usmca_countries is TRUE (the default), the
  # denormalized path zeroes out CA/MX shares so USMCA product-level shares
  # can own the entire reduction end-to-end (step 7 in 06_calculate_rates.R).
  # Mirror that filter at emit time so the resolver doesn't need to know
  # about the policy flag.
  if (exists('load_mfn_exemption_shares', mode = 'function')) {
    tryCatch({
      mfn_shares <- load_mfn_exemption_shares()
      if (!is.null(mfn_shares) && nrow(mfn_shares) > 0) {
        exclude_usmca <- isTRUE(pp$MFN_EXEMPTION$exclude_usmca_countries)
        if (exclude_usmca) {
          usmca_codes <- c(pp$country_codes$CTY_CANADA,
                           pp$country_codes$CTY_MEXICO)
          usmca_codes <- usmca_codes[!is.null(usmca_codes) &
                                       !is.na(usmca_codes) &
                                       nzchar(as.character(usmca_codes))]
          if (length(usmca_codes) > 0) {
            mfn_shares <- mfn_shares %>%
              filter(!as.character(cty_code) %in% as.character(usmca_codes))
          }
        }
        mfn_out <- mfn_shares %>%
          transmute(
            hs2             = as.character(hs2),
            country         = as.character(cty_code),
            exemption_share = as.numeric(exemption_share)
          )
        .write_parquet_safe(mfn_out,
                            file.path(output_dir, 'mfn_exemption_shares.parquet'))
      }
    }, error = function(e) {
      message('emit_normalized_statics: mfn_exemption_shares skipped: ', e$message)
    })
  }

  # ---- country_group_membership ----
  if (!is.null(pp)) {
    groups <- list()
    if (!is.null(pp$EU27_CODES)) {
      groups[['eu']] <- tibble(country_group = 'eu',
                                country = as.character(pp$EU27_CODES))
    }
    if (!is.null(pp$country_codes$CTY_JAPAN)) {
      groups[['japan']] <- tibble(country_group = 'japan',
                                   country = as.character(pp$country_codes$CTY_JAPAN))
    }
    if (!is.null(pp$country_codes$CTY_SKOREA)) {
      groups[['korea']] <- tibble(country_group = 'korea',
                                   country = as.character(pp$country_codes$CTY_SKOREA))
    }
    swiss <- c(pp$country_codes$CTY_SWITZERLAND, pp$country_codes$CTY_LIECHTENSTEIN)
    swiss <- swiss[!is.null(swiss) & nzchar(as.character(swiss))]
    if (length(swiss) > 0) {
      groups[['swiss']] <- tibble(country_group = 'swiss',
                                   country = as.character(swiss))
    }
    cg_df <- bind_rows(groups)
    if (nrow(cg_df) > 0) {
      .write_parquet_safe(cg_df,
                          file.path(output_dir, 'country_group_membership.parquet'))
    }
  }

  invisible(TRUE)
}
