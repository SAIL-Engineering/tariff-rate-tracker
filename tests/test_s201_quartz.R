# =============================================================================
# Tests: §201 quartz surface products TRQ determination (9903.45.30/.31)
# =============================================================================
#
# The quartz safeguard (U.S. note 41, 91 FR 50645, new in 2026_rev_16) is a
# tariff-rate quota: 25% in-quota / 50% over-quota. The owed rate depends on
# quota standing — a fact the pipeline does not hold — so the contract is:
#   1. NO rate is ever collapsed into rate_section_201 for quartz.
#   2. Both tiers are emitted as requires-more-facts determination rules in
#      ch99_rules_json on covered, non-exempt rows, with heading attribution
#      and the required user inputs named.
#   3. Note-41(c) exempt origins get no rule.
#   4. The classifier claims the headings (handled_by_s201_determination) so
#      the completeness gate can flag the NEXT unclaimed rated safeguard.
#
# Usage:
#   Rscript tests/test_s201_quartz.R
#
# =============================================================================

library(tidyverse)
library(jsonlite)
library(here)

source(here('src', 'helpers.R'))
source(here('src', '03_parse_chapter99.R'))

pass_count <- 0
fail_count <- 0

run_test <- function(name, expr) {
  tryCatch({
    force(expr)
    message('  PASS: ', name)
    pass_count <<- pass_count + 1
  }, error = function(e) {
    message('  FAIL: ', name, ' — ', conditionMessage(e))
    fail_count <<- fail_count + 1
  })
}

quartz_ch99 <- tibble(
  ch99_code = c('9903.45.30', '9903.45.31'),
  rate = c(0.25, 0.50),
  authority = 'section_201',
  country_type = 'all',
  description = c(
    paste('Quartz surface products, as defined in U.S. note 41(a) to this',
          'subchapter, when the product of any country not exempt under U.S.',
          'note 41(c) to this subchapter, if entered in an aggregate quantity',
          'not exceeding the quantity defined in U.S. note 41(d)'),
    paste('Quartz surface products, as defined in U.S. note 41(a) to this',
          'subchapter, when the product of any country not exempt under U.S.',
          'note 41(c) to this subchapter, if entered in an aggregate quantity',
          'exceeding the quantity defined in U.S. note 41(d)')
  )
)

message('\n=== build_s201_quartz_candidates ===')

run_test('both tiers built from the headings\' own rates', {
  q <- build_s201_quartz_candidates(quartz_ch99)
  stopifnot(nrow(q$candidates) == 6)  # 3 HTS10 x 2 tiers
  stopifnot(setequal(unique(q$candidates$hts10),
                     c('6810990020', '6810990040', '7020006000')))
  stopifnot(all(q$candidates$statutory_rate[q$candidates$tier == 'in_quota'] == 0.25))
  stopifnot(all(q$candidates$statutory_rate[q$candidates$tier == 'over_quota'] == 0.50))
})

run_test('note-41(c) exemptions loaded (CA/MX + FTA + developing + CBERA)', {
  q <- build_s201_quartz_candidates(quartz_ch99)
  stopifnot(length(q$exempt_codes) > 100)
  # Canada (1220), Mexico (2010) exempt under 41(c)(i)
  stopifnot(all(c('1220', '2010') %in% q$exempt_codes))
  # China (5700), India (5330) are NOT exempt
  stopifnot(!'5700' %in% q$exempt_codes)
  stopifnot(!'5330' %in% q$exempt_codes)
})

run_test('empty when headings absent (pre-rev_16 revisions)', {
  q <- build_s201_quartz_candidates(quartz_ch99[0, ])
  stopifnot(nrow(q$candidates) == 0, length(q$exempt_codes) == 0)
})

message('\n=== classifier claims the headings ===')

run_test('9903.45.30/.31 -> handled_by_s201_determination (not resolved_by_parser)', {
  st <- classify_resolution_status(c('9903.45.30', '9903.45.31'), c('all', 'all'))
  stopifnot(all(st == 'handled_by_s201_determination'))
})

run_test('solar 9903.45.2x claimed by extractor regardless of country scope', {
  st <- classify_resolution_status(c('9903.45.22', '9903.45.25'), c('unknown', 'all'))
  stopifnot(all(st == 'handled_by_s201_extractor'))
})

message('\n=== completeness gate: unclaimed rated safeguard is an offender ===')

run_test('a NEW rated 9903.45.3x-style heading with no claim trips the gate', {
  # Simulate the next quartz-like case: a rated 9903.46.xx heading whose
  # country scope parsed fine (resolved_by_parser) but which nothing claims.
  fake <- tibble(
    ch99_code = '9903.46.01', rate = 0.30, authority = 'section_201',
    country_type = 'all', countries = list(character(0)),
    description = 'New safeguard, product of any country not exempt',
    resolution_status = 'resolved_by_parser'
  )
  err <- tryCatch({
    withr::with_envvar(c(SAIL_CH99_STRICT = '1'),
      check_ch99_completeness(fake, revision_id = '2026_rev_99'))
    NULL
  }, error = function(e) conditionMessage(e))
  if (!requireNamespace('withr', quietly = TRUE)) {
    Sys.setenv(SAIL_CH99_STRICT = '1')
    err <- tryCatch({
      check_ch99_completeness(fake, revision_id = '2026_rev_99'); NULL
    }, error = function(e) conditionMessage(e))
  }
  stopifnot(!is.null(err), grepl('9903.46.01', err, fixed = TRUE))
})

run_test('quartz itself passes the gate (claimed by the determination)', {
  fake <- tibble(
    ch99_code = c('9903.45.30', '9903.45.31'), rate = c(0.25, 0.5),
    authority = 'section_201', country_type = 'all',
    countries = list(character(0), character(0)),
    description = quartz_ch99$description,
    resolution_status = classify_resolution_status(
      c('9903.45.30', '9903.45.31'), c('all', 'all'))
  )
  # Must NOT stop
  check_ch99_completeness(fake, revision_id = '2026_rev_99')
})

message('\n=== ch99_rules_json emission ===')

prov_fixture <- tibble(
  hts10 = c('6810990020', '6810990020', '6810990040', '0101210010'),
  country = c('5700', '1220', '5330', '5700'),  # China, Canada (exempt), India, China
  base_rate = 0, statutory_base_rate = 0,
  rate_232 = 0, rate_301 = 0, rate_ieepa_recip = 0, rate_ieepa_fent = 0,
  rate_s122 = 0, rate_section_201 = 0,
  total_rate = 0, total_additional = 0
)

run_test('both tiers emitted on covered non-exempt rows; rates untouched', {
  q <- build_s201_quartz_candidates(quartz_ch99)
  out <- attach_duty_provenance(prov_fixture, s201_quartz = q)
  j <- fromJSON(out$ch99_rules_json[1], simplifyDataFrame = FALSE)  # China x QSP
  qr <- Filter(function(x) identical(x$program, 's201_quartz_trq'), j)
  stopifnot(length(qr) == 2)
  codes <- vapply(qr, function(x) x$ch99_code, character(1))
  stopifnot(setequal(codes, c('9903.45.30', '9903.45.31')))
  tiers <- vapply(qr, function(x) x$tier, character(1))
  rates <- vapply(qr, function(x) x$statutory_rate, numeric(1))
  stopifnot(rates[tiers == 'in_quota'] == 0.25, rates[tiers == 'over_quota'] == 0.5)
  stopifnot(all(vapply(qr, function(x)
    identical(x$status, 'potentially_applicable_requires_more_facts'), logical(1))))
  stopifnot(all(vapply(qr, function(x)
    'quota_fill_status' %in% unlist(x$missing_facts), logical(1))))
  stopifnot(all(vapply(qr, function(x)
    'entered_quantity' %in% unlist(x$required_user_inputs), logical(1))))
  # The determination NEVER sets a rate
  stopifnot(identical(out$rate_section_201, prov_fixture$rate_section_201))
})

run_test('note-41(c) exempt origin (Canada) gets no quartz rule', {
  q <- build_s201_quartz_candidates(quartz_ch99)
  out <- attach_duty_provenance(prov_fixture, s201_quartz = q)
  j <- fromJSON(out$ch99_rules_json[2], simplifyDataFrame = FALSE)  # Canada x QSP
  stopifnot(!any(vapply(j, function(x)
    identical(x$program, 's201_quartz_trq'), logical(1))))
})

run_test('non-covered product gets no quartz rule', {
  q <- build_s201_quartz_candidates(quartz_ch99)
  out <- attach_duty_provenance(prov_fixture, s201_quartz = q)
  j <- fromJSON(out$ch99_rules_json[4], simplifyDataFrame = FALSE)  # China x horse
  stopifnot(!any(vapply(j, function(x)
    identical(x$program, 's201_quartz_trq'), logical(1))))
})

run_test('rules json stays valid JSON on all rows', {
  q <- build_s201_quartz_candidates(quartz_ch99)
  out <- attach_duty_provenance(prov_fixture, s201_quartz = q)
  for (i in seq_len(nrow(out))) fromJSON(out$ch99_rules_json[i])
})

message('\n', strrep('=', 50))
message('Tests: ', pass_count, ' passed, ', fail_count, ' failed')
message(strrep('=', 50))
if (fail_count > 0) quit(status = 1)
