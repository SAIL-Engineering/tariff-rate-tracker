suppressPackageStartupMessages({ library(tidyverse); library(here) })
source(here('src', 'helpers.R'))
.pass <- 0L; .fail <- 0L
run_test <- function(desc, expr) {
  tryCatch({ force(expr); .pass <<- .pass + 1L; message('  PASS: ', desc) },
    error = function(e) { .fail <<- .fail + 1L; message('  FAIL: ', desc, ': ', conditionMessage(e)) })
}
row <- function(country = '1220', steel = .5, aluminum = 0, auto = 0, fent = .1) {
  x <- tibble(hts10 = '7202115000', country, base_rate = .015,
    rate_232 = steel + aluminum + auto, rate_ieepa_fent = fent,
    rate_232_steel = steel, rate_232_aluminum = aluminum,
    rate_232_auto = auto, rate_232_copper = 0, rate_232_other = 0,
    metal_share = 1)
  zero_fill_authority_rates(x)
}
run_test('primary amendment reverses priority at the exact Eastern minute', {
  before <- apply_stacking_precedence(row(), '2025-06-04T00:00:59-04:00')
  after <- apply_stacking_precedence(row(), '2025-06-04T00:01:00-04:00')
  utc <- apply_stacking_precedence(row(), '2025-06-04T04:01:00Z')
  stopifnot(before$rate_232 == 0, before$rate_ieepa_fent == .1,
            after$rate_232 == .5, after$rate_ieepa_fent == 0,
            identical(utc, after), grepl('proc10947_5_metals', after$s232_suppressed_json))
})
run_test('historical live Canadian ferroalloy case changes only at the legal boundary', {
  pre <- apply_stacking_rules(apply_stacking_precedence(row(steel = .25), '2025-06-03'))
  post <- apply_stacking_rules(apply_stacking_precedence(row(), '2025-06-04'))
  stopifnot(abs(pre$total_rate - .115) < 1e-12, abs(post$total_rate - .515) < 1e-12)
})
run_test('auto priority survives the amendment; steel and aluminum remain cumulative', {
  r <- bind_rows(row(auto = .25, aluminum = .5), row(aluminum = .5))
  out <- apply_stacking_precedence(r, '2025-06-04')
  stopifnot(identical(out$rate_232, c(.25, 1)), all(out$rate_ieepa_fent == 0))
})
run_test('shared IEEPA column is suppressed only for the named countries', {
  r <- bind_rows(lapply(c('1220','2010','5700','5820'), function(c) row(country = c)))
  out <- apply_stacking_precedence(r, '2025-06-04')
  stopifnot(identical(out$rate_ieepa_fent, c(0,0,.1,.1)), all(out$rate_232 == .5))
})
run_test('all later eras inherit the amended action precedence', {
  for (date in c('2026-02-20','2026-02-24','2026-04-06','2026-07-24','2026-10-22')) {
    era <- resolve_stacking_era(date)
    stopifnot(length(era$non_stacking) == 3,
              era$non_stacking[[3]]$rule_id == 'proc10947_5_metals')
    # Duties themselves come from their own operative windows, not this graph.
    r <- apply_stacking_precedence(row(auto = .25, fent = 0), era = era)
    stopifnot(r$rate_232 == .25, r$rate_232_steel == 0)
  }
})
run_test('config ordering and duplicate source order cannot change priority', {
  cfg <- load_stacking_rules(); cfg$eras <- rev(cfg$eras)
  i <- which(vapply(cfg$eras, function(e) e$id == 'proc10947', logical(1)))
  cfg$eras[[i]]$non_stacking <- rev(cfg$eras[[i]]$non_stacking)
  stopifnot(identical(apply_stacking_precedence(row(auto = .25), '2025-08-01'),
    apply_stacking_precedence(row(auto = .25), '2025-08-01', cfg = cfg)))
})
run_test('collection end and Section 122 start are distinct instants on the same day', {
  stopifnot(resolve_stacking_era('2026-02-23T23:59:59-05:00')$id == 'proc10962',
    resolve_stacking_era('2026-02-24T00:00:00-05:00')$id == 'post_ieepa',
    resolve_stacking_era('2026-02-24T00:00:59-05:00')$id == 'post_ieepa',
    resolve_stacking_era('2026-02-24T00:01:00-05:00')$id == 's122',
    resolve_stacking_era('2026-02-24')$id == 's122')
  cfg <- load_stacking_rules(); cfg$eras <- rev(cfg$eras)
  stopifnot(resolve_stacking_era('2026-02-24', cfg)$id == 's122')
})
run_test('copper clause (5) suppresses copper only when auto duty is owed', {
  x <- row(auto = .25, fent = 0, steel = 0)
  x$rate_232_copper <- .5; x$rate_232 <- .75
  before <- apply_stacking_precedence(x, '2025-08-01T00:00:59-04:00')
  after <- apply_stacking_precedence(x, '2025-08-01T00:01:00-04:00')
  stopifnot(before$rate_232 == .75, after$rate_232 == .25,
            grepl('proc10962', after$s232_suppressed_json))
  x$rate_232_auto <- 0; x$rate_232 <- .5
  stopifnot(apply_stacking_precedence(x, '2025-08-01')$rate_232 == .5)
})
run_test('cycles, unknown parents and incomplete action data fail rather than zero', {
  cfg <- load_stacking_rules(); cfg$eras[[1]]$inherits <- 'legacy'
  stopifnot(inherits(try(resolve_stacking_era('2024-01-01', cfg), silent = TRUE), 'try-error'))
  cfg$eras[[1]]$inherits <- 'missing'
  stopifnot(inherits(try(resolve_stacking_era('2024-01-01', cfg), silent = TRUE), 'try-error'))
  x <- row(); x$rate_232_steel <- NA_real_
  stopifnot(inherits(try(apply_stacking_precedence(x, '2025-07-01'), silent = TRUE), 'try-error'))
  x$rate_232_steel <- NULL
  stopifnot(inherits(try(apply_stacking_precedence(x, '2025-07-01'), silent = TRUE), 'try-error'))
})
run_test('invalid timestamps and missing shared-column origin scopes are rejected', {
  for (date in c('2025-02-30T00:01:00Z','2025-06-04T24:01:00Z','2025-06-04T00:01:00',
                 '2025-06-04T00:01:00+25:00'))
    stopifnot(inherits(try(resolve_stacking_era(date), silent=TRUE), 'try-error'))
  cfg <- load_stacking_rules(); cfg$authority_countries$ieepa_canada <- NULL
  stopifnot(inherits(try(apply_stacking_precedence(row(), '2025-06-04', cfg=cfg), silent=TRUE), 'try-error'))
})
run_test('unrelated 122, China/Brazil/forced-labor 301 and 338 actions remain untouched', {
  x <- row(auto = .25)
  for (col in c('rate_s122','rate_301','rate_s301br','rate_s301fl','rate_s338')) x[[col]] <- .12
  out <- apply_stacking_precedence(x, '2026-10-22')
  for (col in c('rate_s122','rate_301','rate_s301br','rate_s301fl','rate_s338')) stopifnot(out[[col]] == x[[col]])
})
run_test('EO 14195 is full-value for China and Hong Kong; decomposition agrees', {
  for (country in c('5700','5820')) for (share in c(0,.2,.75,1)) {
    x <- row(country = country, steel = 0, fent = .2)
    x$rate_232_copper <- .5; x$rate_232 <- .5; x$metal_share <- share
    x <- apply_stacking_rules(apply_stacking_precedence(x, '2025-08-01'))
    n <- compute_net_authority_contributions(x)
    stopifnot(abs(x$total_additional - .7) < 1e-12, n$net_fentanyl == .2,
      abs(n$net_232 + n$net_fentanyl - x$total_additional) < 1e-12)
  }
})
run_test('statutory evaluation gets unsuppressed inputs, independent of aggregate claim shares', {
  for (date in c('2025-06-03','2025-06-04')) for (share in c(0,.5,1)) {
    x <- row(); x$statutory_base_rate <- .015; x$statutory_rate_232 <- .5
    x$statutory_rate_ieepa_fent <- .1
    inputs <- x[S232_ACTION_RATE_COLS]
    x$rate_ieepa_fent <- .1 * (1-share); x$base_rate <- .015 * (1-share)
    era <- resolve_stacking_era(date)
    x <- apply_stacking_rules(apply_stacking_precedence(x, era = era))
    x <- compute_statutory_totals(x, stacking_era = era, action_inputs = inputs)
    expected <- if (date == '2025-06-03') .115 else .515
    stopifnot(abs(x$statutory_total_rate - expected) < 1e-12)
  }
})
cat(sprintf('Tests: %d passed, %d failed\n', .pass, .fail))
if (.fail) quit(status = 1)
