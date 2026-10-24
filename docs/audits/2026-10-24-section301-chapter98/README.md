# Section 301 Chapter 98 and cross-program claim identity

Base: `f21d50b7` on the original tracker branch `wjr_dev`. This continues the
[Section 338 / Section 122 work](../2026-10-24-section338-valuation/README.md).
No timeseries/revision rebuild, MotherDuck write, publication, push, workflow
change or deployment was performed. SAIL and Trade Intelligence were unchanged.

## Executable decisions

The Section 301 extractor now retains each Chapter 98 clause, its exact named
reporting-heading targets, source-text hash, and the revision-valid Chapter 98
inventory. The R compiler reuses the shared valuation-expression generator:

- A proper Chapter 98 claim exempts the named additional duties except for the
  expressly listed repair/alteration/processing and assembly provisions.
- 9802.00.40/.50/.60 use the value of the qualifying work. Section 301 does not
  import Section 232's different full-value treatment of 9802.00.60.
- 9802.00.80 deducts qualifying U.S. product value from the article value.
- A selected code, eligibility alone, or a modeled share is insufficient.
  Missing entitlement/value, an invalid provision or inconsistent values cannot
  become zero liability or a complete total.
- Product exclusions and Chapter 98 requests can coexist. The named exclusion
  continues to remove its specific charge; it does not need unrelated valuation
  inputs merely because a second claim was selected.
- Cross-program unchanged-duty relationships now require a source-identified
  **Section 301 product exclusion**. Attaching a different claim to a Section 301
  rule is insufficient. Unreviewed Chapter 98 effects on Section 232 stay
  `claim_not_priced`, instead of being treated as unchanged by an overly broad
  Section 301 relationship. This correction applies to legacy metals, pre-March
  metals, note 16, Section 122 and Section 338 composition.

No HTS examples are special-cased. Ordinary unclaimed Section 301 parameters and
aggregate methodology are unchanged by the Chapter 98 adapter.

## Original sources and chronology

The source/compiler audit reconciles **827 action valuations across all 55
configured revisions**. It does not attest complete Section 301 coverage or
Chapter 98 entitlement. Each operative clause comes from that revision's
codification; the following originals independently corroborate the treatment:

1. [August 2018 notice, Annex A and Annex C](https://www.govinfo.gov/content/pkg/FR-2018-08-16/pdf/2018-17709.pdf),
   pages 40825–40826 and 40838, introduces the repair/assembly exceptions and
   replaces the earlier blanket Chapter 98 wording for List 1.
2. [September correction, Annex B](https://www.govinfo.gov/content/pkg/FR-2018-09-28/pdf/2018-21303.pdf),
   page 49155, corrects the missing word “under,” effective back to August 23.
   The PDF text layer **omits this annex**. The retained OCR and visual review of
   the original page recover the exact deletion/insertion operands. The audit
   applies those operands; it does not silently repair the original text.
3. [September 2024 notice, Annex A.4](https://www.govinfo.gov/content/pkg/FR-2024-09-18/pdf/2024-21217.pdf),
   page 76602, inserts note 31(a)'s own Chapter 98 target list and valuation.
4. [October 2025 maritime amendment, Annex V.A.2](https://www.govinfo.gov/content/pkg/FR-2025-10-16/pdf/2025-19568.pdf),
   page 48326, expands that target list to 9903.91.12 and 9903.91.14. Thus Chapter
   98 does affect those maritime actions during their operative interval. The
   existing independently sourced suspension remains in effect after November
   10, 2025, 00:01 EST. Written EDT/EST conflicts still retain unresolved margins.

The initial 2024 list alone would miss the later maritime treatment. Conversely,
applying every later Section 301 claim to every investigation would broaden the
law. The compiler follows the actual amended target list and existing action
windows. The all-revision audit retains every clause in
`source-sweep/revision-clauses.json.gz`, with source and compiler hashes in
`source-sweep/report.json`.

Original PDFs, raw extraction, the missing-annex OCR and review metadata are in
`resources/legal_evidence/section301_chapter98/`. List 3/List 4A full original
notice chronology is not newly reconstructed by this corroboration set; their
operative clauses are checked in all 55 codifications. No pre-2025 liability is
asserted by the new compiler.

## Serving and verification

The normal per-revision emitter includes these effects in `section301_rules.json`
and `claim_effects.parquet`. The existing claim table gains additive
`verification`, `formula_json` and `input_constraints_json` fields and
`conditional_valuation` records, including unresolved temporal margins. The
versioned executable bundle remains authoritative; neither an aggregate rate nor
an unsigned formula copied from the table establishes a complete shipment total.
Existing release-table preparation retains additive Parquet columns. A coordinated
rebuild, versioned release preparation and later approved deployment remain
necessary to make this live.

There are **31 Section 301 R/TypeScript conformance cases**, including statutory
examples, adjacent products, claims, value constraints, maritime changes and
suspension. Actual local JSON/batch/Arrow handlers are tested with in-memory
DuckDB. Cross-program tests additionally reject unreviewed claim identities.
Final checks: **343 Python and 378 Node tests passed**. The full R command
reported 402 counted assertion passes and no counted failures, but exited 1
because normalized parity found 312 missing/stale partitions and the TPC input
was absent. The complete gate remains unsuccessful. A separate Parquet → local
DuckDB check preserved all **38,204 claim-effect rows**, including 14 unresolved
source rows and cross-origin maritime scope. Final grammar guards reject changed
valuation qualifiers or an added sentence, instead of discarding them after a
familiar provision number. All 827 source valuation digests remain unchanged
after those guards. See `verification.json` for commands, scope and log hashes.

Reproduce the source audit without rebuilding rates:

```sh
python3 scripts/audit_section301_chapter98.py NEW_AUDIT_DIRECTORY
Rscript tests/test_section301_revision.R
node --test frontend/tests/section301-reconstruction.test.mjs
```

## Remaining work and rollback

This closes the named Section 301 Chapter 98 valuation path, not the entire
shipment-duty plan. Proper Chapter 98 entitlement, remaining investigations and
exclusion chronology, broader IEEPA executable decisions, Section 232 claims and
sector/country/offset rules, FTZ paths, AD/CVD and financial consumers remain.
There is still no all-authority coverage attestation. New rules intentionally
retain incomplete results when another required action/claim is unreviewed.

The full R parity gate still requires rebuilt normalized partitions; the TPC
comparison requires its external input. WJR retains the timeseries rebuild via
the [manual runbook](../../shipment-duty-manual-rebuild.md). No live deployment
qualification is implied. Rollback before publication is a local commit revert;
future activation must retain the previous validated MotherDuck release.
