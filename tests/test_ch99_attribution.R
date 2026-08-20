# =============================================================================
# test_ch99_attribution.R — the Chapter 99 code must be RECORDED, not inferred
# =============================================================================
# Run: Rscript tests/test_ch99_attribution.R
#
# The defect this guards against: ch99_code_* used to be chosen by matching the
# rate already computed against the published rate of each candidate heading,
# with an alphabetical tie-break. That cannot separate two headings carrying the
# SAME rate for different articles, and §232 autos is exactly that shape —
#
#   9903.94.01  passenger vehicles and light trucks   25%   (note 33)
#   9903.94.05  automobile PARTS                      25%   (note 33(g))
#
# so every auto-parts row cited the vehicles heading. Same mechanism put
# 9903.41.05 (Japanese leather) on solar rows, because it is alphabetically the
# first §201 heading in 2025_rev_20.
#
# The tests below are INVARIANTS over the mechanism, not fixtures for those two
# headings — they hold for provisions not yet written.
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

# Two headings, same rate, different articles — the case inference cannot solve.
.ch99 <- tibble::tibble(
  ch99_code = c('9903.94.01', '9903.94.05', '9903.94.31', '9903.94.32'),
  rate      = c(0.25, 0.25, 0.075, 0.10),
  description = c('passenger vehicles and light trucks',
                  'automobile parts',
                  'passenger vehicles of the United Kingdom',
                  'parts of passenger vehicles of the United Kingdom'))

.cfg <- list(
  autos_passenger = list(default_rate = 0.25, ch99_code = '9903.94.01',
                         ch99_code_by_country = list('4120' = '9903.94.31')),
  auto_parts      = list(default_rate = 0.25, ch99_code = '9903.94.05',
                         ch99_code_by_country = list('4120' = '9903.94.32')))

message('\n--- The declaration is validated against the revision ---')

run_test('a declared heading present at the configured rate is usable', {
  m <- resolve_s232_program_headings(.cfg, .ch99)
  d <- m[is.na(m$country), ]
  stopifnot(all(d$status == 'ok'))
})

run_test('a heading ABSENT from the revision is reported, never guessed', {
  # Copper 9903.78.01 was withdrawn when the April 2026 annex proclamation
  # folded copper into 9903.82. A config still naming it must not resolve.
  cfg <- list(copper = list(default_rate = 0.50, ch99_code = '9903.78.01'))
  m <- resolve_s232_program_headings(cfg, .ch99)
  stopifnot(m$status == 'absent_in_revision')
  stopifnot(is.na(s232_heading_for('copper', '1220', m)))
})

run_test('a heading whose PUBLISHED rate disagrees with config is rejected', {
  # The anti-staleness rule: a constant may stand only while it agrees with the
  # schedule. A repriced heading must surface, not silently mis-cite.
  cfg <- list(autos_passenger = list(default_rate = 0.50,
                                     ch99_code = '9903.94.01'))
  m <- resolve_s232_program_headings(cfg, .ch99)
  stopifnot(m$status == 'rate_mismatch')
  stopifnot(is.na(s232_heading_for('autos_passenger', '5880', m)))
})

run_test('a country deal rate is NOT reported as a config mismatch', {
  # 9903.94.31 publishes 7.5% while the program default is 25%. That is the
  # deal working, not a stale constant — comparing them would flag every deal.
  m <- resolve_s232_program_headings(.cfg, .ch99)
  uk <- m[!is.na(m$country) & m$country == '4120', ]
  stopifnot(nrow(uk) == 2, all(uk$status == 'ok'))
})

message('\n--- Attribution follows the PROGRAM, not the rate ---')

run_test('parts and vehicles at the SAME rate resolve to different headings', {
  m <- resolve_s232_program_headings(.cfg, .ch99)
  got <- s232_heading_for(c('autos_passenger', 'auto_parts'),
                          c('5880', '5880'), m)
  stopifnot(identical(got, c('9903.94.01', '9903.94.05')))
})

run_test('the country-specific heading wins over the program default', {
  m <- resolve_s232_program_headings(.cfg, .ch99)
  got <- s232_heading_for(c('auto_parts', 'auto_parts'),
                          c('4120', '5880'), m)
  stopifnot(identical(got, c('9903.94.32', '9903.94.05')))
})

run_test('an unknown program resolves to NA rather than to any heading', {
  m <- resolve_s232_program_headings(.cfg, .ch99)
  stopifnot(is.na(s232_heading_for('not_a_program', '5880', m)))
})

message('\n--- resolve_ch99_codes projects the recorded source ---')

.rates <- function(src) tibble::tibble(
  hts10 = c('8708801000', '8703231000'),
  country = c('5880', '5880'),
  rate_232 = c(0.25, 0.25),
  statutory_rate_232 = c(0.25, 0.25),
  rate_232_auto = c(0.25, 0.25),
  rate_232_steel = c(0, 0), rate_232_aluminum = c(0, 0),
  rate_232_copper = c(0, 0), rate_232_other = c(0, 0),
  ch99_src_232 = src)

run_test('the recorded heading is what lands in ch99_code_232', {
  r <- resolve_ch99_codes(.rates(c('9903.94.05', '9903.94.01')), .ch99)
  stopifnot(identical(r$ch99_code_232, c('9903.94.05', '9903.94.01')))
})

run_test('a parts row is NOT re-resolved to the vehicles heading', {
  # The regression itself: both rows owe 25%, and only the recorded source
  # distinguishes them. Inference collapsed both onto 9903.94.01.
  r <- resolve_ch99_codes(.rates(c('9903.94.05', '9903.94.01')), .ch99)
  stopifnot(r$ch99_code_232[1] != r$ch99_code_232[2])
})

run_test('a recorded heading absent from the revision is not used', {
  r <- resolve_ch99_codes(.rates(c('9903.99.99', '9903.94.01')), .ch99)
  stopifnot(is.na(r$ch99_code_232[1]) || r$ch99_code_232[1] != '9903.99.99')
})

run_test('no §232 code is emitted on a row owing no §232 duty', {
  x <- .rates(c('9903.94.05', '9903.94.01'))
  x$rate_232 <- c(0, 0)
  r <- resolve_ch99_codes(x, .ch99)
  stopifnot(all(is.na(r$ch99_code_232)))
})

message('\n--- No authority falls back to an alphabetical pick ---')

run_test('§201 with several active headings does not stamp the first one', {
  ch <- tibble::tibble(
    ch99_code = c('9903.41.05', '9903.45.25'),
    rate = c(0.40, 0.14),
    description = c('leather of Japan', 'solar cells'))
  x <- tibble::tibble(hts10 = '8541420010', country = '5880',
                      rate_section_201 = 0.14,
                      ch99_src_s201 = '9903.45.25')
  r <- resolve_ch99_codes(x, ch)
  stopifnot(identical(r$ch99_code_s201, '9903.45.25'))
})

run_test('§201 with no recorded source is NA, not the alphabetical first', {
  ch <- tibble::tibble(
    ch99_code = c('9903.41.05', '9903.45.25'),
    rate = c(0.40, 0.14),
    description = c('leather of Japan', 'solar cells'))
  x <- tibble::tibble(hts10 = '8541420010', country = '5880',
                      rate_section_201 = 0.14,
                      ch99_src_s201 = NA_character_)
  r <- resolve_ch99_codes(x, ch)
  stopifnot(is.na(r$ch99_code_s201))
})

run_test('§301 with several active headings resolves to NA, not List 1', {
  ch <- tibble::tibble(
    ch99_code = c('9903.88.01', '9903.88.02', '9903.88.03'),
    rate = c(0.25, 0.25, 0.075),
    description = c('List 1', 'List 2', 'List 3'))
  x <- tibble::tibble(hts10 = '8471300000', country = '5700', rate_301 = 0.25)
  r <- resolve_ch99_codes(x, ch)
  stopifnot(is.na(r$ch99_code_301))
})

run_test('§301 with exactly ONE active heading does resolve', {
  ch <- tibble::tibble(ch99_code = '9903.88.01', rate = 0.25,
                       description = 'List 1')
  x <- tibble::tibble(hts10 = '8471300000', country = '5700', rate_301 = 0.25)
  r <- resolve_ch99_codes(x, ch)
  stopifnot(identical(r$ch99_code_301, '9903.88.01'))
})

run_test('§301 forward source (ch99_src_301) wins over multi-heading ambiguity', {
  ch <- tibble::tibble(
    ch99_code = c('9903.88.01', '9903.88.02', '9903.88.03'),
    rate = c(0.25, 0.25, 0.075),
    description = c('List 1', 'List 2', 'List 3'))
  x <- tibble::tibble(hts10 = '8471300000', country = '5700', rate_301 = 0.25,
                      ch99_src_301 = '9903.88.02')
  r <- resolve_ch99_codes(x, ch)
  stopifnot(identical(r$ch99_code_301, '9903.88.02'))
})

run_test('country-scoped 2026 authorities resolve by origin (fl/br/338)', {
  ch <- tibble::tibble(
    ch99_code = c('9903.05.20', '9903.05.22', '9903.05.01', '9903.03.12'),
    rate = c(0.125, 0.10, 0.25, 0.50),
    description = c('fl heading A', 'fl heading B', 'Brazil', 'Canada 338'),
    countries = list('7210', '3570', '3510', '1220'))
  x <- tibble::tibble(
    hts10 = '8471300000',
    country = c('7210', '3570', '3510', '1220', '5700'),
    rate_s301fl = c(0.125, 0.10, 0, 0, 0),
    rate_s301br = c(0, 0, 0.25, 0, 0),
    rate_s338 = c(0, 0, 0, 0.50, 0),
    rate_301 = 0)
  r <- resolve_ch99_codes(x, ch)
  stopifnot(identical(r$ch99_code_s301fl[1], '9903.05.20'))
  stopifnot(identical(r$ch99_code_s301fl[2], '9903.05.22'))
  stopifnot(is.na(r$ch99_code_s301fl[3]))          # Brazil row: no fl duty
  stopifnot(identical(r$ch99_code_s301br[3], '9903.05.01'))
  stopifnot(identical(r$ch99_code_s338[4], '9903.03.12'))
  stopifnot(is.na(r$ch99_code_s338[5]))            # China: no 338 duty
})

run_test('invariant: every nonzero authority rate carries a heading when a source exists', {
  ch <- tibble::tibble(
    ch99_code = c('9903.88.01', '9903.05.01', '9903.03.01', '9903.45.22'),
    rate = c(0.25, 0.25, 0.10, 0.30),
    description = c('List 1', 'Brazil', 's122', 'solar'),
    countries = list(character(0), '3510', character(0), character(0)))
  x <- tibble::tibble(
    hts10 = '8471300000', country = c('5700', '3510'),
    rate_301 = c(0.25, 0), ch99_src_301 = c('9903.88.01', NA),
    rate_s301br = c(0, 0.25),
    rate_s122 = c(0.10, 0.10),
    rate_section_201 = c(0.14, 0), ch99_src_s201 = c('9903.45.22', NA))
  r <- resolve_ch99_codes(x, ch)
  rate_to_code <- c(rate_301 = 'ch99_code_301', rate_s301br = 'ch99_code_s301br',
                    rate_s122 = 'ch99_code_s122', rate_section_201 = 'ch99_code_s201')
  for (rc in names(rate_to_code)) {
    cc <- rate_to_code[[rc]]
    bad <- r[[rc]] > 0 & is.na(r[[cc]])
    if (any(bad)) stop(rc, ': ', sum(bad), ' nonzero row(s) with NA ', cc)
  }
})

run_test('stale §301 source not active in this revision is discarded, not asserted', {
  ch <- tibble::tibble(
    ch99_code = c('9903.88.01', '9903.88.03'),
    rate = c(0.25, 0.075),
    description = c('List 1', 'List 3'))
  x <- tibble::tibble(hts10 = '8471300000', country = '5700', rate_301 = 0.25,
                      ch99_src_301 = '9903.88.16')  # suspended -> not in codes_301
  r <- resolve_ch99_codes(x, ch)
  stopifnot(is.na(r$ch99_code_301))
})

message('\n', strrep('=', 50))
message('Tests: ', .pass, ' passed, ', .fail, ' failed')
message(strrep('=', 50))
if (.fail > 0) quit(status = 1)
