#!/usr/bin/env Rscript
# =============================================================================
# backfill_base_rate_source.R — add base_rate_source to the rate parquet WITHOUT
# a full rate recalc.
# =============================================================================
# base_rate_source (own | inherited:<parent> | unresolved) is a PRODUCT-level
# field: a pure function of (hts10, revision) from the HTS indent hierarchy, with
# NO dependency on the per-country rate calculation. So instead of re-running the
# whole timeseries build (stacking, IEEPA floors, country joins, ...), we just
# re-parse products per revision (fast) and join base_rate_source into each
# existing parquet partition by hts10, rewriting the partition in place.
#
# This activates emit_rate_validation's Q4 (and feeds a future full rebuild /
# MotherDuck push the same column). It does NOT change any rate value.
#
#   Rscript scripts/backfill_base_rate_source.R              # all partitions
#   Rscript scripts/backfill_base_rate_source.R --only 2024_rev_9
#   Rscript scripts/backfill_base_rate_source.R --force      # redo even if present
#   Rscript scripts/backfill_base_rate_source.R --no-validate  # skip the Q4 run
#
# Idempotent: a partition that already carries base_rate_source is skipped (unless
# --force). Each partition is written atomically (temp file -> rename), so an
# interruption never leaves a partition half-written; just re-run to continue.
# =============================================================================
suppressWarnings(suppressMessages({
  library(here); library(dplyr); library(purrr); library(stringr)
  library(jsonlite); library(tibble); library(arrow)
}))

args      <- commandArgs(trailingOnly = TRUE)
only_rev  <- if ('--only' %in% args) args[which(args == '--only') + 1] else NULL
force     <- '--force' %in% args
validate  <- !('--no-validate' %in% args)

parquet_root <- here::here('data', 'timeseries', 'rate_timeseries_parquet')
archive_dir  <- here::here('data', 'hts_archives')

suppressWarnings(suppressMessages({
  source(here::here('src', 'helpers.R'))
  source(here::here('src', '04_parse_products.R'))
}))

parts <- list.files(parquet_root, pattern = '^revision=', full.names = TRUE)
if (!is.null(only_rev)) parts <- parts[basename(parts) == paste0('revision=', only_rev)]
if (length(parts) == 0) stop('No matching parquet partitions under ', parquet_root)

# Cache of revision -> (hts10, base_rate_source); carry-forward covers any revision
# whose archive JSON is absent (HTS structure is stable across adjacent revisions).
last_map <- NULL
n_done <- 0L; n_skip <- 0L; n_carry <- 0L
t_start <- Sys.time()

for (i in seq_along(parts)) {
  part <- parts[i]
  rev  <- sub('^revision=', '', basename(part))
  cols <- tryCatch(names(arrow::open_dataset(part)), error = function(e) character())
  if ('base_rate_source' %in% cols && !force) { n_skip <- n_skip + 1L; next }

  # product-level map for this revision (own archive, else carry forward)
  json <- file.path(archive_dir, paste0('hts_', rev, '.json'))
  if (file.exists(json)) {
    prod <- tryCatch(suppressWarnings(suppressMessages(parse_products(json))),
                     error = function(e) NULL)
    if (!is.null(prod) && 'base_rate_source' %in% names(prod)) {
      last_map <- prod %>% distinct(hts10, base_rate_source)
    }
  } else if (!is.null(last_map)) {
    n_carry <- n_carry + 1L
  }
  if (is.null(last_map)) {
    message(sprintf('  [%d/%d] %s: no products map (no archive, no prior) -> skipped',
                    i, length(parts), rev)); next
  }

  tbl <- arrow::open_dataset(part) %>% collect()
  if ('base_rate_source' %in% names(tbl)) tbl$base_rate_source <- NULL  # --force redo
  tbl <- tbl %>% left_join(last_map, by = 'hts10')

  # atomic write: temp file in the partition dir, then swap in
  old_files <- list.files(part, pattern = '\\.parquet$', full.names = TRUE)
  tmp <- file.path(part, '.part-backfill.parquet.tmp')
  arrow::write_parquet(tbl, tmp)
  file.remove(old_files)
  file.rename(tmp, file.path(part, 'part-0.parquet'))

  n_done <- n_done + 1L
  n_na <- sum(is.na(tbl$base_rate_source))
  message(sprintf('  [%d/%d] %s: %d rows, base_rate_source NA=%d  (%.0fs elapsed)',
                  i, length(parts), rev, nrow(tbl), n_na,
                  as.numeric(Sys.time() - t_start, units = 'secs')))
}

message(sprintf('\nBackfill done: %d written, %d already had it (skipped), %d carried forward.',
                n_done, n_skip, n_carry))

if (validate) {
  message('\nRunning emit_rate_validation (Q4 now active where the column landed) ...')
  suppressWarnings(suppressMessages(source(here::here('src', 'emit_rate_validation.R'))))
  invisible(emit_rate_validation())
}
