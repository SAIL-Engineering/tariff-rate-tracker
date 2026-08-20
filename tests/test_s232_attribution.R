# =============================================================================
# test_s232_attribution.R — every §232 duty must be attributable to an action
# =============================================================================
# Run: Rscript tests/test_s232_attribution.R
#
# rate_232 is the RESOLVED TOTAL across §232 actions; the per-action columns
# carry the attribution underneath it. When they disagree, two things break:
#
#   1. The duty has no citable legal basis. The provenance layer labels it
#      `other_ch99` with `ch99_code: null` — 26,637 rows in 2026_rev_13.
#   2. EO 14289 sec. 3(a)(i) tests `rate_232_auto > threshold`, so an
#      unattributed duty cannot participate in precedence at all.
#
# Measured against cached Avalara payloads, this class is the single largest
# driver of total-rate disagreement.
# =============================================================================

suppressPackageStartupMessages({
  library(tidyverse)
  library(here)
})
source(here('src', 'helpers.R'))

.pass <- 0L; .fail <- 0L
run_test <- function(desc, expr) {
  ok <- tryCatch({ force(expr); TRUE }, error = function(e) {
    message('  FAIL: ', desc, ' — ', conditionMessage(e)); FALSE })
  if (ok) { message('  PASS: ', desc); .pass <<- .pass + 1L } else .fail <<- .fail + 1L
}

mk <- function(rate_232, ..., country = '4280') {
  base <- tibble(hts10 = '8482400000', country = country, rate_232 = rate_232,
                 rate_232_auto = 0, rate_232_steel = 0, rate_232_aluminum = 0,
                 rate_232_copper = 0, rate_232_other = 0, rate_ieepa_fent = 0)
  ov <- list(...); for (n in names(ov)) base[[n]] <- ov[[n]]
  base
}

message('\n--- Residual attribution ---')

run_test('an unattributed §232 duty is parked in _other, not left dangling', {
  # The real shape: rate_232 set by an upstream step, every action column 0.
  r <- suppressMessages(attribute_s232_residual(mk(0.25)))
  stopifnot(abs(r$rate_232_other - 0.25) < 1e-12)
  stopifnot(attr(r, 'n_unattributed_s232') == 1)
})

run_test('attribution is RATE-NEUTRAL — the total never moves', {
  for (v in c(0.25, 0.104375, 0.5, 0.162375)) {
    r <- suppressMessages(attribute_s232_residual(mk(v)))
    stopifnot(abs(r$rate_232 - v) < 1e-12)
    sum_actions <- r$rate_232_auto + r$rate_232_steel + r$rate_232_aluminum +
      r$rate_232_copper + r$rate_232_other
    stopifnot(abs(sum_actions - v) < 1e-12)
  }
})

run_test('a partially attributed row only parks the remainder', {
  # Steel 232 already attributed, a deal floor then raised rate_232 on top.
  r <- suppressMessages(attribute_s232_residual(mk(0.50, rate_232_steel = 0.30)))
  stopifnot(abs(r$rate_232_steel - 0.30) < 1e-12)
  stopifnot(abs(r$rate_232_other - 0.20) < 1e-12)
})

run_test('a fully attributed row is left completely alone', {
  r <- suppressMessages(attribute_s232_residual(mk(0.25, rate_232_auto = 0.25)))
  stopifnot(abs(r$rate_232_auto - 0.25) < 1e-12)
  stopifnot(abs(r$rate_232_other) < 1e-12)
  stopifnot(attr(r, 'n_unattributed_s232') == 0)
})

run_test('over-attribution is not "corrected" by inventing negative duty', {
  # Actions summing above rate_232 is a different defect; this function must not
  # mask it by subtracting, which would silently delete duty.
  r <- suppressMessages(attribute_s232_residual(mk(0.25, rate_232_steel = 0.40)))
  stopifnot(abs(r$rate_232_steel - 0.40) < 1e-12)
  stopifnot(abs(r$rate_232_other) < 1e-12)
  stopifnot(all(c(r$rate_232_auto, r$rate_232_steel, r$rate_232_other) >= 0))
})

message('\n--- Why it must run BEFORE EO 14289 ---')

run_test('parking in _other does not suppress anything on a guess', {
  # sec. 3(c): actions outside sec. 2 are cumulative. Parking an unidentified
  # duty in _other must NOT switch off IEEPA CA/MX — that would need it to be
  # positively identified as auto (sec. 3(a)(i)).
  r <- suppressMessages(attribute_s232_residual(
    mk(0.25, rate_ieepa_fent = 0.25, country = '2010')))
  out <- apply_eo14289_precedence(r, threshold = 0)
  stopifnot(abs(out$rate_ieepa_fent - 0.25) < 1e-12)   # NOT suppressed
  stopifnot(abs(out$rate_232 - 0.25) < 1e-12)
})

run_test('a duty correctly identified as auto DOES suppress IEEPA CA/MX', {
  # The contrast case: when attribution is real, precedence works.
  r <- mk(0.25, rate_232_auto = 0.25, rate_ieepa_fent = 0.25, country = '2010')
  out <- apply_eo14289_precedence(r, threshold = 0)
  stopifnot(abs(out$rate_ieepa_fent) < 1e-12)          # sec. 3(a)(i)
})

run_test('the total survives the attribute -> precedence round trip', {
  r <- suppressMessages(attribute_s232_residual(mk(0.104375)))
  out <- apply_eo14289_precedence(r, threshold = 0)
  stopifnot(abs(out$rate_232 - 0.104375) < 1e-12)
})

message('\n--- Edge cases ---')

run_test('an empty frame is returned unchanged', {
  r <- suppressMessages(attribute_s232_residual(mk(0.25)[0, ]))
  stopifnot(nrow(r) == 0)
})

run_test('a zero-232 row gains nothing', {
  r <- suppressMessages(attribute_s232_residual(mk(0)))
  stopifnot(abs(r$rate_232_other) < 1e-12)
  stopifnot(attr(r, 'n_unattributed_s232') == 0)
})

run_test('missing action columns are created rather than erroring', {
  bare <- tibble(hts10 = '8482400000', country = '4280', rate_232 = 0.25)
  r <- suppressMessages(attribute_s232_residual(bare))
  stopifnot(all(S232_ACTION_RATE_COLS %in% names(r)))
  stopifnot(abs(r$rate_232_other - 0.25) < 1e-12)
})

message('\n', strrep('=', 50))
message('Tests: ', .pass, ' passed, ', .fail, ' failed')
message(strrep('=', 50))
if (.fail > 0) quit(status = 1)
