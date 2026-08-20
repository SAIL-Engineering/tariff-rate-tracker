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
# =============================================================================

library(arrow)
library(here)
suppressPackageStartupMessages(library(dplyr))
suppressPackageStartupMessages(library(readr))
suppressPackageStartupMessages(library(yaml))

source(here('src', 'helpers.R'))

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
unlink(parquet_dir, recursive = TRUE)
dir.create(parquet_dir, showWarnings = FALSE)

total_rows <- 0

for (i in seq_along(snapshot_files)) {
  f <- snapshot_files[i]
  rev_name <- gsub('^snapshot_|\\.rds$', '', basename(f))
  message('[', i, '/', length(snapshot_files), '] ', rev_name)

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
  snap <- snap %>%
    select(-any_of(c('valid_from', 'valid_until'))) %>%
    left_join(rev_intervals, by = 'revision') %>%
    arrange(country, hts10)

  total_rows <- total_rows + nrow(snap)

  # Write Parquet partitioned by revision
  rev_part_dir <- file.path(parquet_dir, paste0('revision=', snap$revision[1]))
  dir.create(rev_part_dir, showWarnings = FALSE)
  write_parquet(snap %>% select(-revision),
                file.path(rev_part_dir, 'data.parquet'),
                compression = 'zstd',
                compression_level = 3L)

  rm(snap); gc(verbose = FALSE)
}

message('\nParquet dataset written: ', parquet_dir)
message('  Total rows across all revisions: ', total_rows)

# Verify dataset opens
ds <- open_dataset(parquet_dir, partitioning = 'revision')
ds_count <- ds %>% count() %>% collect() %>% pull(n)
message('  Arrow dataset verified: ', ds_count, ' rows')

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
  n_rows = total_rows,
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
