# Source support and composition follow-up

Local predecessor: 646dba47 on original wjr_dev. No full timeseries/revision rebuild,
production write, release activation, push, deployment or workflow dispatch.

The ordinary-build source frame now has an explicit contract in
`resources/shipment_rules/build_contract.json`. It records the requested audit
bounds and required authority inventories. Base fragments retain the raw HTS
date, aggregate policy date, selected build-support interval and calendar hash.
The role is explicitly `build_support_only_not_statutory_effectiveness`.
`load_revision_dates()` intentionally substitutes policy dates for aggregate
source selection; those dates are not an oracle for every legal action.

For example 2025_rev_8 has raw date April3 and selected policy date April9. A blanket
publication-date cutoff would reject the ordinary build's declared source frame.
The new guard uses that declared frame, preserves the original action windows,
and emits an unresolved-source diagnostic if the caller extends the whole
shipment bundle outside it. It does not invent a repeal or zero liability.
Independent native code-validity, source-publication and legal-effective-date
reconciliation remains part of the unfinished legal coverage audit.

The September15 normal semiconductor/338 fixtures now use the in-period source
`2026_rev_19`. The previous fixture used rev17 outside its declared source frame.
Exercising all in-period fragments exposed two concrete composition failures:

- Metal and semiconductor programs cite the same FR-2026-11314 PDF bytes/URL and
  verification state at different locators. The composer merges only those
  citation locators; different hashes, URLs, statuses or other source properties
  still fail. Rule definitions remain strict. Input order does not choose a rate.
- A note 16 fragment with no product matches registered USMCA with no target rules.
  The compiler now omits that empty claim definition. It retains the evidence
  and does not infer that no other Section 232 action applies.

The actual in-period tests reproduce the $25 semiconductor component on $100 and
its adjacent uncovered case, plus the September15 00:01 Section338 amendment's
$50 motor-control component on $100. Full totals remain unresolved. These are
source-backed components, not complete-stack legal certification.

A streamed JavaScript bundle-index reader now verifies exact interval tiling,
artifact hashes/paths, bundle identities and dataset/evidence/revision versions.
It uses the same strict timestamp parser as the shared SAIL interpreter. It
rejects malformed/mixed/old data and directory escapes. The normal-build
Parquet/localDuckDB/JSON/Arrow/batch check now uses this reader. **The v7 production
release preparer has not yet been upgraded**; this reader is one required bridge,
not proof of successful production release preparation or activation.

Verification: 408 Python tests;566 Node tests;170 direct/prepared R cases; source,
base, empty-claim, citation-order and normal API regressions passed. Full R rerun:
53 suites, 51 OK, one normalized-parity ERROR (685 stale/missing existing artifacts),
one TPC-input SKIP. The runner's427 counted cases are not its total case count.
The full gate exits 1. Missing input: `data/tpc/tariff_by_flow_day.csv`.
SAIL's existing interpreter/projection focused 53 tests, typecheck ratchet and
changed-file lint passed for exposing the existing timestamp parser; its duty
arithmetic is unchanged. The preceding full configured unit gate passed 20,717
with 45 skips. Compressed logs are retained here.

Remaining work includes full release preparation/schema integration, source-clock
and legal chronology reconciliation, broader executable authority/claim/valuation
coverage and financial consumers. Keep WJR's final rebuild on hold until those
rate-affecting decisions are ready. MotherDuck remains unchanged.
