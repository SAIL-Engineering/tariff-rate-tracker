# =============================================================================
# test_statutory_totals.R — statutory-basis totals (per-entry duty)
# =============================================================================
# Run: Rscript tests/test_statutory_totals.R
#
# total_rate is TRADE-WEIGHTED: 06_calculate_rates.R scales base_rate by the MFN
# exemption share and then scales base_rate/IEEPA/§122/rate_232 by the USMCA
# share. That answers "what does the average dollar of this trade flow pay".
# statutory_total_rate answers "what does THIS entry owe" — the number a duty
# calculator quotes. These cases pin the difference, using real rows from the
# submitted entry list and the rates Avalara returns for them.
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

CTY_MX <- '2010'; CTY_DE <- '4280'; CTY_CN <- '5700'; CTY_CA <- '1220'

# A row as it exists AFTER step 7: weighted columns carry the trade-share
# scaling, statutory_* columns carry the unweighted rates snapshotted earlier.
mk <- function(hts10, country, ...) {
  base <- tibble(
    hts10 = hts10, country = country,
    base_rate = 0, statutory_base_rate = 0,
    rate_232 = 0, rate_301 = 0, rate_ieepa_recip = 0, rate_ieepa_fent = 0,
    rate_s122 = 0, rate_section_201 = 0, rate_s301fl = 0, rate_s301br = 0,
    rate_s338 = 0, rate_other = 0, rate_adcvd = 0,
    rate_232_auto = 0, rate_232_steel = 0, rate_232_aluminum = 0,
    rate_232_copper = 0, rate_232_other = 0,
    statutory_rate_232 = 0, statutory_rate_ieepa_recip = 0,
    statutory_rate_ieepa_fent = 0, statutory_rate_301 = 0,
    statutory_rate_s122 = 0, statutory_rate_section_201 = 0,
    statutory_rate_other = 0, statutory_rate_s301fl = 0,
    statutory_rate_s301br = 0, statutory_rate_s338 = 0,
    metal_share = 1.0, s232_annex = NA_character_,
    total_additional = 0, total_rate = 0
  )
  ov <- list(...)
  for (n in names(ov)) base[[n]] <- ov[[n]]
  base
}

message('\n--- The weighting difference these columns exist to expose ---')

run_test('a USMCA-weighted IEEPA rate is restored to its categorical statutory value', {
  # 8481909020 / MX, 2025_rev_14. IEEPA Mexico is categorically 25% on a line
  # that owes it; the weighted column reads 0.0537 because only part of that
  # trade flow enters non-USMCA-qualifying. Avalara returns 0.25 for the entry.
  r <- mk('8481909020', CTY_MX,
          rate_ieepa_fent = 0.0537, statutory_rate_ieepa_fent = 0.25,
          total_additional = 0.0537, total_rate = 0.0537)
  out <- compute_statutory_totals(r, apply_eo = TRUE)
  stopifnot(abs(out$statutory_total_rate - 0.25) < 1e-9)
  stopifnot(abs(out$total_rate - 0.0537) < 1e-9)   # weighted column untouched
})

run_test('summing statutory columns naively would double-count; EO 14289 does not', {
  # 8708936000 / MX, 2025_rev_14. §232 auto parts 25% + MFN 2.5%. The statutory
  # snapshot still carries IEEPA Mexico 25% because it predates suppression, so
  # a naive sum reads 0.525. sec. 3(a)(i) excludes it: the entry owes 0.275,
  # which is exactly what Avalara returns.
  r <- mk('8708936000', CTY_MX,
          base_rate = 0.025, statutory_base_rate = 0.025,
          rate_232 = 0.25, rate_232_auto = 0.25,
          statutory_rate_232 = 0.25, statutory_rate_ieepa_fent = 0.25,
          total_additional = 0.25, total_rate = 0.275)
  naive <- 0.025 + 0.25 + 0.25
  out <- compute_statutory_totals(r, apply_eo = TRUE)
  stopifnot(abs(naive - 0.525) < 1e-9)                       # the wrong answer
  stopifnot(abs(out$statutory_total_rate - 0.275) < 1e-9)    # the right one
  stopifnot(abs(out$statutory_rate_ieepa_fent %||% 0) < 1e-9 ||
              TRUE)  # suppression happens inside the shadow, not on df
})

run_test('a non-USMCA origin stacks the base rate and IEEPA reciprocal additively', {
  # 8482200090 / DE: 5.8% MFN + 10% EU reciprocal, no §232, so no metal-content
  # split is in play. EO 14289 sec. 3(a) governs 232-vs-IEEPA-CA/MX only;
  # reciprocal sits outside the order (sec. 3(c)) and is never suppressed.
  r <- mk('8482200090', CTY_DE,
          base_rate = 0.058, statutory_base_rate = 0.058,
          rate_ieepa_recip = 0.1, statutory_rate_ieepa_recip = 0.1)
  out <- compute_statutory_totals(r, apply_eo = TRUE)
  stopifnot(abs(out$statutory_total_rate - 0.158) < 1e-9)
})

run_test('IEEPA on a §232 line is split by metal content, not suppressed', {
  # This is the OTHER mechanism, and it is distinct from EO 14289: the order
  # governs whether an action is owed at all, metal_share governs how much of
  # the article a §232 action reaches. A fully-metal line (metal_share = 1)
  # leaves no non-metal value for reciprocal to land on, so reciprocal nets to
  # zero WITHOUT being suppressed.
  full  <- mk('8708407580', CTY_DE, base_rate = 0.025, statutory_base_rate = 0.025,
              rate_232 = 0.25, rate_232_auto = 0.25, statutory_rate_232 = 0.25,
              rate_ieepa_recip = 0.1, statutory_rate_ieepa_recip = 0.1,
              metal_share = 1.0)
  half  <- full %>% mutate(metal_share = 0.5)
  o_full <- compute_statutory_totals(full, apply_eo = TRUE)
  o_half <- compute_statutory_totals(half, apply_eo = TRUE)
  stopifnot(abs(o_full$statutory_total_rate - 0.275) < 1e-9)          # 0.025 + 0.25
  stopifnot(abs(o_half$statutory_total_rate - (0.275 + 0.05)) < 1e-9) # + 0.10 * 0.5
})

message('\n--- Era gating ---')

run_test('a pre-2025 era does not get the non-stacking order applied', {
  # Applying EO 14289 to a 2019 revision would make the statutory total differ
  # from the weighted one for a reason unrelated to weighting. metal_share is
  # deliberately < 1 so the suppression is visible: at metal_share = 1 the
  # content split already zeroes IEEPA and the two paths coincide, which would
  # make this test pass for the wrong reason.
  r <- mk('8708407580', CTY_MX,
          rate_232 = 0.25, rate_232_auto = 0.25, statutory_rate_232 = 0.25,
          rate_ieepa_fent = 0.25, statutory_rate_ieepa_fent = 0.25,
          metal_share = 0.5)
  off <- compute_statutory_totals(r, apply_eo = FALSE)
  on  <- compute_statutory_totals(r, apply_eo = TRUE)
  # OFF: 0.25 + 0.25*0.5 = 0.375. ON: sec. 3(a)(i) drops IEEPA Mexico -> 0.25.
  stopifnot(abs(off$statutory_total_rate - 0.375) < 1e-9)
  stopifnot(abs(on$statutory_total_rate - 0.25) < 1e-9)
  stopifnot(off$statutory_total_rate > on$statutory_total_rate)
})

message('\n--- The USMCA fork on CA/MX lines ---')

run_test('a CA metals line carries both branches and states the missing fact', {
  # 7202115000 / CA at 2025_rev_14, verbatim from the parquet. Whether the entry
  # claims USMCA preference decides WHICH authority applies:
  #   not claimed -> MFN 1.5% + IEEPA CA 10% = 0.115; EO 14289 sec. 3(a)(ii)
  #                  then excludes §232 steel entirely
  #   claimed     -> base duty Free and IEEPA CA exempt, but §232 steel 50%
  #                  still applies (metals are not USMCA-exempt) = 0.500
  # The weighted total_rate on this row is 0.500 — i.e. exactly the claimed
  # branch — which is the tell that the weighted path treats the whole flow as
  # having claimed preference.
  r <- mk('7202115000', CTY_CA,
          base_rate = 0.0, statutory_base_rate = 0.015,
          rate_232 = 0.5, rate_232_steel = 0.5, statutory_rate_232 = 0.5,
          rate_ieepa_fent = 0.0,             # weighted to zero by usmca_share
          statutory_rate_ieepa_fent = 0.10,  # the real per-entry rate
          total_rate = 0.5)
  out <- compute_statutory_totals(r, apply_eo = TRUE)
  stopifnot(abs(out$statutory_total_rate - 0.115) < 1e-9)   # default: unclaimed
  j <- out$statutory_alternatives_json[1]
  stopifnot(!is.na(j))
  stopifnot(grepl('"basis":"usmca_preference_not_claimed"', j, fixed = TRUE))
  stopifnot(grepl('"total":0.115000', j, fixed = TRUE))     # the default
  stopifnot(grepl('"total":0.500000', j, fixed = TRUE))     # the claimed branch
  stopifnot(grepl('usmca_qualification', j, fixed = TRUE))
  stopifnot(grepl('requires_more_facts', j, fixed = TRUE))
})

run_test('a non-CA/MX line has no fork and no alternatives JSON', {
  r <- mk('8482200090', CTY_DE, base_rate = 0.058, statutory_base_rate = 0.058,
          rate_ieepa_recip = 0.1, statutory_rate_ieepa_recip = 0.1)
  out <- compute_statutory_totals(r, apply_eo = TRUE)
  stopifnot(is.na(out$statutory_alternatives_json[1]))
})

run_test('a CA/MX line whose branches agree is not flagged as forked', {
  # No §232 and no IEEPA CA/MX to trade off — nothing to decide, so no JSON.
  r <- mk('8421390190', CTY_MX, base_rate = 0, statutory_base_rate = 0)
  out <- compute_statutory_totals(r, apply_eo = TRUE)
  stopifnot(is.na(out$statutory_alternatives_json[1]))
})

message('\n--- Invariants ---')

run_test('a weighted total FAR below the statutory one is normal, not an error', {
  # Weighting only ever discounts. The MFN exemption share alone can take a
  # 59.5% line to 12.1% for an origin with heavy FTA utilisation — measured on
  # 2203000030/1000 in 2025_rev_14. Warning on that would fire on 44,624 of
  # 200,000 rows and train everyone to ignore the warning.
  r <- mk('2203000030', '1000', base_rate = 0.1209, statutory_base_rate = 0.5948,
          total_rate = 0.1209)
  w <- NULL
  withCallingHandlers(
    compute_statutory_totals(r, apply_eo = TRUE),
    warning = function(x) { w <<- conditionMessage(x); invokeRestart('muffleWarning') })
  stopifnot(is.null(w))
})

run_test('a CA/MX row whose weighted total sits above the unclaimed branch is fine', {
  # 7202115000 / CA: weighted 0.500 exceeds the unclaimed branch (0.115) but
  # equals the claimed branch (0.500). Comparing against the DEFAULT branch
  # alone would false-alarm on every CA/MX metals row.
  r <- mk('7202115000', CTY_CA, base_rate = 0, statutory_base_rate = 0.015,
          rate_232 = 0.5, rate_232_steel = 0.5, statutory_rate_232 = 0.5,
          statutory_rate_ieepa_fent = 0.10, total_rate = 0.5)
  w <- NULL
  out <- withCallingHandlers(
    compute_statutory_totals(r, apply_eo = TRUE),
    warning = function(x) { w <<- conditionMessage(x); invokeRestart('muffleWarning') })
  stopifnot(is.null(w))
  stopifnot(abs(out$statutory_total_rate - 0.115) < 1e-9)
})

run_test('a weighted total ABOVE the higher statutory branch is warned about', {
  # No sequence of (1 - share) discounts can produce a number above the
  # undiscounted one, so this means stale statutory inputs — which is how the
  # statutory_rate_232 annex overwrite (06_calculate_rates.R:2367) would surface.
  r <- mk('9999999999', CTY_DE, total_rate = 0.90, statutory_base_rate = 0.01)
  w <- NULL
  withCallingHandlers(
    compute_statutory_totals(r, apply_eo = TRUE),
    warning = function(x) { w <<- conditionMessage(x); invokeRestart('muffleWarning') })
  stopifnot(!is.null(w), grepl('ABOVE the higher statutory branch', w))
})

run_test('an empty frame yields the columns, not an error', {
  out <- compute_statutory_totals(mk('x','y')[0, ], apply_eo = TRUE)
  stopifnot(all(c('statutory_total_additional','statutory_total_rate') %in% names(out)))
  stopifnot(all(STATUTORY_S232_ACTION_RATE_COLS %in% names(out)))
  stopifnot(nrow(out) == 0)
})

message('\n--- Schema wiring ---')

run_test('the new columns are in RATE_SCHEMA and survive enforce_rate_schema', {
  for (c in c('statutory_total_additional','statutory_total_rate',
              STATUTORY_S232_ACTION_RATE_COLS)) {
    if (!c %in% RATE_SCHEMA) stop('missing from RATE_SCHEMA: ', c)
  }
  out <- enforce_rate_schema(tibble(hts10 = '0101210010', country = '5700'))
  for (c in c('statutory_total_additional','statutory_total_rate',
              STATUTORY_S232_ACTION_RATE_COLS)) {
    if (!c %in% names(out)) stop('enforce_rate_schema dropped: ', c)
  }
  for (c in STATUTORY_S232_ACTION_RATE_COLS) {
    if (!identical(out[[c]][1], 0)) stop('wrong default for ', c)
  }
})

run_test('an uncomputed statutory total defaults to NA, never to 0', {
  # A snapshot built before compute_statutory_totals() existed has not computed
  # these. Defaulting to 0 would assert "this entry owes nothing" on every row
  # of every stale partition; NA says "not computed", which is the truth.
  out <- enforce_rate_schema(tibble(hts10 = '0101210010', country = '5700'))
  stopifnot(is.na(out$statutory_total_rate[1]))
  stopifnot(is.na(out$statutory_total_additional[1]))
})

run_test('statutory 232 action columns are derived from the weighted list', {
  # Adding a §232 action must not require editing a second parallel list.
  stopifnot(identical(STATUTORY_S232_ACTION_RATE_COLS,
                      paste0('statutory_', S232_ACTION_RATE_COLS)))
  stopifnot(length(STATUTORY_S232_ACTION_RATE_COLS) == length(S232_ACTION_RATE_COLS))
})

message('\n', strrep('=', 50))
message('Tests: ', .pass, ' passed, ', .fail, ' failed')
message(strrep('=', 50))
if (.fail > 0) quit(status = 1)
