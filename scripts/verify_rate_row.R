# =============================================================================
# Verify any (HTS, country, revision) row in the rate timeseries
# =============================================================================
#
# Generic companion to verify_8471_metal_share.R. Pulls one row from the local
# partitioned parquet and prints the diagnostic fields plus a per-authority
# duty preview. Useful for sanity-checking what the pipeline wrote for any
# (hts10, country_code, revision) triple — for example, when a row in the
# duty calculator shows an unexpected rate and you want to confirm whether
# it came from the parquet or from the frontend display layer.
#
# Usage:
#   Rscript scripts/verify_rate_row.R <hts10> <country_code> [<revision>]
#
# Defaults to revision = '2026_rev_7' if omitted.
#
# Examples:
#   Rscript scripts/verify_rate_row.R 8471500150 5700              # CPU / China
#   Rscript scripts/verify_rate_row.R 8471500150 7771              # CPU / Ethiopia
#   Rscript scripts/verify_rate_row.R 8703230140 1220 2026_rev_7   # Auto / Canada
# =============================================================================

suppressPackageStartupMessages({
  library(tidyverse)
  library(arrow)
  library(here)
})

args <- commandArgs(trailingOnly = TRUE)
if (length(args) < 2) {
  stop('Usage: Rscript scripts/verify_rate_row.R <hts10> <country_code> [<revision>]')
}
target_hts     <- args[1]
target_country <- args[2]
target_rev     <- if (length(args) >= 3) args[3] else '2026_rev_7'

cat('=== Rate row verification ===\n')
cat('Target:  hts10=', target_hts,
    ' country=', target_country,
    ' revision=', target_rev, '\n\n', sep = '')

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
  cat('NO ROW FOUND.\n',
      'This means either the (hts, country) pair has no rates entry — pipeline\n',
      'will synthesize from product_base_rates (MFN-only, no Ch99) — or the\n',
      'inputs are wrong. Check the country Census code in resources/census_codes.csv.\n',
      sep = '')
  quit(status = 0)
}
if (nrow(row) > 1) {
  cat('NOTE: ', nrow(row), ' rows matched (interval-encoded). Showing all.\n\n', sep = '')
}

cat('--- Pipeline-emitted row(s) ---\n')
glimpse(row)

# Pull diagnostic fields if present
diag_cols <- c('hts10', 'country', 'revision',
               'rate_base', 'base_rate', 'statutory_base_rate',
               'rate_232', 'statutory_rate_232',
               'rate_301', 'statutory_rate_301',
               'rate_ieepa_recip', 'statutory_rate_ieepa_recip',
               'rate_ieepa_fent', 'statutory_rate_ieepa_fent',
               'rate_s122', 'rate_section_201',
               'metal_share', 'steel_share', 'aluminum_share',
               'copper_share', 'other_metal_share',
               'derivative_type', 'deriv_type', 's232_anchor',
               's232_annex', 'is_copper_heading',
               'ch99_code_232', 'ch99_code_301',
               'ch99_code_ieepa_recip', 'ch99_code_ieepa_fent',
               'usmca_eligible', 'rate_special',
               'valid_from', 'valid_until')
present <- intersect(diag_cols, names(row))
cat('\n--- Diagnostic fields (', length(present), ' present) ---\n', sep = '')
print(row %>% select(all_of(present)) %>% as.data.frame())

# Per-authority preview at $1000 customs value
cat('\n--- Duty preview at $1,000 customs value ---\n')
val <- 1000
authorities <- list(
  base    = if ('base_rate' %in% names(row)) row$base_rate[1] else 0,
  s232    = if ('rate_232' %in% names(row)) row$rate_232[1] else 0,
  s301    = if ('rate_301' %in% names(row)) row$rate_301[1] else 0,
  ieepa_r = if ('rate_ieepa_recip' %in% names(row)) row$rate_ieepa_recip[1] else 0,
  ieepa_f = if ('rate_ieepa_fent' %in% names(row)) row$rate_ieepa_fent[1] else 0,
  s122    = if ('rate_s122' %in% names(row)) row$rate_s122[1] else 0,
  s201    = if ('rate_section_201' %in% names(row)) row$rate_section_201[1] else 0
)
for (nm in names(authorities)) {
  r <- authorities[[nm]]
  if (!is.null(r) && !is.na(r) && r > 0) {
    cat(sprintf('  %-10s  rate = %7.4f%%   duty on $%d = $%.2f\n',
                nm, r * 100, val, val * r))
  }
}

cat('\n=== End ===\n')
