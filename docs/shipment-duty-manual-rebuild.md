# Manual rebuild and verification commands

WJR requested that **all timeseries/revision rebuilds be run manually**. None of
these build commands was run during the MotherDuck audit. The code is integrated
locally into `wjr_dev`; no push or MotherDuck write is part of this runbook.

This is a reproducible rebuild command for the current corrections, not a claim
that the entire shipment-duty plan is finished. Finish the remaining legal/rule
and serving-path gates before approving publication. Save the current generated
outputs first if an aggregate before/after comparison is needed. Record `git
rev-parse HEAD`, the policy/resource hashes and the evidence snapshot used.

## Rebuild all 55 configured revisions through the audit cutoff

Run from the original tracker checkout on `wjr_dev` with the project's R packages,
HTS archives, trade inputs and existing environment available:

```sh
cd /home/wijreid/Desktop/SAIL/SAIL_Engineering/GitHub_tariff-rate-tracker/tariff-rate-tracker
mkdir -p output/manual-shipment-rebuild
SAIL_EMIT_NORMALIZED=1 SAIL_REQUIRE_NORMALIZED=1 \
  Rscript src/00_build_timeseries.R \
  --only-revisions "$(cat docs/audits/2026-10-23-motherduck/rebuild-revisions.txt)" \
  --build-only --parallel 1 \
  > output/manual-shipment-rebuild/build.log 2>&1
```

Check the exit code before continuing. The checked-in list selects all 55 revisions
(including 2026 revisions 20 and 21), not just the last revision. It does not select
future revisions after October 22. Append only additionally verified releases
within that cutoff after legal review. Existing older snapshots are not rebuilt
by this command; the combine retains their history.

Strict mode rejects missing requested archives, failed revisions and required
normalized/static/authority-contract emission failures before combining a release.
A failed run can leave partial local artifacts: do not publish them or treat them
as a valid release. A fresh successful run and reconciliation are still required.
Do not use `--motherduck-only` (it disables normalized output), `--no-combine`
(leaves serving Parquet stale), or `--core-only` for aggregate qualification.
The default weekday workflow has not been changed to strict mode.

## Run downstream aggregation and verification separately

Run each command only after its predecessor succeeds. Separate execution exposes
exit failures that the legacy combined downstream runner can report as warnings.

```sh
Rscript scripts/run_daily_from_parquet.R > output/manual-shipment-rebuild/daily.log 2>&1
Rscript src/08_weighted_etr.R > output/manual-shipment-rebuild/weighted-etr.log 2>&1
Rscript scripts/prepare_frontend_data.R > output/manual-shipment-rebuild/frontend-data.log 2>&1
Rscript tests/run_all_tests.R --require-data > output/manual-shipment-rebuild/r-tests.log 2>&1
Rscript tests/test_normalized_parity.R --full > output/manual-shipment-rebuild/parity-full.log 2>&1
node --test frontend/tests/*.test.mjs
```

The existing normalized parity suite checks aggregate reconstruction, not complete
shipment legal coverage. Review emitted shares/credits and explain any aggregate
difference. The full-data suite also needs its older fixtures/TPC inputs; a skip
is not release qualification. Missing source evidence must remain unresolved.

The citation generator now updates only the tracker prototype by default. If
updating SAIL's shared citation artifact is intended, explicitly name its checkout:

```sh
Rscript scripts/emit_duty_citations.R --sail-dir \
  /home/wijreid/Desktop/SAIL/SAIL_Engineering/GitHub_sail-gtx-prerelease/sail-gtx-prerelease
```

That command writes a local generated file for review/commit. It does not deploy.

## MotherDuck audit and later release

A new read-only production comparison can be run independently of the rebuild:

```sh
node frontend/scripts/audit-shipment-motherduck.mjs \
  --env .env --out output/shipment-audit-AFTER --sweep
```

Until an approved publication occurs, it will still see the old production data.
A rebuilt wide table alone must not be activated as the corrected shipment
contract. Complete the versioned rules, evidence snapshot, normalized tables,
product-base data, release manifest and all-authority coverage validation first.
Local preparation is available with `frontend/scripts/prepare-shipment-release.mjs`
using an explicit manifest and local DuckDB path; it cannot connect to MotherDuck.
No live synchronization/activation command is authorized by this runbook.


## Conditional-action contract dependency

The next rebuild must include `authority_product_candidates.parquet` for every
revision. The current release preflight requires it; do not reuse an older set
that silently discarded competing auto/semiconductor candidates. Missing configured
product sources now fail extraction, and exact HTS10 scope cannot be widened to
fallback prefixes. Fix the source/revision coverage rather than disabling checks.

Reviewed fragments can be composed locally after a complete base rule bundle has
been constructed (replace the uppercase paths with reviewed versioned artifacts):

```sh
Rscript scripts/compile_shipment_rules.R BASE_BUNDLE.json NEW_COMPOSED_BUNDLE.json \
  resources/shipment_rules/s232_semiconductors.json \
  resources/shipment_rules/s232_auto_parts_condition.json
```

This is not the full rule compiler and does not grant coverage or publication
approval. Do not use the synthetic test bundle as the base of a real release.
The audit and uncompleted Section 301 reconstruction are recorded in
`docs/audits/2026-10-23-conditional-actions/README.md`.
