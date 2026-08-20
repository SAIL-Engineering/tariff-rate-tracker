# =============================================================================
# test_note_scope.R — resolving the product scope that lives in the US Notes
# =============================================================================
# Run: Rscript tests/test_note_scope.R
#
# §232 and IEEPA headings state no products. They point at a note subdivision:
#
#   9903.94.01  "...as provided for in subdivision (b) of U.S. note 33..."
#   9903.94.05  "automobile parts, as provided for in subdivision (g)..."
#
# Until that pointer is resolved, the product-scope invariant in
# emit_ch99_attribution.R can only check §201 — roughly 0.1% of applied duty.
#
# The hard part is not finding tariff lines; it is finding the SUBDIVISION.
# Note 33(a) contains the phrase "enumerated in subdivision (b) of this note"
# long before subdivision (b) actually begins, so a naive scan for "(b)" splits
# the note in the wrong place and shifts every subdivision by one.
# =============================================================================

suppressPackageStartupMessages({
  library(tidyverse)
  library(here)
})
source(here('src', 'parse_note_rules.R'))
source(here('src', 'resolve_note_scope.R'))

.pass <- 0L; .fail <- 0L
run_test <- function(desc, expr) {
  ok <- tryCatch({ force(expr); TRUE }, error = function(e) {
    message('  FAIL: ', desc, ' — ', conditionMessage(e)); FALSE })
  if (ok) { message('  PASS: ', desc); .pass <<- .pass + 1L } else .fail <<- .fail + 1L
}

# A note shaped like the real thing: subdivision (a) is prose that REFERS to
# (b) and (c) before either exists, (c) contains nested roman items.
.note <- paste(
  '33. (a) Except as provided for in headings 9903.94.02 and 9903.94.03,',
  'heading 9903.94.01 provides the ordinary customs duty treatment applicable',
  'to all entries of passenger vehicles classifiable in the headings enumerated',
  'in subdivision (b) of this note. No claim shall be allowed for the vehicles',
  'enumerated in subdivision (b) of this note.',
  '(b) The rates of duty set forth in headings 9903.94.01 and 9903.94.02 apply',
  'to all imported products classifiable in the provisions of the HTSUS',
  'enumerated in this subdivision: 8703.22.01 8703.23.01 8703.24.01 8704.21.01',
  '(c) Heading 9903.94.02 applies to: (i) all entries of articles classifiable',
  'under provisions enumerated in subdivision (b) of this note, but that are',
  'not passenger vehicles; as well as (ii) the U.S. content of vehicles.',
  '(d) Heading 9903.94.05 applies to automobile parts enumerated in this',
  'subdivision: 8708.10.30 8708.29.50 4009.12.00')

message('\n--- Subdivisions are split at markers, not at cross-references ---')

run_test('a prose reference to "(b)" does not start subdivision (b)', {
  s <- split_note_subdivisions(.note)
  stopifnot(all(c('a', 'b', 'c', 'd') %in% names(s)))
  # The tariff lines belong to (b), not to (a) or (c).
  stopifnot(grepl('8703.22.01', s[['b']], fixed = TRUE))
  stopifnot(!grepl('8703.22.01', s[['a']], fixed = TRUE))
})

run_test('nested roman items (i)/(ii) do not split their parent', {
  s <- split_note_subdivisions(.note)
  # (c) must survive whole — it contains both (i) and (ii).
  stopifnot(grepl('U.S. content', s[['c']], fixed = TRUE))
  stopifnot(!any(c('ii') %in% names(s)))
})

run_test('subdivision letters advance monotonically', {
  s <- split_note_subdivisions(.note)
  stopifnot(identical(names(s), c('a', 'b', 'c', 'd')))
})

message('\n--- Tariff lines are read from the right subdivision ---')

run_test('(b) enumerates the vehicle lines and no parts', {
  r <- note_subdivision_scope(.note, 33, 'b')
  stopifnot(r$status == 'enumerated')
  stopifnot(setequal(r$prefixes, c('87032201', '87032301', '87032401', '87042101')))
  stopifnot(!any(startsWith(r$prefixes, '8708')))
})

run_test('Chapter 99 cross-references are not treated as covered products', {
  r <- note_subdivision_scope(.note, 33, 'b')
  # "headings 9903.94.01 and 9903.94.02" appear IN subdivision (b).
  stopifnot(!any(startsWith(r$prefixes, '99')))
  stopifnot(length(r$ch99_refs) >= 2)
})

run_test('a prose-only subdivision reports enumerates_none, not silence', {
  r <- note_subdivision_scope(.note, 33, 'c')
  stopifnot(r$status == 'enumerates_none')
  stopifnot(length(r$prefixes) == 0)
})

run_test('an absent note and an absent subdivision are distinguishable', {
  stopifnot(note_subdivision_scope(.note, 99, 'b')$status == 'note_absent')
  stopifnot(note_subdivision_scope(.note, 33, 'z')$status == 'subdivision_absent')
})

message('\n--- Heading descriptions resolve through their note pointer ---')

run_test('"subdivision (b) of U.S. note 33" resolves to the vehicle lines', {
  v <- heading_scope_via_note(
    'passenger vehicles, as provided for in subdivision (b) of U.S. note 33 to this subchapter',
    .note)
  stopifnot(v$status == 'enumerated', v$note_num == 33)
  stopifnot(setequal(v$prefixes, c('87032201', '87032301', '87032401', '87042101')))
})

run_test('the parts heading resolves to parts, not to vehicles', {
  v <- heading_scope_via_note(
    'automobile parts, as provided for in subdivision (d) of U.S. note 33 to this subchapter',
    .note)
  stopifnot(any(startsWith(v$prefixes, '8708')))
  stopifnot(!any(startsWith(v$prefixes, '8703')))
})

run_test('a description with no note pointer says so', {
  v <- heading_scope_via_note('Articles of iron or steel', .note)
  stopifnot(v$status == 'no_note_ref')
})

run_test('"subdivisions (d) and (f)" reads BOTH subdivisions', {
  nt <- paste('37. (a) prose.',
              '(b) lines: 4403.11.00',
              '(c) prose only.',
              '(d) lines: 9401.61.40',
              '(e) prose.',
              '(f) lines: 9403.40.90')
  v <- heading_scope_via_note(
    'Wood products of Japan as provided for in subdivisions (d) and (f) of U.S. note 37',
    nt)
  stopifnot(setequal(v$prefixes, c('94016140', '94034090')))
})

message('\n--- Coverage is checkable, and unknown is not "excluded" ---')

run_test('scope_covers matches by prefix', {
  # 8703.22.01 is an 8-digit SUBHEADING; its statistical lines are 8703.22.01.xx
  # (dotless 87032201 + 2). 8703220010 would be 8703.22.00.10 — a different
  # subheading entirely, and correctly NOT covered. Getting this wrong in the
  # other direction is how a scope check manufactures false contradictions.
  r <- note_subdivision_scope(.note, 33, 'b')
  got <- scope_covers(r$prefixes, c('8703220110', '8708103000', '8703220010'))
  stopifnot(identical(got, c(TRUE, FALSE, FALSE)))
})

run_test('unknown scope yields NA, never FALSE', {
  # "we could not read the scope" must not be reported as "the scope excludes
  # this row" — that would manufacture contradictions out of ignorance.
  got <- scope_covers(character(0), c('8703220010'))
  stopifnot(all(is.na(got)))
})

message('\n', strrep('=', 50))
message('Tests: ', .pass, ' passed, ', .fail, ' failed')
message(strrep('=', 50))
if (.fail > 0) quit(status = 1)
