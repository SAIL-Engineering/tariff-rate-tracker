# =============================================================================
# Phase 2d — Query engine for the normalized rate schema
# =============================================================================
#
# PUBLIC API:
#   resolve_rate_from_normalized(normalized_dir, hts10, country, revision)
#     Returns a one-row tibble conforming (as far as reasonable) to
#     RATE_SCHEMA in src/helpers.R. The returned row is produced by
#     composing layers 1-4 + product_metal_content and then running the
#     same stacking engine (apply_stacking_rules) as the denormalized
#     pipeline. This is the read-path that replaces DuckDB direct scans
#     once Phase 3 flips.
#
# Design principles:
#   - Trust layer 3's absence. If no applicability row matches a
#     (product, authority), that authority is zero. No heuristics.
#   - Reuse apply_stacking_rules() verbatim. The stacking math is
#     load-bearing and tested by the denormalized pipeline; keeping a
#     single implementation is the only way to guarantee parity.
#   - Read-only. No side effects, no caching state, no mutable globals.
#   - Lazy on I/O: each call reads four per-revision parquets and the
#     two static parquets. For bulk parity runs, a caller can cache the
#     table reads outside this function.
# =============================================================================

suppressPackageStartupMessages({
  library(tidyverse)
  library(arrow)
})

# Make sure the stacking engine is available. Sourced once on first call.
.stacking_sourced <- FALSE
.ensure_stacking_sourced <- function() {
  if (.stacking_sourced) return(invisible(TRUE))
  if (exists('apply_stacking_rules', mode = 'function')) {
    .stacking_sourced <<- TRUE
    return(invisible(TRUE))
  }
  # Attempt to source helpers.R from the local src/ directory.
  helpers <- tryCatch(
    if (requireNamespace('here', quietly = TRUE))
      here::here('src', 'helpers.R')
    else
      file.path('src', 'helpers.R'),
    error = function(e) file.path('src', 'helpers.R')
  )
  if (file.exists(helpers)) {
    source(helpers, local = FALSE)
    .stacking_sourced <<- TRUE
  } else {
    stop('resolve_rate_from_normalized: cannot locate apply_stacking_rules. ',
         'Expected src/helpers.R on the search path.')
  }
  invisible(TRUE)
}

`%||%` <- function(a, b) if (!is.null(a) && length(a) > 0 && !all(is.na(a))) a else b


# ---------------------------------------------------------------------------
# Layer readers (one per table, read-once, return the filtered slice).
# ---------------------------------------------------------------------------
.read_parquet_if_exists <- function(path) {
  if (!file.exists(path)) return(NULL)
  tryCatch(arrow::read_parquet(path), error = function(e) NULL)
}

.read_layer <- function(normalized_dir, revision, filename) {
  .read_parquet_if_exists(file.path(normalized_dir, revision, filename))
}


# ---------------------------------------------------------------------------
# Product-match predicate for layer 3 rows
# ---------------------------------------------------------------------------
# Returns a logical vector indexing rows of `apa` that legally cover the
# given hts10. Handles three cases:
#   - Explicit hts10 match
#   - Blanket (both hts10 and hts_prefix are NA)
#   - Prefix match (hts_prefix is non-NA and is a leading substring of hts10)
.matches_product <- function(apa, hts10) {
  if (is.null(apa) || nrow(apa) == 0) return(logical(0))
  exact <- !is.na(apa$hts10) & apa$hts10 == hts10
  blanket <- is.na(apa$hts10) & (is.na(apa$hts_prefix) | apa$hts_prefix == '')
  prefix <- !is.na(apa$hts_prefix) & apa$hts_prefix != '' &
    startsWith(hts10, apa$hts_prefix)
  exact | blanket | prefix
}


# ---------------------------------------------------------------------------
# Per-authority composition
# ---------------------------------------------------------------------------
# Given all layer-3 rows that match a product, pick one winner per authority.
# Sort keys (descending):
#   1. precedence  — explicit override of the precedence column
#   2. specificity — explicit hts10 > longest hts_prefix > blanket
#   3. statutory_rate — when an authority has multiple equally-specific rows
#      (e.g. a China product that appears on both S301 list_1 at 25% and
#      list_4a at 7.5%, both keyed by hts_prefix=hts8), the higher statutory
#      rate wins. Matches the denormalized pipeline, which applies the
#      maximum per-authority rate rather than the first match found.
# Returns a tibble with one row per distinct authority present.
.pick_winner_per_authority <- function(apa_matches) {
  if (is.null(apa_matches) || nrow(apa_matches) == 0) {
    return(tibble())
  }
  apa_matches %>%
    mutate(
      .specificity = case_when(
        !is.na(hts10) & hts10 != ''           ~ 1000L + nchar(hts10),
        !is.na(hts_prefix) & hts_prefix != '' ~ nchar(hts_prefix),
        TRUE                                   ~ 0L
      ),
      .rate_for_sort = coalesce(as.numeric(statutory_rate), 0)
    ) %>%
    group_by(authority) %>%
    arrange(desc(precedence), desc(.specificity), desc(.rate_for_sort),
            .by_group = TRUE) %>%
    slice_head(n = 1) %>%
    ungroup() %>%
    select(-.specificity, -.rate_for_sort)
}


# Apply rate_type semantics shared across layer-2 and layer-3:
#   surcharge   → rate verbatim
#   floor       → max(0, rate - base_rate)
#   passthrough → 0
#   override    → rate verbatim (alias for surcharge, used by S232 deals)
#   anything else / NA → rate verbatim (default = surcharge)
# Same formula the denorm pipeline uses; centralizing here means a future
# rate_type addition only needs one edit.
.apply_rate_type <- function(rate, rate_type, base_rate) {
  if (is.null(rate_type) || length(rate_type) == 0 || is.na(rate_type)) {
    return(as.numeric(rate))
  }
  if (rate_type == 'floor') {
    return(max(0, as.numeric(rate) - as.numeric(base_rate)))
  }
  if (rate_type == 'passthrough') {
    return(0)
  }
  as.numeric(rate)
}


# For a single layer-3 winner, compute the effective per-authority rate.
# Returns NA if the authority has no applicable rate for this (product, country).
#
# `base_rate` is the current (post-MFN-exemption) base rate — required for
# floor-type rows, whose effective rate is `max(0, rate - base_rate)` and
# must be evaluated against the same base_rate the stacker sees.
#
# Authorities whose rate is country-driven (ieepa_reciprocal, ieepa_fentanyl,
# section_122) are ALWAYS resolved through the layer-2 country lookup. The
# layer-3 winner for these is a blanket marker (statutory_rate=NA) that
# only conveys product applicability; the rate value lives in layer 2.
#
# For other authorities (section_232, section_301, section_201, other), the
# layer-3 winner carries the rate directly. Its rate_type column is honored
# (set to 'floor' for the S232 country deal rows emitted via denorm_state).
.compute_authority_rate <- function(winner, acr, pmc_row, country, base_rate = 0) {
  auth <- winner$authority
  prog <- winner$program

  # country_scope filtering is now done BEFORE winner selection (in the
  # main function at the apa_matches pre-filter step), so we don't
  # need to re-check it here. If this function is called, the winner's
  # scope has already been validated.
  stat <- winner$statutory_rate
  ch99_code <- winner$ch99_code
  rate_type_winner <- if ('rate_type' %in% names(winner)) winner$rate_type else NA_character_

  # Authorities whose per-country rate is the source of truth.
  layer2_authorities <- c('ieepa_reciprocal', 'ieepa_fentanyl', 'section_122')
  needs_layer2 <- is.na(stat) || auth %in% layer2_authorities

  if (needs_layer2) {
    match <- acr %>%
      filter(authority == auth,
             !is.na(country),
             country == !!country)

    # When the layer-3 winner specifies a ch99_code (e.g. fentanyl
    # carveout at 9903.01.13), narrow the layer-2 lookup to that code
    # so the resolver picks the carveout's 0.1 rate, not the general
    # 0.25. Without this, which.max returns the highest-rate layer-2
    # row regardless of which program the layer-3 winner selected.
    winner_ch99 <- ch99_code  # from layer-3 winner
    if (!is.na(winner_ch99) && nzchar(winner_ch99) &&
        'ch99_code' %in% names(match)) {
      narrowed <- match %>% filter(ch99_code == winner_ch99)
      if (nrow(narrowed) > 0) match <- narrowed
      # Fall through to full match if narrowing produced 0 rows
    }

    if (nrow(match) == 0) {
      return(list(rate = NA_real_, ch99_code = NA_character_,
                  deriv_type = winner$deriv_type))
    }
    idx <- which.max(match$statutory_rate)
    stat <- match$statutory_rate[idx]
    layer2_ch99 <- match$ch99_code[idx]
    if (!is.na(layer2_ch99)) ch99_code <- layer2_ch99

    rt <- if ('rate_type' %in% names(match)) match$rate_type[idx] else NA_character_
    stat <- .apply_rate_type(stat, rt, base_rate)
  } else {
    # Use layer-3 statutory_rate, honoring its rate_type (S232 country
    # deals are emitted with rate_type='floor' so the resolver computes
    # max(0, deal_rate - base_rate) here, mirroring denorm step 4c).
    stat <- .apply_rate_type(stat, rate_type_winner, base_rate)
  }

  # Apply metal scaling for derivative programs.
  sd <- winner$scaling_dimension %||% 'none'
  if (!is.na(sd) && sd != 'none' && !is.null(pmc_row) && nrow(pmc_row) > 0) {
    share <- switch(
      sd,
      metal_share    = pmc_row$metal_share %||% 1.0,
      steel_share    = pmc_row$steel_share %||% 0,
      aluminum_share = pmc_row$aluminum_share %||% 0,
      copper_share   = pmc_row$copper_share %||% 0,
      1.0
    )
    stat <- stat * as.numeric(share)
  }

  list(
    rate = as.numeric(stat),
    ch99_code = as.character(ch99_code),
    deriv_type = winner$deriv_type
  )
}


# Layer 4 exemption compounding. Given a set of exemption rows that apply to
# a (product, country, authority), returns the cumulative exemption share in
# [0, 1] where 0 means "no exemption" and 1 means "full exemption". Compound
# rule: share = 1 - prod(1 - share_i).
.compound_exemption_share <- function(exemptions, auth, hts10, country) {
  if (is.null(exemptions) || nrow(exemptions) == 0) return(0)
  mask <- (is.na(exemptions$authority) | exemptions$authority == auth) &
    (is.na(exemptions$hts10)     | exemptions$hts10 == hts10) &
    (is.na(exemptions$country)   | exemptions$country == country) &
    (is.na(exemptions$hts_prefix) | sapply(exemptions$hts_prefix, function(p)
      !is.na(p) && nchar(p) > 0 && startsWith(hts10, p)))
  if (!any(mask)) return(0)
  shares <- as.numeric(exemptions$exemption_share[mask])
  shares[is.na(shares)] <- 0
  # Short-circuit on full exemption
  if (any(shares >= 1 - 1e-12)) return(1)
  1 - prod(1 - shares)
}


# ---------------------------------------------------------------------------
# Main entry point
# ---------------------------------------------------------------------------
#' Reconstruct a single ProductRate row from the normalized layers.
#'
#' @param normalized_dir Path to the normalized output root (contains
#'   {revision}/ subdirectories and the static parquets).
#' @param hts10   10-digit HTS code (digits only)
#' @param country Census country code (character)
#' @param revision Revision id (e.g. "2025_rev_7")
#' @return One-row tibble with the columns the stacking engine writes, plus
#'   layer-1 product metadata. Returns NULL if the product has no row in
#'   products_base for the revision.
resolve_rate_from_normalized <- function(normalized_dir, hts10, country, revision) {
  .ensure_stacking_sourced()

  hts10 <- as.character(hts10)
  country <- as.character(country)
  revision <- as.character(revision)

  # ---- Layer 1: products_base ----
  pb <- .read_layer(normalized_dir, revision, 'products_base.parquet')
  if (is.null(pb)) {
    stop('products_base.parquet missing for revision ', revision)
  }
  base_row <- pb %>% filter(hts10 == !!hts10)
  if (nrow(base_row) == 0) return(NULL)
  base_row <- base_row[1, ]

  # ---- Layer 3: authority_product_applicability (product-matched) ----
  apa <- .read_layer(normalized_dir, revision, 'authority_product_applicability.parquet')
  apa_matches <- if (!is.null(apa) && nrow(apa) > 0) {
    apa[.matches_product(apa, hts10), , drop = FALSE]
  } else {
    tibble()
  }

  # Pre-filter by country_scope BEFORE winner selection. A row whose
  # country_scope is non-NA and doesn't include the queried country can
  # never produce a valid rate — but if it's left in the candidate set
  # its higher precedence will shadow a lower-precedence blanket row
  # that IS valid. Moving the filter here means the blanket row wins
  # naturally when no deal scope matches the country, exactly mirroring
  # the denorm order where country-specific deals REPLACE the blanket
  # only for their eligible countries.
  if (nrow(apa_matches) > 0 && 'country_scope' %in% names(apa_matches)) {
    apa_matches <- apa_matches %>%
      filter({
        sc <- country_scope
        is.na(sc) | sc == '' | vapply(sc, function(s) {
          is.na(s) || s == '' || country %in% strsplit(s, '|', fixed = TRUE)[[1]]
        }, logical(1))
      })
  }

  winners <- .pick_winner_per_authority(apa_matches)

  # ---- Layer 2: authority_country_rates (country-filtered) ----
  acr <- .read_layer(normalized_dir, revision, 'authority_country_rates.parquet')
  if (is.null(acr)) acr <- tibble()

  # ---- Layer 4: authority_exemptions (no filter — compound in place) ----
  ae <- .read_layer(normalized_dir, revision, 'authority_exemptions.parquet')

  # ---- product_metal_content (static) ----
  pmc <- .read_parquet_if_exists(file.path(normalized_dir, 'product_metal_content.parquet'))
  pmc_row <- if (!is.null(pmc)) pmc %>% filter(hts10 == !!hts10) else NULL
  if (!is.null(pmc_row) && nrow(pmc_row) == 0) pmc_row <- NULL

  # ---- Preference-adjusted base rate ----
  # Mirrors the denormalized pipeline's combined steps 6c (MFN exemption
  # shares for non-USMCA countries) and 7 (USMCA per-product utilization
  # shares for CA/MX). The denorm path at src/06_calculate_rates.R:1786-1899
  # keeps statutory_base_rate as the pre-adjustment value and reduces
  # base_rate fractionally; we do the same here so the resolver and the
  # rest of the stack see the same number the denorm row carries.
  #
  # The emitter filters CA/MX out of mfn_exemption_shares when
  # pp$MFN_EXEMPTION$exclude_usmca_countries is TRUE, so the two reductions
  # never double-apply for the same (hts10, country): MFN shares cover
  # non-USMCA countries, USMCA shares cover CA/MX.
  statutory_base_rate <- as.numeric(base_row$base_rate %||% 0)
  base_rate <- statutory_base_rate
  mfn_shares <- .read_parquet_if_exists(file.path(normalized_dir,
                                                  'mfn_exemption_shares.parquet'))
  if (!is.null(mfn_shares) && nrow(mfn_shares) > 0) {
    hs2 <- substr(hts10, 1, 2)
    mfn_hit <- mfn_shares %>%
      filter(hs2 == !!hs2, country == !!country)
    if (nrow(mfn_hit) > 0) {
      share <- pmin(pmax(as.numeric(mfn_hit$exemption_share[1]), 0), 1)
      base_rate <- base_rate * (1 - share)
    }
  }

  # USMCA per-product share applied to base_rate. Layer 4 already encodes
  # the same share for ieepa_reciprocal/ieepa_fentanyl/section_122; the
  # base_rate reduction reads the same row by (hts10, country) so any
  # change to the upstream USMCA shares flows through one source.
  ae_pre <- .read_layer(normalized_dir, revision, 'authority_exemptions.parquet')
  if (!is.null(ae_pre) && nrow(ae_pre) > 0 && 'exemption_type' %in% names(ae_pre)) {
    usmca_hit <- ae_pre %>%
      filter(exemption_type == 'usmca_eligible',
             authority      == 'ieepa_reciprocal',
             !is.na(hts10), hts10 == !!hts10,
             !is.na(country), country == !!country)
    if (nrow(usmca_hit) > 0) {
      usmca_share <- pmin(pmax(as.numeric(usmca_hit$exemption_share[1]), 0), 1)
      base_rate <- base_rate * (1 - usmca_share)
    }
  }

  # ---- Compose per-authority effective rates ----
  # Initialize all authorities to 0. Fill in from layer-3 winners.
  effective <- list(
    section_232       = 0,
    section_301       = 0,
    ieepa_reciprocal  = 0,
    ieepa_fentanyl    = 0,
    section_122       = 0,
    section_201       = 0,
    other             = 0
  )
  ch99_codes <- list(
    section_232       = NA_character_,
    section_301       = NA_character_,
    ieepa_reciprocal  = NA_character_,
    ieepa_fentanyl    = NA_character_,
    section_122       = NA_character_,
    section_201       = NA_character_,
    other             = NA_character_
  )
  deriv_type <- NA_character_

  if (nrow(winners) > 0) {
    for (i in seq_len(nrow(winners))) {
      w <- winners[i, ]
      result <- .compute_authority_rate(w, acr, pmc_row, country,
                                        base_rate = base_rate)
      if (is.na(result$rate) || result$rate <= 0) next
      auth <- w$authority

      # Apply layer-4 exemptions
      ex_share <- .compound_exemption_share(ae, auth, hts10, country)
      if (ex_share >= 1 - 1e-12) next
      effective[[auth]] <- result$rate * (1 - ex_share)
      ch99_codes[[auth]] <- result$ch99_code
      if (auth == 'section_232' && !is.na(result$deriv_type)) {
        deriv_type <- result$deriv_type
      }
    }
  }

  # ---- Assemble wide tibble for stacking engine ----
  # The stacking engine reads the abbreviated column names (rate_232,
  # rate_ieepa_recip, etc.). Also supplies metal_share and per-type shares
  # so the non-metal fill logic kicks in for derivatives. base_rate and
  # statutory_base_rate were computed above (pre- and post-MFN adjustment).
  ms <- function(col, default = 0) {
    if (!is.null(pmc_row) && col %in% names(pmc_row)) {
      v <- pmc_row[[col]]
      if (length(v) && !is.na(v[1])) return(as.numeric(v[1]))
    }
    default
  }

  # s232_annex is a per-product classification attached in layer 1
  # (emit_products_base). Forward it into the wide tibble so
  # apply_stacking_rules honors the post-annex nonmetal_share=0
  # override — this is what keeps the baseline ETR at the annex
  # boundary consistent with the denorm pipeline.
  s232_annex_val <- if ('s232_annex' %in% names(base_row)) {
    v <- base_row$s232_annex
    if (length(v) == 0 || is.na(v[1])) NA_character_ else as.character(v[1])
  } else NA_character_

  wide <- tibble(
    hts10              = hts10,
    country            = country,
    base_rate          = base_rate,
    statutory_base_rate = statutory_base_rate,
    rate_232           = as.numeric(effective$section_232),
    rate_301           = as.numeric(effective$section_301),
    rate_ieepa_recip   = as.numeric(effective$ieepa_reciprocal),
    rate_ieepa_fent    = as.numeric(effective$ieepa_fentanyl),
    rate_s122          = as.numeric(effective$section_122),
    rate_section_201   = as.numeric(effective$section_201),
    rate_other         = as.numeric(effective$other),
    metal_share        = ms('metal_share', 1.0),
    steel_share        = ms('steel_share', 0),
    aluminum_share     = ms('aluminum_share', 0),
    copper_share       = ms('copper_share', 0),
    other_metal_share  = ms('other_metal_share', 0),
    deriv_type         = deriv_type,
    is_copper_heading  = FALSE,
    s232_annex         = s232_annex_val
  )

  # ---- Apply stacking rules (delegated to helpers.R) ----
  cty_china <- '5700'
  stacked <- apply_stacking_rules(wide, cty_china = cty_china,
                                   stacking_method = 'mutual_exclusion')

  # ---- Attach layer-1 product metadata ----
  stacked %>%
    mutate(
      ch99_code_232            = ch99_codes$section_232,
      ch99_code_301            = ch99_codes$section_301,
      ch99_code_ieepa_recip    = ch99_codes$ieepa_reciprocal,
      ch99_code_ieepa_fent     = ch99_codes$ieepa_fentanyl,
      ch99_code_s122           = ch99_codes$section_122,
      ch99_code_s201           = ch99_codes$section_201,
      rate_column2             = base_row$rate_column2,
      rate_column2_raw         = base_row$rate_column2_raw,
      rate_special             = base_row$rate_special,
      rate_special_raw         = base_row$rate_special_raw,
      special_programs_json    = base_row$special_programs_json,
      rate_basis               = base_row$rate_basis,
      specific_amount          = base_row$specific_amount,
      specific_rate_unit       = base_row$specific_rate_unit,
      reported_unit_1          = base_row$reported_unit_1,
      reported_unit_2          = base_row$reported_unit_2,
      duty_basis_unit          = base_row$duty_basis_unit,
      is_qty_duty_relevant     = base_row$is_qty_duty_relevant,
      quantity_source          = base_row$quantity_source,
      rounding_rule            = base_row$rounding_rule,
      calc_status              = base_row$calc_status,
      revision                 = revision,
      effective_date           = base_row$effective_date,
      valid_from               = base_row$valid_from,
      valid_until              = base_row$valid_until,
      usmca_eligible           = FALSE  # Phase 2c TODO: detect from layer-4 usmca exemption
    )
}
