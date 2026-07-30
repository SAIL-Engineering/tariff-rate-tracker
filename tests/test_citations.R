# =============================================================================
# test_citations.R — Phase 0: legal citation integrity
# =============================================================================
#
# Every rule the engine derives must trace to a primary source the frontend can
# link to. These tests pin the registry's invariants so a citation cannot rot
# back into the states that were found and fixed:
#   - an authority with no resolvable URL (proc_11032 sat "pending publication"
#     for two months after it had published at 91 FR 34085)
#   - a citation_key referenced by a rule but never registered
#   - a link that points at a search page rather than a specific document
#   - a duplicate YAML key silently dropping one of two definitions
#
# Run: Rscript tests/test_citations.R
# =============================================================================

suppressPackageStartupMessages({
  library(tidyverse)
  library(yaml)
  library(here)
})

.pass <- 0L; .fail <- 0L
run_test <- function(desc, expr) {
  ok <- tryCatch({ force(expr); TRUE }, error = function(e) {
    message('  FAIL: ', desc, ' — ', conditionMessage(e)); FALSE })
  if (ok) { message('  PASS: ', desc); .pass <<- .pass + 1L } else .fail <<- .fail + 1L
}

ref_path <- here('config', 'legal_reference.yaml')
doc <- yaml::read_yaml(ref_path)
reg <- doc$authorities

message('\n--- Citation registry invariants ---')

run_test('registry parses and is non-trivial', {
  stopifnot(is.list(reg), length(reg) >= 35)
})

run_test('every authority is linkable — a URL or an FR document number', {
  unlinkable <- names(reg)[vapply(reg, function(a) {
    is.null(a$verified_against) && is.null(a$fr_document_number)
  }, logical(1))]
  if (length(unlinkable)) {
    stop('not linkable in the UI: ', paste(unlinkable, collapse = ', '))
  }
})

run_test('no authority is still flagged pending publication or recheck', {
  stale <- names(reg)[vapply(reg, function(a) {
    isTRUE(a$requires_post_publication_recheck) ||
      grepl('pending', a$source_status %||% '', ignore.case = TRUE)
  }, logical(1))]
  if (length(stale)) stop('stale pending flags: ', paste(stale, collapse = ', '))
})

run_test('an index-only link carries a written justification', {
  bad <- names(reg)[vapply(reg, function(a) {
    isTRUE(a$link_is_index) && !nzchar(a$link_is_index_reason %||% '')
  }, logical(1))]
  if (length(bad)) stop('link_is_index without reason: ', paste(bad, collapse = ', '))
})

run_test('a Federal Register citation is paired with its document number', {
  # A volume/page with no document number cannot be turned into a stable URL.
  bad <- names(reg)[vapply(reg, function(a) {
    !is.null(a$federal_register) && is.null(a$fr_document_number) &&
      is.null(a$verified_against)
  }, logical(1))]
  if (length(bad)) stop('FR citation without doc number or URL: ', paste(bad, collapse = ', '))
})

message('\n--- Rules resolve to registered citations ---')

collect_keys <- function(x, acc = character()) {
  if (is.list(x)) {
    for (nm in names(x)) {
      if (nm %in% c('citation_key', 'citation_keys')) {
        v <- unlist(x[[nm]]); acc <- c(acc, v[!is.na(v)])
      }
    }
    for (el in x) acc <- collect_keys(el, acc)
  }
  acc
}

run_test('every citation_key in stacking_rules.yaml is registered', {
  sp <- here('config', 'stacking_rules.yaml')
  stopifnot(file.exists(sp))
  keys <- unique(as.character(collect_keys(yaml::read_yaml(sp))))
  keys <- keys[nzchar(keys)]
  stopifnot(length(keys) > 0)
  dangling <- setdiff(keys, names(reg))
  if (length(dangling)) stop('unregistered: ', paste(dangling, collapse = ', '))
})

run_test('the EO 14289 stacking model cites its primary sources', {
  needed <- c('eo_14289_non_stacking', 'cbp_csms_65054270_non_stacking')
  stopifnot(all(needed %in% names(reg)))
  # CSMS #65054270 supplies the "subject to" threshold the whole order rests on,
  # so it must be verified against the bulletin itself, not a summary.
  csms <- reg[['cbp_csms_65054270_non_stacking']]
  stopifnot(isTRUE(csms$verified))
  stopifnot(grepl('govdelivery', csms$verified_against %||% ''))
  stopifnot(grepl('more than 0%', csms$quotes$subject_to_definition %||% ''))
})

run_test('the Column 2 PNTR gate is backed by a registered statute', {
  k <- 'pl_117_110_suspending_ntr_russia_belarus'
  stopifnot(k %in% names(reg))
  stopifnot(identical(reg[[k]]$effective_date, '2022-04-09'))
  # and the code gate agrees with the registered date
  suppressPackageStartupMessages(source(here('src', 'helpers.R')))
  stopifnot(identical(unname(NON_NTR_EFFECTIVE_FROM[['4621']]), '2022-04-09'))
  stopifnot(identical(unname(NON_NTR_EFFECTIVE_FROM[['4622']]), '2022-04-09'))
})

message('\n--- Validator behaviour ---')

run_test('a duplicate YAML key fails loud instead of dropping a definition', {
  tmp <- tempfile(fileext = '.yaml')
  writeLines(c('authorities:', '  a:', '    verified: true',
               '    verification_scope: "x"', '    verification_scope: "y"'), tmp)
  err <- tryCatch({ yaml::read_yaml(tmp); NULL },
                  error = function(e) conditionMessage(e))
  unlink(tmp)
  stopifnot(!is.null(err), grepl('Duplicate map key', err, fixed = TRUE))
})

run_test('validate_citations.R runs clean on the current registry', {
  out <- suppressWarnings(system2('Rscript', shQuote(here('src', 'validate_citations.R')),
                                  stdout = TRUE, stderr = TRUE))
  tally <- grep('^ERRORS:', out, value = TRUE)
  stopifnot(length(tally) == 1)
  n_err <- as.integer(sub('.*ERRORS:\\s*(\\d+).*', '\\1', tally))
  if (n_err != 0) stop(paste(grep('\\[C[12]_', out, value = TRUE), collapse = '; '))
})

message('\n', strrep('=', 50))
message('Tests: ', .pass, ' passed, ', .fail, ' failed')
message(strrep('=', 50))
if (.fail > 0) quit(status = 1)
