#!/usr/bin/env Rscript
# =============================================================================
# Backfill the base slot of duty_provenance_json into existing parquet
# partitions WITHOUT a full pipeline rebuild.
# =============================================================================
# duty_provenance_json is PURE post-processing of columns already in the parquet.
# This script recomputes ONLY the `base` slot (from statutory_base_rate,
# base_rate, country — all present in the parquet) and splices it into each
# row's existing JSON, leaving the 232/301/IEEPA/etc. slots untouched. It skips
# product parsing and rate calculation (the expensive ~90% of a build).
#
# Use after a change to the BASE provenance logic. A change that touches the
# IEEPA exempt slots needs the per-revision country frame (country_ieepa), which
# this fast path does not reconstruct — use a full rebuild for those.
#
#   Rscript scripts/backfill_provenance.R                          # all partitions
#   Rscript scripts/backfill_provenance.R --only-revisions 2026_rev_5,2026_rev_6
#   Rscript scripts/backfill_provenance.R --dry-run                # report only
# =============================================================================
suppressWarnings(suppressMessages({ library(arrow); library(dplyr); library(here) }))
source(here('src', 'logging.R'))
source(here('src', 'helpers.R'))

cc <- tryCatch(get_country_constants(),
               error = function(e) list(CTY_CANADA = '1220', CTY_MEXICO = '2010', CTY_CHINA = '5700'))

args   <- commandArgs(trailingOnly = TRUE)
dryrun <- '--dry-run' %in% args
only   <- NULL
oi <- match('--only-revisions', args)
if (!is.na(oi) && oi < length(args)) only <- strsplit(args[oi + 1], ',')[[1]]

root  <- here('data', 'timeseries', 'rate_timeseries_parquet')
parts <- list.files(root, pattern = '^revision=', full.names = TRUE)
if (!is.null(only)) {
  parts <- parts[vapply(parts, function(p) {
    r <- sub('.*revision=', '', p)
    any(r == only | startsWith(r, paste0(only, '_')))
  }, logical(1))]
}
if (length(parts) == 0) { message('No matching partitions.'); quit(status = 0) }

cat('Backfilling base provenance slot across', length(parts), 'partition(s)',
    if (dryrun) '(dry run)' else '', '\n')

BASE_RE <- '^\\{"base":\\{[^}]*\\}'
total <- 0L; touched <- 0L
for (p in parts) {
  rev <- sub('.*revision=', '', p)
  f   <- file.path(p, 'data.parquet')
  if (!file.exists(f)) { message('  skip ', rev, ' (no data.parquet)'); next }

  df <- tryCatch(read_parquet(f), error = function(e) NULL)
  if (is.null(df) || !'duty_provenance_json' %in% names(df)) {
    message('  skip ', rev, ' (no duty_provenance_json column — needs a build first)'); next
  }

  # Recompute the enriched base slot via the SAME function the pipeline uses,
  # on a minimal frame (other authorities resolve to not-applicable and are
  # ignored — we only extract the base fragment).
  base_in <- df %>% transmute(hts10, country, base_rate, statutory_base_rate)
  base_json <- attach_duty_provenance(base_in, NULL, NULL, 'all', 'all_products', cc)$duty_provenance_json
  new_base  <- regmatches(base_json, regexpr(BASE_RE, base_json))  # '{"base":{...}'

  # Splice: keep everything after the existing base slot's closing brace. The
  # base slot has no nested braces, so the first '}' closes it.
  old <- df$duty_provenance_json
  ok  <- grepl(BASE_RE, old) & nchar(new_base) > 0
  first_close <- regexpr('}', old, fixed = TRUE)
  rest <- substring(old, first_close + 1L)                          # ',"232":...}' or '}'
  spliced <- old
  spliced[ok] <- paste0(new_base[ok], rest[ok])
  n_changed <- sum(spliced != old, na.rm = TRUE)

  if (!dryrun) {
    df$duty_provenance_json <- spliced
    write_parquet(df, f)
  }
  total <- total + nrow(df); touched <- touched + n_changed
  message('  ', rev, ': ', n_changed, ' base slots updated / ', nrow(df), ' rows',
          if (dryrun) ' (dry run — not written)' else '')
}
cat('\nDone. ', length(parts), ' partition(s), ', total, ' rows, ', touched,
    ' base slots changed', if (dryrun) ' (dry run)' else ' (written).', '\n', sep = '')
