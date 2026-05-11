# =============================================================================
# Stacking-Validation Harness
# =============================================================================
#
# Anchors stacking rules (S122, S232, S301, IEEPA, fentanyl, USMCA) to
# proclamation sources by asserting per-row expectations against the local
# rate_timeseries Parquet. Cases live as data in tests/cases/stacking_cases.csv
# — adding a case = adding a CSV row, never editing R code.
#
# Usage:
#   Rscript tests/test_stacking_harness.R
#
# Requires: local Parquet at data/timeseries/rate_timeseries_parquet/
# =============================================================================

suppressPackageStartupMessages({
  library(tidyverse)
  library(here)
  library(readr)
})

source(here('src', 'helpers.R'))

CASES_PATH   <- here('tests', 'cases', 'stacking_cases.csv')
PARQUET_PATH <- here('data', 'timeseries', 'rate_timeseries_parquet')

pass_count <- 0
fail_count <- 0

`%||%` <- function(a, b) {
  if (is.null(a) || (length(a) == 1 && is.na(a))) b else a
}

# Columns to compare when the corresponding expected_* is non-NA.
# Map: expected_<colname> in CSV  →  <colname> in parquet row.
RATE_COMPARISONS <- c(
  expected_rate_232        = 'rate_232',
  expected_rate_s122       = 'rate_s122',
  expected_rate_301        = 'rate_301',
  expected_rate_ieepa_recip = 'rate_ieepa_recip',
  expected_rate_ieepa_fent  = 'rate_ieepa_fent',
  expected_rate_section_201 = 'rate_section_201',
  expected_rate_other      = 'rate_other',
  expected_total_additional = 'total_additional',
  expected_total_rate      = 'total_rate',
  expected_metal_share     = 'metal_share'
)

# Boolean columns (exact match, no tolerance)
BOOL_COMPARISONS <- c(
  expected_usmca_eligible = 'usmca_eligible'
)

# ---- Assertion helpers ------------------------------------------------------

fmt_num <- function(x) {
  if (is.na(x)) return('NA')
  formatC(x, format = 'f', digits = 6)
}

assert_numeric <- function(actual, expected, tol, label) {
  if (is.na(expected)) return(invisible(NULL))     # skip — nothing pinned
  if (is.na(actual)) {
    stop(sprintf('%s: expected %s but actual is NA', label, fmt_num(expected)))
  }
  if (abs(actual - expected) > tol) {
    stop(sprintf('%s: expected %s, got %s (diff %s, tol %s)',
                 label, fmt_num(expected), fmt_num(actual),
                 fmt_num(abs(actual - expected)), fmt_num(tol)))
  }
}

assert_bool <- function(actual, expected, label) {
  if (is.na(expected)) return(invisible(NULL))
  expected_lgl <- as.logical(expected)
  if (!identical(as.logical(actual), expected_lgl)) {
    stop(sprintf('%s: expected %s, got %s',
                 label, expected_lgl, as.logical(actual)))
  }
}

run_case <- function(case_row, ds) {
  case_id <- case_row$case_id
  desc    <- case_row$description %||% ''
  label   <- paste0(case_id, if (nzchar(desc)) paste0(' — ', desc) else '')

  tryCatch({
    # Required filters
    hts10    <- as.character(case_row$hts10)
    country  <- as.character(case_row$country)
    revision <- as.character(case_row$revision)
    tol      <- case_row$tolerance %||% 1e-6
    expected_n <- if (is.na(case_row$expected_row_count)) 1 else as.integer(case_row$expected_row_count)

    rows <- query_rates(
      ds,
      countries = country,
      hts_codes = hts10,
      revisions = revision
    ) %>% collect()

    # Date filter (optional — expected_row_count interpreted relative to filtered set)
    if (!is.na(case_row$effective_date)) {
      d <- as.Date(case_row$effective_date)
      rows <- rows %>%
        filter(valid_from <= d, valid_until >= d)
    }

    if (nrow(rows) != expected_n) {
      stop(sprintf('row count: expected %d, got %d (filter: hts=%s, country=%s, revision=%s, date=%s)',
                   expected_n, nrow(rows), hts10, country, revision,
                   case_row$effective_date %||% '<none>'))
    }
    if (nrow(rows) == 0) {
      # Already failed if expected_n was > 0; nothing more to assert.
      message('  PASS: ', label, ' (row count = 0 as expected)')
      pass_count <<- pass_count + 1
      return(invisible(NULL))
    }

    # If multiple rows match (e.g., date crosses an interval boundary), assert
    # against the single row containing the effective_date when one is given;
    # otherwise just take the first and let the caller pin expected_row_count.
    row <- rows[1, ]

    for (csv_col in names(RATE_COMPARISONS)) {
      parquet_col <- RATE_COMPARISONS[[csv_col]]
      assert_numeric(row[[parquet_col]], case_row[[csv_col]], tol,
                     paste0(label, ' / ', parquet_col))
    }
    for (csv_col in names(BOOL_COMPARISONS)) {
      parquet_col <- BOOL_COMPARISONS[[csv_col]]
      assert_bool(row[[parquet_col]], case_row[[csv_col]],
                  paste0(label, ' / ', parquet_col))
    }

    message('  PASS: ', label)
    pass_count <<- pass_count + 1
  }, error = function(e) {
    message('  FAIL: ', label)
    message('         ', conditionMessage(e))
    fail_count <<- fail_count + 1
  })
}

# ---- Main -------------------------------------------------------------------

main <- function() {
  if (!file.exists(CASES_PATH)) {
    stop('Cases file not found: ', CASES_PATH)
  }
  if (!dir.exists(PARQUET_PATH)) {
    stop('Parquet dataset not materialized at: ', PARQUET_PATH,
         '\n  Run: Rscript src/00_build_timeseries.R --full --core-only')
  }

  message(strrep('=', 70))
  message('Stacking-Validation Harness')
  message(strrep('=', 70))

  cases <- suppressWarnings(suppressMessages(
    read_csv(CASES_PATH, na = c('', 'NA'), show_col_types = FALSE)
  ))
  message(sprintf('Loaded %d case(s) from %s', nrow(cases), CASES_PATH))

  ds <- open_rate_timeseries(PARQUET_PATH)

  for (i in seq_len(nrow(cases))) {
    run_case(cases[i, ], ds)
  }

  message(strrep('-', 70))
  message(sprintf('Stacking harness: %d passed, %d failed', pass_count, fail_count))
  message(strrep('=', 70))

  if (fail_count > 0) quit(status = 1, save = 'no')
}

main()
