# Build Guide

This guide covers first-run setup, required and optional inputs, build modes, and expected outputs.

## System requirements

- **R 4.3+** with packages listed in `src/install_dependencies.R`
- **RAM**: The full pipeline (`--full`) expands a product × country matrix of roughly 19,000 products × 240 countries during rate calculation. **32 GB RAM is recommended.** Machines with 16 GB may run out of memory during the IEEPA broadcasting step in `06_calculate_rates.R`. If you are memory-constrained, you can build individual revisions rather than running `--full`, since each revision is processed independently.
- **Disk**: The `data/` directory (HTS JSON archives + processed snapshots) requires approximately 2 GB.
- **OS**: Tested on Windows 10/11, macOS, and Linux. No platform-specific dependencies.

## Build modes

The repo is designed to run in progressively richer modes depending on what local data you have.

| Mode | Requires | Produces |
|---|---|---|
| `core` | repo resources, config files, HTS JSON archives, required R packages | tariff timeseries, unweighted daily outputs, quality report |
| `core_plus_weights` | core + import weights in `config/local_paths.yaml` | core outputs + weighted daily fields + weighted ETR outputs |
| `compare_tpc` | core + TPC benchmark CSV | comparison outputs against TPC |
| `compare_etrs` | core + Tariff-ETRs repo path | standalone script (`src/compare_etrs.R`); wrapper in `run_comparisons.R` not yet complete |
| `generate_etrs_config` | core (built timeseries) | ETRs-compatible config: `statutory_rates.csv.gz` + `other_params.yaml` per revision date |

The core series is the production dataset. Comparison inputs are optional.

## Environment variable gates

Several build stages run by default but can be toggled with environment variables, all read in `src/00_build_timeseries.R`:

| Variable | Default | Effect |
|---|---|---|
| `SAIL_VALIDATE_RATES` | report-only | `strict` aborts the build on a rate-validation **correctness** violation (C1 `base_rate ≤ statutory_base_rate`; C2 finite/≥0). Coverage flags (Q3–Q6) stay report-only either way. See [data-pipeline-README.md §8](data-pipeline-README.md#8-quality-report). |
| `SAIL_EMIT_GN3` | `1` (on) | Set `0` to skip General Note 3 parsing (program symbols, Column 2 list, GSP/AGOA/CBERA beneficiaries). Incremental + carry-forward; network/PDF op. |
| `SAIL_EMIT_LEGAL_REFS` | `1` (on) | Set `0` to skip legal-authority extraction (`resources/ch99_legal_refs.csv` from Chapter 99 PDFs). Incremental. |
| `SAIL_EMIT_NORMALIZED` | `1` (on) | Set `0` to disable the Phase 2 normalized dual-write to `output/normalized/`. |
| `SAIL_RESUME_WINDOW_HOURS` | `12` | mtime window for incremental "fresh run" detection / resume clustering. |

The GN3 and legal-ref emitters are network/PDF operations wrapped so they can never abort a build. `SAIL_VALIDATE_RATES=strict` is the only gate that can stop a build, and only on a correctness violation.

## First-run checklist

### 1. Verify the environment

```bash
Rscript src/preflight.R
```

This checks packages, config files, committed resources, HTS JSON availability, and optional local benchmark paths.

### 2. Install packages

```bash
Rscript src/install_dependencies.R
Rscript src/install_dependencies.R --all
```

Required packages:

- `tidyverse`
- `jsonlite`
- `yaml`
- `here`

Optional packages:

- `pdftools`
- `digest`
- `arrow`
- `httr`

### 3. Download HTS JSON archives

```bash
Rscript src/02_download_hts.R --dry-run
Rscript src/02_download_hts.R
```

### 4. Configure optional local paths

If you want weighted outputs or benchmark comparisons:

```bash
copy config\\local_paths.yaml.example config\\local_paths.yaml
```

Set whichever paths you have:

- `import_weights`
- `tpc_benchmark`
- `tariff_etrs_repo`

The core build does not require this file.

### 5. Run the build

```bash
Rscript src/00_build_timeseries.R --full --core-only
```

Useful variants:

```bash
Rscript src/00_build_timeseries.R
Rscript src/00_build_timeseries.R --full
Rscript src/00_build_timeseries.R --build-only
Rscript src/00_build_timeseries.R --with-alternatives
Rscript src/00_build_timeseries.R --full --use-hts-dates
Rscript src/00_build_timeseries.R --full --refresh-usmca
```

The `--refresh-usmca` flag re-downloads USMCA utilization shares from the USITC DataWeb API before building. This updates the monthly and annual share CSVs in `resources/` with the latest available data. Requires a DataWeb API token in `.env` (see `src/download_usmca_dataweb.R` for setup). The flag is optional — without it, the build uses the committed share files.

By default, the pipeline uses **legal policy effective dates** where they differ from HTS revision dates (e.g., SCOTUS ruling effective Feb 20 vs. HTS revision Feb 24). Pass `--use-hts-dates` to use raw HTS revision dates instead. See [docs/policy_timing.md](policy_timing.md) for the full list of affected revisions and legal sources.

## Input inventory

### Required for the core build

| Input | Path | Status | Role | Regeneration |
|---|---|---|---|---|
| HTS JSON archives | `data/hts_archives/*.json` | auto-download | official tariff schedule by revision | `src/02_download_hts.R` |
| Policy config | `config/policy_params.yaml` | committed | tariff logic, dates, and assumptions | manual update when policy changes |
| Revision schedule | `config/revision_dates.csv` | committed | HTS effective dates and benchmark alignment | `src/01_scrape_revision_dates.R` discovers new revisions via USITC API; placeholder dates require manual review |
| Census country codes | `resources/census_codes.csv` | committed | country dimension | manual refresh |
| Country-partner mapping | `resources/country_partner_mapping.csv` | committed | partner aggregates for reporting | manual refresh |
| Section 301 product list | `resources/s301_product_lists.csv` | committed | blanket 301 coverage | `src/scrape_us_notes.R` (validates anchor coverage; refuses partial writes) |
| IEEPA exempt products | `resources/ieepa_exempt_products.csv` | committed | reciprocal exemptions | regenerate when exemption logic changes |
| Section 232 derivative products | `resources/s232_derivative_products.csv` | committed | derivative 232 coverage (aluminum + steel, 568 HTS8 prefixes) | manual / FR 2025-15819; future: `scrape_us_notes.R --232-derivatives` |
| Copper 232 product list | `resources/s232_copper_products.csv` | committed | copper 232 coverage (80 HTS8 prefixes) | `src/scrape_us_notes.R --copper` (validates >= 60 codes; refuses reduced overwrites) |
| Auto and MHD product lists | `resources/s232_auto_parts.txt`, `resources/s232_mhd_parts.txt` | committed | 232 auto and MHD coverage | manual refresh from official notes |
| Fentanyl carve-outs | `resources/fentanyl_carveout_products.csv` | committed | reduced fentanyl rates for carve-out products | manual / documented refresh |
| USMCA product shares | `resources/usmca_product_shares_2024.csv`, `resources/usmca_product_shares_2025.csv` | committed | product-level USMCA utilization | `src/download_usmca_dataweb.R` |
| MFN exemption shares | `resources/mfn_exemption_shares.csv` | committed | effective MFN base-rate adjustment | regenerate from source trade data if methodology changes |
| Metal content shares | `resources/metal_content_shares_bea_hs10.csv` | committed | derivative 232 metal-share estimation | regenerate from BEA workflow if needed |
| Floor exemptions | `resources/floor_exempt_products.csv` plus revision-specific `data/us_notes/floor_exempt_{revision}.csv` | committed plus auto-scrape | floor-country exemptions | `src/scrape_us_notes.R --floor-exemptions` (validates anchor coverage; refuses partial overwrites) |
| Section 122 exemptions | `resources/s122_exempt_products.csv` | committed | Annex II exemptions | manual refresh when authority changes |

### Program and legal-reference data (de-hardcoded)

These drive the frontend's program / Column 2 / preference and citation surfaces. The `generated` rows are extracted per revision during the build; the `committed` rows are reviewed reference data. See [PROVENANCE_PIPELINE.md](PROVENANCE_PIPELINE.md).

| Input | Path | Status | Role | Regeneration |
|---|---|---|---|---|
| GN3 symbol map | `resources/gn3_program_symbols.csv` | generated | Special-program symbol → program name | `src/parse_general_note_3.R` (build, `SAIL_EMIT_GN3`) |
| GN3 Column 2 list | `resources/gn3_column2_countries.csv` | generated | Column 2 (non-NTR) country list | `src/parse_general_note_3.R` |
| GN beneficiary lists | `resources/gn_program_countries.csv` | generated | GSP/AGOA/CBERA → census code | `src/parse_general_note_3.R` |
| Ch99 legal authorities | `resources/ch99_legal_refs.csv` | generated | proclamations/EOs per revision | `src/extract_legal_refs.R` (build, `SAIL_EMIT_LEGAL_REFS`) |
| FTA partners | `resources/fta_partners.csv` | committed | FTA partner → census code + HTS symbols | reviewed; changes by treaty |
| Country name aliases | `resources/country_name_aliases.csv` | committed | GN-name → census-code spelling variants | reviewed |
| Program requirements | `config/program_requirements.yaml` | committed | per-program eligibility requirements | manual; symbols validated vs GN3 map |
| Legal reference registry | `config/legal_reference.yaml` | committed | audited authorities + IEEPA refund block | manual |
| Duty citation registry | `config/duty_citations.yaml` | committed | `reason_code` → citation / narrative | manual |

### Optional inputs

| Input | Path | Status | Role |
|---|---|---|---|
| Import weights | local path via `config/local_paths.yaml` | private/local | weighted daily outputs and weighted ETRs |
| TPC benchmark | local path via `config/local_paths.yaml` | private/local | validation only |
| Tariff-ETRs repo | local path via `config/local_paths.yaml` | optional/local | comparison only |
| Chapter 99 PDFs | `data/us_notes/*.pdf` | auto-download via `scrape_us_notes.R`; hash-checked by `01_scrape_revision_dates.R` | regenerate resource files from US Notes |

## What runs without what

| Scenario | Timeseries | Daily aggregates | Weighted ETR | TPC comparison |
|---|---|---|---|---|
| Core only | Yes | Yes | No | No |
| Core + weights | Yes | Yes | Yes | No |
| Core + TPC | Yes | Yes | No | Yes |
| Core + weights + TPC | Yes | Yes | Yes | Yes |

## Expected outputs

### Core outputs

| Path | Description |
|---|---|
| `data/timeseries/rate_timeseries_parquet/` | partitioned Parquet dataset (primary queryable format) |
| `data/timeseries/snapshot_*.rds` | per-revision rate snapshots |
| `data/timeseries/delta_*.rds` | revision-to-revision diffs |
| `output/daily/daily_overall.csv` | daily aggregate mean and weighted ETR series |
| `output/daily/daily_by_country.csv` | daily country-level aggregate rates |
| `output/daily/daily_by_authority.csv` | daily authority decomposition |
| `output/quality/` | build diagnostics and quality checks (Ch99 triage, quality metrics) |
| `output/quality/rate_reconciliation_base*.csv` | rate-validation invariants C1–Q6 (`emit_rate_validation.R`) |
| `resources/gn3_*.csv`, `resources/gn_program_countries.csv`, `resources/ch99_legal_refs.csv` | generated General-Note + legal-authority reference data (incremental) |
| `frontend/public/data/*.json` | daily aggregates plus the de-hardcoded program / legal-reference bundles |

### Optional outputs

| Path | Description |
|---|---|
| `output/etr/` | weighted ETR tables and plots |
| `output/comparisons/` | benchmark comparison artifacts |
| `output/alternative/` | sensitivity variants |
| `output/etrs_config/{date}/` | ETRs-compatible config directories (from `generate_etrs_config.R`) |

## Comparison workflows

TPC and Tariff-ETRs are comparison tools, not production inputs.

```bash
Rscript src/run_comparisons.R
Rscript src/run_comparisons.R --tpc
Rscript src/run_comparisons.R --etr
```

`--etrs` is currently a placeholder in the wrapper. For Tariff-ETRs comparison, run `src/compare_etrs.R` directly (requires `tariff_etrs_repo` in `config/local_paths.yaml`).

### Generating ETRs config

To export tracker rates into Tariff-ETRs-compatible config format:

```bash
Rscript src/generate_etrs_config.R 2026-04-01 ../Tariff-ETRs/config/baseline/2026-04-01
```

This writes `statutory_rates.csv.gz` (dense per-authority statutory rates at HTS10 × country level) and `other_params.yaml` (adjustment parameters: metal content, USMCA, auto rebate). The CSV is the primary lossless interface — ETRs reads it directly and applies all adjustments (USMCA scaling, metal content, stacking). Legacy per-authority YAML generators are also available for backward compatibility.

To generate configs for all revision dates at once, use `generate_etrs_configs_all_revisions()` from R.

## Updating when a new HTS revision is published

See [pipeline-operations.md](pipeline-operations.md) for detailed step-by-step instructions.

Quick summary:

1. `Rscript src/01_scrape_revision_dates.R` — discover the new revision
2. Edit `config/revision_dates.csv` — set correct `effective_date`, `policy_event`, clear `needs_review`
3. `Rscript src/02_download_hts.R --year 2026` — download the JSON archive
4. `Rscript src/00_build_timeseries.R` — incremental build (snapshots + Parquet + frontend data)
5. Restart `cd frontend && node server.js` — pick up new Parquet partition

## Troubleshooting

- If `preflight.R` reports missing packages, run `src/install_dependencies.R --all`.
- If weighted outputs are skipped, check `config/local_paths.yaml`.
- If benchmark comparisons are skipped, confirm the configured TPC path exists.
- If no HTS JSON archives are found, run `src/02_download_hts.R`.

## Querying built data

The authoritative dataset is the partitioned Parquet at `data/timeseries/rate_timeseries_parquet/`. Use `arrow::open_dataset()` for memory-efficient queries:

```r
library(arrow)
library(dplyr)

ds <- open_dataset('data/timeseries/rate_timeseries_parquet', partitioning = 'revision')

# Point-in-time query (lazy, only scans relevant partitions)
snapshot <- ds %>%
  filter(valid_from <= '2026-06-15', valid_until >= '2026-06-15') %>%
  collect()

# Single product-country history
history <- ds %>%
  filter(hts10 == '7208510030', country == '5700') %>%
  collect()
```

The frontend DuckDB server (`frontend/server.js`) also queries this Parquet dataset. See [pipeline-operations.md](pipeline-operations.md) for full details.
