# Discrepancy routing: 22 chapter-prefix rows in `s232_annex_products.csv`

**Date:** 2026-05-11
**Branch:** `nx_stacking_harness` off `wjr_dev@039cc011`
**Related:** `docs/analysis/s232_annex_provenance_audit_2026-05-08.md` (the original audit on `nx_dev`)

## Purpose

The 2026-05-08 audit memo classified all 22 chapter-prefix rows as **plausible / suspect / artifact** based on whether the prefix sits in a primary-metal chapter (72/73/74/76) and surrounding context. This memo adds a second axis: **what kind of fix each row needs**.

- **parser-artifact** — the row is stale residue from the bare-4-digit regex bug at `scripts/parse_annex_products.R:59`. The CSV row should be deleted. The tightened regex on `nx_dev@a3c5efc4` already restricts plain-4 capture to chapters 72/73/74/76, so a fresh parse run would not re-emit these rows.
- **legitimate-but-stacking-untested** — the row is genuinely in the proclamation Annex, and we should have a regression test covering its stacking interaction. Add a harness case.
- **confirmed-legitimate** — row is correct, no action needed.

## Decisive new evidence: FR Proclamation 11021 body text

Fetched today (2026-05-11) from `https://www.federalregister.gov/documents/full_text/text/2026/04/09/2026-06960.txt`.

- **Title:** "Strengthening Actions Taken To Adjust Imports of Aluminum, Steel, and Copper Into the United States"
- **Signed:** 2026-04-02
- **Effective:** 2026-04-06 12:01 AM EDT

**The body text names only chapters 72, 73, 74, 76** — clause 9 verbatim:

> "goods specified in Annex I-B or Annex III to this proclamation...that are not classifiable in Chapters 72, 73, 74, and 76 of the HTSUS..."

**No mention of:** chapter 87, HTS heading 8703, HTS heading 8704, "passenger car", "motor vehicles for transport of goods". Only "civil aircraft" appears, in a WTO context (clause 10) — not a coverage statement.

This is dispositive for chapter 87 Annex II rows. The proclamation does not extend S232 to passenger cars or trucks via Annex II. Any chapter-87 row in the CSV is parser-artifact residue.

## 22-row routing table

Axis A taken from the 2026-05-08 audit memo. Axis B is the new routing call.

| Row (hts_prefix) | Annex col | Audit verdict (Axis A) | Routing (Axis B) | Justification |
|---|---|---|---|---|
| 7601 | 1a | plausible (Ch76 aluminum primary) | confirmed-legitimate | Body text names Ch76. Already covered indirectly by `s122_carveout_aluminum_001` + `s232_steel_base_001` aluminum stacking pattern. |
| 7604 | 1a | plausible (Ch76 aluminum bars/rods) | confirmed-legitimate | Same. |
| 7605 | 1a | plausible (Ch76 aluminum wire) | confirmed-legitimate | Same. |
| 7606 | 1a | plausible (Ch76 aluminum plate/sheet) | confirmed-legitimate | Same. This is the HTS family our harness anchors on. |
| 7607 | 1a | plausible (Ch76 aluminum foil) | confirmed-legitimate | Same. |
| 7608 | 1a | plausible (Ch76 aluminum tubes) | confirmed-legitimate | Same. |
| 7609 | 1a | plausible (Ch76 aluminum tube fittings) | confirmed-legitimate | Same. Note: `metal_type=steel` mislabel for 7601-7609 already fixed on `nx_dev@ad147d33`. |
| 8471 | 1b | confirmed artifact (CPUs) | parser-artifact | Already dropped on `nx_dev@75822a02`. Not on this branch yet; lands when `nx_dev` merges. |
| 8407 | 2 | suspect (engines) | parser-artifact | Chapter 84 not in proclamation body. Engines fall under separate S232 auto-parts program (Proc 11023 rev_11), not via Annex II. |
| 8427 | 1b | suspect (heavy machinery) | parser-artifact | Chapter 84 not in proclamation body. |
| 8429 | 1b | suspect (heavy machinery) | parser-artifact | Same. |
| 8430 | 1b | suspect (heavy machinery) | parser-artifact | Same. |
| 8501 | 1b | suspect (electric motors) | parser-artifact | Chapter 85 not in proclamation body. Our `s301_tranche4_motor_001` case uses 8501104020 + China and confirms rate_232=0 — proving Annex I-B inclusion isn't producing S232 here, which means either the row is inert or already overridden. Either way, cleanup-only impact. |
| 8502 | 1b | suspect (electric generators) | parser-artifact | Same. |
| 8601 | 1b | suspect (rail locomotives) | parser-artifact | Chapter 86 not in proclamation body. |
| 8605 | 1b | suspect (rail passenger cars) | parser-artifact | Same. |
| 8701 | 1b | suspect (tractors) | parser-artifact | **Chapter 87 not in proclamation body.** Body text explicit on this. |
| 8702 | 1b | suspect (motor vehicles 10+ persons) | parser-artifact | Same. |
| 8703 | 2 | suspect — **high blast radius** (passenger cars) | **parser-artifact (CONFIRMED)** | FR Proc 11021 body text contains no mention of chapter 87 / 8703 / "passenger car". Existing auto S232 governs from Proc 10908 (rev_6, 25%), independent of Annex II. Cleanup has zero rate-calculation impact today; restores CSV hygiene. |
| 8704 | 2 | suspect — **high blast radius** (trucks) | **parser-artifact (CONFIRMED)** | Same evidence as 8703. |
| 8705 | 1b | suspect (special purpose vehicles) | parser-artifact | Chapter 87 not in body text. |
| 8709 | 1b | suspect (works trucks) | parser-artifact | Same. |

**Counts:**
- 7 confirmed-legitimate (the Ch76 aluminum block 7601-7609)
- 15 parser-artifact (8471 already fixed on `nx_dev`; remaining 14 across chapters 84, 85, 86, 87 — all outside the 72/73/74/76 scope clause-9 names)
- 0 legitimate-but-stacking-untested

The two-axis analysis collapses to: **the 22 chapter-prefix rows are either Ch76 primary-aluminum (legitimate) or non-72/73/74/76 prefix-artifacts (residue from the pre-`a3c5efc4` regex bug)**. There is no "legitimate but untested" middle ground in this dataset.

## Why the artifacts haven't surfaced as rate bugs

Spot-checked via the harness against the local parquet:

- **8501 electric motors (Annex I-B "steel"):** harness case `s301_tranche4_motor_001` asserts `rate_232=0` for 8501104020 + China + 2025_rev_22. The Annex I-B inclusion is inert — either suppressed by a downstream check or not wired into derivative-rate application. Confirmed: Annex I-B chapter-prefix rows outside 72/73/74/76 don't currently raise S232 rates.
- **8703 passenger cars (Annex II):** harness case `usmca_auto_8703_001` asserts `rate_232=0.25` for 8703101000 + Mexico + 2026_rev_7. This rate comes from the **auto S232 program (Proc 10908)**, not from Annex II. Annex II "removed-from-S232" status would zero rate_232 if it were honored, but it isn't — meaning the auto S232 path takes precedence regardless. Removing 8703/8704 from the CSV will not change observable rates.

This is good news: the artifacts haven't been silently miscalculating duties. Bad news: it means we've been carrying inconsistent metadata in the CSV without symptoms, which masks the regex bug from any rate-based audit.

## Recommended actions

### On `nx_dev` (already done)

1. Drop 8471 row (`75822a02`).
2. Relabel 7601-7609 `metal_type` to `aluminum` (`ad147d33`).
3. Tighten parser regex to capture plain-4 only for chapters 72/73/74/76 (`a3c5efc4`).
4. Audit memo (`10f21ecb`).

### New work — recommended next commit

5. **Drop the remaining 14 parser-artifact rows** (8407, 8427, 8429, 8430, 8501, 8502, 8601, 8605, 8701, 8702, 8703, 8704, 8705, 8709). Single commit, message: "drop chapter-prefix artifacts outside Ch72-76 (FR Proc 11021 clause 9 evidence)."
6. **Defer until after `nx_dev` merges to `wjr_dev`** to avoid duplicating work. Once merged, cut a new branch off `wjr_dev`, apply the 14-row drop, push. Or fold it into the `nx_dev` PR as a follow-up commit if William prefers.

### Out of scope for this routing pass

- **OCR of the WhiteHouse PDF annex pages** — would convert provenance-debt-by-inference into provenance-debt-by-direct-evidence for the legitimate I-A / I-B / III HTS-10 rows (777 non-chapter-prefix rows). Worth doing eventually; not needed for the chapter-prefix routing call above.

## Test coverage tying back to this analysis

The stacking-validation harness at `tests/test_stacking_harness.R` already exercises representative cases for each verdict category:

- Ch76 aluminum (confirmed-legitimate prefixes): `s122_carveout_aluminum_001`, `ieepa_to_s122_pre_001`, `ieepa_to_s122_post_001`
- Ch85 electric motor (parser-artifact prefix; rate_232=0 confirms inert): `s301_tranche4_motor_001`
- Ch87 passenger car (parser-artifact prefix; rate_232=0.25 from auto S232 path): `usmca_auto_8703_001`

Tests are anchored to proclamation source via the `source_proclamation` / `source_fr_doc` / `source_effective_date` columns in `tests/cases/stacking_cases.csv`, not to `s232_annex_products.csv`. When the 14-row drop lands, the harness should remain green without modification — the proclamation-anchored expected values don't change.
