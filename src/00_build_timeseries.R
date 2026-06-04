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
#   Rscript src/00_build_timeseries.R --start-from 2025_rev_28  # Explicit incremental
#   Rscript src/00_build_timeseries.R --resume              # Auto-resume from last fresh-cached revision (crash recovery, mtime-aware)
#   Rscript src/00_build_timeseries.R --list-cached         # Diagnostic: show all cached revisions with mtimes and normalized-output status
#   Rscript src/00_build_timeseries.R --reemit-normalized   # Re-emit Phase 2 normalized parquets for cached revisions (skips denormalized build)
#   Rscript src/00_build_timeseries.R --reemit-normalized --force      # Re-emit all cached (even those with complete normalized dirs)
#   Rscript src/00_build_timeseries.R --reemit-normalized --only-stale # Re-emit only the stale tail from prior runs
#   Rscript src/00_build_timeseries.R --build-only  # Skip downstream (daily/ETR/quality)
#   Rscript src/00_build_timeseries.R --core-only  # Build + downstream, but skip weighted outputs
#   Rscript src/00_build_timeseries.R --with-alternatives  # Also run rebuild alternatives
#   Rscript src/00_build_timeseries.R --refresh-usmca     # Re-download USMCA shares from DataWeb API
#   Rscript src/00_build_timeseries.R --full --parallel 8  # Full rebuild, 8 fork workers (Linux/macOS)
#
# Env knobs:
#   SAIL_RESUME_WINDOW_HOURS  mtime window for "fresh run" detection (default 12)
#   SAIL_EMIT_NORMALIZED=0    disable Phase 2 normalized emission (default 1)
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
source(here('src', 'emit_quality_metrics.R'))
source(here('src', 'extract_legal_refs.R'))


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
  only_revisions = NULL,
  stacking_method = 'mutual_exclusion',
  use_policy_dates = TRUE,
  parallel_workers = 1L
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

  # Optional subset: build ONLY the specified revisions (e.g. an older-year
  # backfill that must not recompute existing snapshots). Each token matches an
  # exact rev_id (e.g. "2019_basic") OR a year prefix (e.g. "2019" = all
  # 2019_* revisions). Snapshots for all OTHER revisions are left untouched on
  # disk; because the downstream combine/daily/frontend steps read EVERY
  # partition present, the assembled timeseries still spans the full set.
  if (!is.null(only_revisions) && length(only_revisions) > 0) {
    keep <- vapply(revisions_to_process, function(r) {
      any(r == only_revisions | startsWith(r, paste0(only_revisions, '_')))
    }, logical(1))
    revisions_to_process <- revisions_to_process[keep]
    if (length(revisions_to_process) == 0) {
      stop('--only-revisions matched no available revisions: ',
           paste(only_revisions, collapse = ', '))
    }
    message('Subset build (--only-revisions): ',
            paste(revisions_to_process, collapse = ', '))
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

  # ---- Per-revision processing function ----
  #
  # Pure with respect to in-memory state: every input is passed explicitly
  # and every output is written to disk. This is what lets us run the
  # revision loop in parallel via parallel::mclapply without worrying about
  # shared-state races. All rate-computation logic (parse → extract →
  # calculate_rates_for_revision → emit_normalized_revision) is identical
  # to the prior serial implementation — only the delta step moves out,
  # because it requires the previous revision's parsed state and is purely
  # an audit side-output. A post-pass below recomputes deltas serially
  # from the cached ch99_*.rds / products_*.rds files so the on-disk
  # artefact set is unchanged.
  process_one_revision <- function(rev_id, rev_dates, archive_dir, output_dir,
                                    countries, country_lookup, census_codes,
                                    tpc_path, stacking_method, pp_build) {
    rev_info <- rev_dates %>% filter(revision == rev_id)
    eff_date <- rev_info$effective_date
    tpc_date <- rev_info$tpc_date

    result <- list(rev_id = rev_id, status = 'ok', n_rows = 0L,
                   error = NA_character_)

    tryCatch({
      # a. Resolve JSON path
      json_path <- resolve_json_path(rev_id, archive_dir)

      # b. Read raw JSON (needed for IEEPA/USMCA extraction)
      hts_raw <- fromJSON(json_path, simplifyDataFrame = FALSE)

      # c. Parse Chapter 99 entries
      ch99_data <- parse_chapter99(json_path, revision_id = rev_id)

      # d. Parse products
      products <- parse_products(json_path)

      # e. Extract IEEPA rates, fentanyl rates, Section 232 rates, and USMCA eligibility.
      #    Pass eff_date so IEEPA & fentanyl extractors gate entries whose legal
      #    effective date in their description is after this revision (mirrors
      #    the filter_active_ch99() gate inside calculate_rates_for_revision).
      ieepa_rates <- extract_ieepa_rates(hts_raw, country_lookup, effective_date = eff_date)
      fentanyl_rates <- extract_ieepa_fentanyl_rates(hts_raw, country_lookup, effective_date = eff_date)
      s232_rates <- extract_section232_rates(ch99_data)
      usmca <- extract_usmca_eligibility(hts_raw)

      # f. Calculate rates for this revision
      rates <- calculate_rates_for_revision(
        products, ch99_data, ieepa_rates, usmca,
        countries, rev_id, eff_date,
        s232_rates = s232_rates,
        fentanyl_rates = fentanyl_rates,
        stacking_method = stacking_method,
        policy_params = pp_build
      )

      # g. Save snapshot + parse caches
      saveRDS(rates, file.path(output_dir, paste0('snapshot_', rev_id, '.rds')))
      saveRDS(ch99_data, file.path(output_dir, paste0('ch99_', rev_id, '.rds')))
      saveRDS(products, file.path(output_dir, paste0('products_', rev_id, '.rds')))

      # h. TPC validation if this revision has a tpc_date
      if (!is.na(tpc_date) && file.exists(tpc_path)) {
        tryCatch({
          validation <- validate_revision_against_tpc(
            revision_rates = rates,
            tpc_path      = tpc_path,
            tpc_date      = tpc_date,
            census_codes  = census_codes
          )
          saveRDS(validation,
                  file.path(output_dir, paste0('validation_', rev_id, '.rds')))
          result$tpc_match_rate <- validation$match_rate
        }, error = function(e) {
          result$tpc_error <<- conditionMessage(e)
        })
      }

      result$n_rows <- nrow(rates)
      if (nrow(rates) > 0) {
        ieepa_summary <- rates %>%
          filter(rate_ieepa_recip > 0) %>%
          summarise(n_countries = n_distinct(country),
                    mean_rate   = mean(rate_ieepa_recip))
        result$ieepa_n_countries <- ieepa_summary$n_countries
        result$ieepa_mean_rate   <- ieepa_summary$mean_rate
      }
    }, error = function(e) {
      result$status <<- 'failed'
      result$error  <<- conditionMessage(e)
    })

    result
  }

  # ---- Main processing loop ----
  failed_revisions <- character()
  last_successful_rev <- if (!is.null(start_from)) start_from else NULL
  n_revisions <- length(revisions_to_process)

  # Decide between serial and parallel execution.
  #
  # Rate computation is self-contained per revision, so mclapply() is safe.
  # Parallel path is Linux-only (fork()); we fall back to serial on any
  # platform where mc.cores > 1 is not supported. The delta side-output is
  # moved to a serial post-pass regardless of which path runs — this keeps
  # the on-disk artefacts identical between serial and parallel builds.
  use_parallel <- isTRUE(parallel_workers > 1) &&
                  requireNamespace('parallel', quietly = TRUE) &&
                  .Platform$OS.type != 'windows'

  if (use_parallel) {
    # Cap workers at the number of revisions — no point forking idle workers.
    n_workers <- min(as.integer(parallel_workers), n_revisions)
    message('Processing ', n_revisions, ' revisions in parallel across ',
            n_workers, ' workers (fork-based).')
    log_info('Parallel dispatch: ', n_workers, ' workers for ', n_revisions,
             ' revisions')

    results <- parallel::mclapply(
      revisions_to_process,
      function(rid) {
        process_one_revision(
          rev_id = rid,
          rev_dates = rev_dates, archive_dir = archive_dir,
          output_dir = output_dir, countries = countries,
          country_lookup = country_lookup, census_codes = census_codes,
          tpc_path = tpc_path, stacking_method = stacking_method,
          pp_build = pp_build
        )
      },
      mc.cores       = n_workers,
      mc.preschedule = FALSE  # long, variable tasks — dispatch on demand
    )

    # Drain results serially to produce the per-revision log lines the user
    # expects to see. Parallel workers can't interleave cli_progress_bar
    # cleanly, so we emit a flat summary instead.
    for (i in seq_along(results)) {
      r <- results[[i]]
      # mclapply can return a try-error if a worker crashed outright
      if (inherits(r, 'try-error')) {
        rid <- revisions_to_process[i]
        message('[', i, '/', n_revisions, '] ', rid, ' — WORKER CRASH: ',
                conditionMessage(attr(r, 'condition')))
        log_error('FAILED: ', rid, ' — worker crash')
        failed_revisions <- c(failed_revisions, rid)
        next
      }
      if (identical(r$status, 'ok')) {
        last_successful_rev <- r$rev_id
        log_info('  OK: ', r$rev_id, ' — ', r$n_rows, ' product-country rates')
        msg <- paste0('[', i, '/', n_revisions, '] ', r$rev_id, ' OK — ',
                      r$n_rows, ' rows')
        if (!is.null(r$ieepa_n_countries)) {
          msg <- paste0(msg, '; IEEPA active in ', r$ieepa_n_countries,
                        ' countries, mean ',
                        round(r$ieepa_mean_rate * 100, 1), '%')
        }
        if (!is.null(r$tpc_match_rate)) {
          msg <- paste0(msg, '; TPC match ',
                        round(r$tpc_match_rate * 100, 1), '%')
        }
        message(msg)
      } else {
        failed_revisions <- c(failed_revisions, r$rev_id)
        log_error('FAILED: ', r$rev_id, ' — ', r$error)
        message('[', i, '/', n_revisions, '] ', r$rev_id, ' FAILED — ',
                r$error)
      }
    }
  } else {
    if (parallel_workers > 1) {
      message('Parallel requested but unavailable on this platform; ',
              'falling back to serial.')
    }
    cli::cli_progress_bar(
      format = "Processing {cli::pb_current}/{cli::pb_total} [{cli::pb_bar}] {cli::pb_eta} | {rev_id} ({eff_date})",
      total = n_revisions,
      clear = FALSE
    )

    for (i in seq_along(revisions_to_process)) {
      rev_id <- revisions_to_process[i]
      rev_info <- rev_dates %>% filter(revision == rev_id)
      eff_date <- rev_info$effective_date
      cli::cli_progress_update()

      message('\n', strrep('-', 60))
      message('[', i, '/', n_revisions, '] Processing: ',
              rev_id, ' (effective ', eff_date, ')')
      message(strrep('-', 60))
      log_info('[', i, '/', n_revisions, '] ', rev_id, ' (', eff_date, ')')

      r <- process_one_revision(
        rev_id = rev_id,
        rev_dates = rev_dates, archive_dir = archive_dir,
        output_dir = output_dir, countries = countries,
        country_lookup = country_lookup, census_codes = census_codes,
        tpc_path = tpc_path, stacking_method = stacking_method,
        pp_build = pp_build
      )
      if (identical(r$status, 'ok')) {
        last_successful_rev <- r$rev_id
        if (!is.null(r$ieepa_n_countries)) {
          message('  IEEPA active in ', r$ieepa_n_countries,
                  ' countries, mean rate: ',
                  round(r$ieepa_mean_rate * 100, 1), '%')
        }
        if (!is.null(r$tpc_match_rate)) {
          message('  TPC match rate: ',
                  round(r$tpc_match_rate * 100, 1), '%')
        }
        log_info('  OK: ', r$n_rows, ' product-country rates')
      } else {
        failed_revisions <- c(failed_revisions, r$rev_id)
        log_error('FAILED: ', r$rev_id, ' — ', r$error)
        message('  ERROR: ', r$error)
        message('  Skipping ', r$rev_id, ' and continuing...')
      }
    }
    cli::cli_progress_done()
  }

  # ---- Delta post-pass ----
  # Walks cached ch99_*.rds / products_*.rds in revision order and writes
  # delta_{rev}.rds for each consecutive pair. This is the one cross-
  # revision step in the build; pulling it out of the main loop is what
  # makes the per-revision work parallelizable without changing any rate
  # output. Cheap (just object diffs from already-loaded RDS files), so
  # we run it unconditionally to keep serial and parallel builds byte-for-
  # byte equivalent on disk.
  {
    processed_ok <- setdiff(revisions_to_process, failed_revisions)
    if (length(processed_ok) >= 1) {
      ordered <- rev_dates %>%
        filter(revision %in% processed_ok) %>%
        arrange(effective_date) %>%
        pull(revision)

      # Seed the walk with the `start_from` cached state when incremental,
      # otherwise start at the first successful revision with no prior.
      prev_ch99_post <- NULL
      prev_products_post <- NULL
      if (!is.null(start_from)) {
        seed_ch99  <- file.path(output_dir, paste0('ch99_', start_from, '.rds'))
        seed_prods <- file.path(output_dir, paste0('products_', start_from, '.rds'))
        if (file.exists(seed_ch99) && file.exists(seed_prods)) {
          prev_ch99_post <- readRDS(seed_ch99)
          prev_products_post <- readRDS(seed_prods)
        }
      }

      for (rid in ordered) {
        ch99_path <- file.path(output_dir, paste0('ch99_', rid, '.rds'))
        prod_path <- file.path(output_dir, paste0('products_', rid, '.rds'))
        if (!file.exists(ch99_path) || !file.exists(prod_path)) next
        this_ch99 <- readRDS(ch99_path)
        this_prods <- readRDS(prod_path)
        if (!is.null(prev_ch99_post)) {
          delta <- list(
            ch99     = compare_chapter99(prev_ch99_post, this_ch99),
            products = compare_products(prev_products_post, this_prods)
          )
          saveRDS(delta, file.path(output_dir, paste0('delta_', rid, '.rds')))
        }
        prev_ch99_post <- this_ch99
        prev_products_post <- this_prods
      }
    }
  }

  snapshot_paths <- file.path(output_dir,
                              paste0('snapshot_', revisions_to_process, '.rds'))
  snapshot_paths <- snapshot_paths[file.exists(snapshot_paths)]

  # Report failures
  if (length(failed_revisions) > 0) {
    log_warn('Failed revisions (', length(failed_revisions), '): ',
             paste(failed_revisions, collapse = ', '))
    message('\nWARNING: ', length(failed_revisions), ' revision(s) failed: ',
            paste(failed_revisions, collapse = ', '))
  }

  # ---- Phase 2 dual-write: emit normalized statics ----
  # Writes revisions.parquet and country_group_membership.parquet to
  # output/normalized/. product_metal_content.parquet is emitted per-revision
  # from inside calculate_rates_for_revision (hts10 list is only available
  # there). Env gate mirrors the per-revision flag in 06_calculate_rates.R.
  if (!identical(Sys.getenv('SAIL_EMIT_NORMALIZED', '1'), '0')) {
    tryCatch({
      emit_src <- here('src', '07_emit_normalized.R')
      if (file.exists(emit_src)) source(emit_src, local = FALSE)
      if (exists('emit_normalized_statics', mode = 'function')) {
        # Build a revisions tibble from config/revision_dates.csv. valid_from/
        # valid_until come from each revision's effective_date paired against
        # the next revision's effective_date.
        rev_df <- rev_dates %>%
          arrange(effective_date) %>%
          mutate(
            revision = as.character(revision),
            effective_date = as.Date(effective_date),
            valid_from = as.Date(effective_date),
            valid_until = dplyr::lead(as.Date(effective_date) - 1,
                                      default = as.Date('2099-12-31')),
            policy_event = if ('policy_event' %in% names(.)) policy_event
                           else NA_character_,
            ieepa_invalidated = if (!is.null(pp_build$IEEPA_INVALIDATION_DATE))
                                  as.Date(effective_date) >= as.Date(pp_build$IEEPA_INVALIDATION_DATE)
                                else FALSE
          )
        emit_normalized_statics(rev_df, pp_build,
                                output_dir = here('output', 'normalized'))
        message('Emitted normalized static parquets (revisions, country_group_membership)')
      }
    }, error = function(e) {
      message('[phase2 emit_normalized_statics skipped: ', conditionMessage(e), ']')
    })
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
  # For a subset build (--only-revisions), preserve the existing last_revision
  # pointer so a subsequent default/forward-incremental build still anchors on
  # the globally-latest revision rather than this subset's tail (otherwise
  # backfilling old years would make the next incremental rebuild 2022-2026).
  meta_last_rev <- last_successful_rev
  if (!is.null(only_revisions)) {
    existing_meta_path <- file.path(output_dir, 'metadata.rds')
    if (file.exists(existing_meta_path)) {
      meta_last_rev <- tryCatch(readRDS(existing_meta_path)$last_revision,
                                error = function(e) last_successful_rev)
      message('  Subset build: preserving metadata last_revision = ', meta_last_rev)
    }
  }
  metadata <- list(
    last_revision = meta_last_rev,
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


#' Detect the last fully-cached revision for crash recovery
#'
#' Scans output_dir for revisions that have all three cache files
#' (ch99_*.rds, products_*.rds, snapshot_*.rds). Returns the latest such
#' revision **from the most recent run** — not simply the latest in revision
#' order, because stale caches from earlier runs would shadow a fresh partial
#' run's progress. A "run" is detected by mtime clustering: the most recent
#' snapshot's mtime anchors the window, and any snapshot cached within
#' `window_hours` of that anchor belongs to the same run.
#'
#' Env knob: `SAIL_RESUME_WINDOW_HOURS` (default 12). Expand the window for
#' builds that take longer than 12 hours end-to-end.
#'
#' @return Character revision ID to pass to start_from, or NULL if none found
detect_resume_point <- function(
  output_dir = here::here('data', 'timeseries'),
  revision_dates_path = here::here('config', 'revision_dates.csv'),
  use_policy_dates = TRUE,
  window_hours = NULL
) {
  if (!dir.exists(output_dir)) return(NULL)
  if (is.null(window_hours)) {
    env_val <- Sys.getenv('SAIL_RESUME_WINDOW_HOURS', '12')
    window_hours <- suppressWarnings(as.numeric(env_val))
    if (is.na(window_hours) || window_hours <= 0) window_hours <- 12
  }

  rev_dates <- load_revision_dates(revision_dates_path,
                                    use_policy_dates = use_policy_dates)
  ordered_revs <- rev_dates$revision

  has_full_cache <- function(rev_id) {
    all(file.exists(c(
      file.path(output_dir, paste0('ch99_', rev_id, '.rds')),
      file.path(output_dir, paste0('products_', rev_id, '.rds')),
      file.path(output_dir, paste0('snapshot_', rev_id, '.rds'))
    )))
  }

  cached <- ordered_revs[vapply(ordered_revs, has_full_cache, logical(1))]
  if (length(cached) == 0) {
    message('No fully-cached revisions found — nothing to resume from')
    return(NULL)
  }

  # Gather mtimes of each cached revision's snapshot file (the canonical
  # "this revision finished" marker).
  snap_mtimes <- vapply(cached, function(r) {
    as.numeric(file.info(file.path(output_dir, paste0('snapshot_', r, '.rds')))$mtime)
  }, numeric(1))
  max_mtime <- max(snap_mtimes, na.rm = TRUE)
  window_seconds <- window_hours * 3600
  fresh_mask <- (max_mtime - snap_mtimes) <= window_seconds
  fresh_cached <- cached[fresh_mask]

  # Within the fresh cluster, return the latest revision in revision-date
  # order (not the latest mtime — revisions may be processed out-of-order in
  # principle, and we want to resume at the end of the ordered sequence).
  if (length(fresh_cached) == 0) {
    last_cached <- tail(cached, 1)
    message('Resume: no fresh snapshots within ', window_hours,
            'h window; using stale tail ', last_cached)
  } else {
    last_cached <- fresh_cached[length(fresh_cached)]
    stale_count <- length(cached) - length(fresh_cached)
    message('Resume: last fresh-cached revision is ', last_cached,
            ' (fresh cluster: ', length(fresh_cached), ', stale skipped: ',
            stale_count, ', window: ', window_hours, 'h)')
    if (stale_count > 0) {
      stale_revs <- setdiff(cached, fresh_cached)
      message('  Stale revisions (from prior runs, will be reprocessed): ',
              paste(head(stale_revs, 8), collapse = ', '),
              if (length(stale_revs) > 8) paste0(' ... +', length(stale_revs) - 8, ' more') else '')
    }
  }

  # Warn about orphan/partial files from an interrupted revision
  next_idx <- which(ordered_revs == last_cached) + 1
  if (next_idx <= length(ordered_revs)) {
    next_rev <- ordered_revs[next_idx]
    orphans <- list.files(
      output_dir,
      pattern = paste0('^(delta|ch99|products|snapshot|validation)_',
                       next_rev, '\\.rds$'),
      full.names = TRUE
    )
    if (length(orphans) > 0) {
      message('  Removing ', length(orphans), ' orphan file(s) from interrupted ',
              next_rev, ':')
      for (o in orphans) message('    ', basename(o))
      file.remove(orphans)
    }
  }

  return(last_cached)
}


#' List all cached revisions with their snapshot mtimes.
#'
#' Diagnostic helper. Prints a table so the user can decide where to resume.
#' Grouped into "fresh" and "stale" using the same mtime-clustering rule as
#' detect_resume_point().
list_cached_revisions <- function(
  output_dir = here::here('data', 'timeseries'),
  revision_dates_path = here::here('config', 'revision_dates.csv'),
  use_policy_dates = TRUE,
  window_hours = NULL
) {
  if (!dir.exists(output_dir)) {
    message('Output dir not found: ', output_dir)
    return(invisible(NULL))
  }
  if (is.null(window_hours)) {
    env_val <- Sys.getenv('SAIL_RESUME_WINDOW_HOURS', '12')
    window_hours <- suppressWarnings(as.numeric(env_val))
    if (is.na(window_hours) || window_hours <= 0) window_hours <- 12
  }

  rev_dates <- load_revision_dates(revision_dates_path,
                                    use_policy_dates = use_policy_dates)
  ordered_revs <- rev_dates$revision
  has_full_cache <- function(rev_id) {
    all(file.exists(c(
      file.path(output_dir, paste0('ch99_', rev_id, '.rds')),
      file.path(output_dir, paste0('products_', rev_id, '.rds')),
      file.path(output_dir, paste0('snapshot_', rev_id, '.rds'))
    )))
  }
  cached <- ordered_revs[vapply(ordered_revs, has_full_cache, logical(1))]
  if (length(cached) == 0) {
    message('No fully-cached revisions under ', output_dir)
    return(invisible(NULL))
  }

  rows <- lapply(cached, function(r) {
    sp <- file.path(output_dir, paste0('snapshot_', r, '.rds'))
    mt <- file.info(sp)$mtime
    norm_dir <- here::here('output', 'normalized', r)
    norm_ok <- dir.exists(norm_dir) &&
      all(c('products_base.parquet', 'authority_country_rates.parquet',
            'authority_product_applicability.parquet',
            'authority_exemptions.parquet') %in% list.files(norm_dir))
    tibble::tibble(
      revision = r,
      snapshot_mtime = format(mt, '%Y-%m-%d %H:%M:%S'),
      mtime_numeric = as.numeric(mt),
      normalized_ok = norm_ok
    )
  })
  df <- dplyr::bind_rows(rows)
  max_mt <- max(df$mtime_numeric, na.rm = TRUE)
  df$freshness <- ifelse(
    (max_mt - df$mtime_numeric) <= window_hours * 3600,
    'fresh',
    'stale'
  )

  cat('\n=== Cached revisions (', nrow(df), ' total, window: ', window_hours, 'h) ===\n', sep = '')
  cat(sprintf('%-20s  %-20s  %-8s  %s\n',
              'revision', 'snapshot_mtime', 'normalized', 'freshness'))
  cat(strrep('-', 70), '\n')
  for (i in seq_len(nrow(df))) {
    cat(sprintf('%-20s  %-20s  %-8s  %s\n',
                df$revision[i],
                df$snapshot_mtime[i],
                ifelse(df$normalized_ok[i], 'OK', 'missing'),
                df$freshness[i]))
  }

  fresh_revs <- df$revision[df$freshness == 'fresh']
  stale_revs <- df$revision[df$freshness == 'stale']
  cat('\nFresh cluster:', length(fresh_revs), 'revisions\n')
  cat('Stale     :   ', length(stale_revs), 'revisions\n')
  if (length(fresh_revs) > 0) {
    cat('\nResume hint: Rscript src/00_build_timeseries.R --start-from ',
        tail(fresh_revs, 1), '\n', sep = '')
  }
  invisible(df)
}


#' Re-emit normalized parquet layers for cached revisions.
#'
#' Skips the denormalized rate pipeline entirely. Iterates cached revisions,
#' re-runs `calculate_rates_for_revision` for each one (loading cached
#' ch99/products RDSes for speed), which has the side effect of writing the
#' normalized layer parquets via the Phase 2 emitter. Skips the parquet
#' combine and downstream steps.
#'
#' Use when:
#'   - A build crashed after snapshots were written but before normalized
#'     output finished for some revisions.
#'   - Normalized output is missing/partial for already-built revisions
#'     (e.g., Phase 2 was added after the initial pipeline run).
#'
#' @param force If TRUE, re-emit every cached revision even if its normalized
#'              output directory already has all four layer parquets.
#' @param only_stale If TRUE (default FALSE), only process revisions whose
#'                   snapshot mtime is outside the fresh window — i.e. the
#'                   stale tail from prior runs.
reemit_normalized_for_cached <- function(
  output_dir = here::here('data', 'timeseries'),
  revision_dates_path = here::here('config', 'revision_dates.csv'),
  archive_dir = here::here('data', 'hts_archives'),
  census_codes_path = here::here('resources', 'census_codes.csv'),
  use_policy_dates = TRUE,
  force = FALSE,
  only_stale = FALSE,
  window_hours = NULL
) {
  if (is.null(window_hours)) {
    env_val <- Sys.getenv('SAIL_RESUME_WINDOW_HOURS', '12')
    window_hours <- suppressWarnings(as.numeric(env_val))
    if (is.na(window_hours) || window_hours <= 0) window_hours <- 12
  }

  message('Re-emit normalized for cached revisions')
  message('  output_dir : ', output_dir)
  message('  force      : ', force)
  message('  only_stale : ', only_stale)

  pp_build <- load_policy_params(use_policy_dates = use_policy_dates)
  rev_dates <- load_revision_dates(revision_dates_path,
                                    use_policy_dates = use_policy_dates)
  ordered_revs <- rev_dates$revision

  census_codes <- read_csv(census_codes_path,
                            col_types = cols(.default = col_character()))
  countries <- census_codes$Code
  country_lookup <- build_country_lookup(census_codes_path)

  has_full_cache <- function(rev_id) {
    all(file.exists(c(
      file.path(output_dir, paste0('ch99_', rev_id, '.rds')),
      file.path(output_dir, paste0('products_', rev_id, '.rds')),
      file.path(output_dir, paste0('snapshot_', rev_id, '.rds'))
    )))
  }
  cached <- ordered_revs[vapply(ordered_revs, has_full_cache, logical(1))]
  if (length(cached) == 0) {
    message('No cached revisions found. Nothing to re-emit.')
    return(invisible(NULL))
  }

  if (only_stale) {
    snap_mtimes <- vapply(cached, function(r) {
      as.numeric(file.info(file.path(output_dir, paste0('snapshot_', r, '.rds')))$mtime)
    }, numeric(1))
    max_mt <- max(snap_mtimes, na.rm = TRUE)
    stale_mask <- (max_mt - snap_mtimes) > window_hours * 3600
    cached <- cached[stale_mask]
    message('Filtered to stale cluster: ', length(cached), ' revisions')
  }

  normalized_root <- here::here('output', 'normalized')
  needs_emit <- function(rev_id) {
    if (force) return(TRUE)
    rev_dir <- file.path(normalized_root, rev_id)
    if (!dir.exists(rev_dir)) return(TRUE)
    required <- c('products_base.parquet', 'authority_country_rates.parquet',
                   'authority_product_applicability.parquet',
                   'authority_exemptions.parquet')
    missing <- setdiff(required, list.files(rev_dir))
    if (length(missing) > 0) return(TRUE)
    # Also treat empty files as missing
    for (f in required) {
      if (file.size(file.path(rev_dir, f)) == 0) return(TRUE)
    }
    FALSE
  }
  to_process <- cached[vapply(cached, needs_emit, logical(1))]
  message('Revisions needing re-emit: ', length(to_process), ' / ',
          length(cached), ' cached')
  if (length(to_process) == 0) {
    message('Nothing to do. Use --force to re-emit all cached revisions.')
    return(invisible(NULL))
  }

  # Source calculate_rates_for_revision (which internally sources the emitter
  # and writes normalized output as a side effect).
  source(here::here('src', '06_calculate_rates.R'), local = FALSE)

  n <- length(to_process)
  for (i in seq_along(to_process)) {
    rev_id <- to_process[i]
    rev_info <- rev_dates %>% filter(revision == rev_id)
    eff_date <- rev_info$effective_date[1]

    message(sprintf('\n[%d/%d] %s  (%s)', i, n, rev_id, eff_date))

    tryCatch({
      # Load cached parse outputs
      ch99_data <- readRDS(file.path(output_dir, paste0('ch99_', rev_id, '.rds')))
      products  <- readRDS(file.path(output_dir, paste0('products_', rev_id, '.rds')))

      # Re-extract revision-level structures from raw JSON
      json_path <- resolve_json_path(rev_id, archive_dir)
      hts_raw <- fromJSON(json_path, simplifyDataFrame = FALSE)
      ieepa_rates    <- extract_ieepa_rates(hts_raw, country_lookup, effective_date = eff_date)
      fentanyl_rates <- extract_ieepa_fentanyl_rates(hts_raw, country_lookup, effective_date = eff_date)
      s232_rates     <- extract_section232_rates(ch99_data)
      usmca          <- extract_usmca_eligibility(hts_raw)

      # Run the full rate calculator — the Phase 2 dual-write fires inside
      # and the normalized parquets land. We discard the returned rates
      # tibble; the denormalized parquet dataset is untouched.
      calculate_rates_for_revision(
        products, ch99_data, ieepa_rates, usmca,
        countries, rev_id, eff_date,
        s232_rates = s232_rates,
        fentanyl_rates = fentanyl_rates,
        stacking_method = 'mutual_exclusion',
        policy_params = pp_build
      )
      message('  ok')
    }, error = function(e) {
      message('  FAILED: ', conditionMessage(e))
    })
  }

  # Static parquets (revisions, country_group_membership)
  message('\nEmitting normalized statics')
  tryCatch({
    source(here::here('src', '07_emit_normalized.R'), local = FALSE)
    rev_df <- rev_dates %>%
      arrange(effective_date) %>%
      mutate(
        revision = as.character(revision),
        effective_date = as.Date(effective_date),
        valid_from = as.Date(effective_date),
        valid_until = dplyr::lead(as.Date(effective_date) - 1,
                                   default = as.Date('2099-12-31')),
        policy_event = if ('policy_event' %in% names(.)) policy_event
                       else NA_character_,
        ieepa_invalidated = if (!is.null(pp_build$IEEPA_INVALIDATION_DATE))
                              as.Date(effective_date) >= as.Date(pp_build$IEEPA_INVALIDATION_DATE)
                            else FALSE
      )
    emit_normalized_statics(rev_df, pp_build,
                            output_dir = here::here('output', 'normalized'))
    message('  ok')
  }, error = function(e) {
    message('  statics emit FAILED: ', conditionMessage(e))
  })

  message('\nDone. Normalized output refreshed under ', normalized_root)
  invisible(TRUE)
}


# =============================================================================
# Main Execution
# =============================================================================

if (sys.nframe() == 0) {
  library(here)

  # Parse CLI args
  args <- commandArgs(trailingOnly = TRUE)
  full_rebuild <- '--full' %in% args
  resume <- '--resume' %in% args
  build_only <- '--build-only' %in% args
  core_only <- '--core-only' %in% args
  with_alternatives <- '--with-alternatives' %in% args
  refresh_usmca <- '--refresh-usmca' %in% args
  use_policy_dates <- !('--use-hts-dates' %in% args)  # default: policy dates
  list_cached <- '--list-cached' %in% args
  reemit_normalized <- '--reemit-normalized' %in% args
  reemit_force <- '--force' %in% args
  reemit_only_stale <- '--only-stale' %in% args
  start_from <- NULL
  only_revisions <- NULL
  for (i in seq_along(args)) {
    if (args[i] == '--start-from' && i < length(args)) start_from <- args[i + 1]
    if (args[i] == '--only-revisions' && i < length(args)) {
      only_revisions <- trimws(strsplit(args[i + 1], ',')[[1]])
      only_revisions <- only_revisions[nzchar(only_revisions)]
    }
    if (args[i] == '--parallel' && i < length(args)) {
      parallel_workers <- suppressWarnings(as.integer(args[i + 1]))
    }
  }
  if (!exists('parallel_workers') || is.null(parallel_workers) ||
      is.na(parallel_workers) || parallel_workers < 1L) {
    parallel_workers <- 1L
  }

  # --- Diagnostic modes (exit before running the build) ---
  if (list_cached) {
    list_cached_revisions(use_policy_dates = use_policy_dates)
    quit(status = 0)
  }
  if (reemit_normalized) {
    reemit_normalized_for_cached(
      use_policy_dates = use_policy_dates,
      force = reemit_force,
      only_stale = reemit_only_stale
    )
    quit(status = 0)
  }

  # --- Step A: Determine build mode ---
  if (!is.null(only_revisions)) {
    # Subset backfill: process only the named revisions from the start of the
    # sequence (prev-state = NULL for the first), leaving all other snapshots
    # untouched. Do NOT run incremental start detection.
    start_from <- NULL
    message('Mode: Subset build (--only-revisions ',
            paste(only_revisions, collapse = ','), ')')
  } else if (full_rebuild) {
    start_from <- NULL
    message('Mode: Full rebuild (--full)')
  } else if (resume) {
    resume_rev <- detect_resume_point(use_policy_dates = use_policy_dates)
    if (is.null(resume_rev)) {
      message('Mode: --resume found no cache; falling back to full backfill')
      start_from <- NULL
    } else {
      start_from <- resume_rev
      message('Mode: Resume from ', start_from, ' (crash recovery)')
    }
  } else if (!is.null(start_from)) {
    message('Mode: Incremental from ', start_from)
  } else {
    start_from <- detect_incremental_start(use_policy_dates = use_policy_dates)
  }

  # --- Step B: Download missing JSON ---
  # The rate pipeline reads JSON only (parse_chapter99/parse_products use
  # fromJSON); the CSV format is an auxiliary RAG/automation side-channel and
  # is fetched/managed separately. Restrict the build's download to JSON so it
  # doesn't pull (and structurally-validate) pre-2025 CSV editions, whose older
  # USITC export layout trips the CSV validator and is irrelevant here.
  tryCatch(
    download_missing_revisions(formats = 'json'),
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
                                   only_revisions = only_revisions,
                                   use_policy_dates = use_policy_dates,
                                   parallel_workers = parallel_workers)

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

    # Quality report — the full quality_report.R still requires the monolithic RDS.
    # However, we now produce a lightweight ch99 triage summary from per-revision
    # caches, which captures the most actionable quality signal.
    message('\n--- Ch99 Country Scope Triage Summary ---')
    tryCatch({
      # Prefer year-prefixed canonical ch99 caches (e.g., ch99_2025_rev_5.rds)
      # over legacy short-format ones (ch99_rev_5.rds). The legacy files sort
      # lexicographically HIGHER than year-prefixed ("r" > "2"), so an unfiltered
      # sort picks the wrong one.
      ch99_all <- list.files(output_dir, pattern = '^ch99_.*\\.rds$',
                              full.names = TRUE)
      ch99_canonical <- ch99_all[grepl('^ch99_(20[0-9]{2})_', basename(ch99_all))]
      ch99_files <- if (length(ch99_canonical) > 0) ch99_canonical else ch99_all

      if (length(ch99_files) == 0) {
        log_warn('Ch99 triage: no ch99 caches found in ', output_dir)
      } else {
        # Keep only caches whose format matches the current parser (has
        # resolution_status). Older caches from pre-triage builds are skipped.
        has_status <- vapply(ch99_files, function(f) {
          'resolution_status' %in% names(readRDS(f))
        }, logical(1))
        enriched_files <- ch99_files[has_status]
        stale_count <- sum(!has_status)

        if (length(enriched_files) == 0) {
          log_warn('Ch99 triage: no ch99 caches have resolution_status column. ',
                   'Run a full rebuild (--full) to regenerate with the new parser.')
        } else {
          if (stale_count > 0) {
            log_info('Ch99 triage: skipping ', stale_count,
                     ' stale cache(s) from pre-triage builds')
          }

          latest_ch99 <- readRDS(sort(enriched_files, decreasing = TRUE)[1])
          # Re-derive with the CURRENT classifier so the preview is never
          # stale-labeled, and separate the two categories that actually matter
          # from "unknown country scope" (which is mostly handled downstream).
          if (exists('classify_resolution_status', mode = 'function')) {
            latest_ch99$resolution_status <- classify_resolution_status(
              latest_ch99$ch99_code, latest_ch99$country_type)
          }
          n_truly_unresolved <- sum(latest_ch99$resolution_status == 'unresolved')
          n_unmodeled <- sum(latest_ch99$resolution_status == 'unresolved_s201')
          log_info('Ch99 (latest-revision preview): ', n_truly_unresolved,
                   ' truly unresolved, ', n_unmodeled, ' rated-but-unmodeled. ',
                   'Authoritative cross-revision resolution summary prints in ',
                   'Quality metrics at the end of the build.')

          # Write aggregate triage CSV for all enriched revisions
          ensure_dir(here('output', 'quality'))
          all_triage <- map_dfr(enriched_files, function(f) {
            ch99 <- readRDS(f)
            rev <- gsub('^ch99_|\\.rds$', '', basename(f))
            ch99 %>%
              filter(country_type == 'unknown') %>%
              select(ch99_code, authority, country_type, resolution_status,
                     any_of('references'), description) %>%
              mutate(revision = rev)
          })
          if (nrow(all_triage) > 0) {
            if ('references' %in% names(all_triage)) {
              all_triage <- all_triage %>%
                mutate(references = sapply(references,
                                            function(r) paste(r, collapse = '; ')))
            }
            write_csv(all_triage,
                      here('output', 'quality', 'ch99_country_scope_triage.csv'))
            log_info('Triage CSV written: output/quality/ch99_country_scope_triage.csv (',
                     nrow(all_triage), ' entries across ',
                     n_distinct(all_triage$revision), ' revisions)')
          } else {
            log_info('Ch99 triage: no unknown-country entries to report')
          }
        }
      }
    }, error = function(e) log_error('Ch99 triage summary failed: ',
                                       conditionMessage(e)))
    message('\n--- Full quality report: run separately via Rscript src/quality_report.R ---')

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

  # Quality metrics — regenerate on EVERY build mode (full, resume, scoped,
  # build-only), unconditionally, so output/quality/ never goes stale. Pure
  # read/derive from on-disk ch99 caches; wrapped so it can never abort a build.
  tryCatch(emit_quality_metrics(),
           error = function(e) message('Quality metrics emit failed: ', conditionMessage(e)))

  # Legal-authority extraction — machine-source the proclamations/EOs each ch99
  # authority cites, per revision, from that release's Chapter 99 PDF. INCREMENTAL:
  # only revisions not already in resources/ch99_legal_refs.csv are fetched, so a
  # new revision is covered automatically with no re-downloads. Network/PDF op —
  # wrapped so it can never abort a build; opt out with SAIL_EMIT_LEGAL_REFS=0.
  if (!identical(Sys.getenv('SAIL_EMIT_LEGAL_REFS', '1'), '0')) {
    tryCatch(emit_legal_refs_incremental(),
             error = function(e) message('Legal-refs emit failed: ', conditionMessage(e)))
  }
}
