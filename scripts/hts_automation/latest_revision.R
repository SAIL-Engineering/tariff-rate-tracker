# =============================================================================
# latest_revision.R — emit the newest US HTS revision metadata as KEY=VALUE
# =============================================================================
#
# Reads config/revision_dates.csv, picks the row with the greatest
# effective_date that also has needs_review = FALSE (or blank), and prints
# KEY=VALUE lines on stdout in a form that GitHub Actions can splice into
# $GITHUB_OUTPUT via `>>`. This is the single source of truth the workflow
# uses to populate Supabase + env vars + commit messages.
#
# Output keys (always in this order, one per line):
#   REV_ID=2026_rev_8
#   YEAR=2026
#   REV_NUM=8
#   EFFECTIVE_DATE=2026-05-22         # ISO date for Supabase + env var
#   EFFECTIVE_DATE_LABEL=May 22, 2026 # Human label for Supabase + UI fallback
#   JSON_PATH=data/hts_archives/hts_2026_revision_8.json
#   CSV_PATH=data/hts_archives_csv/hts_2026_revision_8.csv
#
# Usage:
#   Rscript scripts/hts_automation/latest_revision.R
#   Rscript scripts/hts_automation/latest_revision.R --revision 2026_rev_8
#
# Exits non-zero with a clear error message if:
#   * No eligible revisions exist
#   * The chosen revision still has needs_review = TRUE
#   * effective_date is missing / unparseable
#
# =============================================================================

suppressPackageStartupMessages({
  library(tidyverse)
  library(here)
})
source(here('src', 'helpers.R'))

args <- commandArgs(trailingOnly = TRUE)
override_rev <- NULL
for (i in seq_along(args)) {
  if (args[i] == '--revision' && i < length(args)) {
    override_rev <- args[i + 1]
  }
}

csv_path <- here('config', 'revision_dates.csv')
if (!file.exists(csv_path)) {
  stop('revision_dates.csv not found at ', csv_path)
}

rows <- suppressWarnings(
  read_csv(csv_path, col_types = cols(.default = col_character()))
) %>%
  mutate(
    effective_date_parsed = suppressWarnings(as.Date(effective_date)),
    needs_review_flag = toupper(ifelse(is.na(needs_review), 'FALSE', needs_review))
  )

# Filter to US revisions only — the revision id schema (`YYYY_rev_N` / `YYYY_basic`)
# is US-specific, so a presence test is sufficient.
us_rows <- rows %>%
  filter(!is.na(revision), !is.na(effective_date_parsed))

if (nrow(us_rows) == 0) {
  stop('No rows with a parseable effective_date in ', csv_path)
}

if (!is.null(override_rev)) {
  picked <- us_rows %>% filter(revision == override_rev)
  if (nrow(picked) == 0) {
    stop('Override --revision ', override_rev, ' not found in revision_dates.csv')
  }
} else {
  picked <- us_rows %>%
    filter(needs_review_flag != 'TRUE') %>%
    arrange(desc(effective_date_parsed)) %>%
    slice(1)
  if (nrow(picked) == 0) {
    stop('No eligible revisions (all rows are needs_review = TRUE).')
  }
}

if (picked$needs_review_flag == 'TRUE') {
  stop('Selected revision ', picked$revision, ' still has needs_review = TRUE. ',
       'Run 01_scrape_revision_dates.R --auto-clear-review or clear manually.')
}

parsed <- parse_revision_id(picked$revision)
year <- parsed$year
rev <- parsed$rev

if (rev == 'basic') {
  rev_num_out <- 'basic'
  json_name <- paste0('hts_', year, '_basic.json')
  csv_name  <- paste0('hts_', year, '_basic.csv')
} else if (grepl('^rev_', rev)) {
  rev_num_out <- sub('^rev_', '', rev)
  json_name <- paste0('hts_', year, '_rev_', rev_num_out, '.json')
  csv_name  <- paste0('hts_', year, '_rev_', rev_num_out, '.csv')
} else {
  stop('Unknown revision shape: ', rev)
}

effective_iso <- format(picked$effective_date_parsed, '%Y-%m-%d')
# Label format mirrors what the Supabase `hts_revisions.effective_date_label`
# rows already contain — e.g. "May 22, 2026". format() with %B gives the
# full English month name regardless of locale on GH-hosted runners.
effective_label <- format(picked$effective_date_parsed, '%B %d, %Y')
# Strip leading zero from day-of-month for "May 22, 2026" not "May 22, 2026"
# style. %e renders space-padded; we trim. Cross-platform safe.
effective_label <- format(picked$effective_date_parsed, '%B %e, %Y')
effective_label <- gsub('  ', ' ', effective_label)  # collapse double space

cat('REV_ID=',                picked$revision, '\n', sep = '')
cat('YEAR=',                  year, '\n', sep = '')
cat('REV_NUM=',               rev_num_out, '\n', sep = '')
cat('EFFECTIVE_DATE=',        effective_iso, '\n', sep = '')
cat('EFFECTIVE_DATE_LABEL=',  effective_label, '\n', sep = '')
cat('JSON_PATH=',             file.path('data', 'hts_archives', json_name), '\n', sep = '')
cat('CSV_PATH=',              file.path('data', 'hts_archives_csv', csv_name), '\n', sep = '')
