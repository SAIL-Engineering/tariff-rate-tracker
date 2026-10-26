# Manual rebuild and verification commands

WJR requested that **all timeseries/revision rebuilds be run manually**. None of
these build commands was run during the MotherDuck audit. The code is integrated
locally into `wjr_dev`; no push or MotherDuck write is part of this runbook.

This is a reproducible rebuild command for the current corrections, not a claim
that the entire shipment-duty plan is finished. Finish the remaining legal/rule
and serving-path gates before approving publication. Save the current generated
outputs first if an aggregate before/after comparison is needed. Record `git
rev-parse HEAD`, the policy/resource hashes and the evidence snapshot used.

## October25 normal-build integration checkpoint

The ordinary calculator now assembles executable bundles and evaluates shipment
decisions after constructing the aggregate grid. It emits `shipment_rules.json`
as a versioned exact-time bundle index, immutable bundle files, decision classes
and product/origin membership Parquets. Wide shipment fields come from those
decisions. The declared quote uses USD1 customs value and no preference claim;
it assumes no FTZ, content, use, quota, party or quantity facts. This mathematical
reference is not a completed shipment declaration. Incomplete totals are null.
Previous aggregate-backed statutory projections are retained under
`modeled_legacy_*`; economic rate columns retain their methodology. Legacy scalar
codes/provenance are retained under `aggregate_*`, with reporting decisions in
the executable result. Model shares and credits cannot alter these decisions.

**Keep the final rebuild on hold.** Broader executable authority coverage,
financial consumers and the production release preparer's multi-bundle/index
upgrade remain unfinished. The current v7 release preparer rejects the new index;
the local API fixture is a serializer/evaluator test, not production release
preparation. A real pinned export also remains required. Do not activate a wide
table alone or relabel the placeholder as an evidence snapshot.

Read-only source/extraction preflight (does not build any rates):

```sh
Rscript scripts/preflight_shipment_sources.R \
  --output=output/manual-shipment-rebuild/source-preflight.json
```

All55 configured primary HTS/Chapter99/GN3 files are present. The census identified
one malformed native HTS branch in2025_rev_16; it remains explicitly unpriced,
with its PDF/JSON discrepancy and neighboring valid code retained in
`docs/audits/2026-10-25-shipment-normal-build`. The preflight reports it as an
unresolved inventory rather than succeeding silently. Other complete duty
expressions requiring further executable extraction are listed in its report.

For the eventual manual build, supply the existing Trade Intelligence export's
manifest via `SAIL_DUTY_EVIDENCE_MANIFEST=/absolute/path/to/manifest.json`.
The tracker checks schema8/extractor2, snapshot identity, every table hash/row
count, published-manifest hash and reference-artifact hashes. A valid export
remains `requires_reconciliation`; it does not certify AD/CVD scope coverage.
Configured Commerce grant snapshots also enter the dataset/cache identity.

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

## Reciprocal country, claim and metal-portion rules

The normal normalized emitter now also writes
`ieepa_reciprocal_initial_rules.json` for every configured 2025/2026 revision.
This source-derived fragment implements the original April 5, April 9 and April
10 actions, the May 14 China suspension, the corrected June 16 transit deadline,
the June 4 metal-portion interaction, June 30 UK aircraft relief and July 9
suspension extension. Its legal horizon ends **exclusively at
August 1, 2025, 00:01 Eastern**, before the next copper/country-policy interval. Empty
rules outside that horizon mean unsupported coverage, never zero liability.

Compose this fragment together with the same revision's other reviewed authority
fragments and `ieepa_reciprocal_scope_evidence.json`. Section 232 reporting
dependencies must be bound in the same composition; missing Section 232 coverage
keeps the reciprocal result unresolved. Use a reviewed base bundle, not fixtures.
The emitter and tests do not construct a production-ready all-authority bundle.
The existing release v7 and result v1 contracts are unchanged by this addition.

Run its source and cross-program regressions without a timeseries rebuild:

```sh
python3 -m pytest -q tests/python/test_ieepa_reciprocal_initial.py
Rscript tests/test_ieepa_reciprocal_rules.R
Rscript tests/test_reciprocal_pipeline.R
node --test frontend/tests/shipment-ieepa-reciprocal.test.mjs
```

The pipeline test uses a small, temporary product/origin fixture and deletes its
outputs. Full builds remain the manual commands above. A repeat read-only live
comparison of the original-action cases is:

```sh
node frontend/scripts/audit-shipment-motherduck.mjs \
  --out output/reciprocal-initial-motherduck-AFTER \
  --cases resources/shipment_audit/reciprocal_initial_cases.json
```

See the [executable reciprocal audit](audits/2026-10-25-reciprocal-executable/README.md)
for source discrepancies, valuation assumptions and remaining coverage boundaries.


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
  output/normalized/REVISION/section232_semiconductors_rules.json \
  resources/shipment_rules/s232_auto_parts_condition.json
```

This is not the full rule compiler and does not grant coverage or publication
approval. Do not use the synthetic test bundle as the base of a real release.
Use the newly emitted revision-bound semiconductor fragment. The original static
January fragment is a reviewed interpreter template and historical regression
fixture; it does not contain the April, May and June amendment chronology or the
executable FTZ/Chapter 98 questions. Normal 2026 builds now emit the dated fragment,
exact product candidates and Chapter 99 inventory links automatically. The full
production bundle still requires the remaining authority inventory and composition.
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

Release manifests now require `sail.tariff-release/v7`, the decision and claim-effect partitions,
and the new rate fields. Preparation validates their relationships locally and
does not activate anything. The rule/result API contract remains v1. An old v1/v2/v3/v4/v5/v6
release is not accepted by the new reader: rollback across this boundary requires
the compatible previous code and release, not only an active-ID change. Within
v7, retain the previous validated release for the existing atomic rollback path.


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

## Executable Section 122 interaction dependency

The next ordinary build emits `section122_rules.json` for active Section 122
states. Compose this fragment alongside the same revision's Section 232 and
Section 301 fragments. It binds reporting decisions and requires verified
Section 232 coverage before pricing a remaining taxable portion. Missing rules
or attestations cannot be replaced by zero/aggregate values.

The shared R and SAIL interpreters must both include `authority_covered` before
a later approved release activation. Use a new dataset version. No extra live
migration is required; the versioned rule bundle carries the expression. Read
[the interaction findings and remaining source conflicts](audits/2026-10-23-section122-interactions/README.md).

A source-only check, independent of WJR's timeseries rebuild, is:

```sh
python3 scripts/audit_section122_interactions.py output/section122-interactions-NEW.json
Rscript tests/test_s122_rules.R
```

## Executable Section 338 and Chapter 98 dependency

The normal emitter also writes `section338_source.json` and
`section338_rules.json`, and action-specific rows in the existing
`authority_product_applicability.parquet`. The latter exposes
`legal_rate_parameter`, exact/prefix scope, `requires_section232_inventory`,
`source_ids_json` and `entry_valid_from`; it leaves unpriced `statutory_rate` NULL.
These are additive columns in an existing release table, not permission to
replace the active table in place. Rebuild every partition consistently.

Compose each revision's emitted Section 338 fragment with that revision's
reviewed base bundle and other fragments. It retains August 22/September 15
instants even when they fall between HTS publications. Reuse of a single pinned
revision does not satisfy the release contract. Example local composition:

```sh
Rscript scripts/compile_shipment_rules.R BASE_BUNDLE.json NEW_COMPOSED_BUNDLE.json \
  output/normalized/REVISION/section338_rules.json \
  OTHER_REVIEWED_FRAGMENTS.json
```

The Section 122/338 Chapter 98 clauses now use revision-valid provisions,
proper claim/CBP agreement and source-defined repair/assembly values. Supply
`CHAPTER_98` in the shipment's claims when selecting that treatment. Other
authorities with uncompiled claim effects remain “Claim not priced.” Intersecting
Section 232 and adjusted Chapter 98 values needs a reconciled overlap value.

Read-only/source-only reproduction, without a timeseries rebuild:

```sh
node frontend/scripts/audit-section338-motherduck.mjs .env NEW_MD_EXPORT.json
python3 scripts/audit_section338_sources.py NEW_AUDIT_DIR --motherduck NEW_MD_EXPORT.json
Rscript tests/test_s338_rules.R
Rscript tests/test_s338_pipeline.R
```

The last command uses four products in temporary local output. It is not a
revision rebuild. See the [evidence, findings and limits](audits/2026-10-24-section338-valuation/README.md).
No live MotherDuck publication is authorized. The full R gate still requires
rebuilt normalized partitions and the actual TPC input.

## Section 301 Chapter 98 and claim identity follow-up

The normal emitter now adds source-defined Chapter 98 valuation and exemption
rules to `section301_rules.json`; no additional timeseries command is needed.
`claim_effects.parquet` retains the formulas, constraints and verification state.
Select `CHAPTER_98` explicitly and provide the applicable revision-valid
`chapter98_provision`, `chapter98_properly_claimed`, and requested valuation facts.
Sections 122/338 retain their separately required CBP-agreement fact. Unreviewed
effects on another action remain `claim_not_priced`. A Section 301 exclusion
identity must not be reused to bypass another claim's missing effect.

```sh
python3 scripts/audit_section301_chapter98.py NEW_301_CHAPTER98_AUDIT_DIR
Rscript tests/test_section301_revision.R
node --test frontend/tests/section301-reconstruction.test.mjs
```

The audit checks all 55 revisions without rebuilding rates or writing MotherDuck.
See [the legal and verification report](audits/2026-10-24-section301-chapter98/README.md).

## Executable IEEPA emergency follow-up

The ordinary normalized build now emits `ieepa_emergency_rules.json` beside the
existing evidence-only fragment. Compose it with the same revision's reviewed
base, Section 232 and Section 301 fragments. Its rules keep exact amendment
instants inside the daily revision window. `USMCA` requires actual free entry
under GN11; Chapter 98 requires its own proper-claim/CBP-agreement and valuation
facts. FTZ and de minimis paths remain explicitly unresolved.

```sh
Rscript scripts/compile_shipment_rules.R BASE_BUNDLE.json NEW_COMPOSED_BUNDLE.json \
  output/normalized/REVISION/ieepa_evidence_sources.json \
  output/normalized/REVISION/ieepa_emergency_rules.json \
  output/normalized/REVISION/section232_legacy_rules.json \
  output/normalized/REVISION/section301_rules.json
python3 scripts/audit_ieepa_executable.py NEW_EXECUTABLE_AUDIT_DIR
```

Use the appropriate Section 232 fragment for the revision. A synthetic test
bundle is not a production base bundle. The complete release and broader legal
coverage remain unfinished; this does not authorize a rebuild, MotherDuck
write, activation or publication. The existing timeseries commands above remain
WJR's to run once the remaining logic is ready. See
[the legal, serving and audit report](audits/2026-10-24-ieepa-executable/README.md).

## Reciprocal Annex II correction (release v7)

The ordinary rebuild now uses original-annex chronology through
`src/ieepa_reciprocal_sources.py` and `src/ieepa_reciprocal_history.py` for every
2025/2026 revision. It does not read the legacy universal CSV. The two old
regeneration scripts deliberately fail with a replacement command; they must
not reconstruct legal dates from first appearances or widen HTS10 to HTS8.
The ETR YAML exporter uses the same source-derived unconditional list.

A source-only audit, which does **not** rebuild the timeseries, is:

```sh
python3 scripts/audit_reciprocal_scope.py --out output/reciprocal-scope-audit-NEW
```

Every normalized revision now needs `ieepa_reciprocal_scope_decisions.parquet`,
`ieepa_reciprocal_source.json`, and `ieepa_reciprocal_scope_evidence.json`.
Include the evidence fragment when composing that revision's rule bundle:

```sh
Rscript scripts/compile_shipment_rules.R BASE_BUNDLE.json COMPOSED_BUNDLE.json \
  output/normalized/REVISION/ieepa_reciprocal_scope_evidence.json
```

This fragment pins product-exemption chronology and primary sources; it does
not supply the remaining reciprocal charge/claim/FTZ rules or grant coverage.
Release **v7** requires the new decision partition and its matching chronology
pin in `bundle.evidence_dependencies.reciprocal_scope`. Preparation persists
the partition and pin with the immutable release and rejects missing/altered
scope, conditions, dates, sources and revision membership. Use the normal local
preparation tool only after the full rule bundle has passed legal qualification.
A v6 release is unsupported by the v7 reader. A later approved rollback across
this boundary requires matching v6 code and the previous validated release.
No activation or MotherDuck write has been performed.

The legacy artifact gate now also checks missing revision directories, including
20 and 21; undiscovered directories can no longer disappear from its count.
See the [source audit and current limits](audits/2026-10-25-reciprocal-scope/README.md).

The exact shipment interpreter now requires the R `gmp` dependency. Install the
tracked required dependencies before any later manual build:

```bash
Rscript src/install_dependencies.R
Rscript src/preflight.R
```

Shipment arithmetic retains decimal rationals internally; percentages and cents
retain their divisors in the source expression. Wide scalar rates also require
value-invariant applicability, suppression and valuation constraints. A USD1
reference inactivity cannot establish a zero rate for a larger shipment. The
legal-state merger preserves immutable JSON bytes and validates staged bundle
hashes before replacing a revision. These fixes do not complete the unreviewed
legal inventories or upgrade the v7 production release preparer. Keep the final
timeseries rebuild on hold.
