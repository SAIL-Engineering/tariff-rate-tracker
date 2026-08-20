# =============================================================================
# test_product_scope.R — which products a Chapter 99 heading reaches
# =============================================================================
# Run: Rscript tests/test_product_scope.R
#
# A heading with a rate and a country but no product linkage cannot attach to
# anything, so its duty is silently never collected. That was the state of the
# §201 washing-machine safeguard: rates published in note 17(d)/(e), term
# published, and no HTS10 mapping — so it never applied, including 2018-2023
# when it was live.
#
# Its scope was in the text all along, on the PARENT line:
#   (no code) "Household-type (residential) washing machines ... provided for
#              in subheading 8450.11.00 or 8450.20.00:"
#   9903.45.01 "If entered in an aggregate quantity ..."            14%
# =============================================================================

suppressPackageStartupMessages({
  library(tidyverse)
  library(here)
})
source(here('src', 'resolve_product_scope.R'))

.pass <- 0L; .fail <- 0L
run_test <- function(desc, expr) {
  ok <- tryCatch({ force(expr); TRUE }, error = function(e) {
    message('  FAIL: ', desc, ' — ', conditionMessage(e)); FALSE })
  if (ok) { message('  PASS: ', desc); .pass <<- .pass + 1L } else .fail <<- .fail + 1L
}

message('\n--- Covered subheadings are read from the text ---')

run_test('subheadings named in the heading are extracted', {
  r <- extract_covered_subheadings(
    'Household-type washing machines (provided for in subheading 8450.11.00 or 8450.20.00)')
  stopifnot(r$status == 'explicit')
  stopifnot(setequal(r$prefixes, c('84501100', '84502000')))
})

run_test('a 4-digit heading is kept as a prefix, not padded or dropped', {
  r <- extract_covered_subheadings(
    'Bovine and equine leather (provided for in heading 4104 or 4107)')
  stopifnot(setequal(r$prefixes, c('4104', '4107')))
})

run_test('CHAPTER 99 cross-references are NOT treated as covered products', {
  # "except for products provided for in headings 9903.01.34 and 9903.02.01" is
  # an exclusion. Reading it as product scope would scope a heading to other
  # Chapter 99 lines — matching nothing, or the wrong thing.
  r <- extract_covered_subheadings(
    'Articles of any country, except for products provided for in headings 9903.01.34 and 9903.02.01')
  stopifnot(length(r$prefixes) == 0)
  stopifnot(setequal(r$ch99_refs, c('9903.01.34', '9903.02.01')))
})

run_test('a mixed sentence separates products from cross-references', {
  r <- extract_covered_subheadings(
    'Tires provided for in subheading 4011.10.50, except products provided for in heading 9903.01.34')
  stopifnot(setequal(r$prefixes, '40111050'))
  stopifnot(setequal(r$ch99_refs, '9903.01.34'))
})

run_test('scope delegated to a note is reported as by_note, not as absent', {
  # "enumerated in subdivision (g) of this note" is a pointer, not a failure —
  # but an unresolved pointer means the heading covers nothing, so it must be
  # visible rather than silently empty.
  r <- extract_covered_subheadings(
    'Automobile parts classifiable in the headings enumerated in subdivision (g) of this note')
  stopifnot(r$status == 'by_note')
  stopifnot(!is.na(r$note_ref))
})

message('\n--- Product scope inherits down the hierarchy ---')

.fragment <- function() {
  tibble::tibble(
    htsno  = c('', '9903.45.01', '9903.45.02', '', '9903.45.06'),
    indent = c(0L, 1L, 1L, 0L, 1L),
    description = c(
      'Household-type (residential) washing machines, including machines which both wash and dry (as defined in note 17(c) and provided for in subheading 8450.11.00 or 8450.20.00):',
      'If entered in an aggregate quantity, in any quarterly period specified in note 17(i)',
      'Other',
      'Parts of household-type (residential) washing machines, such parts provided for in subheading 8450.90.20 or 8450.90.60:',
      'Other'))
}

run_test('a rate-bearing child inherits the parent’s product scope', {
  r <- resolve_product_scope_hierarchical(.fragment(),
        hts10 = c('8450110000', '8450200000', '8450902000', '8450906000', '8471300000'))
  a <- r[r$htsno == '9903.45.01', ][1, ]
  stopifnot(a$scope_status == 'inherited')
  stopifnot(setequal(a$prefixes[[1]], c('84501100', '84502000')))
  stopifnot(a$n_products == 2)
})

run_test('"Other" tiers inherit too — they carry a rate and no scope of their own', {
  r <- resolve_product_scope_hierarchical(.fragment(),
        hts10 = c('8450110000', '8450200000', '8450902000', '8450906000'))
  b <- r[r$htsno == '9903.45.02', ][1, ]
  stopifnot(b$scope_status == 'inherited')
  stopifnot(b$n_products == 2)
})

run_test('a new parent replaces the previous scope, it does not accumulate', {
  # The parts block must not inherit the machines block.
  r <- resolve_product_scope_hierarchical(.fragment(),
        hts10 = c('8450110000', '8450200000', '8450902000', '8450906000'))
  p <- r[r$htsno == '9903.45.06', ][1, ]
  stopifnot(setequal(p$prefixes[[1]], c('84509020', '84509060')))
  stopifnot(!any(grepl('^84501100', p$prefixes[[1]])))
})

run_test('own text wins over an inherited parent', {
  df <- tibble::tibble(
    htsno = c('', '9903.99.01'), indent = c(0L, 1L),
    description = c('Machines provided for in subheading 8450.11.00:',
                    'Tires provided for in subheading 4011.10.50'))
  r <- resolve_product_scope_hierarchical(df, hts10 = c('8450110000', '4011105000'))
  x <- r[r$htsno == '9903.99.01', ][1, ]
  stopifnot(x$scope_source == 'own_text')
  stopifnot(setequal(x$prefixes[[1]], '40111050'))
})

message('\n--- Matching against the product universe ---')

run_test('a prefix expands to every HTS10 beneath it', {
  hts <- c('4104110000', '4104190000', '4107110000', '8450110000')
  got <- covered_hts10('Leather (provided for in heading 4104)', hts)
  stopifnot(setequal(got, c('4104110000', '4104190000')))
})

run_test('a heading covering nothing reports 0, and does not error', {
  stopifnot(length(covered_hts10('Ordinary text with no subheadings', c('8450110000'))) == 0)
  stopifnot(length(covered_hts10(NA_character_, c('8450110000'))) == 0)
})

message('\n', strrep('=', 50))
message('Tests: ', .pass, ' passed, ', .fail, ' failed')
message(strrep('=', 50))
if (.fail > 0) quit(status = 1)
