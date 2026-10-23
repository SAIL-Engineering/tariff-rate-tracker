# Revision-bound Section 301 reconstruction — 2026-10-23

This checkpoint replaces the 2025/2026 China technology-transfer charge's global
HTS8 list/MAX-rate calculation with revision-bound source extraction in the normal
build. It also models the separate maritime action and its suspension. It does
**not** complete Section 301 exclusions or the entire shipment-duty plan.

Implementation base: tracker `wjr_dev`,
`aae4c08f840da6730499f29bc45a5b67d388c702`. Work is committed directly to that
original branch. SAIL and Trade Intelligence were not modified in this checkpoint.
Their existing local integrated work remains in `pinecone-hts` and `main`.
No timeseries/revision rebuild, production write, publication, push, activation,
deployment or workflow dispatch occurred. The prototype build only copied existing
local public data; those generated dist copies were restored and are not committed.

## Read-only MotherDuck comparison

`motherduck-china.json.gz` captures 1,115,476 China product/revision rows from all
55 configured revisions in `duty_calculator`, queried in read-only mode on October
23. `snapshots.json` records exact capture times and uncompressed hashes. Each
revision is independently reconciled against its full Chapter 99 PDF and HTS JSON;
`comparison.json` pins those hashes, extractor version and audit-script hash.

| Measure | Product/revision rows |
| --- | ---: |
| Stored China rows compared | 1,115,476 |
| Matched reconstructed technology-transfer charge | 994,113 |
| Scope requiring product-description facts | 363 |
| Different modeled charge rate | 7,051 |
| Different statutory rate or completeness | 7,216 |
| Different reporting-heading attribution | 904,123 |
| Attribution differences caused by previously missing headings | 903,253 |

`differences.json.gz` retains the affected rows, old/new charge projection,
source locators and required descriptions. These are **charge comparisons**, not
complete duty totals or a claim that every difference is an over/underpayment.
The audit uses the revision's first day at 23:59:59 UTC, matching the aggregate
projection. Intraday legal boundaries are covered separately by source-derived
tests. It does not traverse every instant, claim or shipment-fact combination.

`motherduck-maritime.json.gz` captures 7,920 candidate rows across 240 origins and
revisions 26/27/28 of 2025. Of these, 2,640 are in revision 27. The action's source
scope identifies 11 China candidate products in that revision and can also reach
qualifying cranes of other origins. This is a candidate population; scope facts
must be established before a shipment deposit/duty can be asserted.

## Root causes and corrections

- The undated list expanded some statistical references to HTS8 and scanned across
  legal boundaries. The replacement bounds each note/table/enumeration, preserves
  HTS10 exclusions, distinguishes descriptions from bare code tables, and fails
  when a reference or operative positive heading is unparsed. Sentence-ending
  punctuation no longer drops an exact-code exception.
- Note 20(g), reporting heading 9903.88.04, was omitted by the old list path.
  Its 11 set-difference scopes are now extracted alongside the other charge lists.
- Staged masks, gloves, batteries and semiconductor actions use the relevant
  revision's headings, table membership, deletions and entry windows. The legal
  rate is read from the heading expression, never chosen by numerical maximum.
  Exact product validity is checked against that revision's HTS product universe.
- Described subsets require shipment facts. Aggregate modeling assumes qualifying
  scope with an explicitly emitted share of 1. The statutory column is null where
  qualification has not been established. Model shares/assembly credits cannot
  change the executable shipment amount.
- The maritime investigation has separate source-defined actions, origin scope
  and columns. Qualifying cranes may owe that charge cumulatively with the earlier
  China crane action. A technology-transfer exclusion cannot silently remove a
  maritime duty. The later suspension ends the maritime charge, not the earlier
  technology-transfer action.
- The maritime source says eastern daylight time for a November start, while
  calendar Eastern time is standard time. The affected hour is an unresolved
  source interval; a definite amount starts only after both interpretations.
  The same general check applies to other conflicting source time-zone wording.

Primary evidence includes each revision's USITC Chapter 99/HTS sources, the
[2024 modification](https://www.govinfo.gov/content/pkg/FR-2024-09-18/html/2024-21217.htm),
[December 2024 amendment](https://www.govinfo.gov/content/pkg/FR-2024-12-16/html/2024-29462.htm),
[maritime modification](https://www.govinfo.gov/content/pkg/FR-2025-10-16/html/2025-19568.htm)
and [suspension](https://www.govinfo.gov/content/pkg/FR-2025-11-13/html/2025-19873.htm).
Browser-extracted primary text and SHA256 metadata are retained under
`resources/legal_evidence/`. The [October 2026 technical amendment](https://www.govinfo.gov/content/pkg/FR-2026-10-07/html/2026-20511.htm)
to note 20(vvv)(i)(20), retroactive to July 1, is retained as research evidence;
it has **not yet been applied** to a reconstructed exclusion timeline.

## Build and delivery

The ordinary calculation invokes `load_s301_revision_source`, matching on the
revision's own product universe and action date. Missing/mismatched sources fail
instead of falling back to the old global list. Cached extraction is invalidated
by PDF/HTS/extractor/additional-source hashes. All 55 source pairs were parsed;
this is source validation, not a timeseries rebuild. Missing normalized revisions
20/21 still require WJR's manual build.

Each revision emits decision Parquet, source JSON and a declarative rule fragment.
Wide modeled/statutory fields and separate maritime fields are projected from the
same extraction. The aggregate adapter preserves cumulative actions and explicit
model shares. The existing shared R/TypeScript interpreter evaluates the emitted
rules without React constants or copied legal rates.

Release contract `sail.tariff-release/v2` requires the decision partition and new
rate fields, validates source/product/origin relationships, reconciles wide rates,
and rejects missing rates and false statutory completeness. Rule/result contracts
remain v1. Local immutable preparation stores the new table alongside all other
partitions; it neither changes the active release nor confers legal qualification.
Live MotherDuck still contains its previously published data.

## Verification

- 13 real-source Python tests plus R source/revision/evaluator checks passed.
  They cover neighboring scope, deleted items, exact-code exceptions, changed
  grammar, wrong source revisions, conditional descriptions, conflicting actions,
  cumulative investigations, suspension and ambiguous boundary instants.
- Nine source-derived R/TypeScript conformance cases and a stored-DuckDB API test
  preserve known subtotals and null complete totals through JSON, Arrow and batch.
  The broader Node suite passed **110 tests**, including release preparation,
  rollback, source/version checks, missing values and cross-origin contamination.
- The full R runner passed **25 of 27 suites** (402 counted legacy assertions plus
  suites with their own assertions). Normalized parity failed on 156 missing new
  artifacts in old generated output; TPC skipped for missing built data. The full
  data gate therefore remains red. Final source/program-isolation changes passed
  the focused R suite afterward. No failed data gate was waived.
- Tracker TypeScript/Vite build passed. No SAIL UI changed in this checkpoint;
  this build is not browser or production qualification.
- The former normalized parity `--full` option actually ran the same sample. It
  now rejects that unsupported mode. Exhaustive all-authority traversal remains
  required; the default test is explicitly a sample.

Logs are retained here. `files.sha256.json` records their artifact hashes.

## Reproduce and rebuild manually

Read-only audit (use a new output path; no production writes):

```sh
node frontend/scripts/audit-section301-motherduck.mjs .env /tmp/s301-new.json.gz
python3 scripts/audit_section301_reconstruction.py \
  --snapshot /tmp/s301-new.json.gz --out /tmp/s301-new-comparison
node frontend/scripts/audit-section301-motherduck.mjs .env /tmp/s301-maritime-new.json.gz --maritime
```

Run the [manual rebuild commands](../../shipment-duty-manual-rebuild.md) to
regenerate all 55 revisions. This is how the corrections propagate across HTS,
origin and revision rather than being written to a handful of audited rows.
Then compose each emitted fragment into the reviewed all-authority bundle and
validate the entire release before requesting production approval.

## Remaining gates and rollback

Full exclusion/claim and retroactive-amendment chronology, other Section 301
investigations, complete IEEPA/232/122/338 validation, Chapter 98/quotas/AD/CVD,
all-authority compilation, consumer migration, exhaustive parity and aggregate
before/after outputs remain unfinished. Current fragments deliberately grant no
complete Section 301 coverage. Known subtotals are not complete totals.

No live rollback is needed. Preserve later work before reverting the implementation
commit on `wjr_dev`. A future v2-to-v2 data rollback uses the previous validated
release identifier. Rolling back to a v1 release also requires its compatible
reader code; an ID switch alone is unsupported. Never publish or activate these
partial fragments to bypass the remaining gates.
