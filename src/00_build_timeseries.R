# =============================================================================
# Step 00: Build Tariff Rate Time Series
# =============================================================================
#
# Main orchestrator: iteratively processes HTS revisions to build a time series
# of tariff rates. Supports full backfill, incremental updates, and auto-update.
# After building, runs downstream scripts (daily series, ETR, quality report).
#
# Usage:
#   Rscript src/00_build_timeseries.R              # Auto-update (default)
#   Rscript src/00_build_timeseries.R --full        # Full rebuild from scratch
#   Rscript src/00_build_timeseries.R --start-from rev_25  # Explicit incremental
#   Rscript src/00_build_timeseries.R --build-only  # Skip downstream (daily/ETR/quality)
#   Rscript src/00_build_timeseries.R --core-only  # Build + downstream, but skip weighted outputs
#   Rscript src/00_build_timeseries.R --with-alternatives  # Also run rebuild alternatives
#   Rscript src/00_build_timeseries.R --refresh-usmca     # Re-download USMCA shares from DataWeb API
#
# Storage layout:
#   data/timeseries/
#     metadata.rds                # last_revision, last_build_time
#     snapshot_basic.rds          # rates for baseline
#     snapshot_rev_1.rds          # rates for rev_1
#     ...
#     delta_rev_1.rds             # changes from basic -> rev_1
#     ch99_rev_32.rds             # cached parse (for incremental start)
#     products_rev_32.rds
#     rate_timeseries_parquet/    # partitioned Parquet (batch-written, never monolithic)
#     validation_rev_6.rds        # TPC comparison at rev_6
#
# =============================================================================

library(tidyverse)
library(jsonlite)
library(arrow)
library(here)

# Source pipeline components
source(here('src', 'logging.R'))
source(here('src', 'helpers.R'))
source(here('src', '01_scrape_revision_dates.R'))
source(here('src', '02_download_hts.R'))
source(here('src', '03_parse_chapter99.R'))
source(here('src', '04_parse_products.R'))
source(here('src', '05_parse_policy_params.R'))
source(here('src', '06_calculate_rates.R'))
source(here('src', '07_validate_tpc.R'))


# =============================================================================
# Main Orchestrator
# =============================================================================

#' Build full tariff rate time series
#'
#' Processes HTS revisions sequentially, building rate snapshots at each point.
#' Supports both full backfill and incremental updates.
#'
#' @param archive_dir Directory containing HTS JSON files
#' @param output_dir Directory for time series outputs
#' @param revision_dates_path Path to revision_dates.csv
#' @param census_codes_path Path to census_codes.csv
#' @param tpc_path Path to TPC validation data; defaults to local_paths config
#' @param scenario Scenario name (default: 'baseline')
#' @param start_from NULL for full backfill; revision ID for incremental
#' @return List with metadata and final timeseries path
build_full_timeseries <- function(
  archive_dir = 'data/hts_archives',
  output_dir = 'data/timeseries',
  revision_dates_path = 'config/revision_dates.csv',
  census_codes_path = 'resources/census_codes.csv',
  tpc_path = NULL,
  scenario = 'baseline',
  start_from = NULL,
  stacking_method = 'mutual_exclusion',
  use_policy_dates = TRUE
) {
  start_time <- Sys.time()

  message('\n', strrep('=', 70))
  message('TARIFF RATE TIME SERIES BUILDER')
  message(strrep('=', 70))
  message('Started: ', start_time)
  message('Mode: ', if (is.null(start_from)) 'Full backfill' else paste('Incremental from', start_from))
  message(strrep('=', 70), '\n')

  # ---- Initialize logging ----
  log_dir <- here('output', 'logs')
  init_logging(
    log_file = file.path(ensure_dir(log_dir),
                         paste0('build_', format(start_time, '%Y%m%d_%H%M%S'), '.log')),
    level = 'info'
  )
  log_info('Build started: ', if (is.null(start_from)) 'full backfill' else paste('from', start_from))

  # ---- Setup ----
  ensure_dir(output_dir)
  if (is.null(tpc_path)) {
    tpc_path <- load_local_paths()$tpc_benchmark
  }

  # Load revision dates
  rev_dates <- load_revision_dates(revision_dates_path,
                                    use_policy_dates = use_policy_dates)

  # Load one canonical policy object for this build so revision ordering,
  # rate construction, interval creation, and downstream steps share a regime.
  pp_build <- load_policy_params(use_policy_dates = use_policy_dates)

  # Load country codes
  census_codes <- read_csv(census_codes_path, col_types = cols(.default = col_character()))
  countries <- census_codes$Code
  message('Countries: ', length(countries))

  # Build country lookup for IEEPA extraction
  country_lookup <- build_country_lookup(census_codes_path)

  # ---- Determine revision sequence ----
  all_revisions <- rev_dates$revision

  # Filter to revisions that have JSON files available
  available <- get_available_revisions_all_years(all_revisions, archive_dir)

  revisions_to_process <- all_revisions[all_revisions %in% available]
  missing <- all_revisions[!all_revisions %in% available]
  if (length(missing) > 0) {
    message('Skipping revisions without JSON: ', paste(missing, collapse = ', '))
  }

  message('Revisions to process: ', length(revisions_to_process))

  # ---- Handle incremental mode ----
  prev_ch99 <- NULL
  prev_products <- NULL
  start_idx <- 1

  if (!is.null(start_from)) {
    if (!start_from %in% revisions_to_process) {
      stop('start_from revision not found: ', start_from)
    }

    # Load cached state from the start_from revision
    ch99_cache <- file.path(output_dir, paste0('ch99_', start_from, '.rds'))
    prod_cache <- file.path(output_dir, paste0('products_', start_from, '.rds'))

    if (!file.exists(ch99_cache) || !file.exists(prod_cache)) {
      stop('Cached state not found for ', start_from,
           '. Run full backfill first or ensure cache files exist.')
    }

    prev_ch99 <- readRDS(ch99_cache)
    prev_products <- readRDS(prod_cache)

    # Start from the revision AFTER start_from
    start_idx <- which(revisions_to_process == start_from) + 1

    if (start_idx > length(revisions_to_process)) {
      message('No new revisions after ', start_from, '. Nothing to process.')
      return(invisible(NULL))
    }

    revisions_to_process <- revisions_to_process[start_idx:length(revisions_to_process)]
    message('Incremental: processing ', length(revisions_to_process),
            ' revisions after ', start_from)
  }

  # ---- Main processing loop ----
  snapshot_paths <- character()
  failed_revisions <- character()
  last_successful_rev <- if (!is.null(start_from)) start_from else NULL
  n_revisions <- length(revisions_to_process)

  cli::cli_progress_bar(
    format = "Processing {cli::pb_current}/{cli::pb_total} [{cli::pb_bar}] {cli::pb_eta} | {rev_id} ({eff_date})",
    total = n_revisions,
    clear = FALSE
  )

  for (i in seq_along(revisions_to_process)) {
    rev_id <- revisions_to_process[i]
    rev_info <- rev_dates %>% filter(revision == rev_id)
    eff_date <- rev_info$effective_date
    tpc_date <- rev_info$tpc_date

    cli::cli_progress_update()

    message('\n', strrep('-', 60))
    message('[', i, '/', n_revisions, '] Processing: ',
            rev_id, ' (effective ', eff_date, ')')
    message(strrep('-', 60))
    log_info('[', i, '/', length(revisions_to_process), '] ', rev_id,
             ' (', eff_date, ')')

    tryCatch({
      # a. Resolve JSON path
      json_path <- resolve_json_path(rev_id, archive_dir)

      # b. Read raw JSON (needed for IEEPA/USMCA extraction)
      hts_raw <- fromJSON(json_path, simplifyDataFrame = FALSE)

      # c. Parse Chapter 99 entries
      ch99_data <- parse_chapter99(json_path)

      # d. Parse products
      products <- parse_products(json_path)

      # e. Extract IEEPA rates, fentanyl rates, Section 232 rates, and USMCA eligibility
      ieepa_rates <- extract_ieepa_rates(hts_raw, country_lookup)
      fentanyl_rates <- extract_ieepa_fentanyl_rates(hts_raw, country_lookup)
      s232_rates <- extract_section232_rates(ch99_data)
      usmca <- extract_usmca_eligibility(hts_raw)

      # f. Compute delta from previous revision
      if (!is.null(prev_ch99)) {
        delta <- list(
          ch99 = compare_chapter99(prev_ch99, ch99_data),
          products = compare_products(prev_products, products)
        )
        delta_path <- file.path(output_dir, paste0('delta_', rev_id, '.rds'))
        saveRDS(delta, delta_path)

        message('  Delta: +', delta$ch99$n_added, ' ch99 entries, ',
                '+', delta$products$n_added, ' products, ',
                delta$ch99$n_rate_changes, ' rate changes')
      }

      # g. Calculate rates for this revision
      rates <- calculate_rates_for_revision(
        products, ch99_data, ieepa_rates, usmca,
        countries, rev_id, eff_date,
        s232_rates = s232_rates,
        fentanyl_rates = fentanyl_rates,
        stacking_method = stacking_method,
        policy_params = pp_build
      )

      # h. Save snapshot
      snapshot_path <- file.path(output_dir, paste0('snapshot_', rev_id, '.rds'))
      saveRDS(rates, snapshot_path)
      snapshot_paths <- c(snapshot_paths, snapshot_path)

      # i. Cache parse results (for incremental)
      saveRDS(ch99_data, file.path(output_dir, paste0('ch99_', rev_id, '.rds')))
      saveRDS(products, file.path(output_dir, paste0('products_', rev_id, '.rds')))

      # j. TPC validation if this revision has a tpc_date
      if (!is.na(tpc_date) && file.exists(tpc_path)) {
        message('  Running TPC validation for date: ', tpc_date)
        tryCatch({
          validation <- validate_revision_against_tpc(
            revision_rates = rates,
            tpc_path = tpc_path,
            tpc_date = tpc_date,
            census_codes = census_codes
          )
          val_path <- file.path(output_dir, paste0('validation_', rev_id, '.rds'))
          saveRDS(validation, val_path)
          message('  TPC match rate: ', round(validation$match_rate * 100, 1), '%')
        }, error = function(e) {
          message('  TPC validation failed: ', conditionMessage(e))
        })
      }

      # k. Log summary
      if (nrow(rates) > 0) {
        ieepa_summary <- rates %>%
          filter(rate_ieepa_recip > 0) %>%
          summarise(
            n_countries = n_distinct(country),
            mean_rate = mean(rate_ieepa_recip)
          )
        message('  IEEPA active in ', ieepa_summary$n_countries, ' countries, ',
                'mean rate: ', round(ieepa_summary$mean_rate * 100, 1), '%')
      }

      # l. Update previous state
      prev_ch99 <- ch99_data
      prev_products <- products

      last_successful_rev <<- rev_id
      log_info('  OK: ', nrow(rates), ' product-country rates')

    }, error = function(e) {
      log_error('FAILED: ', rev_id, ' — ', conditionMessage(e))
      message('  ERROR: ', conditionMessage(e))
      message('  Skipping ', rev_id, ' and continuing...')
      failed_revisions <<- c(failed_revisions, rev_id)
    })
  }
  cli::cli_progress_done()

  # Report failures
  if (length(failed_revisions) > 0) {
    log_warn('Failed revisions (', length(failed_revisions), '): ',
             paste(failed_revisions, collapse = ', '))
    message('\nWARNING: ', length(failed_revisions), ' revision(s) failed: ',
            paste(failed_revisions, collapse = ', '))
  }

  # ---- Combine snapshots into Parquet (batch, one at a time) ----
  # NEVER load all snapshots into memory at once — the monolithic approach
  # exceeds available RAM (~150M+ rows). Instead, process each snapshot
  # individually and write directly to partitioned Parquet.
  message('\n', strrep('=', 60))
  message('Combining snapshots into Parquet (batch mode)...')

  all_snapshot_files <- list.files(output_dir, pattern = '^snapshot_.*\\.rds$', full.names = TRUE)

  # Filter out legacy short-format snapshots (e.g., snapshot_rev_2.rds) that

  # duplicate canonical year-prefixed snapshots (e.g., snapshot_2025_rev_2.rds).
  # These are orphans from an older build that used short revision IDs.
  legacy <- grepl('/snapshot_rev_', all_snapshot_files) |
            grepl('/snapshot_basic\\.rds$', all_snapshot_files)
  if (any(legacy)) {
    message('  Skipping ', sum(legacy), ' legacy snapshot(s) without year prefix')
    all_snapshot_files <- all_snapshot_files[!legacy]
  }

  if (length(all_snapshot_files) == 0) {
    stop('No snapshot files found in ', output_dir)
  }

  # Collect revision names from snapshots without loading full data
  all_revisions_seen <- character()
  for (f in all_snapshot_files) {
    snap <- readRDS(f)
    all_revisions_seen <- c(all_revisions_seen, unique(snap$revision))
    rm(snap); gc(verbose = FALSE)
  }

  # Build revision intervals
  horizon_end <- pp_build$SERIES_HORIZON_END %||% Sys.Date()
  last_eff <- max(rev_dates$effective_date[rev_dates$revision %in% unique(all_revisions_seen)])
  if (horizon_end < last_eff) {
    warning('series_horizon.end_date (', horizon_end,
            ') is earlier than last revision (', last_eff, '). Using last revision date.')
    horizon_end <- last_eff
  }

  rev_intervals <- rev_dates %>%
    filter(revision %in% unique(all_revisions_seen)) %>%
    arrange(effective_date) %>%
    mutate(
      valid_from = effective_date,
      valid_until = lead(effective_date) - 1
    ) %>%
    mutate(valid_until = if_else(is.na(valid_until), horizon_end, valid_until)) %>%
    select(revision, valid_from, valid_until)

  # Write each snapshot as a Parquet partition
  parquet_dir <- file.path(output_dir, 'rate_timeseries_parquet')
  unlink(parquet_dir, recursive = TRUE)
  dir.create(parquet_dir, showWarnings = FALSE)

  total_rows <- 0
  n_revisions_written <- 0

  for (i in seq_along(all_snapshot_files)) {
    f <- all_snapshot_files[i]
    rev_name <- gsub('^snapshot_|\\.rds$', '', basename(f))
    message('[', i, '/', length(all_snapshot_files), '] ', rev_name)

    snap <- tryCatch(readRDS(f), error = function(e) {
      warning('Failed to read snapshot: ', f, ' -- ', e$message)
      NULL
    })
    if (is.null(snap) || nrow(snap) == 0) next

    snap <- enforce_rate_schema(snap)
    snap <- snap %>%
      select(-any_of(c('valid_from', 'valid_until'))) %>%
      left_join(rev_intervals, by = 'revision') %>%
      arrange(country, hts10)

    total_rows <- total_rows + nrow(snap)
    n_revisions_written <- n_revisions_written + 1

    rev_part_dir <- file.path(parquet_dir, paste0('revision=', snap$revision[1]))
    dir.create(rev_part_dir, showWarnings = FALSE)
    arrow::write_parquet(snap %>% select(-revision),
                          file.path(rev_part_dir, 'data.parquet'),
                          compression = 'zstd',
                          compression_level = 3L)

    rm(snap); gc(verbose = FALSE)
  }

  message('Parquet dataset written: ', parquet_dir)
  message('  Total rows: ', total_rows,
          '  Revisions: ', n_revisions_written)

  if (total_rows == 0) {
    warning('Timeseries is empty — all revisions may have failed')
  }

  # ts_path points to the Parquet directory (not a monolithic RDS)
  ts_path <- parquet_dir

  # ---- Save metadata ----
  metadata <- list(
    last_revision = last_successful_rev,
    last_build_time = Sys.time(),
    n_revisions = n_revisions_written,
    n_rows = total_rows,
    scenario = scenario,
    format = 'parquet_partitioned'
  )
  saveRDS(metadata, file.path(output_dir, 'metadata.rds'))

  # ---- Summary ----
  end_time <- Sys.time()
  elapsed <- round(difftime(end_time, start_time, units = 'mins'), 1)

  message('\n', strrep('=', 70))
  message('TIME SERIES BUILD COMPLETE')
  message(strrep('=', 70))
  message('Elapsed: ', elapsed, ' minutes')
  message('Revisions processed: ', length(revisions_to_process))
  message('Output: ', ts_path)
  message(strrep('=', 70), '\n')

  return(list(
    metadata = metadata,
    timeseries_path = ts_path,
    output_dir = output_dir
  ))
}


#' Print time series summary by revision
#'
#' @param timeseries_path Path to Parquet dataset directory
print_timeseries_summary <- function(timeseries_path = 'data/timeseries/rate_timeseries_parquet') {
  ds <- arrow::open_dataset(timeseries_path, partitioning = 'revision')

  summary <- ds %>%
    group_by(revision, effective_date) %>%
    summarise(
      n_products = n_distinct(hts10),
      n_countries = n_distinct(country),
      n_rows = n(),
      .groups = 'drop'
    ) %>%
    arrange(effective_date) %>%
    collect()

  cat('\n=== Time Series Summary ===\n\n')
  print(summary, n = Inf)

  return(invisible(summary))
}


# =============================================================================
# Auto-Update Detection
# =============================================================================

#' Detect incremental start revision from previous build metadata
#'
#' Reads metadata from last build, checks for new revisions available.
#' Returns the last processed revision (for incremental start), or NULL
#' if no previous build exists (triggers full backfill).
#'
#' @param output_dir Directory containing metadata.rds
#' @param archive_dir Directory containing HTS JSON files
#' @param revision_dates_path Path to revision_dates.csv
#' @return Character revision ID to start from, or NULL for full backfill
detect_incremental_start <- function(
  output_dir = 'data/timeseries',
  archive_dir = 'data/hts_archives',
  revision_dates_path = 'config/revision_dates.csv',
  use_policy_dates = TRUE
) {
  metadata_path <- file.path(output_dir, 'metadata.rds')
  if (!file.exists(metadata_path)) {
    message('No previous build found — full backfill')
    return(NULL)
  }

  metadata <- readRDS(metadata_path)
  last_rev <- metadata$last_revision
  message('Last build: ', metadata$last_build_time, ' (', last_rev, ')')

  # Check for new revisions after last_rev
  rev_dates <- load_revision_dates(revision_dates_path,
                                    use_policy_dates = use_policy_dates)
  all_revisions <- rev_dates$revision

  available <- get_available_revisions_all_years(all_revisions, archive_dir)

  revisions_available <- all_revisions[all_revisions %in% available]
  last_idx <- which(revisions_available == last_rev)

  if (length(last_idx) == 0) {
    message('Last revision ', last_rev, ' not found — full backfill')
    return(NULL)
  }

  if (last_idx >= length(revisions_available)) {
    message('No new revisions — rebuilding from ', last_rev)
    return(last_rev)
  }

  new_revs <- revisions_available[(last_idx + 1):length(revisions_available)]
  message('New revisions: ', paste(new_revs, collapse = ', '))
  return(last_rev)
}


# =============================================================================
# Main Execution
# =============================================================================

if (sys.nframe() == 0) {
  library(here)

  # Parse CLI args
  args <- commandArgs(trailingOnly = TRUE)
  full_rebuild <- '--full' %in% args
  build_only <- '--build-only' %in% args
  core_only <- '--core-only' %in% args
  with_alternatives <- '--with-alternatives' %in% args
  refresh_usmca <- '--refresh-usmca' %in% args
  use_policy_dates <- !('--use-hts-dates' %in% args)  # default: policy dates
  start_from <- NULL
  for (i in seq_along(args)) {
    if (args[i] == '--start-from' && i < length(args)) start_from <- args[i + 1]
  }

  # --- Step A: Determine build mode ---
  if (full_rebuild) {
    start_from <- NULL
    message('Mode: Full rebuild (--full)')
  } else if (!is.null(start_from)) {
    message('Mode: Incremental from ', start_from)
  } else {
    start_from <- detect_incremental_start(use_policy_dates = use_policy_dates)
  }

  # --- Step B: Download missing JSON ---
  tryCatch(
    download_missing_revisions(),
    error = function(e) message('Download check failed: ', conditionMessage(e))
  )

  # --- Step B2: Refresh USMCA shares from DataWeb API (if requested) ---
  if (refresh_usmca) {
    message('\n', strrep('=', 70))
    message('Refreshing USMCA utilization shares from USITC DataWeb API')
    message(strrep('=', 70))
    pp_temp <- load_policy_params(use_policy_dates = use_policy_dates)
    usmca_year <- pp_temp$USMCA_SHARES$year %||% 2025L
    refresh_failures <- character()
    # Download monthly data (produces per-month CSVs + diagnostic)
    monthly_rc <- system2('Rscript', c(here('src', 'download_usmca_dataweb.R'),
                                        '--monthly', '--year', usmca_year),
                           stdout = TRUE, stderr = TRUE)
    if (!is.null(attr(monthly_rc, 'status')) && attr(monthly_rc, 'status') != 0) {
      message('  USMCA monthly refresh FAILED (exit ', attr(monthly_rc, 'status'), '):')
      message(paste(tail(monthly_rc, 20), collapse = '\n'))
      refresh_failures <- c(refresh_failures, 'monthly')
    } else {
      message('  Monthly shares refreshed for ', usmca_year)
    }
    # Download annual for the same year
    annual_rc <- system2('Rscript', c(here('src', 'download_usmca_dataweb.R'),
                                       '--year', usmca_year),
                          stdout = TRUE, stderr = TRUE)
    if (!is.null(attr(annual_rc, 'status')) && attr(annual_rc, 'status') != 0) {
      message('  USMCA annual refresh FAILED (exit ', attr(annual_rc, 'status'), '):')
      message(paste(tail(annual_rc, 20), collapse = '\n'))
      refresh_failures <- c(refresh_failures, 'annual')
    } else {
      message('  Annual shares refreshed for ', usmca_year)
    }
    if (length(refresh_failures) > 0) {
      stop('USMCA refresh failed for: ', paste(refresh_failures, collapse = ', '),
           '. Fix the issue or remove --refresh-usmca to use existing files.')
    }
  }

  # --- Step C: Build timeseries ---
  if (use_policy_dates) {
    message('Mode: Using policy effective dates (default; pass --use-hts-dates to override)')
  } else {
    message('Mode: Using raw HTS revision dates (--use-hts-dates)')
  }
  result <- build_full_timeseries(start_from = start_from,
                                   use_policy_dates = use_policy_dates)

  # --- Step D: Summary ---
  if (!is.null(result)) {
    # Summary from Parquet (no monolithic RDS load)
    ds <- arrow::open_dataset(result$timeseries_path, partitioning = 'revision')
    summary_tbl <- ds %>%
      group_by(revision, effective_date) %>%
      summarise(
        n_products = n_distinct(hts10),
        n_countries = n_distinct(country),
        n_rows = n(),
        .groups = 'drop'
      ) %>%
      arrange(effective_date) %>%
      collect()
    cat('\n=== Time Series Summary ===\n\n')
    print(summary_tbl, n = Inf)
  }

  # --- Step E: Downstream (unless --build-only) ---
  # Downstream scripts operate on Parquet via batch processing.
  # NEVER load the full dataset into RAM — use the standalone scripts instead.
  if (!build_only && !is.null(result)) {
    message('\n', strrep('=', 70))
    message('POST-BUILD: Running downstream scripts (batch mode)')
    message(strrep('=', 70))

    # Daily series from Parquet (batch, one revision at a time)
    tryCatch({
      message('\n--- Daily series (from Parquet) ---')
      rc <- system2('Rscript', c(here('scripts', 'run_daily_from_parquet.R')),
                     stdout = '', stderr = '')
      if (!is.null(attr(rc, 'status')) && attr(rc, 'status') != 0) {
        message('Daily series script exited with status ', attr(rc, 'status'))
      }
    }, error = function(e) message('Daily series failed: ', conditionMessage(e)))

    # Quality report — skipped in automated pipeline (still uses monolithic load).
    # Run manually: Rscript scripts/combine_snapshots.R && then quality_report.R
    message('\n--- Quality report: run separately via Rscript src/quality_report.R ---')

    # Frontend data export
    tryCatch({
      message('\n--- Preparing frontend data ---')
      rc <- system2('Rscript', c(here('scripts', 'prepare_frontend_data.R')),
                     stdout = '', stderr = '')
      if (!is.null(attr(rc, 'status')) && attr(rc, 'status') != 0) {
        message('Frontend data script exited with status ', attr(rc, 'status'))
      }
    }, error = function(e) message('Frontend data failed: ', conditionMessage(e)))

    # Weighted ETR (uses its own data loading, not the timeseries)
    if (!core_only) {
      tryCatch({
        source(here('src', '08_weighted_etr.R'))
        pp <- load_policy_params(use_policy_dates = use_policy_dates)
        run_weighted_etr(policy_params = pp)
      }, error = function(e) message('Weighted ETR failed: ', conditionMessage(e)))
    }
  }
}
