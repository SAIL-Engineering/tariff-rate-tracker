# HTS 8471.50.0150 — "Pure metal product" S232 over-classification

**Date:** 2026-05-08
**Author:** Nishanth Palaniswami
**Status:** Triage complete; root cause not yet isolated. Documented as **validation seed #1** for the 22 flagged rate-accuracy discrepancies.
**Branch:** `nx_dev`

## Summary

In the local `local`-mode frontend at revision `2026_rev_7` (build 2026-05-04→05), HTS `8471.50.0150` (CPUs / processing units) imported from China shows a 50% effective rate composed of S301 25% + S232 25%, with the badge label _"232 takes full precedence (pure metal product)"_. The label requires `metal_share >= 1` (`DutyStackBreakdown.tsx:412`), but the BEA-derived metal share for this HTS is **0.0084406 (~0.84%)**. The pipeline is overriding the share to 1.0 somewhere, or applying a derivative path 8471 should not match.

**Blast radius:** Chapter 84 is one of the highest-value import chapters. CPUs/laptops from China are high-volume. If real, this is the kind of overstatement the 22 flagged discrepancies will look like at scale.

## Evidence

### 1. `s232_derivative_products.csv` does not list HTS 8471

```
$ rg '^8471|,8471' resources/s232_derivative_products.csv
(no matches)
```

The file's HTS prefixes start at 7-series (e.g., `76141050` aluminum cookware, `73089030` steel structures). Chapter 84 is absent entirely. So `apply_232_derivatives()` (`src/06_calculate_rates.R:252`) should not match 8471.50.0150 against `deriv_products`.

### 2. `metal_content_shares_bea_hs10.csv` shows 8471500150 has trace metal content

```csv
hs10,naics,bea_detail_code,steel_share,aluminum_share,copper_share,other_metal_share,metal_share
8471500150,334111,334111,0.0025048898213443143,0.0013307871093320496,0.0031135376832511,0.0014913853860725368,0.0084406
```

Row 17032. Total `metal_share = 0.84%`. This is what we'd expect for a CPU — small steel/aluminum/copper in casing, heat sink, traces.

### 3. The frontend label fires only when `metal_share >= 1`

```tsx
// frontend/src/components/duty-lookup/DutyStackBreakdown.tsx:412
{rate.rate_232 > 0 && nonmetalShare === 0 && rate.metal_share >= 1 && (
  <Badge ...>232 takes full precedence (pure metal product)</Badge>
)}
```

So the API row served for 8471500150 must have `metal_share = 1.0` and `rate_232 > 0` for this badge to render. Both conditions are wrong relative to the BEA file.

### 4. The user reported S232 reference `9903.78.01`

`9903.78.01` is the steel-derivative anchor in Chapter 99. The user observed this in the right-panel detail. So the pipeline is matching 8471500150 to the steel-derivative path despite the CSV not listing it.

## Hypotheses (ordered by likelihood)

### H1 — Heading/derivative-overlap reset path (lines 432–446)

`06_calculate_rates.R:432` resets `metal_share = 1.0` for products in `heading_derivs` — products that have both a heading rate and a derivative match. If 8471500150 is somehow getting flagged as `heading_derivs` (perhaps via a Ch99 footnote in `9903.78.01` that scopes more broadly than the CSV expects), the reset would explain `metal_share = 1.0`.

**Verification:** query the Parquet for `hts10='8471500150'`, country 5700 (China), revision `2026_rev_7`. Inspect `metal_share`, `rate_232`, `nonmetal_share`, plus any `derivative_type` / `s232_anchor` columns.

### H2 — BEA join missing in the read path the API uses

`apply_232_derivatives()` only loads `metal_shares` for derivative-matched HTS (`unique(rates$hts10), deriv_matched` at `06_calculate_rates.R:369`). If 8471500150 is matched as a derivative through a code path that bypasses the BEA join, the `coalesce(metal_share, 1.0)` at line 375 falls back to 1.0.

**Verification:** check whether 8471500150 appears in `deriv_matched` in the rev_7 build, vs. whether it gets `metal_share` from `metal_content_shares_bea_hs10.csv`.

### H3 — `s232_annex_products.csv` (April 2026 annex) brings 8471 in

The April 6 annex restructuring (`docs/analysis/section_232_review_memo_2026-04-06.md`) added a new derivative scope. `resources/s232_annex_products.csv` was scaffolded for this. If 8471 prefixes were added there for the 2026 annex, that's the simplest explanation — the question becomes whether the annex genuinely covers CPUs or whether the scope is too broad.

**Verification:** `rg '^8471' resources/s232_annex_products.csv` and cross-check against the Federal Register annex text.

### H4 — Frontend bug only

Pipeline produces correct partial `metal_share` and reduced `rate_232`, but the frontend conflates a derived `effective_metal_share` with the raw `metal_share` field, triggering the badge incorrectly.

**Verification:** read the actual API response for 8471500150 / China / 2026-05-05 and inspect every `metal_*` and `rate_232*` field.

## Recommended verification path (next session)

A single DuckDB query against the local parquet ends the speculation. Packaged as `scripts/verify_8471_metal_share.R` (commit `b8521f56`):

```bash
Rscript scripts/verify_8471_metal_share.R
```

The script:
1. Opens the parquet at `data/timeseries/rate_timeseries_parquet/`, filters to the target row, `glimpse()`s every column.
2. Reads `metal_share` from the captured row and prints a verdict mapping it to H1–H4:
   - `metal_share == 1.0` → H1 (heading/derivative reset) or H2 (BEA join miss).
   - `metal_share ≈ 0.0084` → H4 (frontend-only — pipeline is correct, badge condition is wrong).
   - `metal_share ≈ 0.5` → BEA fallback fired (8471500150 missing from BEA join).
   - anything else → unexpected, capture and re-triage.
3. Greps `resources/s232_annex_products.csv` for `8471` prefixes (H3 check).
4. Confirms the BEA row for `8471500150` (sanity check that the source data hasn't drifted).

After the row is inspected, the next step is either (a) add a regression test in `tests/test_rate_calculation.R` asserting the correct `metal_share` and `rate_232` for this HTS+country+date triple, or (b) document `8471500150` as known-correct under the annex scope and adjust the badge condition.

## Why this is validation seed #1

Per the 2026-04-09 huddle item 3 (Nishanth + William, due 2026-04-22, currently overdue), the deliverable is a regression test set built from known discrepancy cases. This HTS+country+date triple is the cleanest first case:

- It came from real frontend exploration, not a synthetic corner case.
- It's mechanically diagnosable (one DuckDB query closes the question).
- The expected behavior is unambiguous (a CPU is not a pure metal product).
- High-volume HTS so blast radius is real.

Whatever the resolution, the row should land in the regression set and any policy clarification should land in `docs/methodology.md`.

## References

- `frontend/src/components/duty-lookup/DutyStackBreakdown.tsx:412` — badge condition
- `src/06_calculate_rates.R:230–500` — S232 derivatives + metal scaling block
- `resources/s232_derivative_products.csv` — derivative HTS list (does not contain 8471)
- `resources/metal_content_shares_bea_hs10.csv:17032` — BEA share for 8471500150
- `docs/analysis/section_232_review_memo_2026-04-06.md` — prior annex review
