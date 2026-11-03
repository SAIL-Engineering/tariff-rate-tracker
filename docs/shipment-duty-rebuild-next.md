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

The corrections target **2025 and 2026**. There are 55 configured revisions through
October 22: 33 in 2025 and 22 in 2026, ending at `2026_rev_21`. The following
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

## Revision 22: downloaded, outside current executable horizon

Revision 22's JSON, Chapter 99 and GN3 are installed in their normal local source
directories. Its Change Record and hashes are retained in
[the source receipt](audits/2026-11-03-revision-22/README.md). Its October 30
commencement is beyond the current executable audit horizon. It is deliberately
not added to the active revision calendar yet: doing so would make a strict
shipment build fail on that interval before the amendment and horizon are
implemented. Neither command above builds revision 22.

## Frontend and MotherDuck

The rule interpreter already supports these compiled rules; no new legal
constants belong in React. Duty Workspace has a resolver panel, but remaining
bulk, schedule and Post-Entry Audit paths still need the versioned result adapter.
Local Parquet changes do not update the running application. After qualification,
an approved coordinated release must deliver rates, normalized tables, rules,
product-base data, evidence/version metadata and compatible API consumers.
MotherDuck preparation/activation and any deployment are separate approval steps.
