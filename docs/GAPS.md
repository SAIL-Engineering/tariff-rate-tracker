# Known Gaps — Data, Logic, Coverage, and Provenance

**Last updated:** 2026-06-04
**Scope:** what the tariff-rate pipeline and the duty-provenance/legal layer do **not**
yet have, why, and — per gap — whether it is **closeable through correct data
provenance / PDF (HTS + Federal Register) parsing**, the maintainable path we use
everywhere else, vs. whether it needs an input we cannot parse (trade/CBP data,
legal review, or a human-provided file).

This document is the honest counterpart to the provenance feature: the provenance
layer explains *why a rate is what it is*; this file explains *where we still
cannot fully explain or compute it*, so nothing reads as more complete than it is.

## How to read the closeability flag

| Flag | Meaning |
|------|---------|
| ✅ **Parseable** | Closeable with the maintainable pattern we already use — parse the HTS revision JSON/PDF and/or the Federal Register proclamation/EO, emit a column or resource, auto-applies to every future revision. No human input beyond a one-time parser. |
| ⚠️ **Parseable structure, external calibration** | The *coverage/structure* (which HTS codes, which legal authority) is parseable, but the *number that makes it non-dormant* (a trade-weighted share, a metal-content fraction) needs import/CBP data we do not parse. We can light up the framework and provenance; we cannot calibrate the magnitude from PDFs. |
| ❌ **Not parseable** | Needs data that does not exist in any HTS/FR document — per-shipment broker billing, trade-weighted import values, BEA/Census micro-data, or a legal determination. Provenance can *describe* it; parsing cannot *close* it. |

---

## A. Data gaps

### A1. Per-metal shares (`steel_share` / `aluminum_share` / `copper_share`) are 0 in the unweighted build
**State:** Only the aggregate `metal_share` is populated (≈703k §232 rows in `2026_rev_9`);
the per-metal split columns are all 0. The per-metal content split comes from the
BEA metal-content model (`resources/metal_content_shares_bea_hs10.csv`), which is
only exercised in the **weighted** build (requires `config/local_paths.yaml` +
import weights — out of scope per the backport plan).
**Impact:** The §232 metal split for *stacking* and *provenance* cannot rely on
trade-weighted per-metal shares.
**Mitigation already shipped:** the provenance metal is now taken from the **annex
product list's `metal_type`** via the new `s232_metal` column (06 → `RATE_SCHEMA`
→ `attach_duty_provenance`). This closes the *provenance* need (we can name the
covered metal) without weights.
**Closeability:** ⚠️ *Parseable structure, external calibration.* The covered metal
(coverage source) is parseable and now emitted. The trade-weighted *magnitude* of
each metal's content needs BEA/Census import data — not in any PDF.

### A2. Post-annex copper coverage is unwired
**State:** The copper product list (`resources/s232_copper_products.csv`, 81 rows)
maps to the **legacy** founding heading `9903.78.01` only. There is **no** annex-era
copper wiring: `copper_share` is 0 everywhere, the list does not map into the
`9903.82` annex reporting codes, there is no Note 16 subdivision layer, no
inclusion-notice table, and no Proc 11032 (eff. 2026-06-08, `9903.82.20–.26`)
date routing.
**Impact:** Copper derivatives covered by the April-2026 annex / June-2026
expansion are not captured as annex-era §232 copper. The provenance reasons
`s232_copper` / `s232_copper_derivative` now exist and will light up the moment 06
emits `s232_metal == 'copper'` under an annex bucket — but 06 does not yet route
copper into the annex.
**Closeability:** ✅ **Parseable.** The annex HTS revision (subchapter III, Note 16
subdivisions), the copper product list, and Proclamations 10962 / 11021 / 11032
define the coverage. Same pattern as the steel/aluminum annex parse: extend the
annex product list with copper `metal_type` rows + Note 16 subdivisions, route
to `9903.82`, gate Proc 11032 on its 2026-06-08 effective date. This is the
**scoped backend task** and the `s232_metal` plumbing is already in place for it.

### A3. `deriv_type` is NULL across the dataset
**State:** The derivative-metal-type column is unpopulated; the stacking
`nonmetal_share` per-metal branch falls back to the aggregate.
**Mitigation:** provenance no longer depends on `deriv_type` — it uses
`s232_annex` (tier) + `s232_metal`.
**Closeability:** ✅ **Parseable.** The derivative metal is in the annex/derivative
product lists' `metal_type`; the same `s232_metal` derivation can backfill
`deriv_type` if the stacking math needs the per-metal branch.

### A4. Semiconductor (Note 39, `9903.79`) qualifying share
**State:** Framework present (`resources/s232_semi_products.csv`,
`resources/semi_qualifying_shares.csv`); binary qualifying-share model (only
AI-accelerator HTS carry the 25% from 2026-01-16).
**Closeability:** ⚠️ *Parseable structure, external calibration.* The covered HTS
list is parseable from Note 39. The *fraction* of a heading that is the qualifying
(AI-accelerator) article is a trade-mix input, not a PDF fact.

### A5. Subdivision (r) auto-parts blend
**State:** Framework present (`resources/s232_subdivision_r_products.csv`,
`resources/subdivision_r_dataweb_signal.csv`) but **dormant** — all shares 0.
**Closeability:** ⚠️ *Parseable structure, external calibration.* The product set
is parseable; the three-way blend weight needs per-prefix metal-content trade data
(CBP entry summaries / DataWeb), not a PDF.

### A6. Zero-metal-content carve-out (`9903.82.01`, Note 16(a))
**State:** Framework present in `config/policy_params.yaml`
(`section_232_annexes.exemptions.zero_metal_content`); dormant
(`aggregate_share: 0`).
**Closeability:** ⚠️ *Parseable structure, external calibration.* The carve-out
*rule* is parseable from Note 16(a); the *fraction* of imports under each annex
product that contains zero metal needs CBP entry / industry data.

### A7. Trade-weighted effective rates (import weights)
**State:** Unweighted is the default; there is no `config/local_paths.yaml`, so the
import-weight infrastructure, GTAP aggregation, and the weighted ETR path are off.
The base-rate "effective" blend (preference utilization) uses Census MFN HS2×country
shares, which **are** present; the §232 per-metal weighting is what is missing.
**Closeability:** ❌ **Not parseable.** Import weights are trade-value micro-data.
Out of scope per the backport plan; revisit only if weighted ETRs are needed.

### A8. Pre-2025 historical coverage
**State:** The machine legal-ref + timeseries coverage is strong for 2024–2026
(54 full revisions + 2 of 2023). A true multi-year pre-2025 backfill has only the
documented `2024_basic` anchor recipe, not a full series.
**Closeability:** ⚠️ *Parseable structure, external calibration.* The HTS
revisions are downloadable and parseable; accuracy of a deep backfill depends on
period-correct §301 list coverage and historical base rates — parseable but
labor-intensive to verify per period.

### A9. Per-shipment broker billing
**State:** Broker/entry-line billed duty arrives only via **user file upload** (per
shipment). It is not in our data and never will be.
**Closeability:** ❌ **Not parseable** — by design. This is an *input*, not a gap to
close. The provenance/variance layer's job is to *reconcile against* it, not
reproduce it.

---

## B. Logic / calculation gaps

### B1. Statutory→effective shown on additional duties without explanation *(frontend)*
**State:** Additional-duty cards (IEEPA / §232 / §301) render
"Statutory: X → Effective: Y" using the same visual as the base rate, but the
mechanism is entirely different and unexplained. Two real mechanisms make them
differ:
- **IEEPA reciprocal floor** — `rate_ieepa_recip` is recomputed as
  `max(0, floor_rate − base_rate)` ([06:2511-2513](../src/06_calculate_rates.R#L2511-L2513)),
  captured against the pre-floor `statutory_rate_ieepa_recip`
  ([06:2456](../src/06_calculate_rates.R#L2456)). Effective **>** statutory: the
  floor tops the line up so `base + reciprocal = floor`.
- **Stacking `nonmetal_share` scaling** — IEEPA reciprocal & S122 apply only to the
  non-metal portion of a §232 product. Effective **<** statutory.

**Closeability:** ✅ **Closeable now (frontend)** — the direction (>/<) plus the
provenance reason (`ieepa_recip_floor` vs derivative) identifies which mechanism
applies; explain it with the source. *(Being addressed in the frontend pass.)*

### B2. EU-auto 25% floor — baseline vs counterfactual (plan item G8)
**State:** Flagged for verification: whether the EU 232+MFN auto floor
(15%→25%, eff. 2026-05-04) is baseline policy (we would be under-collecting EU
autos) or a scenario patch.
**Closeability:** ✅ **Parseable** — resolved by reading the controlling
proclamation's effective-date language; the patch-DSL framework supports it.

### B3. §232 USMCA-eligibility refresh post-annex (plan item G5)
**State:** Backported in `dade9838`; confirm it restored USMCA eligibility for
annex 1a/1b/3 auto/MHD products outside ch. 72/73/76.
**Closeability:** ✅ **Parseable / verify** — driven by HTS USMCA program
indicators per HTS10.

### B4. `unresolved_s201` — 1,848 rows (see Section C)
Solar §201 codes mapped to the 201 range but with no extracted rate. Detailed in C.

---

## C. Unresolved Chapter 99 codes

From `output/quality/ch99_country_scope_triage.csv` (37,474 code×country×revision
rows). The pipeline classifies each Ch99 code's resolution status; the build
metrics (`src/emit_quality_metrics.R`) regenerate this on every timeseries run, so
it never goes stale.

| resolution_status | rows | interpretation | closeable? |
|---|---:|---|---|
| `handled_by_s232_extractor` | 18,379 | resolved | — |
| `not_duty_relevant_trq` | 13,075 | TRQ headings — correctly **not** duty-driving | — (correct exclusion) |
| `handled_by_s301_config` | 2,729 | resolved | — |
| **`unresolved_s201`** | **1,848** | **§201 (solar) codes in range, no rate extracted** | ✅ **Parseable** |
| `handled_by_s201_extractor` | 446 | resolved | — |
| `handled_by_ieepa_extractor` | 339 | resolved | — |
| `ieepa_exclusion_no_rate` | 327 | IEEPA **exclusions** — correctly 0 rate | — (correct) |
| `handled_by_fentanyl_extractor` | 277 | resolved | — |
| `handled_by_s122_config` | 54 | resolved | — |

**The only genuinely-unresolved bucket is `unresolved_s201` (1,848).** These are
§201 safeguard codes (e.g. `9903.45.2x` solar) whose Year-N rate is not extracted
from the note (HTS "general" shows the Year-1 30%, but the correct Year-8 is
14.5%). Everything else is either resolved or a correct non-duty/exclusion class.
**Closeability:** ✅ **Parseable** — the §201 solar extractor + `s201_solar_products.csv`
+ the proclamation's annual step-down schedule close this; the resource file
already exists, the extractor needs to read the Year-N rate from the note.

---

## D. Legal / provenance reference gaps

### D1. Country-specific IEEPA EOs — metadata unverified
**State:** `eo_14245_venezuelan_oil`, `eo_14323_brazil`, `eo_14329_russia`,
`eo_14380_cuba`, `eo_14382_iran` are in `config/legal_reference.yaml` with
`verified: false` (Federal Register citations/dates pending).
**Closeability:** ✅ **Parseable** — Federal Register presidential-documents search
+ the EO PDF resolve citation, FR number, and signing date; flip `verified: true`
once confirmed.

### D2. Copper proclamations — FR citations pending
**State:** `proc_10962_copper_2025` (`federal_register: null`, `verified: false`)
and `proc_11032_copper_derivatives_2026`
(`source_status: federal_register_public_inspection_pending_publication`,
`requires_post_publication_recheck: true`).
**Closeability:** ✅ **Parseable** — proc 10962 from the FR archive now; proc 11032
the moment it publishes (the pending-publication flag already tells the UI to
caveat it).

### D3. Machine legal-ref layer does not reach pre-2024 revisions
**State:** `src/extract_legal_refs.R` extracts U.S. Note proclamations/EOs per
release from the USITC reststop PDF. Works 2024+; pre-2024 releases return an HTML
error (no PDF at that endpoint), so only 2 of 2023 are machine-sourced.
**Closeability:** ⚠️ *Parseable from an alternate source.* The reststop endpoint
lacks pre-2024 PDFs; the USITC archive / govinfo may carry them, but it is a
different fetch path, not the maintainable per-release one. Recent revisions
(the priority) are fully covered.

### D4. `verified: false` reference entries await legal review
**State:** The audited reference table separates `verified` (metadata confirmed
against an official source) from current applicability. Entries still
`verified: false` need a legal pass before their badge flips from
"reference · pending" to "reference ✓".
**Closeability:** ❌ **Not parseable** — this is a human legal-review step by
design, not an extraction.

---

## E. Frontend explainability gaps *(in-progress this pass)*

| Gap | State | Closeable |
|---|---|---|
| E1. IEEPA "active" pill is misleading | Pill shows calc-time `active` even though IEEPA collection **ended 2026-02-24** and refunds may apply | ✅ pill made temporal/legal-aware + refund notice |
| E2. Statutory→effective unexplained on additional duties | See B1 | ✅ reframed with mechanism + source |
| E3. Percentage decimals inconsistent | `formatRate` 2dp vs `formatRateShort` 1dp vs `formatPct` 1dp vs inline `toFixed(0/1/2)` | ✅ standardize duty surfaces on 2dp |
| E4. IEEPA refund / recovery commentary absent | Flags + "why SAIL differs from broker" do not mention the ended-collection / refund / litigation posture | ✅ `ieepa_refund` 4-layer block now in the bundle; wiring into Flags + reconciliation |

---

## F. Normalized-layer parity *(measured 2026-07-30)*

### F1. The normalized resolver diverges from the denormalized pipeline on 27% of sampled rows

**State:** `Rscript tests/test_normalized_parity.R` — 2,146 OK, **798 FAIL**
across **261 distinct (hts10, country, revision) cases**; exit code 2.

The failures have a single root cause with a cascade:

| Field | Failures |
|---|---|
| `rate_232` | 244 |
| `total_additional` | 251 |
| `total_rate` | 251 |
| `rate_ieepa_fent` | 21 |
| `base_rate` | 17 |
| `rate_ieepa_recip` | 9 |
| `rate_s122` | 5 |

`total_additional` and `total_rate` are downstream of `rate_232`, so the 244
`rate_232` divergences produce essentially all of the rest.

Concentrated in the chapters where §232 is heading- or content-driven rather
than a flat blanket: **87 (86), 84 (54), 85 (34), 74 (14)**, then 83, 94, 38,
82, 76, 34. The normalized resolver returns the raw blanket rate where the
denormalized pipeline returns the heading rate or the metal-content-scaled
rate — e.g. `8703230120/2010/2025_rev_20` denorm `0.160408` (auto heading rate
after the rebate) vs norm `0.237625` (`0.50 × 0.47525` metal share); the
resolver is treating a passenger vehicle as a metal derivative.

**Impact: NOT a production defect today.** The MotherDuck push and the frontend
read the DENORMALIZED `data/timeseries/rate_timeseries_parquet`.
`output/normalized/` is a Phase-2 dual-write consumed only by this parity test
and `src/resolve_rate_normalized.R`. The gap matters because the parity test
exists to prove the normalized layer can eventually replace the denormalized
one, and at 27% divergence it cannot.

**Correction to the record:** this suite was twice described inaccurately during
the 2026-07-30 pass — first as an ERROR (a misclassification by
`tests/run_all_tests.R`, fixed in `0aee9569`), then as passing with exit 0. The
second claim came from reading the exit code of a `| tail` pipeline rather than
of `Rscript`, which reports tail's status. Commit `6aa4c910` asserts it exits 0;
that assertion is wrong. Run it unpiped, or via `tests/run_all_tests.R`.

**Closeable:** yes, but it is a port of the heading-program and metal-content
logic from `src/06_calculate_rates.R` into `src/resolve_rate_normalized.R`, not
a small patch. Related: the plan's T4.1 (`rate_s301fl` / `rate_s301br` /
`rate_s338` absent from the resolver entirely).


## Closeability summary

**✅ Parseable now (maintainable, auto-applies to future revisions):** A2 post-annex
copper, A3 deriv_type, B2 EU-auto floor, B3 USMCA refresh, C `unresolved_s201`,
D1 country-EO metadata, D2 copper FR citations, E1–E4 frontend.

**⚠️ Parseable structure, needs external calibration data:** A1 per-metal weighted
shares, A4 semi qualifying share, A5 subdivision-(r) blend, A6 zero-metal-content,
A8 pre-2025 backfill, D3 pre-2024 machine refs.

**❌ Not parseable (needs trade/CBP micro-data or human input):** A7 import weights,
A9 per-shipment broker billing, D4 legal review sign-off.

**Bottom line:** every *coverage and provenance* gap is parseable — the metal, the
annex tier, the legal authority, the §201 step-down, the EO metadata all live in
HTS/Federal Register documents we already parse, and the new `s232_metal` +
`ieepa_refund` plumbing is built for exactly that. What is **not** parseable is the
*magnitude* of trade-weighted effects (metal-content fractions, qualifying shares)
and per-shipment broker data — those are inputs, and the provenance layer's role is
to describe and reconcile them, not invent them.
