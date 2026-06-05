# Pipeline Operations Guide

Step-by-step instructions for running the tariff-rate-tracker data pipeline: discovering new HTS revisions, building the rate timeseries, and refreshing the frontend.

For calculation methodology, see [CALCULATION_LOGIC.md](CALCULATION_LOGIC.md). For system requirements and input inventory, see [build.md](build.md).

---

## Table of Contents

1. [Architecture Overview](#1-architecture-overview)
2. [Integrating a New HTS Revision](#2-integrating-a-new-hts-revision)
3. [Full Rebuild](#3-full-rebuild)
4. [Frontend Refresh](#4-frontend-refresh)
5. [Command Reference](#5-command-reference)
6. [Memory and Batch Processing](#6-memory-and-batch-processing)
7. [Troubleshooting](#7-troubleshooting)
8. [File Inventory](#8-file-inventory)

---

## 1. Architecture Overview

### Data Flow

```
USITC REST API                     config/revision_dates.csv
      |                                       |
      v                                       v
01_scrape_revision_dates.R ──> Manual review (effective_date, policy_event)
                                              |
      v                                       v
02_download_hts.R ──> data/hts_archives/hts_{year}_{rev}.json
                                              |
                                              v
00_build_timeseries.R
  ├─ 03_parse_chapter99.R     (Ch99 entries)
  ├─ 04_parse_products.R      (products + rate basis)
  ├─ 05_parse_policy_params.R (policy constants)
  ├─ 06_calculate_rates.R     (product x country matrix)
  └─ Per-revision snapshots → Parquet (batch, one at a time)
                                              |
                                              v
                      data/timeseries/rate_timeseries_parquet/
                        revision=2025_basic/data.parquet
                        revision=2025_rev_1/data.parquet
                        ...
                                              |
                          ┌───────────────────┼───────────────────┐
                          v                   v                   v
              run_daily_from_parquet.R  prepare_frontend_data.R  DuckDB server
              (daily CSVs)             (JSON exports)           (frontend API)
```

### Key Principle: Batch Processing

The full timeseries is hundreds of millions of rows across 132 revisions (`2019_basic` → `2026_rev_9`). **The pipeline never loads all rows into memory at once.** Each revision (~4M rows) is processed independently:

- Build step: one snapshot at a time, written to Parquet immediately, then freed
- Daily aggregation: `run_daily_from_parquet.R` reads one Parquet partition per revision
- Frontend server: DuckDB queries Parquet lazily (memory-mapped)

The monolithic `rate_timeseries.rds` is **not produced** by the current pipeline. Any script that calls `readRDS('data/timeseries/rate_timeseries.rds')` is using a legacy path. The authoritative dataset is the partitioned Parquet at `data/timeseries/rate_timeseries_parquet/`.

---

## 2. Integrating a New HTS Revision

This is the standard operational workflow when USITC publishes a new revision. Example: integrating "2026 HTS Revision 5" (effective April 8, 2026).

### Step 1: Discover the Revision

```bash
Rscript src/01_scrape_revision_dates.R
```

This contacts the USITC REST API at `hts.usitc.gov/reststop/releaseList`, discovers new releases (e.g., `2026HTSRev5`), converts the name to `2026_rev_5`, and appends it to `config/revision_dates.csv` with:

- The API **publication date** as a placeholder `effective_date`
- `policy_event` set to `[REVIEW] added {date} — effective_date is publication date, not policy date`
- A `needs_review` column set to `TRUE`

**The build will refuse to run while `needs_review = TRUE`** — the gate is in `src/helpers.R` (`load_revision_dates()`). This prevents accidental builds with incorrect dates.

**If a Chapter 99 PDF change is detected** (SHA-256 hash comparison against `config/.chapter99_hash`), you'll see a warning. Review the changes, then accept:

```bash
Rscript src/01_scrape_revision_dates.R --accept-pdf-hash
```

### Step 2: Curate the Metadata

Open `config/revision_dates.csv` and edit the new row. The USITC API returns the HTS publication date, which often differs from the true policy effective date by days or weeks.

**Before (auto-generated):**
```csv
2026_rev_5,2026-04-10,,,,[REVIEW] added 2026-04-09 — effective_date is publication date not policy date,,TRUE
```

**After (manual edit):**
```csv
2026_rev_5,2026-04-08,,,,Descriptive label for the policy change,,
```

Fields to set:
- `effective_date`: the correct policy date (e.g., `2026-04-08`)
- `policy_effective_date`: leave blank unless the policy date differs from the HTS effective date (see [policy_timing.md](policy_timing.md))
- `policy_event`: descriptive label (e.g., `Section 122 extended; copper 232 annex update`)
- `needs_review`: delete the value or remove the column entirely

### Step 3: Download the HTS JSON Archive

```bash
Rscript src/02_download_hts.R --year 2026
```

This checks `config/revision_dates.csv` for 2026 revisions, compares against files in `data/hts_archives/`, and downloads any missing archives. The file is validated for minimum size (>=1 MB) and JSON structure.

**Flags:**
- `--year 2026` — only download missing files for 2026 (default: all years)
- `--dry-run` — report missing files without downloading

Files are saved to `data/hts_archives/hts_2026_rev_5.json`.

### Step 4: Build the Timeseries

```bash
Rscript src/00_build_timeseries.R
```

The default behavior calls `detect_incremental_start()`, which reads `data/timeseries/metadata.rds` to find `last_revision`, then processes new revisions incrementally. It reuses cached parse results (`ch99_*.rds`, `products_*.rds`) for delta computation.

**What happens internally:**

1. Per-revision loop: parse Ch99, parse products, calculate rates for all 240 countries
2. Save `snapshot_2026_rev_5.rds` (rate matrix for the new revision)
3. Batch-write all snapshots to Parquet (one at a time, never all in RAM)
4. Run downstream scripts (daily aggregation, frontend data export)
5. Run the build-wired quality and provenance emitters (each wrapped so it can never abort the build):
   - `emit_quality_metrics()` → `output/quality/*` (always)
   - `emit_rate_validation()` → `output/quality/rate_reconciliation_base*.csv` (report-only; `SAIL_VALIDATE_RATES=strict` aborts on a correctness violation)
   - `emit_legal_refs_incremental()` → `resources/ch99_legal_refs.csv` → `legal_refs.json` (gate `SAIL_EMIT_LEGAL_REFS`, default on)
   - `emit_gn3()` + `emit_gn_program_countries()` → `resources/gn3_*.csv`, `gn_program_countries.csv` → `program_symbols.json` / `program_countries.json` (gate `SAIL_EMIT_GN3`, default on)
6. Save `metadata.rds` with `last_revision = 2026_rev_5`

**When to use `--start-from`:** If metadata is stale (interrupted build) or you want to recompute from a specific point:

```bash
Rscript src/00_build_timeseries.R --start-from 2026_rev_4
```

### Step 5: Verify

```bash
# Check the Parquet dataset
ls data/timeseries/rate_timeseries_parquet/

# Start the frontend API server and inspect
cd frontend && node server.js
```

The DuckDB server should show the new revision count and row count at startup. The frontend picks up new data after server restart.

---

## 3. Full Rebuild

After schema changes, logic updates, or resource file modifications:

```bash
# Full rebuild from scratch (all revisions, all countries)
Rscript src/00_build_timeseries.R --full

# Full rebuild, core outputs only (skip weighted ETR)
Rscript src/00_build_timeseries.R --full --core-only

# Full rebuild, skip downstream entirely (snapshots + Parquet only)
Rscript src/00_build_timeseries.R --full --build-only
```

**Memory note:** Each revision processes ~19,000 products x ~240 countries. 32 GB RAM is recommended for the per-revision rate calculation step. The combine step is always batch (one snapshot at a time) regardless of build mode.

---

## 4. Frontend Refresh

If the automated downstream in `00_build_timeseries.R` was skipped (e.g., `--build-only`), or you need to refresh frontend data independently:

```bash
# 1. Regenerate Parquet from snapshots (batch, memory-safe)
Rscript scripts/combine_snapshots.R

# 2. Regenerate daily aggregate CSVs from Parquet
Rscript scripts/run_daily_from_parquet.R

# 3. Export static JSON for the frontend dashboard
Rscript scripts/prepare_frontend_data.R
```

**What each script does:**

| Script | Input | Output | Memory |
|--------|-------|--------|--------|
| `combine_snapshots.R` | `snapshot_*.rds` files | `rate_timeseries_parquet/` (partitioned Parquet) | Low — one snapshot at a time |
| `run_daily_from_parquet.R` | Parquet dataset | `output/daily/*.csv` | Low — one revision at a time |
| `prepare_frontend_data.R` | Daily CSVs + Parquet metadata | `frontend/public/data/*.json` | Low |

After running these, restart the frontend API server to pick up the new Parquet partitions:

```bash
cd frontend && node server.js
```

---

## 5. Command Reference

### Pipeline Scripts

| Command | Description |
|---------|-------------|
| `Rscript src/01_scrape_revision_dates.R` | Discover new USITC revisions; append to `config/revision_dates.csv` |
| `Rscript src/01_scrape_revision_dates.R --dry-run` | Preview new revisions without writing |
| `Rscript src/01_scrape_revision_dates.R --accept-pdf-hash` | Accept pending Chapter 99 PDF change |
| `Rscript src/02_download_hts.R` | Download missing HTS JSON archives (all years) |
| `Rscript src/02_download_hts.R --year 2026` | Download missing archives for 2026 only |
| `Rscript src/02_download_hts.R --dry-run` | Report missing files without downloading |
| `Rscript src/00_build_timeseries.R` | Auto-update (incremental from last build) |
| `Rscript src/00_build_timeseries.R --full` | Full rebuild from scratch |
| `Rscript src/00_build_timeseries.R --start-from 2026_rev_4` | Incremental from a specific revision |
| `Rscript src/00_build_timeseries.R --build-only` | Skip downstream (daily series, frontend data) |
| `Rscript src/00_build_timeseries.R --core-only` | Build + daily + quality, skip weighted ETR |
| `Rscript src/00_build_timeseries.R --use-hts-dates` | Use raw HTS dates instead of policy dates |
| `Rscript src/00_build_timeseries.R --refresh-usmca` | Re-download USMCA shares before building |

### Frontend Data Scripts

| Command | Description |
|---------|-------------|
| `Rscript scripts/combine_snapshots.R` | RDS snapshots → partitioned Parquet |
| `Rscript scripts/run_daily_from_parquet.R` | Parquet → daily aggregate CSVs |
| `Rscript scripts/prepare_frontend_data.R` | Daily CSVs → frontend JSON exports |

### Frontend Server

| Command | Description |
|---------|-------------|
| `cd frontend && node server.js` | Start API server (DuckDB + Parquet, port 3001) |
| `cd frontend && npm run dev` | Start Vite dev server (port 5173) |
| `cd frontend && npm run dev:all` | Start both servers together |
| `cd frontend && npm run build` | Production build to `frontend/dist/` |

---

## 6. Memory and Batch Processing

### The Monolithic RDS is Deprecated

The old pipeline combined all snapshots into a single `rate_timeseries.rds` (~155M rows, multi-GB in memory). This routinely exceeded available RAM and caused OOM failures.

The current pipeline **always uses batch processing:**

1. **Build step** (`00_build_timeseries.R`): processes each HTS revision independently, saves a per-revision `snapshot_*.rds`, then writes each to Parquet one at a time. Peak memory = one snapshot (~4M rows).

2. **Combine step** (embedded in `00_build_timeseries.R`, also available standalone via `combine_snapshots.R`): reads one snapshot, enforces schema, joins interval columns, writes to `rate_timeseries_parquet/revision={rev}/data.parquet`, frees memory, moves to next.

3. **Daily aggregation** (`run_daily_from_parquet.R`): opens the Parquet dataset with `arrow::open_dataset()`, processes one revision at a time.

4. **Frontend server** (`server.js`): DuckDB creates a view over the Parquet files. Queries are lazy — only the relevant partitions are scanned.

### If You See `rate_timeseries.rds` References

Some older scripts (`quality_report.R`, `apply_scenarios.R`, `diagnose_china_gap.R`) still reference the monolithic RDS. These are legacy paths. For production use, always work from the Parquet dataset:

```r
library(arrow)
ds <- open_dataset('data/timeseries/rate_timeseries_parquet', partitioning = 'revision')

# Point-in-time query (lazy, memory-efficient)
rates <- ds %>%
  filter(valid_from <= '2026-06-15', valid_until >= '2026-06-15') %>%
  collect()

# Single product-country
rates <- ds %>%
  filter(hts10 == '7208510030', country == '5700') %>%
  collect()
```

---

## 7. Troubleshooting

### Build refuses to run: `needs_review = TRUE`

The `01_scrape_revision_dates.R` script adds new revisions with `needs_review = TRUE`. Open `config/revision_dates.csv`, set the correct `effective_date` and `policy_event`, and clear or delete the `needs_review` column value for those rows.

### `02_download_hts.R` re-downloads everything

**Fixed.** Earlier versions had a bug where 2025 revision filenames weren't matched correctly against the CSV. The `--year` flag also had no effect. Both issues have been resolved:
- All years now use consistent year-prefixed IDs for comparison (`2025_rev_1`, not `rev_1`)
- `--year` correctly filters to the specified year; omitting it checks all years

### Build OOM (out of memory)

The current pipeline never loads all revisions into RAM simultaneously. If you still hit OOM:
- It's likely during the per-revision rate calculation step (19K products x 240 countries). 32 GB RAM is recommended.
- Use `--build-only` and then run `scripts/combine_snapshots.R` separately if the combine step is the issue.

### Parquet dataset has duplicate revisions

Legacy short-format revisions (e.g., `rev_2`, `rev_3`) may exist in `data/timeseries/rate_timeseries_parquet/` alongside the canonical year-prefixed revisions (`2025_rev_2`, `2025_rev_3`). The frontend DuckDB server filters these out with `WHERE revision LIKE '20%'` in the view definition (`frontend/server.js`). To clean them from the Parquet dataset, delete the `revision=rev_*` directories and re-run `scripts/combine_snapshots.R`.

### Frontend shows stale data

The DuckDB server catalogs the Parquet dataset at startup. After rebuilding Parquet, restart the API server:

```bash
cd frontend && node server.js
```

---

## 8. File Inventory

### Configuration

| File | Purpose | Update Method |
|------|---------|---------------|
| `config/revision_dates.csv` | Revision schedule with effective dates and policy events | `01_scrape_revision_dates.R` discovers; manual review required |
| `config/policy_params.yaml` | All policy constants: country codes, authority ranges, 232 programs, floor rates, USMCA settings | Manual update when policy changes |
| `config/.chapter99_hash` | SHA-256 hash of the Chapter 99 PDF (change detection) | Auto-managed by `01_scrape_revision_dates.R` |
| `.env` | USITC DataWeb API token (optional, only for `--refresh-usmca`) | Manual |

### Data

| Path | Content | Produced By |
|------|---------|-------------|
| `data/hts_archives/hts_{year}_{rev}.json` | Raw HTS JSON archives from USITC | `02_download_hts.R` |
| `data/timeseries/snapshot_{rev}.rds` | Per-revision rate matrix | `00_build_timeseries.R` |
| `data/timeseries/delta_{rev}.rds` | Revision-to-revision diffs | `00_build_timeseries.R` |
| `data/timeseries/ch99_{rev}.rds` | Cached Chapter 99 parse (for incremental) | `00_build_timeseries.R` |
| `data/timeseries/products_{rev}.rds` | Cached product parse (for incremental) | `00_build_timeseries.R` |
| `data/timeseries/metadata.rds` | Build metadata: last_revision, timestamp, counts | `00_build_timeseries.R` |
| `data/timeseries/rate_timeseries_parquet/` | Partitioned Parquet dataset (primary queryable format) | `00_build_timeseries.R` or `combine_snapshots.R` |

### Output

| Path | Content | Produced By |
|------|---------|-------------|
| `output/daily/daily_overall.csv` | Daily aggregate mean tariff rates | `run_daily_from_parquet.R` |
| `output/daily/daily_by_country.csv` | Daily per-country aggregate rates | `run_daily_from_parquet.R` |
| `output/daily/daily_by_authority.csv` | Daily per-authority decomposition | `run_daily_from_parquet.R` |
| `output/logs/build_*.log` | Build logs with timestamps | `00_build_timeseries.R` |

### Frontend

| Path | Content | Produced By |
|------|---------|-------------|
| `frontend/public/data/countries.json` | Country metadata (Census codes, ISO, partner groups) | `prepare_frontend_data.R` |
| `frontend/public/data/revision_timeline.json` | Revision schedule for dashboard timeline | `prepare_frontend_data.R` |
| `frontend/public/data/daily_overall.json` | Daily tariff statistics | `prepare_frontend_data.R` |
| `frontend/public/data/daily_by_authority.json` | Daily rates by authority | `prepare_frontend_data.R` |
| `frontend/public/data/daily_by_country_summary.json` | Per-country per-revision summary | `prepare_frontend_data.R` |
| `frontend/public/data/sample_rates.json` | Sample product rates for dashboard display | `prepare_frontend_data.R` |
| `frontend/public/data/program_symbols.json` | Special-program symbol map + Column 2 list, per revision | `scripts/emit_program_symbols.R` |
| `frontend/public/data/program_countries.json` | Country → preference-program membership (GSP/AGOA/CBERA + FTA) | `scripts/emit_program_countries.R` |
| `frontend/public/data/program_requirements.json` | Per-program eligibility requirements | `scripts/emit_program_requirements.R` |
| `frontend/public/data/legal_refs.json` | Audited proclamations / EOs / CBP messages per Ch99 authority | `scripts/emit_legal_refs_json.R` |
| `frontend/public/data/duty_citations.json` | `reason_code` → citation / narrative registry | `scripts/emit_duty_citations.R` |
| `frontend/server.js` | Express + DuckDB API server (port 3001) | Manual |
| `frontend/dist/` | Production build output | `npm run build` |
