# =============================================================================
# Fast-path: patch usmca_eligible in-place
# =============================================================================
#
# Narrows `usmca_eligible` to country in {1220 Canada, 2010 Mexico} across
# every existing parquet partition and RDS snapshot, without re-running
# calculate_rates_for_revision(). Safe because the change is a pure column
# mutation — no rate values change, no other columns change.
#
# Skip the full `00_build_timeseries.R --full` rebuild if the only thing you
# want to propagate is the step-7 narrowing. After this runs, re-run
# `scripts/prepare_frontend_data.R` to refresh `sample_rates.json`.
#
# Usage:
#   Rscript scripts/patch_usmca_eligible.R
#
# Runtime: ~1–3 minutes for 39 revisions. Uses `arrow` (already a pipeline
# dependency); does not require `duckdb` R package.
# =============================================================================

suppressPackageStartupMessages({
  library(here)
  library(dplyr)
  library(arrow)
})

USMCA_COUNTRIES <- c('1220', '2010')

patch_parquet_file <- function(pf) {
  tbl <- arrow::read_parquet(pf)
  if (!'usmca_eligible' %in% names(tbl)) {
    return(FALSE)  # unexpected schema — skip
  }
  tbl$usmca_eligible <- tbl$usmca_eligible & tbl$country %in% USMCA_COUNTRIES
  tmp <- paste0(pf, '.tmp')
  arrow::write_parquet(tbl, tmp, compression = 'snappy')
  file.rename(tmp, pf)
  TRUE
}

patch_parquet_partition <- function(partition_dir) {
  parquet_files <- list.files(partition_dir, pattern = '\\.parquet$', full.names = TRUE)
  n_ok <- 0L; n_skipped <- 0L
  for (pf in parquet_files) {
    if (patch_parquet_file(pf)) n_ok <- n_ok + 1L else n_skipped <- n_skipped + 1L
  }
  list(ok = n_ok, skipped = n_skipped)
}

patch_rds_snapshot <- function(rds_path) {
  snap <- readRDS(rds_path)
  if (!'usmca_eligible' %in% names(snap)) {
    return(FALSE)
  }
  snap$usmca_eligible <- snap$usmca_eligible & snap$country %in% USMCA_COUNTRIES
  saveRDS(snap, rds_path)
  TRUE
}

main <- function() {
  parquet_root <- here('data', 'timeseries', 'rate_timeseries_parquet')
  rds_root <- here('data', 'timeseries')

  # --- Patch parquet partitions ---
  partitions <- list.dirs(parquet_root, recursive = FALSE)
  partitions <- partitions[grepl('^revision=', basename(partitions))]
  message('Patching parquet: ', length(partitions), ' partitions in ', parquet_root)

  total_ok <- 0L; total_skipped <- 0L
  t0 <- Sys.time()
  for (p in partitions) {
    res <- patch_parquet_partition(p)
    total_ok <- total_ok + res$ok
    total_skipped <- total_skipped + res$skipped
  }
  message('  ', total_ok, ' parquet files patched',
          if (total_skipped > 0) paste0(' (', total_skipped, ' skipped — no column)') else '',
          ' in ', round(as.numeric(difftime(Sys.time(), t0, units = 'secs')), 1), 's')

  # --- Patch RDS snapshots ---
  # Include both canonical year-prefixed (snapshot_2025_rev_5.rds) and any
  # legacy short-format (snapshot_rev_5.rds) that may still exist.
  snap_files <- list.files(rds_root, pattern = '^snapshot_.*\\.rds$',
                           full.names = TRUE)
  message('Patching RDS: ', length(snap_files), ' snapshot files in ', rds_root)

  t0 <- Sys.time()
  n_patched <- 0L; n_skipped <- 0L
  for (f in snap_files) {
    ok <- patch_rds_snapshot(f)
    if (ok) n_patched <- n_patched + 1L else n_skipped <- n_skipped + 1L
  }
  message('  ', n_patched, ' RDS patched, ', n_skipped,
          ' skipped (no usmca_eligible column) in ',
          round(as.numeric(difftime(Sys.time(), t0, units = 'secs')), 1), 's')

  # --- Verification: re-read the parquet dataset and count TRUE rows by country ---
  message('\nVerification — rows with usmca_eligible=TRUE by country (should be CA 1220 and MX 2010 only):')
  ds <- arrow::open_dataset(parquet_root, partitioning = 'revision')
  res <- ds %>%
    filter(usmca_eligible == TRUE) %>%
    count(country, name = 'n_true') %>%
    arrange(desc(n_true)) %>%
    collect()
  print(res)

  if (nrow(res) > 0) {
    bad <- setdiff(res$country, USMCA_COUNTRIES)
    if (length(bad) > 0) {
      stop('FAIL: non-CA/MX countries still have usmca_eligible=TRUE: ',
           paste(bad, collapse = ', '))
    }
  }

  message('\nDone. Next step: regenerate sample_rates.json:')
  message('  Rscript scripts/prepare_frontend_data.R')
}

main()
