# Reciprocal product scope: original annexes, normal builds and release integrity

Base: `3cfb8a893c6d69170a8ed46062c655296c4ee5ed`, local tracker `wjr_dev`.
Only this repository changed. No timeseries rebuild, MotherDuck write, publication,
push, deployment or workflow change. The small calculator fixtures use temporary
output; they are not complete revision builds.

## Root defect and verified correction

The production calculator and ETR exporter read `ieepa_exempt_products.csv`.
Its regeneration widened entries through HTS8, added entire chapters, and gave
unmatched entries an unlimited window. The file also contains entries from the
separate **Potential Tariff Adjustments for Aligned Partners** annex as though
those were universal Annex II exemptions. First appearance in an HTS snapshot
was used as a legal date, even when a presidential amendment operated earlier.

The replacement parses the original operative enumerations, preserves their
4/6/8/10-digit scope, and reconciles every native note inventory against a
verified historical state. Unknown table content, changed hashes and unexplained
inventory differences fail. No test HTS code controls production behavior.
The normal daily build splits source-derived legal event days, while the evidence
retains exact 00:01 Eastern instants and exclusive ends. Original corrections
apply even when the selected revision predates their publication.

| Original source | Executable source decision |
| --- | --- |
| [EO 14257, Annex III note 2(v)(iii)](https://www.govinfo.gov/content/pkg/FR-2025-04-07/pdf/2025-06063.pdf) | Initial 1,039 scope entries; commencement April 5, 2025 at 00:01 EDT. |
| [April 11 electronics memorandum](https://www.whitehouse.gov/presidential-actions/2025/04/clarification-of-exceptions-under-executive-order-14257-of-april-2-2025-as-amended/) | Inserts the listed headings retroactively from April 5; nine new scope entries after overlap with the initial list. |
| [Proclamation 10962, Annex paragraph 3](https://www.govinfo.gov/content/pkg/FR-2025-08-05/pdf/2025-14893.pdf) | Deletes 76 copper provisions from August 1 at 00:01 EDT. Non-copper value and Section 232 remain separate stack decisions. |
| [EO 14346, Annex I](https://www.govinfo.gov/content/pkg/FR-2025-09-10/pdf/2025-17507.pdf) | Adds 39 and removes eight provisions from September 8 at 00:01 EDT. The exact `8505.11.0070` entry is not widened to adjacent statistical provisions. |
| [Proclamation 10976, Annex I paragraph 6(iii)](https://www.govinfo.gov/content/pkg/FR-2025-10-06/pdf/2025-19482.pdf) | Deletes 158 Chapter 44 provisions from October 14 at 00:01 EDT, retaining 12. |
| [EO 14360, Annex I paragraph f](https://www.govinfo.gov/content/pkg/FR-2025-11-25/pdf/2025-21203.pdf) | Adds 237 unconditional and 11 description-limited entries from November 13 at 00:01 EST. Only qualifying descriptions receive 9903.02.78. |

The timber investigation resolved an apparent ambiguity rather than leaving it
as an invented user fact. Clause 12 describes the aligned-partner/AD-CVD-order
criterion. The same proclamation's operative annex implements it with an exact
deletion list. Its image-based pages 13–14 were read visually; retained OCR agrees
with the later HTS inventory. Deleting all Chapter 44 provisions would be wrong;
asking users to adjudicate that original annex's retained provisions is unnecessary.
This finding does not decide shipment-specific AD/CVD applicability.

Collection ends at the existing source-backed February 24, 2026 midnight boundary,
not the February 20 ruling date. The termination source explicitly names EO 14257.

## Live and exhaustive source observations

All **55 configured source snapshots** reconciled, including 2026 revisions 20
and 21. All retained historical payloads were compared with the final history
compiler output and current raw PDF/HTS hashes. See `source-reconciliation.json`
and `scope-summary.json`. These are source checks, not a full grid of priced
HTS × origin × instant results.

At each revision's configured legal day while reciprocal duties were collected,
**1,639–1,659 revision-valid products** appeared as unconditional legacy
Annex-II/ITA exemptions without an unconditional match in the legal enumeration.
The legacy list also omitted **34–35** unconditional matches. Description-limited
entries are deliberately not counted as unconditional. Differences are retained
in `scope-differences.csv.gz`. No aggregate dollar impact is claimed before rebuild.

A separate read-only MotherDuck transaction inspected 55 live intervals and
retrieved 385 rows for seven product/origin pairs. Under the stated ordinary
commercial-entry assumptions, `0106.19.9120 / Australia / 2025-06-01` returned
reciprocal duty **0**, with statutory total **0**, instead of the **10% reciprocal
component** supported by the original action. The corrected bounded calculator
returns 10%. Three other explicit component expectations matched (electronics,
exact magnet exemption, retained teak). The adjacent magnet and conditional bread
also currently return zero; their full stacks were not certified by this audit.
The three overlapping late-2026 production revision intervals remain visible.
Reports and exact queries are retained as `motherduck-*.json` and compressed rows;
MotherDuck was not changed. The archive checksum in its original manifest refers
to the uncompressed case JSON.

## Normal build and serving contract

The calculator and ETR exporter now use the same source-backed unconditional
projection. Chapter 98 and informational-material predicates are no longer
created by blanket chapter additions to the universal list. In particular,
Annex II cannot suppress the separate drug-emergency action. Description-limited
agricultural candidates retain their full conditions; their wide statutory
reciprocal rate and complete total remain unavailable for exposed origins.
The aggregate projection uses the ordinary non-exempt treatment for those
unproven conditions. Actual claim pricing remains a separate rule decision.

The normal normalized emitter writes `ieepa_reciprocal_scope_decisions.parquet`,
`ieepa_reciprocal_source.json` and `ieepa_reciprocal_scope_evidence.json`. Composition
pins the history and sources in `bundle.evidence_dependencies.reciprocal_scope`.
This evidence fragment deliberately adds no charge rules or coverage attestation.

Release **v7** requires the decision table. Read-only preflight reconstructs its
exact product inventory from the bundle pin and rejects changed scope, conditions,
dates, source IDs, missing/duplicate rows or mismatched revision/product membership.
Preparation stores the table and the bundle pin in the new immutable release
schema. This is connected to the existing database release path, not a replacement
local database. v6 readers/data require their matching previous code for rollback;
no active identifier has been switched. The public result contract remains v1.

## Verification and limits

- 366 Python tests passed, including 15 new source/chronology regressions.
- 429 Node tests passed, including local Parquet/DuckDB release preparation,
  old-contract rejection, changed descriptions, scope widening and missing rows.
  These ran outside the sandbox: the sandboxed native process run only reported
  file exits and was not counted as successful individual test execution.
- The existing full R invocation passed 40 of 42 suites; normalized artifact
  completeness failed and the TPC suite skipped for missing input. Both new R
  suites then passed: source/projection/composition/ETR/Parquet tests and a six-row
  actual-source calculator/normalized-emitter fixture. This does not make the full
  data gate green.
- The updated normalized inventory gate now reports **473 missing-artifact or
  missing-revision errors**, versus 312 before adding reciprocal evidence and
  explicitly detecting absent directories 20/21. These are more complete checks
  of old artifacts, not 473 newly introduced rate errors. The exhaustive numerical
  parity sweep remains unfinished.
- TypeScript typecheck and Vite build passed. Generated prototype build artifacts
  were restored; no production UI changed. No browser/deployment smoke test is
  claimed for the unactivated release.

The fixture still surfaced pre-existing Section 201 staged-source fallback and
aggregate ledger citation warnings; those are not legal qualification. Broader
reciprocal country/claim/content/transit/FTZ execution, remaining Section 232
sectors/claims, Section 122/338/301 interactions, AD/CVD/Chapter 98 and financial
consumers remain unfinished. The scope correction must not be presented as complete
all-authority coverage. A normal rebuild will apply these source corrections
across revisions, but should not be published until the remaining gates are met.

Rebuild and rollback instructions remain in [the manual runbook](../../shipment-duty-manual-rebuild.md).
