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
PDF revision header, and caches by source/extractor hashes. The coordinated source pass requires retained PDF and JSON archives before calculation;
acquire missing sources through the existing source-acquisition pipeline before rebuilding. Missing sources, unknown potentially operative charge
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

Release manifests now require `sail.tariff-release/v6`, the decision and claim-effect partitions,
and the new rate fields. Preparation validates their relationships locally and
does not activate anything. The rule/result API contract remains v1. An old v1/v2/v3/v4/v5
release is not accepted by the new reader: rollback across this boundary requires
the compatible previous code and release, not only an active-ID change. Within
v6, retain the previous validated release for the existing atomic rollback path.


The source-backed exclusions and five retroactive amendments are part of this
same ordinary rebuild. Original-grant PDFs/text, extension notices and amendment
metadata are versioned in `resources/legal_evidence/`; altered or absent hashes
fail extraction. Read the [exclusion audit](audits/2026-10-23-section301-exclusions/README.md)
for verified scope, unresolved source boundaries and remaining legal gates.

## Metals headings and independent IEEPA actions (release v4)

The normal build also emits `section232_scope_decisions.parquet`,
`ieepa_action_decisions.parquet`, and separate reciprocal/independent-EO
parameters in `authority_country_rates.parquet`. Every revision needs typed
partitions, including an empty partition when that particular regime is absent.
Release preparation checks product/candidate/source relationships and rejects
missing artifacts or mixed versions. It does not certify legal completeness.

Post-April metals revisions additionally emit `section232_note16_rules.json`;
IEEPA source extraction emits `ieepa_evidence_sources.json`. Compose the relevant
fragments into the same revision's reviewed base bundle, alongside its Section
301 and other action fragments. The note 16 fragment requires exact snapshot
intervals and carries conditional source discrepancies. It grants no complete
Section 232 coverage. Its column-1 duty amount must be the actual resolved
shipment duty, including specific/compound quantities and any verified preference.
Do not substitute a modeled base or aggregate AVE.

Read the [reporting-heading findings and remaining tasks](audits/2026-10-23-reporting-headings/README.md)
and [IEEPA interval limitation](audits/2026-10-23-ieepa-actions/README.md) before
interpreting a rebuild as complete historical correction. The shared build now splits the November 14 legal event; complete
coverage of other amendments, remaining authority predicates and consumers is
still unfinished. New tables and a successful rebuild alone do not close them.

Existing production data was only read. Rollback of this local source change is
a local revert on `wjr_dev`; no active MotherDuck identifier needs restoring.
After a later approved deployment, retain both the preceding validated release
and its compatible reader. Never activate partly regenerated partitions.

## Legal states and emergency-note provenance (release v5)

The ordinary build recalculates each known legal state inside a source revision.
`valid_from`/`valid_until` therefore need not be unique per revision. Preserve them
when combining, aggregating, exporting or preparing a release. The v5 preflight
rejects duplicate/incomplete product-country state grids and normalized windows
that disagree with the wide data. Daily states do not replace the exact entry
timestamps preserved in rule/source evidence. The existing aggregate horizon
extends to December 31, 2026; this audit only covers through October 22. Keep
shipment bundle coverage bounded to reviewed dates and do not certify the
remaining forecast period as audited history.

Section 122 production scope now comes from the matching revision's full note
2(aa), retaining statistical suffixes and use/description conditions. Each active
revision emits `section122_source.json` alongside the normalized exemptions. It
is source evidence, not a complete rule bundle. Emergency evidence now includes
ordinary/conditional actions, source notes and amendment chronology. Compose the
updated `ieepa_evidence_sources.json` into the reviewed bundle before preflight.

These source-only audits can be run before the manual rebuild. Choose new output
directories; they do not calculate a timeseries or write MotherDuck:

```sh
node frontend/scripts/audit-ieepa-emergency-motherduck.mjs \
  .env output/emergency-read-only.json
Rscript scripts/audit_ieepa_emergency.R \
  output/emergency-source-audit output/emergency-read-only.json
python3 scripts/audit_section122_sources.py output/section122-source-audit
```

The first command uses a read-only MotherDuck connection. The other two use
retained local sources. See the [findings, counts and remaining gates](audits/2026-10-23-legal-intervals/README.md).
Do not deploy a v5 reader against a v4 release. Rollback across the contract
boundary requires the previous compatible reader and release together.

## Historical metal scopes, headings and claim ordering (release v6)

The same manual rebuild now extracts March 12, 2025 through April 5, 2026 metal
scope from each archived Chapter 99 PDF and matching HTS JSON. Primary metal
scope is enumerated in the notes; chapter membership alone is insufficient.
Derivative lists preserve exact statistical suffixes, exclusions, limited
descriptions and UK alternatives. The old static derivative CSV is not the
scope source for this period. Retired and pre-effective headings cannot seed
the model through a product footnote.

Each applicable revision emits `section232_legacy_source.json` and
`section232_legacy_rules.json`. Compose the latter with the other reviewed action
fragments and the identified base bundle. It prices declared material values,
US-metal relief, Russian material/origin treatment and FTZ reporting distinctions;
it does not attest complete Section 232 coverage. Conditional candidates retain
null statutory rates and no synthesized scalar reporting code. Aggregate metal
shares remain model inputs, separate from these shipment rules.

The June 4 amendment changes rates, valuation and Canada/Mexico emergency
precedence at 00:01 Eastern. Its new revision fragment includes the previous
archived treatment for the first minute of the daily interval. Claim changes
reevaluate dependent actions; zero duty does not trigger positive-duty priority.
Registered Section 301 exclusions leave the reviewed metal actions unchanged.

Release v6 requires `state_valid_from` and `state_valid_until` (both DATE) on
`section232_scope_decisions.parquet`, including post-April note 16 decisions.
Preflight checks the exact daily state, scope/candidate inventory and evidence
hashes against the complete release. An older v5 partition is incompatible;
regenerate it rather than filling dates or rates in the API. The result/rule
contract remains v1, and browsers receive no MotherDuck credentials.

For a fresh independent source comparison, use new paths:

```sh
node frontend/scripts/audit-legacy-metals-motherduck.mjs \
  .env output/legacy-metals-read-only.json
python3 scripts/audit_section232_legacy.py output/legacy-metals-source-audit \
  --motherduck output/legacy-metals-read-only.json
```

These commands audit sources and read MotherDuck; they do not rebuild a timeseries
or publish data. See the [retained findings and limitations](audits/2026-10-23-legacy-metals/README.md).
Pre-March quotas/exclusions, the remaining cross-authority predicates, complete
chronology, exhaustive parity and downstream consumers remain release gates.
No live deployment or release activation has occurred. To undo the local code,
revert its commit on `wjr_dev`; after an eventual deployment, rollback across v6
requires both the compatible previous reader and its validated release.

## Pre-March quotas, exemptions and exclusions

The local implementation now also covers source-defined pre-March metal scopes,
quota/reporting decisions and general approved exclusions, including the old/new
heading transition inside 2025 revision 4. The aggregate country configuration
now restricts Japan/South Korea/Brazil/Ukraine relief to steel; an extracted-source
check rejects unsupported zero country overrides for either metal. These are
versioned scope/parameter corrections, with aggregate weighting methods retained.

Source-only audit and read-only MotherDuck comparison (no rebuild/publication):

```sh
node frontend/scripts/audit-legacy-metals-motherduck.mjs \
  .env output/pre-march-read-only.json --pre-march
python3 scripts/audit_section232_pre_march.py \
  output/pre-march-source-audit --motherduck output/pre-march-read-only.json
Rscript tests/test_s232_pre_march.R
Rscript tests/test_s232_pre_march_pipeline.R
node --test frontend/tests/shipment-pre-march.test.mjs
```

Choose unused output paths. The pipeline test writes only its bounded fixture to
a temporary directory. The all-55 manual rebuild command above remains the
required route for regenerating rates, normalized outputs and downstream data.
Individual Commerce grants and inconsistent published quota references remain
unresolved; do not treat a passing source audit as all-authority qualification.
See `docs/audits/2026-10-23-pre-march-metals/README.md` for evidence and limits.

## Optional reviewed Commerce grant snapshot

The legacy metal build can now consume reviewed individual decisions through
`SECTION232_GRANT_SNAPSHOT`. This is not an HTS correction list: each grant must
retain the original decision and its party/product/action/date/quantity limits.
The official bulk export is currently unavailable; no production grant snapshot
has been populated by this change. See `docs/section232-grant-evidence.md`.

Only after a real trade-intelligence snapshot has been exported and reviewed:

```sh
export SECTION232_GRANT_SNAPSHOT=/absolute/path/to/reviewed-grant-export/snapshot.json
python3 src/section232_grants.py "$SECTION232_GRANT_SNAPSHOT"
```

Then run the all-55 build at the top of this document manually, retaining that
environment variable for every revision. Do not point it at the synthetic test
fixture. A configured missing/corrupt snapshot fails compilation. The output
fragment includes the snapshot as a hashed source artifact; recomposition
retains its identity, and local release preparation rejects missing or mixed
grant pins. The regular release's trade-intelligence snapshot, new dataset
version and complete normalized/rate partitions remain required.

Without a reviewed snapshot, individual claims remain unavailable. Broad
all-authority, post-April-2026 grant and preference/Chapter 98 interactions still
need review. This option does not change aggregate shares, trigger a build,
publish a release or write to MotherDuck.
