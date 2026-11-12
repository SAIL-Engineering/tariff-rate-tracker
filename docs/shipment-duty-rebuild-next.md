# WJR: what to run next

Updated November 3, 2026. Tracker branch: `wjr_dev`. No rebuild, MotherDuck write
or deployment was run for this handoff.

## Recommended now: one small local diagnostic

```bash
cd /home/wijreid/Desktop/SAIL/SAIL_Engineering/GitHub_tariff-rate-tracker/tariff-rate-tracker
python3 scripts/run_shipment_diagnostic.py --ref f9da4d99
```

This freezes the committed corrections, builds 2025 revision 11 and 2026 revision
19, validates the emitted cells, and stages a local DuckDB. It prints progress
and periodic activity. It does not replace canonical outputs or contact MotherDuck.

## All affected historical revisions, if a larger local validation is wanted

The corrections target **2025 and 2026**. There are 57 configured revisions through
November 11: 33 in 2025 and 24 in 2026, ending at `2026_rev_23`. The following
rebuilds every one, preserving older-year history in the combined output. It
replaces canonical local outputs, so keep the checkout and inputs fixed while
it runs and save existing outputs first if a before/after comparison is needed.

```bash
cd /home/wijreid/Desktop/SAIL/SAIL_Engineering/GitHub_tariff-rate-tracker/tariff-rate-tracker
mkdir -p output/manual-shipment-rebuild
set -o pipefail
SAIL_EMIT_NORMALIZED=1 SAIL_REQUIRE_NORMALIZED=1 \
  Rscript src/00_build_timeseries.R \
  --only-revisions "$(cat docs/audits/2026-10-23-motherduck/rebuild-revisions.txt)" \
  --build-only --parallel 1 \
  2>&1 | tee "output/manual-shipment-rebuild/build-$(date -u +%Y%m%dT%H%M%SZ).log"
```

This is local diagnostic rebuilding, **not a qualified final release**. The
remaining legal coverage, consumer and serving gates still apply. A successful
build can correctly emit `unresolved_source` and NULL totals; build success does
not certify that every duty program is implemented. Supply the reviewed Trade
Intelligence evidence manifest through `SAIL_DUTY_EVIDENCE_MANIFEST` when one is
available; a placeholder is not a production evidence snapshot. Downstream
aggregate and full-data checks remain in [the full runbook](shipment-duty-manual-rebuild.md).

Do not use `--motherduck-only` for this rebuild: it disables normalized rule
emission. Rebuilding only the last revision leaves earlier corrected intervals
stale. Do not use the old three-column migration plus wide-only push as a
shipment-contract release.

## Revision 22: reconciled, registered, inside the executable horizon

Revision 22's JSON, Chapter 99 and GN3 are installed in their normal local
source directories, and its Change Record, hashes, annex reconciliation and
source preflight are retained in
[the source receipt](audits/2026-11-03-revision-22/README.md).

Its one legal change -- Proclamation 11076 amending U.S. note 51(b)(3) at
12:01 a.m. eastern time on 2026-10-30 -- is implemented, and `audit_until` now
reaches `2026-11-03T00:00:00-05:00`, so the October 30 commencement is inside
the executable window. `2026_rev_22` is registered in the revision calendar and
in the rebuild inventory, and the commands above build it.

Two things to carry forward. The aggregate `rates` table is daily, so it cannot
represent the 12:01 a.m. boundary: an October 30 entry before that instant is
priced as if after it. Only the rule-bundle path, whose intervals are
`TIMESTAMPTZ`, carries the instant. The heading 9903.01.63 forward requirement
was settled when the horizon moved for Revision 23 (below).

## Revision 23: two Section 301 notices, inside the executable horizon

Revision 23 (released 2026-11-10) changes seven Chapter 99 rows, all by USTR
notice, and nothing else: the 178 exclusions under 9903.88.69 and 9903.88.70 are
extended through 11:59 p.m. ET 2027-01-09 (FR 2026-22925), and the maritime
action's headings 9903.91.12-9903.91.16 now begin 2027-01-10 instead of
2026-11-10 (FR 2026-22867). Both notices are retained in `resources/legal_evidence`,
the exclusion extension is a fifth window in `section301_sources.py`, and
`audit_until` reaches `2026-11-12T00:00:00-05:00`, with the Section 232
automobile review carried to the same instant. No instrument continuing the
9903.01.63 suspension past 2026-11-10T00:01:00-05:00 was published; the lapse
does not resume collection, which ended 2026-02-24. See
[the source receipt](audits/2026-11-12-revision-23/README.md).

Revision 22 must be rebuilt with Revision 23. Revision 22 was built as the last
revision, so its legal states run to the series horizon (2026-12-31); with
Revision 23 registered it ends on 2026-11-09, and the combine refuses a snapshot
whose states do not tile that interval. The incremental form is:

```bash
Rscript src/00_build_timeseries.R --start-from 2026_rev_21 --motherduck-only
node frontend/scripts/push-to-motherduck.mjs --only-revisions 2026_rev_22,2026_rev_23
```

## Frontend and MotherDuck

The rule interpreter already supports these compiled rules; no new legal
constants belong in React. Duty Workspace has a resolver panel, but remaining
bulk, schedule and Post-Entry Audit paths still need the versioned result adapter.
Local Parquet changes do not update the running application. After qualification,
an approved coordinated release must deliver rates, normalized tables, rules,
product-base data, evidence/version metadata and compatible API consumers.
MotherDuck preparation/activation and any deployment are separate approval steps.
