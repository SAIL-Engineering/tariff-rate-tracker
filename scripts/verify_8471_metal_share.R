# =============================================================================
# Verify HTS 8471.50.0150 metal_share + rate_232 in the rate timeseries
# =============================================================================
#
# Companion to docs/analysis/hts_8471_500150_metal_share_investigation_2026-05-08.md
#
# Goal: collapse the four hypotheses (H1 heading/derivative reset,
# H2 BEA join miss, H3 2026 annex scope, H4 frontend-only bug) to one
# by inspecting the actual row the pipeline wrote for
#   hts10 = '8471500150', country = '5700' (China), revision = '2026_rev_7'.
#
# Usage:
#   Rscript scripts/verify_8471_metal_share.R
#
# Reads from:
#   data/timeseries/rate_timeseries_parquet/    (partitioned by revision)
#   resources/s232_derivative_products.csv      (does NOT contain 8471 — confirmed)
#   resources/s232_annex_products.csv           (check if 8471 was added under 2026 annex)
#   resources/metal_content_shares_bea_hs10.csv (BEA share for 8471500150 = 0.0084406)
#
# Decision tree from the captured row's metal_share:
#   metal_share == 1.0  → H1 or H2 (pipeline-side override). Inspect rate_232 + flags.
#   metal_share ≈ 0.008 → H4 (frontend reading wrong field). Pipeline is correct.
#   metal_share ≈ 0.5   → BEA fallback fired (hts not in BEA file or join failed).
#   anything else       → unexpected — capture and re-triage.
# =============================================================================

suppressPackageStartupMessages({
  library(tidyverse)
  library(arrow)
  library(here)
})

target_hts     <- '8471500150'
target_country <- '5700'        # China per resources/census_codes.csv
target_rev     <- '2026_rev_7'

cat('=== HTS 8471.50.0150 metal_share verification ===\n')
cat('Target:  hts10=', target_hts, ' country=', target_country,
    ' revision=', target_rev, '\n\n', sep = '')

# ---- 1. Pipeline output row ----------------------------------------------
parquet_dir <- here('data', 'timeseries', 'rate_timeseries_parquet')
if (!dir.exists(parquet_dir)) {
  stop('Parquet dataset not found at ', parquet_dir,
       '\nRun: Rscript src/00_build_timeseries.R --full --core-only')
}

ds <- open_dataset(parquet_dir, partitioning = 'revision')
row <- ds %>%
  filter(revision == target_rev,
         hts10 == target_hts,
         country == target_country) %>%
  collect()

if (nrow(row) == 0) {
  stop('No row found for ', target_hts, ' / ', target_country,
       ' / ', target_rev, '. Check column names with `names(collect(head(ds, 1)))`.')
}
if (nrow(row) > 1) {
  cat('NOTE: ', nrow(row), ' rows matched (interval-encoded). ',
      'Showing all — pick the period covering 2026-05-05.\n\n', sep = '')
}

cat('--- Pipeline-emitted row(s) ---\n')
glimpse(row)

# Pull the most diagnostic fields if present
diag_cols <- c('hts10', 'country', 'revision',
               'rate_base', 'rate_232', 'rate_301', 'rate_ieepa',
               'rate_122', 'rate_201', 'effective_rate',
               'metal_share', 'steel_share', 'aluminum_share', 'copper_share',
               'other_metal_share', 'nonmetal_share',
               'derivative_type', 's232_anchor', 's232_ch99_code',
               'is_derivative', 'is_heading_232',
               'valid_from', 'valid_until')
present <- intersect(diag_cols, names(row))
cat('\n--- Diagnostic fields (', length(present), ' of ',
    length(diag_cols), ' present) ---\n', sep = '')
print(row %>% select(all_of(present)) %>% as.data.frame())

# ---- 2. Verdict on metal_share -------------------------------------------
ms <- row$metal_share[1]
cat('\n--- metal_share verdict ---\n')
if (is.null(ms) || is.na(ms)) {
  cat('FAIL: metal_share is NA — schema or join bug.\n')
} else if (abs(ms - 1.0) < 1e-6) {
  cat('Pipeline-side override fired. metal_share = 1.0.\n',
      'Likely H1 (heading/derivative-overlap reset at 06_calculate_rates.R:432-446)\n',
      '   or H2 (BEA join miss → coalesce fallback at line 375).\n',
      'Next: check is_heading_232 / derivative_type fields above and grep\n',
      '       for 8471 in resources/s232_annex_products.csv.\n', sep = '')
} else if (abs(ms - 0.0084406) < 1e-4) {
  cat('Pipeline is correct. metal_share = 0.0084 matches BEA.\n',
      'This is H4 — the frontend badge condition (metal_share >= 1)\n',
      'must be reading a different field than expected, OR the API is\n',
      'replacing this value before serving.\n',
      'Next: hit /api/rates?hts10=', target_hts, '&country=', target_country,
      ' and inspect the JSON response.\n', sep = '')
} else if (abs(ms - 0.5) < 1e-3) {
  cat('BEA fallback fired. metal_share = 0.5 (default per build log).\n',
      'Means 8471500150 was treated as a derivative but the BEA join missed.\n',
      'Inspect resources/metal_content_shares_bea_hs10.csv — confirm 8471500150\n',
      'is present with the expected key format.\n', sep = '')
} else {
  cat('UNEXPECTED metal_share = ', ms, '. Capture full row and re-triage.\n', sep = '')
}

# ---- 3. Annex scope check ------------------------------------------------
annex_path <- here('resources', 's232_annex_products.csv')
if (file.exists(annex_path)) {
  annex <- read_csv(annex_path, show_col_types = FALSE)
  cat('\n--- s232_annex_products.csv check ---\n')
  cat('Total rows: ', nrow(annex), '\n', sep = '')
  hts_col <- intersect(c('hts_prefix', 'hts10', 'hts'), names(annex))[1]
  if (!is.na(hts_col)) {
    matches <- annex[grepl('^8471', as.character(annex[[hts_col]])), ]
    cat('Rows matching prefix 8471: ', nrow(matches), '\n', sep = '')
    if (nrow(matches) > 0) {
      cat('H3 confirmed — annex scope brings 8471 into S232.\n')
      print(matches)
    } else {
      cat('H3 ruled out — annex does not list 8471.\n')
    }
  }
} else {
  cat('\nNote: ', annex_path, ' does not exist — H3 not verifiable here.\n', sep = '')
}

# ---- 4. BEA share sanity check ------------------------------------------
bea_path <- here('resources', 'metal_content_shares_bea_hs10.csv')
bea <- read_csv(bea_path, show_col_types = FALSE,
                col_types = cols(hs10 = col_character()))
bea_row <- bea %>% filter(hs10 == target_hts)
cat('\n--- BEA share for ', target_hts, ' ---\n', sep = '')
if (nrow(bea_row) == 0) {
  cat('NOT in BEA file. metal_share fallback would kick in.\n')
} else {
  print(bea_row %>% as.data.frame())
}

cat('\n=== End ===\n')
