# Ordinary-build shipment evaluation checkpoint

Tracker base: `94f1faa946c8e326d5f57784cc7aae0cf6ef359d` on original `wjr_dev`.
SAIL contract base: `62e85ee35b564f5fe9951121a5825ee24abcc236`; local commit
`dafbdb514` is merged into original `pinecone-hts`. No Trade Intelligence code,
weekday workflow, active release or production database was changed. Nothing
was pushed or deployed. Full timeseries/revision builds remain WJR's manual task.

## What now runs in the ordinary build

`06_calculate_rates.R` finishes the economic grid, obtains current-invocation
normalized fragments from `07_emit_normalized.R`, then assembles and evaluates
shipment bundles. It no longer returns the legacy aggregate-backed statutory
projection as a shipment answer when assembly fails or is disabled.

`src/shipment_base_sources.py` extracts complete native duty expressions using
all structural rows. It rejects unrelated ancestors and conflicting duplicate
observations. No percentage, AVE, preference share or metal share is supplied
by the economic calculation. `src/shipment_build.R` uses the existing complete
expression parser and the revision's primary General Note3 PDF for Column2
origin treatment. Missing/unsupported expressions retain source errors.

The assembler partitions exact instants, including changes within a revision,
and retains rules needed for dependency lookup. A fragment's supported or legal
horizon does not become a repeal or zero rate. Unreviewed authority inventories
remain unresolved, independently of how many rules were emitted. No source
presence is promoted to full legal coverage. Globally required inventories
include other IEEPA actions, AD/CVD and other Chapter99 provisions.

The normal output now contains:

- `shipment_rules.json`: `sail.shipment-bundle-index/v1`, selecting immutable,
  SHA256-checked exact-time bundles.
- `shipment_decision_classes.parquet`: compact decisions and per-authority rate
  projections; formulas, scope and source evidence remain in the referenced bundle.
- `shipment_decision_membership.parquet`: product/origin/exact-window links.
- Versioned wide-row decision/bundle references, missing facts, source errors,
  completeness and quote-profile metadata. Statutory amounts/totals are nullable.

The declared reference quote is USD1 customs value, no claims, with no invented
FTZ/use/content/quantity/party/quota facts. Only a proven homogeneous expression
can become a scalar ad-valorem projection. Multiple daily decisions are retained;
they are not resolved by choosing midnight or selecting the highest rate.
`modeled_legacy_*` preserves old aggregate-backed statutory projections for
comparison; `aggregate_*` preserves old scalar reporting/provenance fields.
Economic rate columns retain their method. A full historical aggregate numerical
comparison has not been run; it requires WJR's later rebuild.

The prepared R evaluator reuses the reference interpreter's conditions, claims,
dependencies and formulas. Product/country/time scope indexing and signature
classes reduce repeated interpretation; no second tariff arithmetic was added.

## Source and legal findings

The read-only source census inspected all 55 configured revisions, containing
1,088,196 product/revision records. All required primary HTS/Chapter99/GN3 files
are present. The GN3 country inventory consistently contains Cuba, North Korea,
Republic of Belarus and Russian Federation.

One native branch is malformed: 2025_rev_16 contains9401993030 below94019925,
without a matching duty-bearing HTS8 owner. The original Chapter94 PDF repeats
this stranded line on printed page94-7 and separately prints9401999030 under
94019990. Statistical note2 names9401999030. Visual inspection confirms the PDF
layout, so this is not merely a JSON indentation issue. Evidence and hashes are
retained in `resources/legal_evidence/USITC-2025-rev16-ch94`. The original source is
[USITC Revision16 Chapter94](https://hts.usitc.gov/reststop/file?release=2025HTSRev16&filename=Chapter%2094).
No corrective instrument was established. Production logic neither renumbers the
stranded code nor copies Free/60percent from the unrelated preceding owner.
A regression retains the precise source question and independently prices the
neighboring valid code's45percent Column2 **base-only component**.

The census also retains 38 distinct unparsed general and 70 Column2 complete duty
expressions across the history (not a count of confirmed statutory errors).
Conditional terms, note references and unresolved units do not become zero or a
recognized percentage substring. The source-only preflight exits nonzero for the
malformed inventory and expressly does not qualify legal coverage.

Two actual-source normal-build checks demonstrate execution:

1. A qualifying8471500150 semiconductor entry from4280 on2026-09-15 produces a
   $25 Section232 component on explicit$100 value and technical/use/ordinary-entry
   facts. Adjacent8471410150 produces no semiconductor component. Both complete
   totals remain unresolved; this is not certification of their complete stacks.
2. Canadian8537109130 before2026-09-15 00:01EDT retains the unresolved232-dependent
   Section338 interaction. At00:01 the amended independent motor-control action
   produces$50 on explicit$100 with its required facts. Missing global coverage
   still prevents a complete total. The daily wide row retains both decisions.

The legal rates/windows/headings come from the existing original-instrument
compilers; production code does not special-case these regression examples.

## Evidence versions and serving limits

Build IDs hash source/compiler/configuration inputs, generated shared adapters,
and configured evidence/grant pins. `SAIL_DUTY_EVIDENCE_MANIFEST` reuses the existing
Trade Intelligence `sail.duty-evidence/v1` export, served schema 8/extractor 2.
The loader verifies snapshot identity, table hashes/counts, publication-manifest
hash and separate customs-reference artifacts. Export status remains
`requires_reconciliation`; it is not an AD/CVD scope approval. A missing pin is
explicitly unresolved, never a fabricated 64-character snapshot identifier.

SAIL's new shared `shipmentWide.ts` adapter defines the nullable projection
contract, rejects malformed/contradictory/old fields, and never reads economic
rates. The tracker generates its JS and TS copies from those source bytes.
The ordinary API projection carries the new metadata; existing JSON/Arrow/batch
serializers preserve nulls and version identity.

**Production release preparation is still unfinished.** The existing v7 preparer
accepts one bundle per revision and rejects this new index. It needs a coordinated
multi-bundle/index, table-relationship and schema/preflight upgrade. Legacy
numeric ProductRate financial consumers also still require the new adapter.
The local DuckDB/API fixture deliberately exercises routing and serialization
without qualifying or activating a production release. Do not publish a wide
Parquet alone, manufacture a pin, or mark this release validated.

## Verification and limits

- Python: 407 tests passed. Node: 561 tests passed; final shared-adapter focused
  checks also passed. Prototype TypeScript/Vite build passed.
- R: 170 direct/prepared conformance cases passed. New normal-build boundary,
  source-horizon, source-tamper, model-isolation, malformed-index, singleton-array
  and JSON-null checks passed. Base source/country/unit/integrity checks passed.
- Actual normal semiconductor Parquet -> local DuckDB -> shared TypeScript ->
  JSON/Arrow/batch checks passed for both fixture products, including stale dataset
  rejection and bundle corruption. Required facts and reporting codes survive.
- Actual Section338 normal-build before/at-amendment regression passed. The old
  pipeline fixture's scalar expectation was updated; its previous parameters are
  checked under modeled_legacy_ and its new incomplete statutory amounts are null.
- SAIL: 20,717 configured unit tests passed / 45 skipped with four workers; 1,219 files
  passed / 8 skipped. Initial five unrelated export test timeouts, focused 90-test
  rerun, and final strict-status regression are retained separately. Typecheck
  ratchet passed without baseline changes; changed-file lint passed.
- Last complete R gate initially ran 52 suites: 49OK, two errors, one TPC skip.
  One error was the updated338 fixture, which passed its subsequent targeted run.
  Normalized parity reported 685 missing/stale existing artifacts; the TPC input
  `data/tpc/tariff_by_flow_day.csv` is missing. The full R gate is not green.

Fresh MotherDuck audit: READ_ONLY connection to `duty_calculator`, transaction
rolled back; 220 stored rows, 12 dated semiconductor cases, 24 field mismatches,
and three overlapping stored revision intervals. Each check concerns conditional
shipment fields, not an assumed complete legal stack. Compressed report artifacts
retain the queries, source specification and exact stored values. Production data
was not changed and its findings remain open until an approved release.

Logs/reports are compressed alongside this note. Manual commands are maintained
in `docs/shipment-duty-manual-rebuild.md`. Broader reciprocal IEEPA after August 7,
additional 232 sectors/claims/FTZ paths, remaining 122/338/301 interactions, Chapter 98,
AD/CVD, complete coverage attestations and financial consumers remain unfinished.
Keep the final rebuild on hold while completing these rate-affecting decisions.
