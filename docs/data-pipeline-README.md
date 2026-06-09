# Data Pipeline: End-to-End Guide

This document describes the complete data pipeline from raw HTS JSON archives to the frontend dashboard. It consolidates operational knowledge from [build.md](build.md), [pipeline-operations.md](pipeline-operations.md), and [methodology.md](methodology.md) into a single reference focused on **how the data flows and what each step produces**.

For system requirements and input inventory, see [build.md](build.md). For calculation methodology, see [CALCULATION_LOGIC.md](CALCULATION_LOGIC.md).

---

## Table of Contents

1. [Quick Reference: Full Data Refresh](#1-quick-reference-full-data-refresh)
2. [Pipeline Architecture](#2-pipeline-architecture)
3. [Data Flow Diagram](#3-data-flow-diagram)
4. [Step-by-Step: What Each Script Does](#4-step-by-step-what-each-script-does)
5. [Two-Layer Country Resolution](#5-two-layer-country-resolution)
6. [Ch99 Cross-References](#6-ch99-cross-references)
7. [Warning Triage System](#7-warning-triage-system)
8. [Quality Report](#8-quality-report)
9. [Frontend Data Chain](#9-frontend-data-chain)
10. [Command Reference](#10-command-reference)

---

## 1. Quick Reference: Full Data Refresh

### From scratch (first time or after schema changes)

```bash
# 1. Setup
Rscript src/preflight.R
Rscript src/install_dependencies.R --all

# 2. Download HTS archives
Rscript src/02_download_hts.R

# 3. Full build (snapshots + Parquet + daily series + frontend JSON)
Rscript src/00_build_timeseries.R --full --core-only

# 4. Start the frontend
cd frontend && npm install && npm run dev:all
```

### Incremental update (new HTS revision published)

```bash
# 1. Discover new revision from USITC API
Rscript src/01_scrape_revision_dates.R

# 2. Edit config/revision_dates.csv — set correct effective_date, clear needs_review

# 3. Download the new JSON archive
Rscript src/02_download_hts.R --year 2026

# 4. Incremental build (auto-detects new revisions)
Rscript src/00_build_timeseries.R

# 5. Restart the frontend API server
cd frontend && node server.js
```

### Publish a new revision to sail-gtx (deployed app)

The steps above refresh data **locally**. To roll a new revision out to the
deployed **sail-gtx-prerelease** app (Railway server + Vercel frontend), run the
HTS automation `run_locally.sh`. It is a 9-step pipeline that discovers/builds the
revision, refreshes the RAG index, records the revision in Supabase, commits the
dataset JSON into sail-gtx, repoints both deployments at the new revision, and
smoke-tests the result.

#### One-time setup: credentials

Every secret lives in **`scripts/hts_automation/.env.hts_automation`** (copied from
`.env.hts_automation.example`, **gitignored — never commit it**). `run_locally.sh`
sources it automatically, so this is the single place all credentials are written:

```bash
cp scripts/hts_automation/.env.hts_automation.example scripts/hts_automation/.env.hts_automation
pip install -r scripts/hts_automation/requirements.txt
# then edit scripts/hts_automation/.env.hts_automation and fill in every value
```

| Variable | Used by (step) | How to get it |
|----------|----------------|---------------|
| `RAGIE_API_KEY` (`tnt_…`) | 5 Ragie swap | Ragie dashboard → API Keys |
| `SUPABASE_URL` | 6 Supabase upsert | Supabase project → Settings → API → Project URL (already set in the template) |
| `SUPABASE_SERVICE_ROLE_KEY` (`eyJ…`) | 6 Supabase upsert | Supabase project → Settings → API → the **`service_role`** secret key |
| `SAIL_GTX_REPO_PAT` (`github_pat_…`) | 7 cross-repo commit | GitHub fine-grained PAT — see below |
| `SAIL_GTX_PRODUCTION_BRANCH` | 7, 8 | sail-gtx branch the deploys read from (e.g. `illegal-transshipment`). Config, not a secret. |
| `RAILWAY_TOKEN` | 8 Railway env | Railway → Account Settings → Tokens (an account/team token, not a one-off project token) |
| `RAILWAY_PROJECT_ID` / `_SERVICE_ID` / `_ENVIRONMENT_ID` | 8 Railway env | All three are in the dashboard URL — see note below |
| `VERCEL_TOKEN` | 8 Vercel env | Vercel → Account Settings → Tokens → Create Token (scope it to the team that owns the project) |
| `VERCEL_PROJECT_ID` (`prj_…`) | 8 Vercel env | Vercel project → Settings → General → Project ID (also set `VERCEL_TEAM_ID` if on a team) |
| `SAIL_GTX_HEALTHCHECK_URL` / `SAIL_GTX_API_BASE` | 9 smoke test | Deployed Railway URLs (already set in the template) |
| `GIT_USER_NAME` / `GIT_USER_EMAIL` | 7 commit author | Optional; defaults to `sail-gtx-bot` |

> **Getting the three Railway IDs (and why `SERVICE_ID` matters):** the env-var
> update is scoped by `(projectId, environmentId, serviceId)`, so **`RAILWAY_SERVICE_ID`
> is what targets the `sail-gtx-prerelease` service specifically** rather than any
> other service in the same project. Open that service in the **production**
> environment in the Railway dashboard; the URL contains all three UUIDs:
> `…/project/<RAILWAY_PROJECT_ID>/service/<RAILWAY_SERVICE_ID>?environmentId=<RAILWAY_ENVIRONMENT_ID>`.
> Click the correct service (not the sibling repo) and confirm the environment
> selector reads "production" before copying them.

**Creating `SAIL_GTX_REPO_PAT`:** on GitHub go to **Settings → Developer settings →
Fine-grained tokens → Generate new token**, then:
- **Resource owner:** `SAIL-Engineering`
- **Repository access:** Only select repositories → `sail-gtx-prerelease`
- **Repository permissions → Contents: Read and write** (nothing else is needed)
- Copy the `github_pat_…` value into `SAIL_GTX_REPO_PAT`. Tokens expire — regenerate
  when they lapse. The branch in `SAIL_GTX_PRODUCTION_BRANCH` must not be protected
  against the token's identity, or the *push* (not the clone) will 403.

#### Run it

```bash
scripts/hts_automation/run_locally.sh                         # latest published revision
scripts/hts_automation/run_locally.sh --revision 2026_rev_10  # a specific revision
scripts/hts_automation/run_locally.sh --dry-run               # run every step, write nothing external
```

| Flag | Effect |
|------|--------|
| *(none)* | Roll out the latest published revision |
| `--revision <id>` | Target a specific revision (e.g. `2026_rev_10`) |
| `--dry-run` | Execute every step but make **no** external writes (clone + diff only; no push, upsert, or env change) |
| `--skip-scrape` | Skip step 1; reuse the existing `config/revision_dates.csv` |
| `--run-classify` / `--skip-classify` | Toggle the optional canary classify (default: skip) |

#### What the 9 steps do

| # | Step | What it does | Needs |
|---|------|--------------|-------|
| 1 | Scrape | `01_scrape_revision_dates.R` polls USITC, updates `config/revision_dates.csv`, clears `needs_review` | — |
| 2 | Resolve target | Picks the target revision and resolves its year / number / effective date / JSON + CSV paths | — |
| 3 | Download | `02_download_hts.R` fetches the HTS JSON + CSV for the year if missing | — |
| 4 | Ragie minimal CSV | `build_hts_minimal.py` trims the CSV for the RAG partition | — |
| 5 | Ragie partition swap | Uploads the new CSV to the `us_hts_<year>_latest` partition, waits for `ready`, deletes the old docs | `RAGIE_API_KEY` |
| 6 | Supabase upsert | Upserts the revision row into `hts_revisions` (the canonical active-revision record) | `SUPABASE_*` |
| 7 | Cross-repo commit | `sail_gtx_commit.py` commits the dataset JSON to sail-gtx (`server/data/hts/` **and** `public/data/hts-explorer/`) + a `hts-<year>-rev<n>` tag | `SAIL_GTX_REPO_PAT`, `SAIL_GTX_PRODUCTION_BRANCH` |
| 8 | Env var update | `update_env_vars.py` sets `VITE_HTS_REVISION_*` on **Railway and Vercel** so both deployments redeploy pointing at the new revision; writes a rollback snapshot to `/tmp/hts-env-snapshot.json` | `RAILWAY_*`, `VERCEL_*` |
| 9 | Smoke test | `smoke_test.py` hits the health + API endpoints to confirm the redeploy is serving the new revision | `SAIL_GTX_HEALTHCHECK_URL`, `SAIL_GTX_API_BASE` |

> **Step ordering matters:** step 7 (commit the JSON) must run before step 8
> (env-var change → redeploy). The server asserts the JSON file exists at boot, so
> if the env var flips before the file is committed the redeploy fails its boot
> check. That is why a step-7 failure stops the run before steps 8-9 ever execute.

#### Where the dataset lands

`hts_<YEAR>_revision_<N>.json` is written to the two locations the deployed app
reads from — both must be updated or the frontend HTS Explorer lags the server:

| sail-gtx destination | Consumer | When read |
|----------------------|----------|-----------|
| `server/data/hts/` | Railway API server (`HTS_DATA_DIR`) | at runtime |
| `public/data/hts-explorer/` | Vercel static frontend (HTS Explorer) | fetched as a static asset |

`public/data/hts-explorer/manifest.json` (which tells the frontend the latest
revision to load) is **regenerated automatically** at sail-gtx build time by the
Vite `htsManifestPlugin`, so it is never pushed.

#### CI equivalent + JSON-only push

In CI this same rollout runs as **`.github/workflows/hts-revision-update.yml`**
(`run_locally.sh` is the manual/local equivalent; the GitHub Actions secrets mirror
the `.env` keys above). To push only the JSON to both locations (no rebuild), call
the committer directly with two `--dest-path` flags (repeatable — same source, one
commit; idempotent: byte-identical files are skipped, and the PAT is redacted from
all log output):

```bash
python3 scripts/hts_automation/sail_gtx_commit.py \
  --owner SAIL-Engineering --repo sail-gtx-prerelease --branch <production-branch> \
  --source <built hts_YEAR_revision_N.json> \
  --dest-path "server/data/hts/hts_2026_revision_10.json" \
  --dest-path "public/data/hts-explorer/hts_2026_revision_10.json" \
  --commit-message "chore: HTS 2026 Rev 10 dataset"
```

#### Troubleshooting and recovery

- **`Authentication failed` / `Invalid username or token` at step 7** — `SAIL_GTX_REPO_PAT`
  is missing, still the `github_pat_REPLACE_ME` placeholder, expired, or lacks
  **Contents: write** on `sail-gtx-prerelease`. Fix the token (above) and re-run.
- **Exit code > 1 (a step failed)** — the steps are idempotent, so re-running from
  the top is safe: Ragie ends with one ready doc, the Supabase upsert is keyed, and
  the commit skips byte-identical files. If step 8 already changed some env vars,
  replay the snapshot: `python3 scripts/hts_automation/update_env_vars.py revert --snapshot /tmp/hts-env-snapshot.json`.
- **Resume from step 7 only** — when steps 1-6 already succeeded (as in a step-7
  auth failure), avoid re-uploading to Ragie by running `sail_gtx_commit.py`
  directly (the JSON-only push above), then run `update_env_vars.py` for steps 8-9.
- **Verify success** — both `hts_<y>_revision_<n>.json` files are present in sail-gtx
  on the production branch (+ the `hts-<y>-rev<n>` tag); after the Vercel build,
  `public/data/hts-explorer/manifest.json` names the new revision; and the step-9
  smoke test passes against the live URLs.

### Frontend-only refresh (data already built)

```bash
# If you ran --build-only or need to regenerate frontend data:
Rscript scripts/combine_snapshots.R           # RDS snapshots → Parquet
Rscript scripts/run_daily_from_parquet.R      # Parquet → daily CSVs
Rscript scripts/prepare_frontend_data.R       # daily CSVs → frontend JSON
cd frontend && node server.js                 # restart API server
```

---

## 2. Pipeline Architecture

The pipeline processes HTS revisions **one at a time** (never all in memory). Each revision produces a snapshot (~4M rows: 19K products x 240 countries), written to Parquet immediately. Daily aggregations and frontend JSON exports are derived from the Parquet dataset.

### Key principle: batch processing

The full timeseries is hundreds of millions of rows across 132 revisions (`2019_basic` → `2026_rev_9`), at ~4M rows per revision (19K products × 240 countries). The pipeline never loads all rows at once:

- **Build step**: one snapshot at a time → RDS + Parquet
- **Daily aggregation**: reads one Parquet partition per revision
- **Frontend server**: DuckDB queries Parquet lazily (memory-mapped)

---

## 3. Data Flow Diagram

```
USITC REST API                     config/revision_dates.csv
      │                                       │
      ▼                                       ▼
01_scrape_revision_dates.R ──► Manual review (effective_date, policy_event)
                                              │
      ▼                                       ▼
02_download_hts.R ──► data/hts_archives/hts_{year}_{rev}.json
                                              │
                                              ▼
00_build_timeseries.R (per-revision loop)
  │
  ├─ 03_parse_chapter99.R ──► ch99 entries + resolution_status + cross-references
  │     │
  │     ├─ Layer 1: parse_countries() ─── generic country scope
  │     └─ Layer 2: authority-specific extractors ─── downstream resolution
  │           ├─ extract_ieepa_rates()           (9903.01.43-89, 9903.02.02-91)
  │           ├─ extract_ieepa_fentanyl_rates()  (9903.01.01-24)
  │           └─ extract_section232_rates()       (9903.80-85, 9903.94)
  │
  ├─ 04_parse_products.R ──► products + rate basis
  ├─ 05_parse_policy_params.R ──► policy constants + IEEPA/fentanyl extraction
  └─ 06_calculate_rates.R ──► product × country rate matrix
                                              │
                            Per-revision outputs:
                            ├─ snapshot_{rev}.rds (rate matrix)
                            ├─ ch99_{rev}.rds (parsed ch99 with triage)
                            ├─ products_{rev}.rds (parsed products)
                            └─ delta_{rev}.rds (revision diffs)
                                              │
                                              ▼
                      data/timeseries/rate_timeseries_parquet/
                        revision=2025_basic/data.parquet
                        revision=2025_rev_1/data.parquet
                        ...
                                              │
                          ┌───────────────────┼───────────────────┐
                          ▼                   ▼                   ▼
              run_daily_from_parquet.R  prepare_frontend_data.R  DuckDB server
              (daily CSVs)             (JSON exports)           (frontend API)
                          │                   │                   │
                          ▼                   ▼                   ▼
              output/daily/*.csv    frontend/public/data/*.json  port 3001
                                                                  │
                                                                  ▼
                                                     frontend (Vite, port 5173)
```

**Also emitted during `00_build_timeseries.R`, after the per-revision loop** (each
wrapped so it can never abort a build):

```
rate_timeseries_parquet/  +  ch99_*.rds caches
      │
      ├─ emit_quality_metrics()         → output/quality/*                     (always)
      ├─ emit_rate_validation()         → output/quality/rate_reconciliation_base*.csv
      │                                   (report-only; SAIL_VALIDATE_RATES=strict aborts)
      ├─ emit_legal_refs_incremental()  → resources/ch99_legal_refs.csv → legal_refs.json
      │                                   (incremental; SAIL_EMIT_LEGAL_REFS, default on)
      └─ emit_gn3() + emit_gn_program_countries()
                                        → resources/gn3_*.csv, gn_program_countries.csv
                                        → program_symbols.json / program_countries.json
                                          (incremental; SAIL_EMIT_GN3, default on)
```

The legal-reference and General-Note emitters de-hardcode the frontend's program
and citation data; see [PROVENANCE_PIPELINE.md](PROVENANCE_PIPELINE.md).

---

## 4. Step-by-Step: What Each Script Does

### Phase 1: Discovery and Download

| Script | Input | Output | Notes |
|--------|-------|--------|-------|
| `src/01_scrape_revision_dates.R` | USITC API | `config/revision_dates.csv` (appended) | Sets `needs_review = TRUE`; build refuses to run until cleared |
| `src/02_download_hts.R` | `config/revision_dates.csv` | `data/hts_archives/hts_{year}_{rev}.json` | Validates size (≥1 MB) and JSON structure |

### Phase 2: Build (per-revision)

For each revision in `config/revision_dates.csv`:

| Step | Script/Function | Input | Output | Memory |
|------|----------------|-------|--------|--------|
| Parse Ch99 | `03_parse_chapter99.R` → `parse_chapter99()` | HTS JSON | ch99 entries with country_type, resolution_status, references | Low |
| Parse products | `04_parse_products.R` → `parse_products()` | HTS JSON | product list with rate basis | Low |
| Extract IEEPA | `05_parse_policy_params.R` → `extract_ieepa_rates()` | HTS JSON + country lookup | per-country IEEPA rates | Low |
| Extract fentanyl | `05_parse_policy_params.R` → `extract_ieepa_fentanyl_rates()` | HTS JSON + country lookup | per-country fentanyl rates with carve-outs | Low |
| Extract S232 | `05_parse_policy_params.R` → `extract_section232_rates()` | ch99 data | blanket 232 rates by metal type | Low |
| Calculate rates | `06_calculate_rates.R` → `calculate_rates_for_revision()` | All of the above + 240 countries | product × country rate matrix (~4M rows) | **High** (32 GB recommended) |
| Save snapshot | — | Rate matrix | `snapshot_{rev}.rds`, `ch99_{rev}.rds`, `products_{rev}.rds` | Low |

### Phase 3: Combine and Export

| Script | Input | Output | Memory |
|--------|-------|--------|--------|
| Combine to Parquet (embedded in build) | `snapshot_*.rds` | `rate_timeseries_parquet/` | Low (one at a time) |
| `scripts/run_daily_from_parquet.R` | Parquet dataset | `output/daily/daily_overall.csv`, `daily_by_country.csv`, `daily_by_authority.csv` | Low (one revision at a time) |
| `scripts/prepare_frontend_data.R` | Daily CSVs + Parquet metadata | `frontend/public/data/*.json` | Low |

### Phase 4: Quality and Triage

| Script | Input | Output | Notes |
|--------|-------|--------|-------|
| Ch99 triage (embedded in build) | `ch99_*.rds` caches | `output/quality/ch99_country_scope_triage.csv` | Always runs; classifies unknown entries |
| `src/emit_quality_metrics.R` → `emit_quality_metrics()` (embedded) | `ch99_*.rds` caches | `output/quality/*` | Always runs (every build mode); per-revision statistical audit |
| `src/emit_rate_validation.R` → `emit_rate_validation()` (embedded) | Parquet + generated GN reference data | `output/quality/rate_reconciliation_base*.csv` | Report-only; `SAIL_VALIDATE_RATES=strict` aborts on a correctness violation. See [§8](#8-quality-report) |
| `src/quality_report.R` (manual) | `rate_timeseries.rds` (monolithic) | `output/quality/*.csv` | Requires monolithic RDS; run separately |

### Phase 5: Provenance and De-hardcoding (build-wired, incremental)

These emitters generate the frontend's program and legal-reference data from the
same HTS PDFs the pipeline already fetches, so a new revision updates the data with
no code change. Each is incremental (only revisions not already extracted are
fetched) and wrapped so a network/PDF error can never abort a build.

| Script / Function | Input | Output | Gate |
|--------|-------|--------|------|
| `src/extract_legal_refs.R` → `emit_legal_refs_incremental()` | Chapter 99 PDF per revision | `resources/ch99_legal_refs.csv` → `legal_refs.json` | `SAIL_EMIT_LEGAL_REFS` (default on) |
| `src/parse_general_note_3.R` → `emit_gn3()` | GN 3(b)/3(c) PDF per revision | `resources/gn3_program_symbols.csv`, `resources/gn3_column2_countries.csv` → `program_symbols.json` | `SAIL_EMIT_GN3` (default on) |
| `src/parse_general_note_3.R` → `emit_gn_program_countries()` | GN 4/16/7 (GSP/AGOA/CBERA) PDFs | `resources/gn_program_countries.csv` → `program_countries.json` | `SAIL_EMIT_GN3` (default on) |

The JSON bundles are produced by `scripts/emit_program_{symbols,countries,requirements}.R`
and `scripts/emit_{legal_refs_json,duty_citations}.R`. Census mapping is
precision-first: a General-Note name that doesn't match a census code exactly (or
via `resources/country_name_aliases.csv`) is emitted name-only with no code, so a
miss falls back to the safe MFN default rather than fabricating a preference. Full
detail in [PROVENANCE_PIPELINE.md](PROVENANCE_PIPELINE.md).

---

## 5. Two-Layer Country Resolution

Chapter 99 entries describe tariff provisions. Each entry's country scope (which countries it applies to) is resolved through a two-layer architecture:

### Layer 1: Generic Parser (`parse_countries()`)

Located in `src/03_parse_chapter99.R`. Performs pattern matching on the entry's description text:

- `"product of China"` → `specific: CN`
- `"product of Canada"` + `"Mexico"` → `specific: CA, MX`
- `"except...heading/subheading"` → `all` (blanket rate)
- `"except products of Australia, Canada..."` → `all_except: AU, CA`
- `"Russian Federation"` → `specific: RU`
- No match → `unknown` (fail-closed default)

The fail-closed design prevents a parser miss from silently promoting a country-specific entry to a global blanket tariff. Entries classified as `unknown` are not applied to any country at this layer.

### Layer 2: Authority-Specific Extractors

These functions read directly from the HTS JSON or ch99 parse output. They have their own country resolution logic tailored to each authority:

| Extractor | Code Range | Country Logic |
|-----------|------------|---------------|
| `extract_ieepa_rates()` | `9903.01.43-89`, `9903.02.02-91` | Parses description + country lookup; country-specific EOs |
| `extract_ieepa_fentanyl_rates()` | `9903.01.01-24` | Recognizes cross-references ("Except for products described in..."); infers country from code block structure (01-09=MX, 10-19=CA, 20-24=CN) |
| `extract_section232_rates()` | `9903.80-85`, `9903.94` | Product definitions (no country in description); country scope is "all" or "all_except" from parent entries |

These run within the same build — no separate script needed. The data flows directly into `calculate_rates_for_revision()` and then into the Parquet dataset.

---

## 6. Ch99 Cross-References

Many Chapter 99 entries reference other ch99 codes in their description. For example:

```
9903.01.01: "Except for products described in headings 9903.01.02, 9903.01.03,
             9903.01.04 and 9903.01.05 articles the product of Mexico..."
```

This means `9903.01.01` is the blanket entry for Mexico, and the referenced codes (`9903.01.02-05`) are carve-outs with different rates or exemptions.

The `extract_ch99_references()` function (in `src/03_parse_chapter99.R`) extracts all `9903.xx.xx` codes mentioned in each entry's description and stores them in the `references` list column of the ch99 parse output. This makes the dependency graph visible in:

- Per-revision `ch99_*.rds` caches
- The `output/quality/ch99_country_scope_triage.csv` CSV (references column, semicolon-separated)

### How cross-references are handled

The authority-specific extractors handle cross-references natively:

- **Fentanyl extractor** (line 487 in `src/05_parse_policy_params.R`): Detects the "Except for products described in" pattern to classify entries as `general` (blanket) vs. `carveout` (reduced rate for specific products).
- **S232 extractor**: Parent entries (`9903.80.xx`) define blanket rates; child entries define product categories. The extractor reads both and applies them together.

---

## 7. Warning Triage System

### The problem

`parse_countries()` returns `country_type = 'unknown'` for ~370 entries per revision. But most of these are **not actually problematic** — they're either handled by downstream extractors or are not duty-relevant.

### The solution: `resolution_status` column

Every ch99 entry now gets a `resolution_status` classification (via `classify_resolution_status()`):

| Status | Meaning | Action Required |
|--------|---------|-----------------|
| `resolved_by_parser` | `parse_countries()` successfully resolved the country scope | None |
| `handled_by_fentanyl_extractor` | Code in `9903.01.01-24` range; handled by `extract_ieepa_fentanyl_rates()` | None |
| `handled_by_ieepa_extractor` | Code in `9903.01.43-89` or `9903.02.02-91` range; handled by `extract_ieepa_rates()` | None |
| `handled_by_s232_extractor` | Code in `9903.80-85` or `9903.94` range; handled by `extract_section232_rates()` | None |
| `handled_by_s301_config` | Code in `9903.88-93` range; handled via `policy_params.yaml` China mapping | None |
| `not_duty_relevant_trq` | WTO tariff-rate quota provision; not a duty surcharge | None |
| `unresolved_s201` | Section 201 safeguard duty; not currently modeled | Low priority — legacy |
| `unresolved` | Genuinely unresolved; needs investigation | **Investigate** |

### Build log output

The build log now shows a triage breakdown instead of a raw count:

```
[WARN] Ch99 country scope [2025_rev_32]: 370 entries with unknown country_type
       (210 handled_by_s232_extractor, 79 not_duty_relevant_trq,
        25 handled_by_s301_config, 15 handled_by_fentanyl_extractor, ...)
[WARN] Truly unresolved entries (13): 9903.xx.xx, ...
```

### Triage CSV

After every build, `output/quality/ch99_country_scope_triage.csv` contains all unknown entries across all revisions with their `resolution_status`, `references`, and full description. Use this to:

1. Identify genuinely unresolved entries
2. Prioritize parser improvements
3. Track how unknown entries change across revisions

---

## 8. Quality Report

### Automated (runs during build)

Three harnesses run on **every** build mode (full, resume, scoped, build-only),
each wrapped so it can never abort a build:

- **Ch99 country-scope triage** → `output/quality/ch99_country_scope_triage.csv` plus
  build-log triage breakdown per revision.
- **Quality metrics** (`emit_quality_metrics()`) → per-revision statistical audit in
  `output/quality/`, derived from the on-disk `ch99_*.rds` caches.
- **Rate reconciliation** (`emit_rate_validation()`) → see below.

### Rate reconciliation (`emit_rate_validation.R`)

Per-revision invariants over the rate Parquet plus the generated General-Note
reference data, so the data-driven rate universe can't silently drift. Report-only
by default; `SAIL_VALIDATE_RATES=strict` aborts the build on a **correctness**
violation (quality flags stay report-only either way). Results land in
`output/quality/rate_reconciliation_base*.csv`, `rate_unknown_symbols.csv`, and
`rate_lines_unresolved.csv`.

| ID | Kind | Invariant |
|----|------|-----------|
| C1 | correctness | `base_rate ≤ statutory_base_rate` |
| C2 | correctness | `base_rate`, `statutory_base_rate` finite and ≥ 0 |
| Q3 | coverage | Special symbols on rate lines are covered by the program map (`gn3_program_symbols.csv` + `fta_partners.csv` + allowlist) |
| Q4 | coverage | `base_rate_source` resolved (`own` / `inherited:…`) for active lines |
| Q5 | coverage | Column 2 names all resolve to a census code; count within band |
| Q6 | coverage | GSP / AGOA / CBERA beneficiary counts within expected band |

### Manual (separate script)

The full quality report requires the monolithic `rate_timeseries.rds` and must be run separately:

```bash
Rscript src/quality_report.R
```

This produces additional checks in `output/quality/`:
- `schema_check.csv` — schema validation
- `revision_quality.csv` — per-revision statistics
- `anomalies.csv` — suspicious rate jumps
- `unknown_country_type.csv` — unknown country entries
- `non_china_301.csv` — Section 301 scope check
- `quality_report.rds` — full report object

---

## 9. Frontend Data Chain

### Static JSON exports

The frontend dashboard reads pre-computed JSON files from `frontend/public/data/`:

| File | Content | Source |
|------|---------|--------|
| `daily_overall.json` | Daily aggregate tariff statistics | `prepare_frontend_data.R` ← `daily_overall.csv` |
| `daily_by_authority.json` | Daily rates decomposed by authority | `prepare_frontend_data.R` ← `daily_by_authority.csv` |
| `daily_by_country_summary.json` | Per-country per-revision summary | `prepare_frontend_data.R` ← Parquet metadata |
| `sample_rates.json` | Sample product rates for display | `prepare_frontend_data.R` ← Parquet |
| `revision_timeline.json` | Revision schedule for timeline UI | `prepare_frontend_data.R` ← `config/revision_dates.csv` |
| `countries.json` | Country metadata | `prepare_frontend_data.R` ← `resources/census_codes.csv` |
| `program_symbols.json` | Special-program symbol map + Column 2 country list, per revision | `scripts/emit_program_symbols.R` ← `gn3_program_symbols.csv`, `gn3_column2_countries.csv` |
| `program_countries.json` | Country → preference-program membership (GSP/AGOA/CBERA + FTA) | `scripts/emit_program_countries.R` ← `gn_program_countries.csv`, `fta_partners.csv` |
| `program_requirements.json` | Per-program eligibility requirements ("missing facts") | `scripts/emit_program_requirements.R` ← `config/program_requirements.yaml` |
| `legal_refs.json` | Audited proclamations / EOs / CBP messages per Ch99 authority | `scripts/emit_legal_refs_json.R` ← `legal_reference.yaml`, `ch99_legal_refs.csv` |
| `duty_citations.json` | `reason_code` → citation / narrative registry | `scripts/emit_duty_citations.R` ← `config/duty_citations.yaml` |

The last five are the **de-hardcoded program and legal-reference bundles**. They are
regenerated from their YAML/CSV sources (auto-staged by `scripts/git-hooks/pre-commit`,
drift-checked in CI), and are written to **both** this repo and the sail-gtx frontend.
See [PROVENANCE_PIPELINE.md](PROVENANCE_PIPELINE.md) for the full data paths.

### DuckDB API server

For live queries (duty lookup, product search), the frontend calls a DuckDB-backed API server:

```bash
cd frontend && node server.js  # Express + DuckDB, port 3001
```

The server creates a view over `data/timeseries/rate_timeseries_parquet/` and queries it lazily. After rebuilding Parquet, **restart the server** to pick up new partitions.

### Vite dev server

```bash
cd frontend && npm run dev      # Vite, port 5173
cd frontend && npm run dev:all  # Both servers together
```

---

## 10. Command Reference

### Core Pipeline

| Command | Description |
|---------|-------------|
| `Rscript src/01_scrape_revision_dates.R` | Discover new USITC revisions |
| `Rscript src/02_download_hts.R` | Download missing HTS JSON archives |
| `Rscript src/00_build_timeseries.R --full` | Full rebuild (all revisions) |
| `Rscript src/00_build_timeseries.R` | Incremental build (new revisions only) |
| `Rscript src/00_build_timeseries.R --full --core-only` | Full rebuild, skip weighted ETR |
| `Rscript src/00_build_timeseries.R --build-only` | Snapshots + Parquet only, skip downstream |

### Frontend Data

| Command | Description |
|---------|-------------|
| `Rscript scripts/combine_snapshots.R` | RDS snapshots → partitioned Parquet |
| `Rscript scripts/run_daily_from_parquet.R` | Parquet → daily aggregate CSVs |
| `Rscript scripts/prepare_frontend_data.R` | Daily CSVs → frontend JSON exports |
| `cd frontend && node server.js` | Start DuckDB API server (port 3001) |
| `cd frontend && npm run dev` | Start Vite dev server (port 5173) |
| `cd frontend && npm run dev:all` | Start both servers |

### Quality and Diagnostics

| Command | Description |
|---------|-------------|
| `Rscript src/quality_report.R` | Full quality report (requires monolithic RDS) |
| `Rscript src/scrape_us_notes.R --301-products` | Regenerate Section 301 product list from PDF |
| `Rscript src/scrape_us_notes.R --floor-exemptions` | Regenerate floor exemption lists from PDF |

### Optional

| Command | Description |
|---------|-------------|
| `Rscript src/00_build_timeseries.R --refresh-usmca` | Re-download USMCA shares before building |
| `Rscript src/00_build_timeseries.R --use-hts-dates` | Use raw HTS dates instead of policy dates |
| `Rscript src/00_build_timeseries.R --with-alternatives` | Build sensitivity variants |
| `Rscript src/generate_etrs_config.R 2026-04-01 <output_dir>` | Export ETRs-compatible config |

### sail-gtx Rollout (deployed app)

| Command | Description |
|---------|-------------|
| `scripts/hts_automation/run_locally.sh` | End-to-end HTS revision rollout; commits the dataset JSON to **both** `server/data/hts/` and `public/data/hts-explorer/` in sail-gtx (see §1) |
| `scripts/hts_automation/run_locally.sh --revision 2026_rev_10` | Roll out a specific revision |
| `scripts/hts_automation/run_locally.sh --dry-run` | Run every step but write nothing external |
| `python3 scripts/hts_automation/sail_gtx_commit.py --dest-path … --dest-path …` | Push an existing JSON to both sail-gtx locations only (no rebuild); `--dest-path` is repeatable |
