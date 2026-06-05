# Changelog

All notable changes to the tariff rate tracker pipeline and frontend.
Entries follow [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and
track Phase 2 schema normalization sub-slices at sub-day granularity because
each slice interacts with the parity harness.

## [Unreleased] — Data-driven rate universe: de-hardcoding, 2019–2024 backfill, provenance & validation

This tranche (referred to as **Phase 0** in the build code) makes the rate
universe data-driven — generated from the HTS General Notes and Chapter 99 PDFs
rather than hardcoded in app code — extends the panel back to 2019, and adds
per-row plus reference-data provenance with a validation harness that keeps the
generated data from silently drifting.

### Added
- **Historical backfill (2019–2024).** `config/revision_dates.csv` now spans 132
  revisions, `2019_basic` (2019-02-21) → `2026_rev_9` (2026-05-28). The mature
  pre-2025 baseline (§232 steel/aluminum, §301 China Lists 1–4, §201) is carried
  in `2019_basic` and flows continuously into the 2025–2026 sequence. Daily
  aggregates and frontend timelines regenerated across the full span.
- **General Note 3 de-hardcoding** (`src/parse_general_note_3.R`, build-wired in
  `00_build_timeseries.R` under `SAIL_EMIT_GN3`, default on). Extracts the
  Special-program symbol map (GN 3(c)(i)), the Column 2 country list (GN 3(b)),
  and the GSP/AGOA/CBERA beneficiary lists (GN 4/16/7) per revision into
  `resources/gn3_program_symbols.csv`, `resources/gn3_column2_countries.csv`, and
  `resources/gn_program_countries.csv`. Incremental + carry-forward (only new
  revisions are fetched); precision-first census mapping (an unmatched name gets
  no code, so a miss falls back to the safe MFN default rather than fabricating a
  preference). Reviewed reference data: `resources/fta_partners.csv`,
  `resources/country_name_aliases.csv`.
- **Frontend program bundles** (`scripts/emit_program_{symbols,countries,requirements}.R`)
  → `frontend/public/data/program_symbols.json`, `program_countries.json`,
  `program_requirements.json`. The program-symbol map, Column 2 list,
  country→program membership, and per-program eligibility requirements ("missing
  facts" behind a suggested preference) are no longer constants in app code.
  Requirements are curated in `config/program_requirements.yaml` and validated
  against the parsed symbol map.
- **Legal-reference reconciliation** (`src/extract_legal_refs.R`,
  `config/legal_reference.yaml`, `config/duty_citations.yaml`,
  `resources/ch99_legal_refs.csv`) → `legal_refs.json` / `duty_citations.json`.
  Machine-extracts the proclamations/EOs/CBP messages each Chapter 99 authority
  cites, per revision, with Federal Register cites and verification status.
  Build-wired under `SAIL_EMIT_LEGAL_REFS` (default on, incremental).
- **Per-row rate provenance** — `base_rate_source` column
  (`'own'` / `'inherited:<parent_htsno>'` / `'unresolved'`) added in
  `src/04_parse_products.R` (via the `htsno_stack`) and to `RATE_SCHEMA`
  (`src/helpers.R`). Records which HTS line each base rate came from, so rate
  inheritance is auditable.
- **Rate-validation harness** (`src/emit_rate_validation.R`), build-wired,
  report-only by default; `SAIL_VALIDATE_RATES=strict` aborts on a correctness
  violation. Invariants: C1 `base_rate ≤ statutory_base_rate`, C2 finite/≥0, plus
  coverage bands Q3 (symbol coverage), Q4 (`base_rate_source` resolved), Q5
  (Column 2 resolves), Q6 (GSP/AGOA/CBERA beneficiary counts). Writes
  `output/quality/rate_reconciliation_base*.csv`.
- **Quality-metrics harness** (`src/emit_quality_metrics.R`) — per-revision
  statistical audit from the on-disk ch99 caches, regenerated on every build mode
  so `output/quality/` never goes stale.
- **Statutory total** — `mean_total_statutory_all_pairs` in
  `src/09_daily_series.R`, the conservative per-shipment total (statutory base +
  additionals), reported alongside the effective (preference-weighted) mean.
- **Bundle freshness automation** — `scripts/git-hooks/pre-commit` regenerates the
  five JSON bundles when their YAML/CSV sources are staged;
  `.github/workflows/bundles-fresh.yml` fails CI on drift.

### Changed
- **Duty-calc ingestion is JSON-only** — the timeseries build no longer ingests
  the auxiliary HTS CSV for duty calculation, removing a data-contract violation.
- **§232 provenance re-architected** — `s232_reason` now derives from the annex
  tier (`s232_annex`: `annex_1a` primary metal, `annex_1b`/`annex_3` derivative)
  plus the covered metal (`s232_metal`: steel/aluminum/copper), not the ambiguous
  9903.82 reporting code. `s232_annex` / `s232_metal` added to `RATE_SCHEMA`.

### Documentation
- Swept `README.md`, `docs/build.md`, `docs/methodology.md`,
  `docs/revision_changelog.md`, `docs/data-pipeline-README.md`,
  `docs/CALCULATION_LOGIC.md`, `docs/pipeline-operations.md`, and
  `docs/PROVENANCE_PIPELINE.md` to the 2019–2026 scope and the new
  de-hardcoding / provenance / validation stages.

## [Unreleased] — Phase 2.5 scaffolding

### Added
- `scripts/triage_parity_failures.R` — groups `[FAIL]` lines from the parity
  harness into actionable buckets by `(column, sign, denorm_bucket, diff_bucket)`
  signature, writes representative cases to `tests/parity_failures_triaged.csv`.
- `tests/ir/parity-cases.md` — living catalog of every parity failure class
  the harness has surfaced, with root cause, fix, and representative case per
  section. Seeded with the eight classes fixed in Phase 2b.
- `docs/adrs/001-denorm-state-pattern.md` — architectural decision record for
  the "emitter as serializer of denorm_state" pattern.
- `src/denorm_state_contract.R` — postcondition validator that asserts every
  `denorm_state` slot is present with the expected shape before emit.
- `frontend/src/types/rate-response.ts` — runtime validator for `ProductRate`
  responses, no new dependency. Used by Phase 3 cutover to lock the schema.
- `frontend/server.js` — `USE_NORMALIZED_GAPFILL` feature flag (default
  `false`), `gapfillFromNormalized()` stub, and `SHADOW_LOG_NORMALIZED=1`
  shadow traffic logger. All scaffolding is feature-flagged off and has zero
  runtime effect until Phase 3 flips the flag.

### Changed
- `docs/normalized-schema.md` — addendum documenting the D1–D7 resolutions,
  new layer-1 `s232_annex` column, new layer-3 `country_scope` / `rate_type`
  columns, precedence tier semantics (1/5/7/10), layer-4 `exemption_type`
  enum additions, and the `denorm_state` slot contract.

### Deprecated
- `__synthesized` flag on `ProductRate` — marked `@deprecated` in
  `frontend/src/types/tariff.ts`. Will be removed in Phase 3d cutover.

## [Unreleased] — Phase 2b (this session, parity-driven iteration)

### Added
- `src/07_emit_normalized.R` IEEPA reciprocal block — serializes
  `denorm_state$country_ieepa` directly, eliminating the parallel aggregation
  that drove the D1 failure class (EU floor countries off by +0.1).
- `src/07_emit_normalized.R` S232 country deals block — emits one layer-3 row
  per `(program × deal_product)` from `denorm_state$s232_deals`, with
  `country_scope` and `rate_type` honoring deal semantics. Precedence 10.
- `src/07_emit_normalized.R` S122 emission across layers 2 / 3 / 4 — per-country
  layer-2 rate, blanket layer-3 applicability, per-HTS8 layer-4 exemptions.
- `src/07_emit_normalized.R` USMCA share expansion — now emits layer-4 rows
  for `ieepa_reciprocal`, `ieepa_fentanyl`, **and `section_122`**, plus a
  separate `usmca_section_232_auto` row with `share = usmca_share *
  us_auto_content_share` for auto / MHD products.
- `src/07_emit_normalized.R` heading/derivative overlap block — per-hts10
  layer-3 rows at precedence 7 with the post-`pmax` statutory_rate captured
  from `denorm_state$heading_overlap`.
- Layer-1 `s232_annex` column — populated from `denorm_state$product_annex`,
  enables the post-annex `nonmetal_share = 0` override in
  `apply_stacking_rules` to fire uniformly across both code paths.
- `--parallel N` flag on `src/00_build_timeseries.R` — `parallel::mclapply`
  over the per-revision loop on Linux, with a serial post-pass for the delta
  computation so on-disk artefacts are byte-identical to serial runs.

### Changed
- `src/06_calculate_rates.R::calculate_rates_for_revision` — captures eight
  intermediate state values into `denorm_state_*` locals and bundles them into
  a `denorm_state` list passed to `emit_normalized_revision`. This replaces
  the prior "emitter re-derives from raw inputs" design.
- `src/06_calculate_rates.R::apply_232_derivatives` — returns
  `heading_overlap` tibble alongside `rates` and `deriv_matched`, capturing
  the post-`pmax(heading_rate, deriv_rate)` value per overlap hts10.
- S232 auto / passenger / light_truck layer-3 rows now bake the assembly
  rebate into `statutory_rate` (`auto_rate - rebate_deduction`) so country
  deal floor rows at precedence 10 cleanly replace the rebated value. The
  layer-4 `auto_assembly_rebate` exemption is no longer emitted.
- `src/resolve_rate_normalized.R::.compute_authority_rate` — new
  `.apply_rate_type()` helper centralizes floor/surcharge/passthrough math
  for both layer-2 and layer-3 winners. `section_122` joins
  `ieepa_reciprocal` and `ieepa_fentanyl` in the layer-2-driven authority set.
- `src/resolve_rate_normalized.R::resolve_rate_from_normalized` — applies
  both MFN exemption shares (from `mfn_exemption_shares.parquet`) and USMCA
  per-product shares (from layer 4) to `base_rate` before the stacking step.
  Reads `s232_annex` from layer 1 and sets it on the wide tibble.

### Fixed
- IEEPA aggregation for EU / Japan / Korea floor countries — `rate_ieepa_recip`
  was +0.1 off because my first emitter `arrange(desc(phase_rate))` inverted
  `first(rate_type)` semantics vs. denorm's `type_priority` sort. Now the
  emitter serializes denorm's computed `country_ieepa` directly.
- S301 applied to non-China countries — layer 3 rows had `country = NA`.
  Added `country_scope` column with China census code.
- Section 232 country deal floors and surcharges — completely missing from
  layer 3. Now emitted as precedence-10 rows with `rate_type='floor'`.
- Section 122 silently zero — layer 3 had no blanket applicability row, so
  the resolver never picked up the rate. Fixed across all four layers.
- CA/MX auto `base_rate` missing USMCA share reduction — resolver now
  queries layer-4 USMCA rows and applies share to `base_rate`.
- Post-annex `nonmetal_share = 0` override not firing in the normalized path
  — resolver now provides `s232_annex` to `apply_stacking_rules`.
- Heading + derivative overlap products computed wrong — prefix derivative
  row with metal scaling was winning over the heading blanket, giving
  `deriv_rate * metal_share` instead of the intended `pmax`.

### Architectural
- **Established the "emitter as serializer of denorm_state" pattern.** See
  `docs/adrs/001-denorm-state-pattern.md` for full rationale. Mandates that
  the emitter reads denorm's computed intermediate state directly rather
  than re-implementing transformations. Eliminates the class of parity
  bugs that drove the 916 failures on the first end-to-end run.

## Earlier phases

See `docs/adrs/` and individual commit history for Phase 0 (Ch99 code
resolution), Phase 1 (frontend synthesis stopgap), and the initial Phase 2b
first slice.
