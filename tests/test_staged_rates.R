# =============================================================================
# test_staged_rates.R — safeguard rates come from the note, not a constant
# =============================================================================
# Run: Rscript tests/test_staged_rates.R
#
# §201 safeguard rates step down annually. Three sources disagree, and only one
# is right. Measured on 2025_rev_20 (entry date 2025-08-27), heading 9903.45.22:
#
#   HTS Rates-of-Duty column          30%     the 2018 initial stage
#   config section_201.solar_rate     14.5%   the 2023-24 stage, TWO stages stale
#   US note 18(f) schedule            14%     correct
#
# The config comment even misdates itself: "2025-02-07 -> 2026-02-07 (Year 8 of
# extension): 14.5%", where the note publishes 14% for exactly that period. A
# staged rate encoded as a constant is wrong every year nobody edits it, which
# is why these tests assert the SCHEDULE is read rather than asserting any
# particular number stays current.
# =============================================================================

suppressPackageStartupMessages({
  library(tidyverse)
  library(here)
})
source(here('src', 'parse_note_rules.R'))

.pass <- 0L; .fail <- 0L
run_test <- function(desc, expr) {
  ok <- tryCatch({ force(expr); TRUE }, error = function(e) {
    message('  FAIL: ', desc, ' — ', conditionMessage(e)); FALSE })
  if (ok) { message('  PASS: ', desc); .pass <<- .pass + 1L } else .fail <<- .fail + 1L
}

# Verbatim from chapter99_2025_rev_20.pdf, US note 18(f).
NOTE_18F <- paste(
  '(f) For purposes of subheading 9903.45.22 to this subchapter, the duty rate',
  'in the Rates of Duty 1-General subcolumn and the Rates of Duty 2 column for',
  'all goods entered under such subheading shall be as follows:',
  'If entered during the period from',
  'February 7, 2022 through February 6, 2023 ...................................14.75%',
  'If entered during the period from',
  'February 7, 2023 through February 6, 2024 ...................................14.5%',
  'If entered during the period from',
  'February 7, 2024 through February 6, 2025 ...................................14.25%',
  'If entered during the period from',
  'February 7, 2025 through February 6, 2026 ...................................14%')

message('\n--- The schedule is read from the note ---')

run_test('a staged schedule is extracted with its periods and rates', {
  st <- extract_staged_rates(flatten_note_text(NOTE_18F))
  stopifnot(nrow(st) == 4)
  stopifnot(all(st$ch99_codes == '9903.45.22'))
  stopifnot(abs(st$rate[st$effective_from == as.Date('2025-02-07')] - 0.14) < 1e-9)
})

run_test('the rate is selected by ENTRY DATE, not by a constant', {
  st <- extract_staged_rates(flatten_note_text(NOTE_18F))
  # Each date lands in its own stage. This is the property that a hardcoded
  # rate cannot have.
  expect <- list(c('2022-06-01', 0.1475), c('2023-06-01', 0.145),
                 c('2024-06-01', 0.1425), c('2025-08-27', 0.14))
  for (e in expect) {
    r <- staged_rate_on(st, '9903.45.22', e[1])
    if (is.null(r)) stop('no stage matched for ', e[1])
    if (abs(r$rate - as.numeric(e[2])) > 1e-9)
      stop('on ', e[1], ' expected ', e[2], ' got ', r$rate)
  }
})

run_test('the config constant is demonstrably stale against the schedule', {
  # Guards the specific regression that motivated this: 0.145 applied to a
  # 2025 entry. If someone reintroduces a constant, this fails.
  st <- extract_staged_rates(flatten_note_text(NOTE_18F))
  r <- staged_rate_on(st, '9903.45.22', '2025-08-27')
  stopifnot(!is.null(r))
  stopifnot(abs(r$rate - 0.145) > 1e-9)   # the constant is NOT the answer
  stopifnot(abs(r$rate - 0.14) < 1e-9)
})

run_test('a date outside every stage yields NULL, never a fallback rate', {
  # A safeguard that has run its course must stop applying. Returning the last
  # stage forever is how an expired duty keeps being collected.
  st <- extract_staged_rates(flatten_note_text(NOTE_18F))
  stopifnot(is.null(staged_rate_on(st, '9903.45.22', '2030-01-01')))
  stopifnot(is.null(staged_rate_on(st, '2017-01-01', '2017-01-01')))
})

run_test('a schedule is attributed to the heading its own preamble names', {
  # Attribution by footnote pointer fails: pointers sit in the tariff-line
  # footnote block, schedules in the notes, so "nearest preceding pointer"
  # mis-assigns every schedule to the first one seen.
  two <- paste(NOTE_18F,
    '(h) For purposes of subheading 9903.45.25 to this subchapter, the duty rate',
    'shall be as follows:',
    'If entered during the period from',
    'February 7, 2025 through February 6, 2026 ...................................18%')
  st <- extract_staged_rates(flatten_note_text(two))
  a <- staged_rate_on(st, '9903.45.22', '2025-08-27')
  b <- staged_rate_on(st, '9903.45.25', '2025-08-27')
  stopifnot(!is.null(a), !is.null(b))
  stopifnot(abs(a$rate - 0.14) < 1e-9)
  stopifnot(abs(b$rate - 0.18) < 1e-9)   # not cross-contaminated
})

run_test('an unknown heading matches no schedule', {
  st <- extract_staged_rates(flatten_note_text(NOTE_18F))
  stopifnot(is.null(staged_rate_on(st, '9903.99.99', '2025-08-27')))
})

run_test('text with no schedule returns empty, not an error', {
  st <- extract_staged_rates(flatten_note_text('No staged rates in this note.'))
  stopifnot(nrow(st) == 0)
})

message('\n--- Suspension and expiry: a heading on the books is not a live duty ---')

# Verbatim from chapter99_2025_rev_20.pdf, U.S. notes 5 and 14(b).
NOTE_5 <- paste(
  '5. The following provisions have been suspended pursuant to executive action:',
  'subheadings 9903.04.05 and 9903.04.10, headings 9903.04.15 through 9903.04.55,',
  'inclusive, subheading 9903.41.25, and subheadings 9903.41.35 through 9903.41.45,',
  'inclusive. 6. Import quotas for upland cotton.')
NOTE_14B <- paste(
  '14. (a) For the purposes of subheadings 9903.40.05 and 9903.40.10, the duties',
  'provided for in this subchapter are cumulative duties. (b) The duty rates',
  'provided for in such subheadings shall each be reduced as follows: September 26,',
  '2010 through September 25, 2011 ... 30% No rate of duty provided for in such',
  'subheadings in chapter 99 shall be imposed on any article described in such',
  'subheadings after the close of September 25, 2012. 15. Other notes.')

run_test('a suspension list is read, including "A through B, inclusive" ranges', {
  st <- extract_provision_status(flatten_note_text(NOTE_5))
  # The range names .35/.40/.45 without listing them; a literal match misses them.
  for (cd in c('9903.41.25', '9903.41.35', '9903.41.40', '9903.41.45')) {
    r <- provision_collectible_on(st, cd, '2025-08-27')
    if (r$collectible) stop('suspended provision reported collectible: ', cd)
  }
})

run_test('a heading NOT on the suspension list stays collectible', {
  # .15/.20/.30 are neither suspended nor expired. Sweeping them in "because
  # 100% looks wrong" would be the same guessing this work is replacing.
  st <- extract_provision_status(flatten_note_text(NOTE_5))
  for (cd in c('9903.41.15', '9903.41.20', '9903.41.30')) {
    r <- provision_collectible_on(st, cd, '2025-08-27')
    if (!r$collectible) stop('wrongly suppressed: ', cd)
  }
})

run_test('an expiry date is honoured, and only AFTER it', {
  st <- extract_provision_status(flatten_note_text(NOTE_14B))
  before <- provision_collectible_on(st, '9903.40.05', '2011-06-01')
  after  <- provision_collectible_on(st, '9903.40.05', '2025-08-27')
  stopifnot(before$collectible)          # live during its term
  stopifnot(!after$collectible)          # dead after the close of 2012-09-25
  stopifnot(grepl('2012-09-25', after$reason))
})

run_test('an unlisted heading is collectible — silence is not suppression', {
  st <- extract_provision_status(flatten_note_text(NOTE_5))
  stopifnot(provision_collectible_on(st, '9903.88.01', '2025-08-27')$collectible)
})

run_test('inline compiler notes are read for every authority, not just IEEPA', {
  stopifnot(identical(inline_provision_status(
    'Articles of China [Compiler\'s note: provision suspended. See 90 Fed. Reg. 50729.]'),
    'suspended'))
  stopifnot(identical(inline_provision_status(
    'Articles of Korea [Compiler\'s note: provision terminated. See 90 Fed. Reg. 37963.]'),
    'terminated'))
  stopifnot(is.na(inline_provision_status('Ordinary heading with no compiler note')))
})

message('\n', strrep('=', 50))
message('Tests: ', .pass, ' passed, ', .fail, ' failed')
message(strrep('=', 50))
if (.fail > 0) quit(status = 1)
