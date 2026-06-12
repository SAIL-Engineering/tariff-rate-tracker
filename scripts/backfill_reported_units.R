#!/usr/bin/env Rscript
# =============================================================================
# backfill_reported_units.R — strip HTML markup from reported_unit_1 /
# reported_unit_2 in the rate parquet WITHOUT a full timeseries rebuild.
# =============================================================================
# USITC's HTS export inconsistently encodes some statistical reporting units
# with HTML markup ("m<sup>2</sup>", "<u>kg</u>", "Cr<sub>2</sub>O<sub>3</sub> t",
# "<il>doz. prs.</il>", "doz.&nbsp;") in some revisions while encoding the SAME
# unit as plain ASCII ("m2", "kg", "Cr2O3 t", "doz. prs.", "doz.") in others.
# The markup was passed through verbatim and surfaces as literal text in the UI.
#
# reported_unit_1/2 are pure string columns — cleaning them has NO dependency on
# the per-country rate calculation. So instead of re-running the whole build we
# apply clean_reported_unit() (the SAME function the parser now uses, in
# src/helpers.R) to the two columns in each existing partition and rewrite it in
# place. Backfilled partitions therefore end up identical to what a fresh build
# emits — no drift between this backfill and future timeseries runs.
#
#   Rscript scripts/backfill_reported_units.R                 # all partitions
#   Rscript scripts/backfill_reported_units.R --only 2025_rev_14
#   Rscript scripts/backfill_reported_units.R --dry-run       # report, write nothing
#   Rscript scripts/backfill_reported_units.R --force         # rewrite even if unchanged
#
# Idempotent: a partition whose units are already clean is left untouched (no
# rewrite) unless --force. clean_reported_unit() is itself idempotent, so re-runs
# are always safe. Each partition is written atomically (temp file -> rename), so
# an interruption never leaves a partition half-written; just re-run to continue.
# =============================================================================
suppressWarnings(suppressMessages({
  library(here); library(dplyr); library(arrow)
}))

args     <- commandArgs(trailingOnly = TRUE)
only_rev <- if ('--only' %in% args) args[which(args == '--only') + 1] else NULL
dry_run  <- '--dry-run' %in% args
force    <- '--force' %in% args

parquet_root <- here::here('data', 'timeseries', 'rate_timeseries_parquet')

suppressWarnings(suppressMessages(source(here::here('src', 'helpers.R'))))

parts <- list.files(parquet_root, pattern = '^revision=', full.names = TRUE)
if (!is.null(only_rev)) parts <- parts[basename(parts) == paste0('revision=', only_rev)]
if (length(parts) == 0) stop('No matching parquet partitions under ', parquet_root)

# A value "changed" if clean_reported_unit() alters it (NA-safe comparison).
changed_vec <- function(orig, clean) {
  (is.na(orig) != is.na(clean)) | (!is.na(orig) & !is.na(clean) & orig != clean)
}

UNIT_COLS <- c('reported_unit_1', 'reported_unit_2')

n_written <- 0L; n_skip <- 0L; n_vals_changed <- 0L; n_markup <- 0L
touched_revs <- character(0)
t_start <- Sys.time()

for (i in seq_along(parts)) {
  part <- parts[i]
  rev  <- sub('^revision=', '', basename(part))
  ds   <- tryCatch(arrow::open_dataset(part), error = function(e) NULL)
  if (is.null(ds)) { n_skip <- n_skip + 1L; next }
  have <- intersect(UNIT_COLS, names(ds))
  if (length(have) == 0) { n_skip <- n_skip + 1L; next }

  # Cheap pre-check: scan ONLY the unit columns' distinct values (a handful per
  # revision) and skip the partition entirely unless cleaning would change one.
  # Avoids materializing every 57-column, multi-million-row partition.
  needs <- force
  if (!needs) {
    distincts <- ds %>% select(all_of(have)) %>% distinct() %>% collect()
    for (col in have) {
      v <- distincts[[col]]
      if (any(changed_vec(v, clean_reported_unit(v)), na.rm = TRUE)) { needs <- TRUE; break }
    }
  }
  if (!needs) { n_skip <- n_skip + 1L; next }

  tbl <- ds %>% collect()

  part_changed <- 0L; part_markup <- 0L
  for (col in have) {
    orig  <- tbl[[col]]
    clean <- clean_reported_unit(orig)
    ch    <- changed_vec(orig, clean)
    part_changed <- part_changed + sum(ch, na.rm = TRUE)
    part_markup  <- part_markup  + sum(!is.na(orig) & grepl('<[^>]*>|&[a-z]+;', orig), na.rm = TRUE)
    tbl[[col]] <- clean
  }
  n_vals_changed <- n_vals_changed + part_changed
  n_markup <- n_markup + part_markup

  if (part_changed == 0L && !force) { n_skip <- n_skip + 1L; next }

  touched_revs <- c(touched_revs, rev)

  if (dry_run) {
    message(sprintf('  [%d/%d] %s: WOULD rewrite — %d value(s) change (%d had markup)',
                    i, length(parts), rev, part_changed, part_markup))
    n_written <- n_written + 1L
    next
  }

  # atomic write: preserve the existing filename so read globs are unaffected.
  old_files <- list.files(part, pattern = '\\.parquet$', full.names = TRUE)
  keep_name <- if (length(old_files) == 1) basename(old_files) else 'data.parquet'
  tmp <- file.path(part, '.reported-units.parquet.tmp')
  arrow::write_parquet(tbl, tmp)
  file.remove(old_files)
  file.rename(tmp, file.path(part, keep_name))

  n_written <- n_written + 1L
  message(sprintf('  [%d/%d] %s: rewrote — %d value(s) cleaned (%d had markup)  (%.0fs elapsed)',
                  i, length(parts), rev, part_changed, part_markup,
                  as.numeric(Sys.time() - t_start, units = 'secs')))
}

verb <- if (dry_run) 'WOULD rewrite' else 'rewrote'
message(sprintf('\nBackfill %s: %s %d partition(s), left %d unchanged. %d value(s) cleaned, %d had HTML markup.',
                if (dry_run) '(dry run)' else 'done', verb, n_written, n_skip, n_vals_changed, n_markup))

# Emit the exact --only-revisions token for the MotherDuck re-push so the cloud
# `rates` table and product_base_rates pick up exactly the cleaned partitions.
if (length(touched_revs) > 0) {
  message(sprintf('\nRe-push these revisions to MotherDuck (run from frontend/):\n  node scripts/push-to-motherduck.mjs --only-revisions %s',
                  paste(sort(touched_revs), collapse = ',')))
}
