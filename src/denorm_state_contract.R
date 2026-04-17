# =============================================================================
# denorm_state contract validator
# =============================================================================
#
# `denorm_state` is the glue between `calculate_rates_for_revision` and
# `emit_normalized_revision`. See docs/adrs/001-denorm-state-pattern.md for
# the architectural rationale.
#
# This file defines `validate_denorm_state(ds, revision_id)` — a postcondition
# called from `calculate_rates_for_revision` right before the emit call.
# Every expected slot is asserted present and shape-checked; a missing slot
# fails loudly with a named error rather than silently dropping a normalized
# layer.
#
# The contract is deliberately liberal about EMPTY slots: some revisions have
# no active S232 deals, some pre-2026 revisions have no annex classification.
# Empty tibbles / empty lists / FALSE `in_force` are valid. What's NOT valid
# is a missing slot name or a value with the wrong type.
#
# To add a new slot: extend `.DENORM_STATE_SCHEMA` below with the slot's
# name, required type, and a validator function. Then update the producer
# in src/06_calculate_rates.R, the consumer in src/07_emit_normalized.R,
# the contract table in docs/normalized-schema.md, and the catalog in
# docs/adrs/001-denorm-state-pattern.md.
# =============================================================================

suppressPackageStartupMessages({
  library(tibble)
})


# ---------------------------------------------------------------------------
# Slot validators
# ---------------------------------------------------------------------------
# Each validator returns NULL on success or a character string describing the
# violation. The top-level `validate_denorm_state` collects any violations and
# throws a single error with all of them.

.is_character_vec <- function(x) is.null(x) || is.character(x)

.validate_country_ieepa <- function(x) {
  if (is.null(x)) return('NULL (expected tibble or NULL from the IEEPA-inactive branch)')
  if (!inherits(x, 'data.frame')) return('not a data.frame / tibble')
  required <- c('census_code', 'ieepa_country_rate', 'ieepa_type')
  missing <- setdiff(required, names(x))
  if (length(missing) > 0) {
    return(paste0('missing columns: ', paste(missing, collapse = ', ')))
  }
  NULL
}

.validate_s232_deals <- function(x) {
  if (is.null(x)) return(NULL)  # empty is fine
  if (!is.list(x)) return('not a list')
  if (length(x) == 0) return(NULL)
  # Each element must carry the deal tuple
  required <- c('program', 'census_codes', 'deal_products', 'rate', 'rate_type')
  for (i in seq_along(x)) {
    missing <- setdiff(required, names(x[[i]]))
    if (length(missing) > 0) {
      return(paste0('element ', i, ' missing fields: ',
                    paste(missing, collapse = ', ')))
    }
  }
  NULL
}

.validate_product_set <- function(label) {
  function(x) {
    if (is.null(x)) return(NULL)  # empty is fine
    if (!.is_character_vec(x)) return(paste0(label, ' is not a character vector'))
    NULL
  }
}

.validate_s122 <- function(x) {
  if (is.null(x)) return(NULL)  # pre-s122 revisions
  if (!is.list(x)) return('not a list')
  required <- c('in_force', 'rate', 'exempt_hts8')
  missing <- setdiff(required, names(x))
  if (length(missing) > 0) {
    return(paste0('missing fields: ', paste(missing, collapse = ', ')))
  }
  if (!is.logical(x$in_force)) return('in_force is not logical')
  if (!is.numeric(x$rate))     return('rate is not numeric')
  if (!.is_character_vec(x$exempt_hts8))
    return('exempt_hts8 is not a character vector')
  NULL
}

.validate_heading_overlap <- function(x) {
  if (is.null(x)) return(NULL)  # empty is fine
  if (!inherits(x, 'data.frame')) return('not a data.frame / tibble')
  required <- c('hts10', 'rate_232', 'deriv_type')
  missing <- setdiff(required, names(x))
  if (length(missing) > 0) {
    return(paste0('missing columns: ', paste(missing, collapse = ', ')))
  }
  NULL
}

.validate_product_annex <- function(x) {
  if (is.null(x)) return(NULL)  # pre-annex revisions
  if (!inherits(x, 'data.frame')) return('not a data.frame / tibble')
  required <- c('hts10', 's232_annex')
  missing <- setdiff(required, names(x))
  if (length(missing) > 0) {
    return(paste0('missing columns: ', paste(missing, collapse = ', ')))
  }
  NULL
}


# ---------------------------------------------------------------------------
# Schema — the source of truth for expected slots
# ---------------------------------------------------------------------------
.DENORM_STATE_SCHEMA <- list(
  country_ieepa          = .validate_country_ieepa,
  s232_deals             = .validate_s232_deals,
  auto_products          = .validate_product_set('auto_products'),
  mhd_products           = .validate_product_set('mhd_products'),
  wood_softwood_products = .validate_product_set('wood_softwood_products'),
  wood_furn_products     = .validate_product_set('wood_furn_products'),
  s122                   = .validate_s122,
  heading_overlap        = .validate_heading_overlap,
  product_annex          = .validate_product_annex
)


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

#' Assert that a denorm_state list satisfies the Phase 2b contract.
#'
#' Called as a postcondition of `calculate_rates_for_revision` right before
#' the emit call. Fails loudly with a named error enumerating every violation.
#'
#' @param ds The denorm_state list to validate.
#' @param revision_id Revision identifier (character), used in error message.
#' @param strict If TRUE (default), missing slots are hard errors. If FALSE,
#'   they become warnings — used by legacy paths that haven't fully migrated.
#' @return invisible(TRUE) on success.
validate_denorm_state <- function(ds, revision_id = NA_character_, strict = TRUE) {
  if (is.null(ds)) {
    msg <- paste0('denorm_state is NULL (revision=', revision_id, ')')
    if (strict) stop(msg) else warning(msg)
    return(invisible(FALSE))
  }
  if (!is.list(ds)) {
    stop('denorm_state is not a list (revision=', revision_id, ')')
  }

  violations <- character(0)

  # Unknown slots are warnings, not errors — tolerates future additions.
  unknown <- setdiff(names(ds), names(.DENORM_STATE_SCHEMA))
  if (length(unknown) > 0) {
    message('  [denorm_state] unknown slots present (ok for forward compat): ',
            paste(unknown, collapse = ', '))
  }

  # Each expected slot must be present and pass its validator.
  for (slot in names(.DENORM_STATE_SCHEMA)) {
    if (!slot %in% names(ds)) {
      violations <- c(violations,
                      paste0('missing slot: ', slot))
      next
    }
    validator <- .DENORM_STATE_SCHEMA[[slot]]
    err <- validator(ds[[slot]])
    if (!is.null(err)) {
      violations <- c(violations,
                      paste0('slot ', slot, ' — ', err))
    }
  }

  if (length(violations) > 0) {
    msg <- paste0(
      'denorm_state contract violated (revision=', revision_id, '):\n  - ',
      paste(violations, collapse = '\n  - ')
    )
    if (strict) stop(msg) else warning(msg)
    return(invisible(FALSE))
  }

  invisible(TRUE)
}
