# Executable Section 122 interactions and historical windows

Tracker base: `46aa24b1b435542ff20e8487a2cc32b37fdf85e3` on `wjr_dev`.
SAIL base: `2e2720b84c78b0fbc2199d614ae83c7912581806` on `pinecone-hts`.
Coordinated SAIL commit: `a072ade66cbf93d00451a557d332d95e4ea0493a` on `pinecone-hts`.
Trade Intelligence is unchanged. No timeseries/revision rebuild, MotherDuck write,
publication, deployment, workflow dispatch or push was performed.

## Implemented

The normal normalized emitter now produces `section122_rules.json`. It compiles
revision-specific exact product exemptions, description/GN6 conditions, actual
USMCA/CAFTA duty-free entry conditions, accompanied baggage, donations,
informational materials, the transit window and the Section 232 overlap.
Chapter 98 and FTZ branches remain explicitly unresolved pending their complete
valuation/eligibility compilation. An import-adjustment offset is not inferred
from a modeled assembly credit or an unreviewed claim.

The overlap uses the applicable Section 232 **reporting decision**, including
expressly named zero-duty branches. Before April 6, the note excludes specified
steel/aluminum/copper portions; the remaining value receives Section 122.
Distinct mixed-metal values must be reconciled without double counting.
An unlisted applicable Section 232 decision remains unresolved even if its duty
amount is zero; a positive-rate test cannot establish the taxable remainder. Whole
article headings and the two qualified vehicle/parts provisions remain separate.
Reporting includes .03.06 for the exempt portion and .03.01 for a priced remainder.

The composer binds source-derived reporting predicates to rule IDs, respecting
product/country/time scope and existing suppression. Commerce grant effects are
reevaluated, with grant metadata required; other unknown Section 232 claims stay
unpriced. Section 301 exclusion independence is explicit. No broad claim discount
or arbitrary maximum-rate rule is used.

Both shared interpreters support `authority_covered`. A dependent amount requires
a reviewed inventory accounting for every matched action. Missing Section 232
coverage cannot establish full-value Section 122, or a known partial remainder.
A separately proven whole-article exemption can still establish zero for that
component. Coverage is not a caller-supplied shipment fact. No new production
coverage attestation is emitted.

## Source reconciliation

Primary artifacts and hashes are in
`resources/legal_evidence/section122/interactions/review.json`.

* [Proclamation 11012](https://www.govinfo.gov/content/pkg/FR-2026-02-25/pdf/2026-03824.pdf),
  paragraph 4 and Annex I, pp.9355-9356, supplies the portion rule and named
  zero-duty references. Paragraph 7 supplies the entry window.
* [Proclamation 11021](https://www.govinfo.gov/content/pkg/FR-2026-04-09/pdf/2026-06960.pdf),
  Annex IV A(4), p.18261, replaces the metal subdivisions at April 6 00:01 Eastern.
  Its new range is .82.02 and .82.04-.82.17. These references are reconstructed
  independently of later snapshots.
* [Taiwan implementation notice](https://www.govinfo.gov/content/pkg/FR-2026-05-28/html/2026-10571.htm),
  Annex paragraphs 6-7, supplies replacements effective **May 1 00:01 Eastern**.
  The original notice itself prints `903.94.67`. No digit is guessed or repaired.
  A matched unlisted Section 232 action, including a zero-duty decision, remains unresolved for the 122
  portion rather than being presumed fully taxable.
* [Commerce's April 23 notice](https://www.govinfo.gov/content/pkg/FR-2026-04-23/pdf/2026-07987.pdf),
  Annex paragraph 3, p.21794, explicitly inserts .82.04-.82.19 into the named
  subdivision. Its deletion operand prints `99903.82.04` with an extra digit.
  The compiler uses the valid insertion, corroborated independently by revision
  6, and retains the malformed operand as evidence. This is a documented legal
  reconciliation, not a general spelling-repair algorithm. The notice expressly
  says Eastern **standard** time on April 23; the compiler honors its literal
  -05:00 offset (01:01 daylight time), rather than silently changing the clock.
* [Proclamation 11032](https://www.govinfo.gov/content/pkg/FR-2026-06-04/pdf/2026-11314.pdf),
  Annex IV A(7), expands .82.04-.82.19 through .82.26 at June 8 00:01 Eastern
  daylight time. The April 23 insertion supplies the missing predecessor, so
  this expansion is now resolved, including its zero-duty headings. The June
  snapshot's missing .82.02 cannot delete the unaffected original reference.
* Later note text explicitly incorporates changes after Section 122 expired.
  Those changes are not applied to earlier entries. The exclusive end remains
  July 24 00:01 Eastern, separately from daily aggregate date labels.

The Taiwan insertion still requires further authoritative reconciliation. It is
not claimed to be permanently unresolvable. The general proclamation and other
Section 232 valuation provisions may resolve individual remaining interactions
once their complete action definitions are compiled.

## Validation and limits

`source-sweep-final.json` checks all 55 configured 2025/2026 source revisions. Eighteen
contain Section 122, and eight carry the post-expiry warning. Bounded compilation
checks the historical interaction windows across those sources; this is not a
full HTS10/origin shipment sweep or a rebuild. The 1,655 extracted product
exemptions are unchanged across the eighteen sources. The compiler rejects any
new product or procedural exemption until its legal chronology is reconciled;
a later snapshot cannot silently replace an earlier predicate.

Tests include real archived metal decisions plus explicitly synthetic inventory
attestations and independent action fixtures. Synthetic coverage is never used
for production. The R/TypeScript cases test portion values, exact suffixes,
conditional use, claims, mixed content, source/quantity gaps and temporal cutoffs.
A local in-memory DuckDB test exercises the stored bundle through the actual
JSON, batch and Arrow handlers, preserving versions and null complete totals.
The full test outcomes and logs are recorded in `verification.json`:

- 330 Python tests passed; the final eight focused tests also pass after adding
  the imported expression helper to the compiler dependency hashes.
- 282 tracker Node tests passed, including 38 R/TypeScript conformance cases and
  the local DuckDB JSON/batch/Arrow test.
- 109 affected SAIL tests, both typechecks, affected SAIL lint, and the tracker
  build passed. The build retains the existing chunk-size warning.
- The full R gate with `--require-data` exits 1: 37 suites pass, normalized parity
  errors on 312 missing/stale partitions, and the TPC suite is skipped for missing
  input. Its 402 counted passing assertions are not a successful full gate.

No UI pages changed in this pass; no new browser UI qualification is claimed.
The legacy wide/statutory summary adapter is not the resolved shipment result.
Its remaining reconciliation and the complete bundle/coverage composition remain
release gates; the emitted fragment must reach the versioned serving release.

The broader plan remains unfinished: complete IEEPA/232/338/301 action coverage,
Section 122 Taiwan reference, offset/Chapter 98/FTZ treatment, AD/CVD,
financial consumers, complete coverage attestations and rebuilt parity still
require work. This pass does not correct the active MotherDuck release.

## Delivery and rollback

Bundle/result contracts remain v1; release remains v6. `authority_covered` is an
additive expression discriminator. Older interpreters reject it as an invalid
expression; they cannot silently price it. Deploy the coordinated interpreters
before activating bundles that use it, and assign a new dataset version.
Compose the emitted fragment with the other independently verified actions and
coverage; do not use the test bundle as a production base.

WJR's manual rebuild commands remain in `docs/shipment-duty-manual-rebuild.md`.
No new live migration is needed for this expression: bundles use the existing
versioned rule storage. A later approved publication still needs complete local
release preparation and a separate MotherDuck smoke test. Roll back local code
with coordinated reverts in the two repositories; no active release changed.
After activation, retain the preceding validated release and compatible reader.
