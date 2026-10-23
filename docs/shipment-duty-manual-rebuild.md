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
Rscript tests/test_normalized_parity.R > output/manual-shipment-rebuild/parity-sample.log 2>&1
node --test frontend/tests/*.test.mjs
```

The existing normalized parity suite checks a sample of aggregate reconstruction,
not an exhaustive sweep or complete shipment legal coverage. Its former `--full`
flag ran the same sample; it now fails explicitly until exhaustive traversal is
implemented. That missing sweep remains a release blocker. Review emitted shares/credits and explain any aggregate
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
The earlier conditional-action audit is recorded in
`docs/audits/2026-10-23-conditional-actions/README.md`.

## Revision-bound Section 301 reconstruction

The command above automatically runs `src/section301_sources.py` through
`src/section301_revision.R` for each requested 2025/2026 revision. Install Python 3
with zoneinfo/tzdata and Poppler's `pdftotext`; both are required build inputs.
The extractor uses that revision's full Chapter 99 PDF and HTS JSON, checks the
PDF revision header, and caches by source/extractor hashes. Missing PDF archives
are downloaded from USITC. Missing sources, unknown potentially operative charge
headings, unsupported table grammar and conflicting actions fail the build.
The local cache includes the verified revision 20/21 PDFs, but is not a production
data store. A clean checkout retrieves them through the same build path.

Each normalized revision now emits:

- `section301_scope_decisions.parquet`: exact products, program/origin scope,
  reporting heading, rate, required description, entry window and source hashes.
- `section301_source.json`: extracted actions, exclusion histories, charge inventory and source versions.
- `claim_effects.parquet`: source-backed claim conditions, exact scope/windows and named charge targets.
- `section301_rules.json`: executable fragment for the shared R/TypeScript runtime.

The wide rows retain aggregate scope shares separately from nullable statutory
fields. Maritime duties have their own cumulative columns; they cannot inherit
China technology-transfer exclusions or a China-only origin gate.
These changes are source-derived across revisions; test HTS examples do not
control production behavior. See the retained [audit and limits](audits/2026-10-23-section301-reconstruction/README.md).

Compose the emitted `section301_rules.json` for each revision into that revision's
reviewed base bundle using the composer command above. It grants no complete
Section 301 coverage: the implemented note 20 and direct-heading exclusions do not
complete the other investigations, claims and Chapter 98 interactions. Do not substitute a test bundle. Source hash artifacts
must exist during composition; serving subsequently uses the stored bundle.

Release manifests now require `sail.tariff-release/v3`, the decision and claim-effect partitions,
and the new rate fields. Preparation validates their relationships locally and
does not activate anything. The rule/result API contract remains v1. An old v1/v2
release is not accepted by the new reader: rollback across this boundary requires
the compatible previous code and release, not only an active-ID change. Within
v3, retain the previous validated release for the existing atomic rollback path.


The source-backed exclusions and five retroactive amendments are part of this
same ordinary rebuild. Original-grant PDFs/text, extension notices and amendment
metadata are versioned in `resources/legal_evidence/`; altered or absent hashes
fail extraction. Read the [exclusion audit](audits/2026-10-23-section301-exclusions/README.md)
for verified scope, unresolved source boundaries and remaining legal gates.
