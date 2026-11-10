# =============================================================================
# Combine Snapshots into Queryable Dataset
# =============================================================================
#
# Writes each snapshot as a Parquet file with interval columns, then produces:
#   1. Partitioned Parquet dataset (primary, memory-efficient queryable format)
#   2. Per-revision sorted RDS files (for code expecting readRDS)
#   3. metadata.rds (for incremental build detection)
#
# The monolithic rate_timeseries.rds (~180M rows) exceeds available RAM.
# Instead, code should use open_dataset() or load individual revision RDS files.
#
# Usage:
#   Rscript scripts/combine_snapshots.R
#   Rscript scripts/combine_snapshots.R --resume   # keep up-to-date partitions
#
# --resume exists because this loop takes ~8 hours over 145 revisions, so losing
# it at [138/145] to an OOM meant redoing 137 partitions that were already
# correct. A partition is kept only when it is NEWER than the snapshot it came
# from; a snapshot rewritten since (a re-run revision, a backfill) is newer than
# its partition and is rebuilt. Without the flag the directory is wiped as
# before, which is still the right default: a revision that has been REMOVED
# from the corpus leaves a partition no snapshot accounts for, and only a wipe
# clears it. --resume reports what it kept so a stale keep is visible.
# =============================================================================

library(arrow)
library(here)
suppressPackageStartupMessages(library(dplyr))
suppressPackageStartupMessages(library(readr))
suppressPackageStartupMessages(library(yaml))

source(here('src', 'helpers.R'))
source(here('src','legal_intervals.R'))

args   <- commandArgs(trailingOnly = TRUE)
resume <- '--resume' %in% args

output_dir <- here('data', 'timeseries')

pp <- load_policy_params()
rev_dates <- load_revision_dates(here('config', 'revision_dates.csv'),
                                  use_policy_dates = TRUE)

# List snapshot files — exclude legacy short-format (snapshot_rev_*.rds)
# that duplicate canonical year-prefixed snapshots (snapshot_2025_rev_*.rds)
snapshot_files <- list.files(output_dir, pattern = '^snapshot_.*\\.rds$', full.names = TRUE)
legacy <- grepl('/snapshot_rev_', snapshot_files) |
          grepl('/snapshot_basic\\.rds$', snapshot_files)
if (any(legacy)) {
  message('Skipping ', sum(legacy), ' legacy snapshot(s) without year prefix')
  snapshot_files <- snapshot_files[!legacy]
}
message('Found ', length(snapshot_files), ' snapshot files')

# Build revision intervals
horizon_end <- pp$SERIES_HORIZON_END %||% Sys.Date()

# The revision name is carried by the filename, so reading every snapshot just
# to collect the set costs a full decompression pass over the whole corpus (3 GB
# of RDS, ~30 min) and produces nothing the loop below does not already derive.
# The main loop asserts filename and payload agree, so this cannot drift.
all_revisions_seen <- gsub('^snapshot_|\\.rds$', '', basename(snapshot_files))

rev_intervals <- rev_dates %>%
  filter(revision %in% unique(all_revisions_seen)) %>%
  arrange(effective_date) %>%
  mutate(valid_from = effective_date,
         valid_until = lead(effective_date) - 1) %>%
  mutate(valid_until = if_else(is.na(valid_until), horizon_end, valid_until)) %>%
  select(revision, valid_from, valid_until)

message('\n', nrow(rev_intervals), ' revisions, horizon: ', horizon_end)

# --- Write per-revision Parquet files ---
parquet_dir <- file.path(output_dir, 'rate_timeseries_parquet')
if (!resume) unlink(parquet_dir, recursive = TRUE)
dir.create(parquet_dir, showWarnings = FALSE)

total_rows <- 0
n_written  <- 0L
n_kept     <- 0L

#' Is this revision's partition already written from the CURRENT snapshot?
#' Row count is not checked because reading it means opening the file, and the
#' writer renames into place only after closing cleanly -- a partition that
#' exists at all was written whole. mtime is the test that matters: it is what
#' distinguishes a finished partition from one predating its snapshot.
partition_current <- function(rev_name, snapshot_path) {
  f <- file.path(parquet_dir, paste0('revision=', rev_name), 'data.parquet')
  file.exists(f) && file.mtime(f) > file.mtime(snapshot_path)
}

for (i in seq_along(snapshot_files)) {
  f <- snapshot_files[i]
  rev_name <- gsub('^snapshot_|\\.rds$', '', basename(f))
  message('[', i, '/', length(snapshot_files), '] ', rev_name, appendLF = !resume)

  if (resume && partition_current(rev_name, f)) {
    message('  — kept (partition newer than snapshot)')
    n_kept <- n_kept + 1L
    next
  }
  if (resume) message('')

  snap <- readRDS(f)

  # rev_intervals is keyed on the filename-derived name, while the partition
  # directory below is keyed on snap$revision[1]. If those ever disagreed the
  # join would not error — it would yield NA valid_from/valid_until, or stretch a
  # neighbouring revision's interval across the gap. Fail loudly instead.
  if (!all(snap$revision == rev_name)) {
    stop('Snapshot ', basename(f), ' contains revision(s) ',
         paste(unique(snap$revision), collapse = ', '),
         ' but its filename says ', rev_name,
         ' — the revision interval join would silently mis-key.', call. = FALSE)
  }

  snap <- enforce_rate_schema(snap)
  validate_hts_column(snap)
  interval <- rev_intervals[rev_intervals$revision==rev_name,]
  snap <- validate_snapshot_intervals(snap,interval$valid_from,interval$valid_until)
  # The sort order goes to the writer as a permutation rather than being
  # applied to snap here. arrange() returns a second full frame, so the loop
  # held two copies of the revision at once -- 28.1 GB each on 2026_rev_22's
  # four legal states, which is 56 GB on a 62 GB machine and is what
  # OOM-killed this loop at [138/145]. The permutation is 78 MB and
  # write_rate_parquet() applies it one row group at a time, writing the
  # identical bytes. See write_rate_parquet() in src/helpers.R.
  snap_order <- order(snap$valid_from, snap$country, snap$hts10,
                      method = 'radix', na.last = TRUE)

  total_rows <- total_rows + nrow(snap)

  # Write Parquet partitioned by revision
  rev_part_dir <- file.path(parquet_dir, paste0('revision=', snap$revision[1]))
  dir.create(rev_part_dir, showWarnings = FALSE)
  # Row groups, not one Arrow table over the whole revision -- see
  # write_rate_parquet() in src/helpers.R. This script and the combine inside
  # 00_build_timeseries.R write the same partitions, so they must stay in step.
  write_rate_parquet(snap %>% select(-revision),
                     file.path(rev_part_dir, 'data.parquet'),
                     compression = 'zstd',
                     compression_level = 3L,
                     row_order = snap_order)

  n_written <- n_written + 1L
  rm(snap, snap_order); gc(verbose = FALSE)
}

message('\nParquet dataset written: ', parquet_dir)
message('  Revisions written this run: ', n_written,
        if (resume) paste0(', kept: ', n_kept) else '')
message('  Rows written this run: ', total_rows)

# Verify dataset opens
ds <- open_dataset(parquet_dir, partitioning = 'revision')
ds_count <- ds %>% count() %>% collect() %>% pull(n)
message('  Arrow dataset verified: ', ds_count, ' rows')

# n_rows below is ds_count, not total_rows: under --resume total_rows counts only
# the revisions this run rewrote, so using it would understate the dataset and
# silently shrink metadata.rds -- which drives incremental build detection. When
# every revision was written here the two must agree, so assert that rather than
# letting a divergence pass unnoticed.
if (!resume && total_rows != ds_count) {
  stop('Wrote ', total_rows, ' rows but the dataset reports ', ds_count,
       ' -- a partition is missing or was written twice.', call. = FALSE)
}

# Collect distinct counts for metadata
n_distinct_products <- ds %>% distinct(hts10) %>%
  collect() %>% nrow()
n_distinct_countries <- ds %>% distinct(country) %>%
  collect() %>% nrow()
message('  Distinct products: ', n_distinct_products,
        ', Distinct countries: ', n_distinct_countries)

# --- Save metadata ---
metadata <- list(
  last_revision = rev_dates$revision[nrow(rev_dates)],
  last_build_time = Sys.time(),
  n_revisions = nrow(rev_intervals),
  n_rows = ds_count,
  n_products = n_distinct_products,
  n_countries = n_distinct_countries,
  hts_format = '10-digit, right-padded zeros',
  country_format = 'Census Bureau codes',
  scenario = 'baseline',
  format = 'parquet_partitioned',
  compression = 'zstd'
)
saveRDS(metadata, file.path(output_dir, 'metadata.rds'))
message('Saved metadata.rds')

# --- Example usage ---
message('\n=== Dataset ready ===')
message('Load with:')
message('  library(arrow)')
message('  ts <- open_dataset("data/timeseries/rate_timeseries_parquet", partitioning = "revision")')
message('  ')
message('Point-in-time query:')
message('  ts %>% filter(valid_from <= "2025-06-01", valid_until >= "2025-06-01") %>% collect()')
message('  ')
message('Single product-country:')
message('  ts %>% filter(hts10 == "0101210010", country == "5700") %>% collect()')

message('\nDone.')
