# =============================================================================
# Step 02: Download HTS Archives (JSON + CSV)
# =============================================================================
#
# Downloads missing HTS archives from USITC in both JSON and CSV formats.
# JSON lands in `data/hts_archives/`; CSV lands in `data/hts_archives_csv/`
# (separate sibling folder so existing JSON consumers aren't disturbed).
#
# Both formats are checked independently — if a revision has JSON but no
# CSV, only the CSV is downloaded. The reverse is also supported.
#
# Usage:
#   Rscript src/02_download_hts.R                       # Download missing (all years, both formats)
#   Rscript src/02_download_hts.R --year 2026           # Year filter
#   Rscript src/02_download_hts.R --dry-run             # Report only
#   Rscript src/02_download_hts.R --formats json        # JSON only
#   Rscript src/02_download_hts.R --formats csv         # CSV only
#   Rscript src/02_download_hts.R --formats json,csv    # Both (default)
#
# =============================================================================

library(tidyverse)


# =============================================================================
# Format-aware URL + path helpers
# =============================================================================

#' USITC suffix for a given format ('json' or 'csv').
#' JSON files end in `_json.json`; CSV files end in `_csv.csv`.
#' @param format Character: 'json' or 'csv'
hts_format_suffix <- function(format) {
  format <- tolower(format)
  if (format == 'json') return('_json.json')
  if (format == 'csv')  return('_csv.csv')
  stop('Unknown format: ', format, ' — expected "json" or "csv".')
}


#' Local archive directory for a given format. JSON keeps its historical
#' path; CSV writes to the parallel `data/hts_archives_csv/` folder.
#' @param format Character: 'json' or 'csv'
hts_format_archive_dir <- function(format) {
  format <- tolower(format)
  if (format == 'json') return(here::here('data', 'hts_archives'))
  if (format == 'csv')  return(here::here('data', 'hts_archives_csv'))
  stop('Unknown format: ', format, ' — expected "json" or "csv".')
}


#' Build USITC download URL for an HTS revision in a given format.
#'
#' Uses the static file host at www.usitc.gov/sites/default/files/tata/hts/
#' (the legacy hts.usitc.gov/reststop/getJSON endpoint was deprecated early 2026).
#'
#' @param revision Revision identifier (e.g., 'basic', 'rev_1', '2026_rev_3')
#' @param year Default year used when the revision is plain (no `YYYY_` prefix)
#' @param format 'json' or 'csv'
#' @return Character URL
build_download_url <- function(revision, year = 2025, format = 'json') {
  base_url <- 'https://www.usitc.gov/sites/default/files/tata/hts'
  parsed <- parse_revision_id(revision)
  yr <- parsed$year
  rev <- parsed$rev
  suffix <- hts_format_suffix(format)

  if (rev == 'basic') {
    # USITC's basic-edition filename convention changed over time (verified
    # against the per-year data.gov resource listings,
    # catalog.data.gov/dataset/harmonized-tariff-schedule-of-the-united-states-<yr>):
    #   2023+ : hts_<yr>_basic_edition_<fmt>.<fmt>
    #   <=2022: hts_<yr>_basic_<fmt>.<fmt>   (no "_edition")
    # Revisions use hts_<yr>_revision_<n>_<fmt>.<fmt> across all years. The
    # structured JSON/CSV files are hosted under /tata/hts/ for every edition
    # back to ~2022 (the reststop API only serves the *current* edition, and
    # the archive UI serves PDFs only — so these static files are the source
    # for any pre-2025 backfill).
    stem <- if (suppressWarnings(as.integer(yr)) >= 2023) '_basic_edition' else '_basic'
    url <- paste0(base_url, '/hts_', yr, stem, suffix)
  } else if (grepl('^rev_', rev)) {
    rev_num <- gsub('rev_', '', rev)
    url <- paste0(base_url, '/hts_', yr, '_revision_', rev_num, suffix)
  } else {
    stop('Unknown revision format: ', revision)
  }

  return(url)
}


#' Local destination path for a revision + format combination.
#'
#' Names follow the existing JSON convention to stay backwards-compatible:
#' `hts_<year>_<rev>.<ext>` in the appropriate archive directory.
#'
#' @param revision Revision identifier
#' @param format 'json' or 'csv'
#' @return Full file path
build_local_path <- function(revision, format = 'json') {
  parsed <- parse_revision_id(revision)
  ext <- if (tolower(format) == 'json') 'json' else 'csv'
  archive_dir <- hts_format_archive_dir(format)
  file.path(archive_dir, paste0('hts_', parsed$year, '_', parsed$rev, '.', ext))
}


# =============================================================================
# Format-specific validators
# =============================================================================

#' Header-byte sanity check for a downloaded JSON file.
#' Quick smoke test — confirms first character is `{` or `[`.
validate_json_head <- function(path) {
  con <- file(path, 'r')
  on.exit(close(con), add = TRUE)
  first_char <- readChar(con, 1)
  close(con)
  on.exit(NULL)
  first_char %in% c('{', '[')
}


#' Column-presence check for a downloaded CSV file. The minimal-build Python
#' script (`v5_build_hts_minimal.py`) consumes columns `HTS Number`,
#' `Description`, `Indent` — if any are missing the downstream build will fail
#' silently, so we fail loudly here instead.
validate_csv_columns <- function(path) {
  required <- c('HTS Number', 'Description', 'Indent')
  header <- tryCatch(
    readLines(path, n = 1, warn = FALSE),
    error = function(e) NULL
  )
  if (is.null(header) || length(header) == 0) return(FALSE)
  # Strip UTF-8 BOM if present + split on comma, accounting for quoted fields.
  header <- sub('^\xef\xbb\xbf', '', header[1])
  # Simple split is OK — CSV headers very rarely contain quoted commas.
  cols <- str_trim(strsplit(header, ',', fixed = TRUE)[[1]])
  all(required %in% cols)
}


# =============================================================================
# Download (format-aware)
# =============================================================================

#' Download a single HTS file with size + structural validation.
#'
#' @param url USITC download URL
#' @param dest_path Destination file path
#' @param format 'json' or 'csv' — selects the structural validator
#' @param min_size_mb Minimum file size in MB to consider valid (default: 1)
#' @return TRUE on success, FALSE on failure
download_hts_file <- function(url, dest_path, format = 'json', min_size_mb = 1) {
  message('  Downloading: ', url)
  message('  Destination: ', dest_path)
  dir.create(dirname(dest_path), recursive = TRUE, showWarnings = FALSE)

  tryCatch({
    download.file(url, dest_path, mode = 'wb', quiet = FALSE)

    file_size_mb <- file.info(dest_path)$size / (1024 * 1024)
    message('  File size: ', round(file_size_mb, 1), ' MB')

    if (file_size_mb < min_size_mb) {
      warning('Downloaded file is suspiciously small (', round(file_size_mb, 2),
              ' MB < ', min_size_mb, ' MB). May be an error page.')
      return(FALSE)
    }

    ok <- tryCatch({
      if (tolower(format) == 'json') validate_json_head(dest_path)
      else validate_csv_columns(dest_path)
    }, error = function(e) {
      warning('Validator threw: ', conditionMessage(e)); FALSE
    })

    if (!isTRUE(ok)) {
      warning('Structural validation failed for ', dest_path)
      return(FALSE)
    }

    message('  Success!')
    return(TRUE)

  }, error = function(e) {
    message('  Download failed: ', conditionMessage(e))
    if (file.exists(dest_path)) file.remove(dest_path)
    return(FALSE)
  })
}


# Back-compat: keep the original name pointing at the new dispatcher so any
# external script that imported `download_hts_json` keeps working.
download_hts_json <- function(url, dest_path, min_size_mb = 1) {
  download_hts_file(url, dest_path, format = 'json', min_size_mb = min_size_mb)
}


# =============================================================================
# Inventory helpers (per format)
# =============================================================================

#' Return the set of revision identifiers (year-prefixed, e.g. `2026_rev_8`)
#' that have a local archive in the given format. Uses the existing
#' `list_available_revisions(year)` helper for the JSON path and a parallel
#' scan of the CSV folder otherwise.
inventory_for_format <- function(years_needed, format) {
  archive_dir <- hts_format_archive_dir(format)
  ext <- if (tolower(format) == 'json') 'json' else 'csv'
  available <- character()
  for (yr in years_needed) {
    pattern <- paste0('hts_', yr, '_.*\\.', ext, '$')
    files <- list.files(archive_dir, pattern = pattern)
    revs <- str_match(files, paste0('hts_', yr, '_(.+)\\.', ext))[, 2]
    revs <- revs[!is.na(revs)]
    if (length(revs) > 0) {
      available <- c(available, paste0(yr, '_', revs))
    }
  }
  available
}


# =============================================================================
# Main driver
# =============================================================================

#' Download missing HTS revisions across one or more formats.
#'
#' For each requested format, computes the set of revisions present in the CSV
#' but not on disk in that format, then downloads them. JSON and CSV are
#' tracked independently — if a revision has JSON but no CSV, only the CSV
#' is downloaded.
#'
#' @param formats Character vector — any subset of c('json', 'csv').
#' @param year Optional year filter
#' @param dry_run If TRUE, list missing without downloading
#' @param revision_dates_path Path to revision_dates.csv
#' @return Tibble with revision, format, status columns
download_missing_revisions <- function(
  formats = c('json', 'csv'),
  year = NULL,
  dry_run = FALSE,
  revision_dates_path = 'config/revision_dates.csv'
) {
  formats <- tolower(formats)
  unknown <- setdiff(formats, c('json', 'csv'))
  if (length(unknown) > 0) {
    stop('Unknown format(s): ', paste(unknown, collapse = ', '))
  }

  rev_dates <- load_revision_dates(revision_dates_path, use_policy_dates = FALSE)
  expected <- rev_dates$revision

  if (!is.null(year)) {
    expected <- expected[map_int(expected, ~ parse_revision_id(.)$year) == year]
    if (length(expected) == 0) {
      message('No revisions for year ', year, ' in revision_dates.csv.')
      return(tibble(revision = character(), format = character(), status = character()))
    }
  }

  years_needed <- unique(map_int(expected, ~ parse_revision_id(.)$year))

  message('\n=== HTS Archive Inventory ===')
  message('Expected revisions: ', length(expected))
  message('Formats:            ', paste(formats, collapse = ', '))

  results <- tibble(revision = character(), format = character(), status = character())

  for (fmt in formats) {
    available <- inventory_for_format(years_needed, fmt)
    missing <- setdiff(expected, available)

    message('\n[', toupper(fmt), '] available: ', length(available),
            '  missing: ', length(missing))
    if (length(missing) > 0) {
      message('   Missing: ', paste(missing, collapse = ', '))
    }

    if (length(missing) == 0) next

    if (dry_run) {
      results <- bind_rows(results, tibble(
        revision = missing, format = fmt, status = 'missing'
      ))
      next
    }

    for (i in seq_along(missing)) {
      rev <- missing[i]
      message('\n[', toupper(fmt), ' ', i, '/', length(missing),
              '] Downloading ', rev, '...')
      url <- build_download_url(rev, format = fmt)
      dest <- build_local_path(rev, format = fmt)
      success <- download_hts_file(url, dest, format = fmt)
      results <- bind_rows(results, tibble(
        revision = rev, format = fmt,
        status = if (success) 'downloaded' else 'failed'
      ))
      if (i < length(missing)) Sys.sleep(2)
    }
  }

  n_ok <- sum(results$status == 'downloaded')
  n_fail <- sum(results$status == 'failed')
  n_planned <- sum(results$status == 'missing')
  message('\n=== Download Summary ===')
  if (dry_run) {
    message('[DRY RUN] Would download: ', n_planned, ' file(s).')
  } else {
    message('Downloaded: ', n_ok, '  Failed: ', n_fail)
  }

  return(results)
}


# =============================================================================
# Main Execution
# =============================================================================

if (sys.nframe() == 0) {
  library(here)
  source(here('src', 'helpers.R'))

  args <- commandArgs(trailingOnly = TRUE)

  year <- NULL
  dry_run <- FALSE
  formats <- c('json', 'csv')

  for (i in seq_along(args)) {
    if (args[i] == '--year' && i < length(args)) {
      year <- as.integer(args[i + 1])
    } else if (args[i] == '--dry-run') {
      dry_run <- TRUE
    } else if (args[i] == '--formats' && i < length(args)) {
      formats <- tolower(strsplit(args[i + 1], ',', fixed = TRUE)[[1]])
      formats <- str_trim(formats)
    }
  }

  results <- download_missing_revisions(
    formats = formats, year = year, dry_run = dry_run
  )
}
