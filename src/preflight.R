# =============================================================================
# Environment Checker — Preflight Validation
# =============================================================================
#
# Verifies that all required and optional dependencies are available before
# running the pipeline. Reports status of R packages, config files, data
# directories, resource files, and optional external files.
#
# Usage:
#   Rscript src/preflight.R
#
# Exit codes:
#   0 = all required items present
#   1 = one or more required items missing
#
# =============================================================================

# --- R packages ---
REQUIRED_PACKAGES <- c('tidyverse', 'jsonlite', 'yaml', 'here')
OPTIONAL_PACKAGES <- c(
  'pdftools',   # scrape_us_notes.R (Chapter 99 PDF parsing)
  'digest',     # 01_scrape_revision_dates.R (Chapter 99 PDF change detection)
  'arrow',      # 09_daily_series.R (Parquet export)
  'openxlsx',   # 09_daily_series.R (Excel workbook export)
  'httr'        # optional HTTP utilities
)

# --- Required config files ---
REQUIRED_CONFIGS <- c(
  'config/policy_params.yaml',
  'config/revision_dates.csv'
)

# --- Optional config files ---
OPTIONAL_CONFIGS <- c(
  'config/local_paths.yaml',
  'config/scenarios.yaml'
)

# --- Required resource files ---
REQUIRED_RESOURCES <- c(
  'resources/census_codes.csv',
  'resources/country_partner_mapping.csv',
  'resources/ieepa_exempt_products.csv',
  'resources/floor_exempt_products.csv',
  'resources/s301_product_lists.csv',
  'resources/s232_derivative_products.csv',
  'resources/s232_auto_parts.txt',
  'resources/s232_mhd_parts.txt',
  'resources/s232_copper_products.csv',
  'resources/fentanyl_carveout_products.csv',
  'resources/hs10_gtap_crosswalk.csv'
)

# --- Optional resource files ---
OPTIONAL_RESOURCES <- c(
  'resources/usmca_product_shares.csv',
  'resources/usmca_shares.csv',
  'resources/mfn_exemption_shares.csv',
  'resources/metal_content_shares_bea_hs10.csv',
  'resources/s122_exempt_products.csv'
)

# --- Required directories ---
REQUIRED_DIRS <- c(
  'data/hts_archives',
  'src',
  'config',
  'resources'
)

# --- Optional data files (resolved from local_paths.yaml) ---
# These are checked dynamically below


# =============================================================================
# Check Functions
# =============================================================================

check_packages <- function(packages, required = TRUE) {
  label <- if (required) 'REQUIRED' else 'OPTIONAL'
  results <- vapply(packages, function(pkg) {
    installed <- requireNamespace(pkg, quietly = TRUE)
    status <- if (installed) 'present' else 'MISSING'
    list(pkg = pkg, status = status, label = label)
    installed
  }, logical(1))

  for (pkg in packages) {
    status <- if (results[pkg]) 'present' else 'MISSING'
    cat(sprintf('  [%s] %-12s  %s\n',
                if (results[pkg]) 'OK' else if (required) '!!' else '--',
                pkg, paste(label, status)))
  }
  return(results)
}

check_files <- function(files, base_dir, required = TRUE) {
  label <- if (required) 'REQUIRED' else 'OPTIONAL'
  results <- vapply(files, function(f) {
    path <- file.path(base_dir, f)
    file.exists(path)
  }, logical(1))

  for (f in files) {
    status <- if (results[f]) 'present' else 'MISSING'
    cat(sprintf('  [%s] %-50s  %s\n',
                if (results[f]) 'OK' else if (required) '!!' else '--',
                f, paste(label, status)))
  }
  return(results)
}

check_dirs <- function(dirs, base_dir) {
  results <- vapply(dirs, function(d) {
    dir.exists(file.path(base_dir, d))
  }, logical(1))

  for (d in dirs) {
    status <- if (results[d]) 'present' else 'MISSING'
    cat(sprintf('  [%s] %-50s  %s\n',
                if (results[d]) 'OK' else '!!', d, status))
  }
  return(results)
}


# =============================================================================
# Main
# =============================================================================

if (sys.nframe() == 0) {
  # Resolve project root
  if (requireNamespace('here', quietly = TRUE)) {
    base_dir <- here::here()
  } else {
    base_dir <- getwd()
    message('Note: `here` package not installed; using working directory as project root')
  }

  cat(strrep('=', 70), '\n')
  cat('Tariff Rate Tracker — Environment Check\n')
  cat(strrep('=', 70), '\n')
  cat('Project root:', base_dir, '\n')
  cat('R version:', R.version.string, '\n')
  cat('Date:', format(Sys.time(), '%Y-%m-%d %H:%M'), '\n')
  cat(strrep('-', 70), '\n\n')

  any_required_missing <- FALSE

  # --- 1. R Packages ---
  cat('R PACKAGES\n')
  req_pkg <- check_packages(REQUIRED_PACKAGES, required = TRUE)
  opt_pkg <- check_packages(OPTIONAL_PACKAGES, required = FALSE)
  if (any(!req_pkg)) any_required_missing <- TRUE
  cat('\n')

  # --- 2. Directories ---
  cat('DIRECTORIES\n')
  dir_ok <- check_dirs(REQUIRED_DIRS, base_dir)
  if (any(!dir_ok)) any_required_missing <- TRUE
  cat('\n')

  # --- 3. Config Files ---
  cat('CONFIG FILES\n')
  req_cfg <- check_files(REQUIRED_CONFIGS, base_dir, required = TRUE)
  opt_cfg <- check_files(OPTIONAL_CONFIGS, base_dir, required = FALSE)
  if (any(!req_cfg)) any_required_missing <- TRUE
  cat('\n')

  # --- 4. Resource Files ---
  cat('RESOURCE FILES\n')
  req_res <- check_files(REQUIRED_RESOURCES, base_dir, required = TRUE)
  opt_res <- check_files(OPTIONAL_RESOURCES, base_dir, required = FALSE)
  if (any(!req_res)) any_required_missing <- TRUE
  cat('\n')

  # --- 5. HTS JSON Archives ---
  cat('HTS JSON ARCHIVES\n')
  json_dir <- file.path(base_dir, 'data', 'hts_archives')
  if (dir.exists(json_dir)) {
    json_files <- list.files(json_dir, pattern = '\\.json$')
    cat(sprintf('  [%s] %d JSON files in data/hts_archives/\n',
                if (length(json_files) > 0) 'OK' else '!!',
                length(json_files)))
    if (length(json_files) == 0) {
      cat('  >> Run: Rscript src/02_download_hts.R\n')
      any_required_missing <- TRUE
    }
  } else {
    cat('  [!!] data/hts_archives/ directory missing\n')
    any_required_missing <- TRUE
  }
  cat('\n')

  # --- 6. Optional External Files (from local_paths.yaml) ---
  cat('OPTIONAL EXTERNAL FILES (from config/local_paths.yaml)\n')
  local_paths_file <- file.path(base_dir, 'config', 'local_paths.yaml')
  if (file.exists(local_paths_file)) {
    lp <- yaml::read_yaml(local_paths_file)

    # Import weights
    iw <- lp$import_weights
    if (is.null(iw)) {
      cat('  [--] import_weights: not configured (weighted outputs will be skipped)\n')
    } else {
      iw_path <- if (startsWith(iw, '/') || grepl('^[A-Za-z]:', iw)) iw else file.path(base_dir, iw)
      exists <- file.exists(iw_path)
      cat(sprintf('  [%s] import_weights: %s\n', if (exists) 'OK' else '--', iw))
    }

    # TPC benchmark
    tpc <- lp$tpc_benchmark
    if (is.null(tpc)) {
      cat('  [--] tpc_benchmark: not configured (TPC validation skipped)\n')
    } else {
      tpc_path <- if (startsWith(tpc, '/') || grepl('^[A-Za-z]:', tpc)) tpc else file.path(base_dir, tpc)
      exists <- file.exists(tpc_path)
      cat(sprintf('  [%s] tpc_benchmark: %s\n', if (exists) 'OK' else '--', tpc))
    }

    # Tariff-ETRs repo
    etrs <- lp$tariff_etrs_repo
    if (is.null(etrs)) {
      cat('  [--] tariff_etrs_repo: not configured (comparison skipped)\n')
    } else {
      exists <- dir.exists(etrs)
      cat(sprintf('  [%s] tariff_etrs_repo: %s\n', if (exists) 'OK' else '--', etrs))
    }
  } else {
    cat('  [--] config/local_paths.yaml not found — using defaults\n')
    cat('       Copy config/local_paths.yaml.example to config/local_paths.yaml\n')
    cat('       and set import_weights path for weighted ETR outputs.\n')
  }
  cat('\n')

  # --- 6b. Citation Integrity ---
  # Every rule the engine derives must trace to a primary source the frontend can
  # link to. A dangling or unlinkable citation is a build-blocking error; softer
  # findings (unverified, stale-pending, index-only links) are reported but do
  # not stop a build.
  cat('CITATION INTEGRITY\n')
  cit_script <- file.path(base_dir, 'src', 'validate_citations.R')
  if (!file.exists(cit_script)) {
    cat('  [--] src/validate_citations.R not found — citation checks skipped\n')
  } else {
    cit_out <- suppressWarnings(system2('Rscript', c(shQuote(cit_script)),
                                        stdout = TRUE, stderr = TRUE))
    cit_status <- attr(cit_out, 'status')
    if (is.null(cit_status)) cit_status <- 0L

    tally <- grep('^ERRORS:', cit_out, value = TRUE)
    n_err <- if (length(tally)) {
      as.integer(sub('.*ERRORS:\\s*(\\d+).*', '\\1', tally[1]))
    } else NA_integer_
    n_warn <- if (length(tally)) {
      as.integer(sub('.*WARNINGS:\\s*(\\d+).*', '\\1', tally[1]))
    } else NA_integer_

    if (cit_status != 0 && is.na(n_err)) {
      # The validator itself failed (e.g. duplicate YAML key) — surface it.
      cat('  [!!] citation validator failed to run:\n')
      for (l in utils::tail(cit_out, 6)) cat('       ', l, '\n', sep = '')
      any_required_missing <- TRUE
    } else {
      cat(sprintf('  [%s] %d citation error(s), %d warning(s)\n',
                  if (isTRUE(n_err > 0)) '!!' else 'OK',
                  if (is.na(n_err)) 0L else n_err,
                  if (is.na(n_warn)) 0L else n_warn))
      if (isTRUE(n_err > 0)) {
        for (l in grep('\\[C[12]_', cit_out, value = TRUE)) cat('       ', l, '\n', sep = '')
        cat('  >> Run: Rscript src/validate_citations.R\n')
        any_required_missing <- TRUE
      } else if (isTRUE(n_warn > 0)) {
        for (l in grep('\\[C[3567]_', cit_out, value = TRUE)) cat('       ', l, '\n', sep = '')
      }
    }
  }
  cat('\n')

  # --- 6c. AD/CVD currency ---
  # Administrative reviews reset cash-deposit rates roughly annually per case,
  # so this layer goes stale on its own. Silent staleness is the failure mode
  # that matters: an old rate looks exactly like a current one.
  cat('AD/CVD LAYER\n')
  adcvd_rates <- file.path(base_dir, 'resources', 'adcvd_rates.csv')
  adcvd_orders <- file.path(base_dir, 'resources', 'adcvd_orders.csv')
  wm_file <- file.path(base_dir, 'resources', '.adcvd_watermark')
  if (!file.exists(adcvd_rates) || !file.exists(adcvd_orders)) {
    cat('  [--] adcvd resources absent — AD/CVD layer inactive\n')
  } else {
    n_orders <- max(0L, length(readLines(adcvd_orders, warn = FALSE)) - 1L)
    n_rates  <- max(0L, length(readLines(adcvd_rates,  warn = FALSE)) - 1L)
    cat(sprintf('  [OK] %d order(s), %d rate row(s)\n', n_orders, n_rates))

    stale_days <- if (file.exists(wm_file)) {
      as.integer(Sys.Date() - as.Date(trimws(readLines(wm_file, warn = FALSE)[1])))
    } else NA_integer_
    if (is.na(stale_days)) {
      cat('  [!!] no refresh watermark — run: Rscript scripts/refresh_adcvd.R\n')
    } else if (stale_days > 45) {
      cat(sprintf('  [!!] rates last refreshed %d days ago (>45) — cash-deposit rates likely superseded\n',
                  stale_days))
      cat('  >> Run: Rscript scripts/refresh_adcvd.R\n')
    } else {
      cat(sprintf('  [OK] refreshed %d day(s) ago\n', stale_days))
    }

    # The order universe cannot currently be seeded from a public endpoint, so
    # it is curated and incomplete by construction. Say so on every run rather
    # than let a small seed read as full coverage.
    if (n_orders < 50) {
      cat(sprintf('  [--] order seed is INCOMPLETE (%d orders; hundreds are active).\n', n_orders))
      cat('       Coverage gaps are reported by scripts/refresh_adcvd.R, not silently dropped.\n')
    }
  }
  cat('\n')

  # --- 7. Run Mode Assessment ---
  cat(strrep('=', 70), '\n')
  cat('RUN MODE ASSESSMENT\n')
  cat(strrep('-', 70), '\n')

  has_json <- dir.exists(json_dir) && length(list.files(json_dir, '\\.json$')) > 0
  has_weights <- !is.null(tryCatch({
    lp <- yaml::read_yaml(local_paths_file)
    iw <- lp$import_weights
    if (!is.null(iw)) {
      iw_full <- if (startsWith(iw, '/') || grepl('^[A-Za-z]:', iw)) iw else file.path(base_dir, iw)
      if (file.exists(iw_full)) iw_full else NULL
    } else NULL
  }, error = function(e) NULL))
  has_tpc <- file.exists(file.path(base_dir, 'data', 'tpc', 'tariff_by_flow_day.csv'))

  modes <- c(
    'core'               = !any_required_missing && has_json,
    'core_plus_weights'  = !any_required_missing && has_json && has_weights,
    'compare_tpc'        = !any_required_missing && has_json && has_tpc,
    'compare_etrs'       = !any_required_missing && has_json && tryCatch({
      lp2 <- yaml::read_yaml(local_paths_file)
      !is.null(lp2$tariff_etrs_repo) && dir.exists(lp2$tariff_etrs_repo)
    }, error = function(e) FALSE)
  )

  for (mode in names(modes)) {
    cat(sprintf('  %-25s %s\n', mode,
                if (modes[mode]) 'READY' else 'not available'))
  }

  cat('\n')
  if (any_required_missing) {
    cat('STATUS: REQUIRED ITEMS MISSING — see [!!] items above\n')
    quit(status = 1)
  } else {
    cat('STATUS: All required items present. Ready to build.\n')
    cat('\nQuick start:\n')
    cat('  Rscript src/02_download_hts.R          # Download HTS JSON if needed\n')
    cat('  Rscript src/00_build_timeseries.R --full  # Full build\n')
    cat('  Rscript src/00_build_timeseries.R --core-only  # Build without weighted outputs\n')
    quit(status = 0)
  }
}
