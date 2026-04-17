# =============================================================================
# Phase 2c — Stratified parity sample generator
# =============================================================================
#
# Reads the denormalized rates parquet and writes a deterministic stratified
# sample of (hts10, country, revision) triples to tests/parity_sample.csv.
# Strata (targeting edge cases most likely to surface emitter bugs):
#
#   S1. Non-IEEPA countries pre-rev_7 (was zero-rows, now base-MFN-only)
#   S2. China + Section 301 products (blanket path)
#   S3. Steel chapter 72/73 × all countries (232 base blanket)
#   S4. Aluminum chapter 76 × all countries (232 base blanket)
#   S5. 232 derivative products × CA/MX/EU (metal scaling stress)
#   S6. Annex A exempt products × IEEPA countries (exemption short-circuit)
#   S7. Fentanyl carveout products × CA/MX (precedence override)
#   S8. Column 2 countries (CU/KP/BY/RU) × random products
#   S9. Auto heading × USMCA countries (CA/MX/EU with deal rates)
#  S10. Random uniform sample across all (product, country, revision)
#
# Output CSV columns: hts10, country, revision, stratum
#
# Run:
#   Rscript scripts/generate_parity_sample.R
#   Rscript scripts/generate_parity_sample.R --per-stratum 500
#   Rscript scripts/generate_parity_sample.R --seed 42
#
# The sample is deterministic given the same (seed, parquet, per-stratum).
# Commit `tests/parity_sample.csv` so CI runs reproduce local results.
# =============================================================================

suppressPackageStartupMessages({
  library(tidyverse)
  library(arrow)
  library(here)
})

args <- commandArgs(trailingOnly = TRUE)
arg_val <- function(flag, default) {
  idx <- which(args == flag)
  if (length(idx) > 0 && idx[1] < length(args)) args[idx[1] + 1] else default
}
PER_STRATUM <- as.integer(arg_val('--per-stratum', '200'))
SEED <- as.integer(arg_val('--seed', '20260414'))
set.seed(SEED)

DENORM_DIR <- here('data', 'timeseries', 'rate_timeseries_parquet')
SAMPLE_OUT <- here('tests', 'parity_sample.csv')

if (!dir.exists(DENORM_DIR)) {
  stop('Denormalized parquet not found at: ', DENORM_DIR,
       '\nRun the pipeline first (Rscript src/00_build_timeseries.R).')
}

message('Opening denormalized dataset: ', DENORM_DIR)
ds <- arrow::open_dataset(DENORM_DIR, partitioning = 'revision')

# Revisions sorted chronologically (best-effort; string sort is stable for
# the `2025_rev_*` naming convention)
revisions <- ds %>% distinct(revision) %>% collect() %>% pull(revision) %>% sort()
message('Found ', length(revisions), ' revisions')

# Column 2 countries (mirrors frontend/src/types/tariff.ts COLUMN2_COUNTRY_CODES)
COLUMN2 <- c('2390', '4622', '4621', '5790')

# USMCA and EU representative countries — used to target strata that exercise
# the USMCA exemption path and the EU floor country override.
USMCA <- c('1220', '2010')       # Canada, Mexico
EU_SAMPLE <- c('4330', '4280', '4351', '4759')   # Germany, France, Czech Rep, Italy (approx)
ASIA_KEY <- c('5700', '5820', '5800')            # China, Japan, Korea

sample_from <- function(df, n, stratum_label) {
  if (is.null(df) || nrow(df) == 0) {
    return(tibble(hts10 = character(), country = character(),
                  revision = character(), stratum = character()))
  }
  df %>%
    slice_sample(n = min(n, nrow(df))) %>%
    transmute(
      hts10 = as.character(hts10),
      country = as.character(country),
      revision = as.character(revision),
      stratum = stratum_label
    )
}

stratified <- list()

# --- S1. Non-IEEPA countries pre-rev_7 ---
# "Missing" rows were Phase 1's motivating case. Targets 2025_rev_1..rev_6.
message('S1: non-IEEPA countries pre-rev_7')
pre_rev7 <- revisions[revisions < '2025_rev_7']
if (length(pre_rev7) > 0) {
  cands <- ds %>%
    filter(revision %in% pre_rev7, !country %in% c('5700', '1220', '2010')) %>%
    select(hts10, country, revision) %>%
    collect()
  stratified[['S1']] <- sample_from(cands, PER_STRATUM, 'S1_non_ieepa_pre_rev7')
}

# --- S2. China + S301 products (rate_301 > 0) ---
message('S2: China + Section 301')
cands <- ds %>%
  filter(country == '5700', rate_301 > 0) %>%
  select(hts10, country, revision) %>%
  collect()
stratified[['S2']] <- sample_from(cands, PER_STRATUM, 'S2_china_s301')

# --- S3. Steel chapter 72/73 ---
message('S3: steel chapter 72/73')
cands <- ds %>%
  filter(substr(hts10, 1, 2) %in% c('72', '73'), rate_232 > 0) %>%
  select(hts10, country, revision) %>%
  collect()
stratified[['S3']] <- sample_from(cands, PER_STRATUM, 'S3_steel_chapter')

# --- S4. Aluminum chapter 76 ---
message('S4: aluminum chapter 76')
cands <- ds %>%
  filter(substr(hts10, 1, 2) == '76', rate_232 > 0) %>%
  select(hts10, country, revision) %>%
  collect()
stratified[['S4']] <- sample_from(cands, PER_STRATUM, 'S4_alum_chapter')

# --- S5. 232 derivative products (non-72/73/76 with rate_232 > 0) ---
message('S5: 232 derivatives (metal-scaled)')
cands <- ds %>%
  filter(
    rate_232 > 0,
    !substr(hts10, 1, 2) %in% c('72', '73', '76'),
    country %in% c(USMCA, EU_SAMPLE)
  ) %>%
  select(hts10, country, revision) %>%
  collect()
stratified[['S5']] <- sample_from(cands, PER_STRATUM, 'S5_s232_deriv_usmca_eu')

# --- S6. Annex A-adjacent: products with base_rate > 0 but rate_ieepa_recip = 0
# when other EU products for the same revision have it. Captures exemption
# short-circuit behavior. Using a proxy since we don't have the Annex A list
# in parquet: IEEPA = 0 AND base_rate > 0 AND country is a floor country.
message('S6: IEEPA exemption proxy (floor countries)')
cands <- ds %>%
  filter(
    country %in% EU_SAMPLE,
    rate_ieepa_recip == 0,
    base_rate > 0,
    revision >= '2025_rev_7'
  ) %>%
  select(hts10, country, revision) %>%
  collect()
stratified[['S6']] <- sample_from(cands, PER_STRATUM, 'S6_floor_exemption')

# --- S7. Fentanyl carveouts ---
# Proxy: CA/MX rows with rate_ieepa_fent > 0 but < typical general rate (0.25).
# Energy/potash carveouts pay 0.10.
message('S7: fentanyl carveouts')
cands <- ds %>%
  filter(
    country %in% USMCA,
    rate_ieepa_fent > 0,
    rate_ieepa_fent < 0.20
  ) %>%
  select(hts10, country, revision) %>%
  collect()
stratified[['S7']] <- sample_from(cands, PER_STRATUM, 'S7_fent_carveout')

# --- S8. Column 2 countries ---
message('S8: Column 2 countries (CU/KP/BY/RU)')
cands <- ds %>%
  filter(country %in% COLUMN2) %>%
  select(hts10, country, revision) %>%
  collect()
stratified[['S8']] <- sample_from(cands, PER_STRATUM, 'S8_column2')

# --- S9. Auto heading (8703/8704/8706/8708) × USMCA ---
message('S9: auto heading × USMCA')
cands <- ds %>%
  filter(
    substr(hts10, 1, 4) %in% c('8703', '8704', '8706', '8708'),
    country %in% c(USMCA, EU_SAMPLE),
    rate_232 > 0
  ) %>%
  select(hts10, country, revision) %>%
  collect()
stratified[['S9']] <- sample_from(cands, PER_STRATUM, 'S9_auto_usmca')

# --- S10. Random uniform sample ---
message('S10: random uniform sample')
cands <- ds %>%
  select(hts10, country, revision) %>%
  collect() %>%
  slice_sample(n = min(PER_STRATUM * 2, 5000))
stratified[['S10']] <- sample_from(cands, PER_STRATUM, 'S10_uniform')

# ---- Combine and dedupe ----
sample <- bind_rows(stratified) %>%
  distinct(hts10, country, revision, .keep_all = TRUE) %>%
  arrange(stratum, revision, country, hts10)

.ensure_dir <- function(p) {
  if (!dir.exists(p)) dir.create(p, recursive = TRUE, showWarnings = FALSE)
}
.ensure_dir(dirname(SAMPLE_OUT))
readr::write_csv(sample, SAMPLE_OUT)

cat('\n=== Parity sample generated ===\n')
cat('  rows:       ', nrow(sample), '\n')
cat('  strata:     ', length(unique(sample$stratum)), '\n')
cat('  per-stratum:', PER_STRATUM, '\n')
cat('  seed:       ', SEED, '\n')
cat('  written to: ', SAMPLE_OUT, '\n')
cat('\nBreakdown by stratum:\n')
print(sample %>% count(stratum))
