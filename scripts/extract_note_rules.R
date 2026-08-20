# =============================================================================
# extract_note_rules.R — pre-extract the Chapter 99 note rules, per revision
# =============================================================================
#
# The US Notes carry facts the tariff lines do not:
#
#   STAGED RATES   §201 safeguard rates step down annually. The Rates-of-Duty
#                  column holds only the INITIAL stage, so reading it gives the
#                  2018 rate in 2025. Note 18(f) publishes the schedule.
#
#   SUSPENSION     "The following provisions have been suspended pursuant to
#                  executive action: ... 9903.41.35 through 9903.41.45" (note 5)
#
#   EXPIRY         "No rate of duty ... shall be imposed ... after the close of
#                  September 25, 2012." (note 14(b))
#
# Without these the pipeline cannot tell a live duty from a dead one, and reads
# a stale rate for the ones that are live. The alternative in place today is a
# hardcoded constant — config/policy_params.yaml section_201.solar_rate: 0.145 —
# which is TWO annual stages behind (the note says 14% for 2025) and whose own
# comment misdates the period it claims to cover.
#
# Extraction runs here rather than inside the build for the same reason
# scrape_us_notes.R does: pdftotext on 95 PDFs is slow, the output is stable per
# revision, and a resource CSV is auditable. Every row keeps its verbatim source
# text so an applied rule can be traced to the sentence that created it.
#
# Usage:
#   Rscript scripts/extract_note_rules.R                 # all revisions found
#   Rscript scripts/extract_note_rules.R --revisions 2025_rev_20,2026_rev_5
# =============================================================================

suppressPackageStartupMessages({
  library(tidyverse)
  library(here)
})
source(here('src', 'parse_note_rules.R'))

args <- commandArgs(trailingOnly = TRUE)
arg_of <- function(flag, d = NULL) {
  i <- which(args == flag); if (length(i) && length(args) > i[1]) args[i[1] + 1] else d
}
only <- arg_of('--revisions', NULL)
notes_dir <- here('data', 'us_notes')
out_dir   <- here('resources')

pdfs <- list.files(notes_dir, pattern = '^chapter99_.*\\.pdf$', full.names = TRUE)
revs <- gsub('^chapter99_|\\.pdf$', '', basename(pdfs))
if (!is.null(only)) {
  keep <- trimws(strsplit(only, ',')[[1]])
  pdfs <- pdfs[revs %in% keep]; revs <- revs[revs %in% keep]
}
if (length(pdfs) == 0) stop('No Chapter 99 note PDFs found in ', notes_dir, call. = FALSE)
message('Extracting note rules from ', length(pdfs), ' revision PDF(s)')

staged_all <- list(); status_all <- list(); cover <- list(); unparsed_all <- list()

for (i in seq_along(pdfs)) {
  rev <- revs[i]
  txt <- tryCatch(
    paste(system2('pdftotext', c('-layout', shQuote(pdfs[i]), '-'),
                  stdout = TRUE, stderr = FALSE), collapse = '\n'),
    error = function(e) NA_character_)
  if (is.na(txt) || !nzchar(txt)) {
    message('  [', rev, '] pdftotext failed — skipped'); next
  }
  flat <- flatten_note_text(txt)

  st <- tryCatch(extract_staged_rates(flat), error = function(e) tibble())
  if (nrow(st) > 0) { st$revision <- rev; staged_all[[rev]] <- st }

  ps <- tryCatch(extract_provision_status(flat), error = function(e) tibble())
  if (nrow(ps) > 0) { ps$revision <- rev; status_all[[rev]] <- ps }

  # Coverage is reported, never assumed. A rule we cannot read is a rule we are
  # not applying, and that must be visible.
  # PERSIST the unparsed statements, not just a count. A bare number cannot be
  # triaged: it says how much we cannot read without saying whether any of it
  # would change a duty. Counting sampled revisions and generalising is exactly
  # the mistake this file exists to avoid, so every revision is written out.
  rules_seen <- if (nrow(st) || nrow(ps)) c(st$verbatim, ps$verbatim) else character(0)
  up <- tryCatch(find_unparsed_rules(flat, rules_seen),
                 error = function(e) tibble(verbatim = character(0)))
  unp <- nrow(up)
  if (unp > 0) {
    up$revision <- rev
    up$norm <- gsub('[[:space:]]+', ' ', trimws(up$verbatim))
    # Only a statement naming BOTH a Chapter 99 heading and a rate can change a
    # number; everything else is scope refinement, quota mechanics, statistical
    # reporting or prose. Classifying at extraction time keeps the triage honest.
    up$names_ch99 <- grepl('9903\\.[0-9]{2}\\.[0-9]{2}', up$norm)
    up$names_rate <- grepl('[0-9]+(\\.[0-9]+)? ?percent|[0-9]+(\\.[0-9]+)? ?%', up$norm)
    up$rule_kind <- dplyr::case_when(
      grepl('statistical (reporting|note)', up$norm, ignore.case = TRUE) ~ 'statistical_reporting',
      nchar(up$norm) < 60                       ~ 'fragment',
      grepl('shall not apply to', up$norm)      ~ 'exclusion',
      grepl('in lieu of', up$norm)              ~ 'replacement',
      grepl('shall be subject to', up$norm)     ~ 'application',
      grepl('in addition to', up$norm)          ~ 'stacking',
      grepl('quota|quantit', up$norm, ignore.case = TRUE) ~ 'quota_quantity',
      TRUE                                      ~ 'other_prose')
    up$can_bind_duty <- up$names_ch99 & up$names_rate &
      up$rule_kind %in% c('exclusion', 'replacement', 'application', 'stacking')
    unparsed_all[[rev]] <- up
  }
  cover[[rev]] <- tibble(revision = rev, staged_rows = nrow(st),
                         status_rows = nrow(ps), unparsed_statements = unp,
                         unparsed_can_bind = if (unp > 0) sum(up$can_bind_duty) else 0L)
  message(sprintf('  [%-14s] staged=%-4d status=%-4d unparsed=%s',
                  rev, nrow(st), nrow(ps), unp))
}

write_out <- function(lst, file, label) {
  d <- if (length(lst)) bind_rows(lst) else tibble()
  # MERGE, never clobber: a --revisions run extracts a subset, but these CSVs
  # are the whole-corpus record (filter_active_ch99 unions suspensions across
  # every revision). Overwriting with the subset silently deleted 61 revisions
  # of suspensions/staged rates once already. Replace only the re-extracted
  # revisions' rows; keep everything else.
  path <- file.path(out_dir, file)
  if (file.exists(path) && length(revs) > 0) {
    ex <- tryCatch(suppressMessages(readr::read_csv(
      path, col_types = readr::cols(.default = readr::col_character()))),
      error = function(e) NULL)
    if (!is.null(ex) && nrow(ex) > 0 && 'revision' %in% names(ex)) {
      ex <- ex[!ex$revision %in% revs, , drop = FALSE]
      if (nrow(ex) > 0) {
        d <- dplyr::bind_rows(ex, dplyr::mutate(d, dplyr::across(
          dplyr::everything(), as.character)))
      }
    }
  }
  readr::write_csv(d, path)
  message('Wrote resources/', file, ' — ', nrow(d), ' ', label,
          ' (', length(unique(d$revision)), ' revisions)')
  d
}
staged <- write_out(staged_all, 'ch99_staged_rates.csv', 'staged rate period(s)')
status <- write_out(status_all, 'ch99_provision_status.csv', 'suspension/expiry row(s)')

up_all <- if (length(unparsed_all)) bind_rows(unparsed_all) else tibble()
if (nrow(up_all) > 0) {
  readr::write_csv(up_all %>% select(revision, rule_kind, names_ch99, names_rate,
                                     can_bind_duty, verbatim),
                   file.path(here('output', 'quality'), 'note_rules_unparsed.csv'))
  message('Wrote output/quality/note_rules_unparsed.csv — ', nrow(up_all),
          ' unparsed statement(s), ', sum(up_all$can_bind_duty),
          ' of which name BOTH a heading and a rate')
  message('  distinct (normalised) across all revisions: ',
          dplyr::n_distinct(up_all$norm))
}

cv <- bind_rows(cover)
readr::write_csv(cv, file.path(here('output', 'quality'), 'note_rule_coverage.csv'))
message('\nCoverage summary (unparsed statements are NOT applied):')
print(as.data.frame(cv %>% summarise(
  revisions = n(), staged = sum(staged_rows), status = sum(status_rows),
  unparsed_total = sum(unparsed_statements, na.rm = TRUE))), row.names = FALSE)
