# Changelog

All notable changes to the tariff rate tracker pipeline and frontend.
Entries follow [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and
track Phase 2 schema normalization sub-slices at sub-day granularity because
each slice interacts with the parity harness.

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
