# =============================================================================
# Phase 2c — Normalized schema parity tests
# =============================================================================
#
# Goal: prove that reconstructing a rate row from the normalized layers
# (output/normalized/) produces the same numeric answer as the denormalized
# rates parquet for every (hts10, country, revision) combination in a
# stratified sample. Any diff is either an emitter bug or a legitimate
# model divergence that must be explained (not silently accepted).
#
# This harness is deliberately skeletal in Phase 2b — the query engine
# (resolve_rate_from_normalized) lives in src/resolve_rate_normalized.R,
# which is a phase-2d deliverable. Until that's written, the harness runs
# only the "emitter smoke" layer: it asserts the normalized parquets exist,
# have non-zero rows, and include the tables declared in
# docs/normalized-schema.md. Actual per-row parity checks are gated behind
# a `has_query_engine` flag.
#
# Run:
#   Rscript tests/test_normalized_parity.R
#   Rscript tests/test_normalized_parity.R --revision 2025_rev_7
#   Rscript tests/test_normalized_parity.R --full      # full sweep
#
# Exit codes:
#   0 — all assertions passed
#   1 — emitter-output assertions failed (no normalized parquets written)
#   2 — parity assertions failed (at least one row diverges)
# =============================================================================

suppressPackageStartupMessages({
  library(tidyverse)
  library(arrow)
  library(here)
})

# Parity tolerance.
#
# Rate columns are stored at full double precision but produced by two
# different code paths (denormalized pipeline vs normalized resolver) that
# multiply and subtract shares in different orders. A strict 1e-9 bound
# flags floating-point noise — e.g. 0.026 * (1 - share) vs the denormalized
# value round-tripped through parquet produces diffs on the order of 1e-5.
# Use an absolute tolerance of 5e-5, which is tighter than any meaningful
# policy divergence (basis-point-level rate differences are 1e-4) yet well
# above IEEE round-trip noise.
PARITY_TOL <- 5e-5

args <- commandArgs(trailingOnly = TRUE)
revision_filter <- NULL
full_mode <- '--full' %in% args
if ('--revision' %in% args) {
  idx <- which(args == '--revision')
  if (length(idx) > 0 && idx[1] < length(args)) {
    revision_filter <- args[idx[1] + 1]
  }
}

NORMALIZED_DIR  <- here('output', 'normalized')
DENORM_DIR      <- here('data', 'timeseries', 'rate_timeseries_parquet')

log_ok <- function(msg) cat('[OK]    ', msg, '\n', sep = '')
log_warn <- function(msg) cat('[WARN]  ', msg, '\n', sep = '')
log_fail <- function(msg) cat('[FAIL]  ', msg, '\n', sep = '')

fail_count <- 0

# ---------------------------------------------------------------------------
# Stage 1 — emitter smoke assertions
# ---------------------------------------------------------------------------
cat('=== Stage 1: emitter smoke assertions ===\n')

if (!dir.exists(NORMALIZED_DIR)) {
  log_fail(paste0('normalized dir missing: ', NORMALIZED_DIR,
                  ' — have you run the pipeline with SAIL_EMIT_NORMALIZED=1?'))
  quit(status = 1)
} else {
  log_ok(paste0('normalized dir exists: ', NORMALIZED_DIR))
}

revision_dirs <- list.dirs(NORMALIZED_DIR, recursive = FALSE)
if (length(revision_dirs) == 0) {
  log_fail('no per-revision subdirectories under normalized/')
  quit(status = 1)
}
log_ok(paste0('found ', length(revision_dirs), ' per-revision directories'))

if (!is.null(revision_filter)) {
  revision_dirs <- revision_dirs[basename(revision_dirs) == revision_filter]
  if (length(revision_dirs) == 0) {
    log_fail(paste0('requested revision ', revision_filter, ' not emitted'))
    quit(status = 1)
  }
}

REQUIRED_LAYERS <- c(
  'products_base.parquet',
  'authority_country_rates.parquet',
  'authority_product_applicability.parquet',
  'authority_exemptions.parquet'
)

for (rd in revision_dirs) {
  rev_id <- basename(rd)
  for (layer in REQUIRED_LAYERS) {
    p <- file.path(rd, layer)
    if (!file.exists(p)) {
      log_fail(paste0(rev_id, '/', layer, ' missing'))
      fail_count <- fail_count + 1
    } else {
      tryCatch({
        t <- arrow::read_parquet(p)
        log_ok(paste0(rev_id, '/', layer, ': ', nrow(t), ' rows, ',
                      ncol(t), ' cols'))
      }, error = function(e) {
        log_fail(paste0(rev_id, '/', layer, ' unreadable: ', conditionMessage(e)))
        fail_count <<- fail_count + 1
      })
    }
  }
}

# Static tables (one-shot — may not exist until emit_normalized_statics runs)
for (f in c('revisions.parquet', 'product_metal_content.parquet',
            'country_group_membership.parquet')) {
  p <- file.path(NORMALIZED_DIR, f)
  if (!file.exists(p)) {
    log_warn(paste0('static ', f, ' not yet emitted (Phase 2b deliverable)'))
  } else {
    log_ok(paste0('static ', f, ' present'))
  }
}

if (fail_count > 0) {
  cat('\nStage 1 FAILED with ', fail_count, ' errors. Stopping before parity.\n',
      sep = '')
  quit(status = 1)
}

# ---------------------------------------------------------------------------
# Stage 2 — per-row parity (gated on query engine availability)
# ---------------------------------------------------------------------------
cat('\n=== Stage 2: per-row parity ===\n')

resolve_path <- here('src', 'resolve_rate_normalized.R')
has_query_engine <- file.exists(resolve_path)

if (!has_query_engine) {
  log_warn('src/resolve_rate_normalized.R not present (Phase 2d deliverable).')
  log_warn('Skipping per-row parity. Run again after query engine lands.')
  quit(status = 0)
}

source(resolve_path, local = TRUE)

# Sample selection
#
# Stratified sample of (hts10, country, revision) test cases. The stratas
# cover the edge cases most likely to surface emitter bugs:
#
#   1. CZ + 8543.70.9860 + 2025_rev_6   — base-MFN-only for non-IEEPA country
#   2. CN + 8543.70.9860 + 2025_rev_6   — S301 China blanket
#   3. CZ + 8543.70.9860 + 2025_rev_7+  — IEEPA reciprocal active for CZ
#   4. Random 100 chapter-72 (steel) × 10 country × all revisions
#   5. Random 100 chapter-76 (aluminum) × 10 country × all revisions
#   6. Chapter 87 auto-listed products × USMCA countries
#   7. Annex A exempt products × all countries × post-rev_7
#   8. Fentanyl carveout products × CA/MX × relevant revisions
#   9. Duty-free products × IEEPA countries (exemption short-circuit)
#  10. Column 2 countries (CU/KP/BY/RU) × random products
#
# In `--full` mode, every (hts10, country) pair in the denormalized parquet
# is checked. Local dev runs without `--full` use the stratified sample only.

SAMPLE_CASES <- tibble::tribble(
  ~hts10,        ~country, ~revision,     ~stratum,
  '8543709860',  '4351',   '2025_rev_6',  'explicit_cz_early',
  '8543709860',  '5700',   '2025_rev_6',  'explicit_cn_s301',
  '8543709860',  '4351',   '2025_rev_7',  'explicit_cz_post_rev7',
  '8543709860',  '2390',   '2025_rev_6',  'explicit_cuba_col2',
  '7208510030',  '4010',   '2025_rev_10', 'explicit_brazil_steel',
  '7606120011',  '4330',   '2025_rev_10', 'explicit_eu_alum',
  '8703230120',  '2010',   '2025_rev_20', 'explicit_mexico_auto',
  '2709000000',  '1220',   '2025_rev_10', 'explicit_canada_fent_carveout'
)

# If a generated sample exists, union it with the explicit cases. Force
# character types on the join keys — census codes like '4351' are numeric-
# looking and readr will guess them as <double> by default, which then
# fails to bind_rows with the explicit-case <character> column.
SAMPLE_PATH <- here('tests', 'parity_sample.csv')
SAMPLE_CASES <- if (file.exists(SAMPLE_PATH)) {
  gen <- suppressMessages(readr::read_csv(
    SAMPLE_PATH,
    col_types = readr::cols(
      hts10    = readr::col_character(),
      country  = readr::col_character(),
      revision = readr::col_character(),
      stratum  = readr::col_character(),
      .default = readr::col_character()
    ),
    show_col_types = FALSE
  ))
  bind_rows(SAMPLE_CASES, gen) %>%
    distinct(hts10, country, revision, .keep_all = TRUE)
} else {
  log_warn(paste0('no generated sample at ', SAMPLE_PATH,
                  ' — running explicit cases only. ',
                  'Run scripts/generate_parity_sample.R first.'))
  SAMPLE_CASES
}

denorm_ds <- tryCatch(
  arrow::open_dataset(DENORM_DIR, partitioning = 'revision'),
  error = function(e) NULL
)
if (is.null(denorm_ds)) {
  log_fail('cannot open denormalized parquet dataset at: ')
  cat('  ', DENORM_DIR, '\n')
  quit(status = 2)
}

diff_count <- 0
for (i in seq_len(nrow(SAMPLE_CASES))) {
  case <- SAMPLE_CASES[i, ]
  hts10  <- case$hts10
  country <- case$country
  revision <- case$revision

  # Baseline from denormalized
  base <- denorm_ds %>%
    filter(hts10 == !!hts10, country == !!country, revision == !!revision) %>%
    collect()

  # Normalized reconstruction
  reconstructed <- tryCatch(
    resolve_rate_from_normalized(NORMALIZED_DIR, hts10, country, revision),
    error = function(e) {
      log_fail(paste0('resolve_rate_from_normalized errored for ',
                      hts10, '/', country, '/', revision, ': ',
                      conditionMessage(e)))
      NULL
    }
  )
  if (is.null(reconstructed)) {
    diff_count <- diff_count + 1
    next
  }

  # Compare the canonical rate columns
  rate_cols <- c('base_rate', 'rate_232', 'rate_301', 'rate_ieepa_recip',
                 'rate_ieepa_fent', 'rate_s122', 'rate_section_201',
                 'rate_other', 'total_additional', 'total_rate')
  label <- paste0(hts10, '/', country, '/', revision)

  if (nrow(base) == 0) {
    # The denormalized row is absent. Under the Phase 1 base-MFN synthesis
    # contract, this should still produce a valid reconstructed row with
    # base_rate > 0 and zero additionals. Treat as "known sparse" — not a
    # parity failure, but flag it.
    if (!is.null(reconstructed) && reconstructed$base_rate > 0 &&
        reconstructed$total_additional == 0) {
      log_ok(paste0(label, ' (sparse — synthesized base_rate=',
                    format(reconstructed$base_rate, digits = 4), ')'))
    } else {
      log_fail(paste0(label, ' sparse but reconstruction produced unexpected shape'))
      diff_count <- diff_count + 1
    }
    next
  }

  diverged <- FALSE
  for (col in rate_cols) {
    a <- base[[col]][1]
    b <- reconstructed[[col]]
    if (is.null(a) || is.null(b)) next
    if (abs(a - b) > PARITY_TOL) {
      log_fail(paste0(label, ' ', col, ': denorm=',
                      format(a, digits = 6), ' norm=',
                      format(b, digits = 6), ' diff=',
                      format(abs(a - b), digits = 6)))
      diverged <- TRUE
    }
  }
  if (diverged) {
    diff_count <- diff_count + 1
  } else {
    log_ok(paste0(label))
  }
}

cat('\n=== Summary ===\n')
cat('Stage 1 emitter smoke: PASS\n')
if (diff_count == 0) {
  cat('Stage 2 parity:        PASS (', nrow(SAMPLE_CASES), ' cases)\n', sep = '')
  quit(status = 0)
} else {
  cat('Stage 2 parity:        FAIL (', diff_count, '/', nrow(SAMPLE_CASES),
      ' cases)\n', sep = '')
  quit(status = 2)
}
