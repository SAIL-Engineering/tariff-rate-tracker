# Shipment duty implementation and integration status

Audit cutoff: 2026-10-22. This is an in-progress implementation, not legal or
production release qualification. Local integration does not activate a dataset.

## Branches and durable worktrees

| Repository | Working branch | Original base SHA | Local merge destination | Durable worktree |
| --- | --- | --- | --- | --- |
| tariff-rate-tracker | codex/shipment-duty-correctness | fca8db2c88fa11370b6dd1c291f36b03dc3bd17a | wjr_dev | SAIL_Engineering/sor-lanes/shipment-duty-tracker |
| sail-trade-intel-data | codex/shipment-duty-evidence | bb6a17f23494de60206d8cf39d8752eb9725fadc | main | SAIL_Engineering/sor-lanes/shipment-duty-evidence |
| sail-gtx-prerelease | codex/shipment-duty-correctness-ui | 2260f0787259253f810a8c5d3462ba02c9c5eb72 | pinecone-hts | SAIL_Engineering/sor-lanes/shipment-duty-ui |

WJR explicitly authorized local merges into the branches above, superseding the
original no-merge instruction. The tracker has `wjr_dev`, not `wjr-dev`; this was
verified against local refs. Original checkouts and unrelated worktrees remain
preserved. All three implementation worktrees were moved out of `/tmp`.

## Production destination and approval boundary

MotherDuck remains the production database for both data repositories. Evidence
snapshots and local DuckDB files are reproducible interchange/test artifacts.
The tracker must serve a complete versioned release across every configured
revision, rather than depend on one pinned local revision. A release is pinned to
an identified evidence snapshot, not permanently pinned to one HTS revision.

No push, deployment, workflow dispatch, data publication, live MotherDuck write
or active release change is authorized. Revisit the explicit production migration
and activation approval with WJR after implementation and validation are complete.
The new customs-reference refresh workflow was explicitly authorized as a code
change and is included locally; it has not been dispatched. Existing source
publication schedules have not been changed.

## Implemented foundation

- AD/CVD evidence retains company/case identity, instruction sections, operative
  entry windows, source offsets and correction references. Interpretation still
  requires scope and chronology review. Served evidence schema is version 8.
- Read-only evidence export pins source hashes, publication versions and validated
  customs-reference artifacts. It declares incomplete historical reconciliation.
- Independent R and shared SAIL TypeScript shipment interpreters distinguish
  unresolved sources, missing inputs, known subtotal and complete total. Rules
  carry formulas, claims, conditions, citations, reporting codes and versions.
- Strict duty-expression parsing preserves quantity and component valuation bases;
  unknown text remains unresolved. Product inheritance no longer crosses siblings.
- Initial statutory/model separation and dated Section 338 amendment handling are
  implemented. These do not establish correctness of every tariff action.
- Local immutable release preparation and read-only API serving have JSON, Arrow,
  batch, missing-contract, version and rollback tests. Preparation never activates.
- SAIL's AD/CVD instruction view shows entry windows and unresolved interpretation.
  The production shipment consumers still require migration to the new contract.

## Remaining implementation and release gates

1. Reconcile all primary legal sources and the ten handoff findings, including the
   Canadian beer result. Neither 40% nor 60% is an accepted oracle yet.
2. Build verified executable rule bundles across all action intervals. Finish
   claim interactions, mixed metals, vehicles/parts, floors/caps, Section 201/301/
   122/338, quotas, Chapter 98 and AD/CVD scope/party/instruction chronology.
3. Remove residual-duty attribution, predicted reporting headings, silent zero
   defaults and remaining model-share leakage. Extend normalized action coverage.
4. Export and pin the actual reconciled evidence snapshot. Complete release
   coverage validation, migrations, immutable preparation and cloud rollout tools.
5. Migrate Duty Workspace, Tariff Schedule, comparisons, scenarios, bulk/export,
   Product DNA, saved results and Post-Entry Audit without aggregate fallbacks.
   Preserve authentication, tenancy, saved dataset versions and explicit recalc.
6. WJR will manually rebuild the 55 configured revisions, including normalized
   revisions 20 and 21, and any additional verified release within the cutoff.
   Do not run timeseries rebuilds on WJR's behalf. Exact commands and the pinned
   55-revision list are in [shipment-duty-manual-rebuild.md](shipment-duty-manual-rebuild.md).
   The exploratory revision 21 build predates later fixes and is not final.
7. Complete action-attribution/temporal/parity/property sweeps, aggregate difference
   review, required R/Python/UI gates and browser checks. Local fixtures cannot
   establish legal completeness or replace the later approved live smoke test.
8. Integrate validated commits locally into the destination branches, record the
   exact integrated SHAs and rollback instructions, and then present the concrete
   MotherDuck migration/activation proposal for WJR's approval.

Known subtotal is never labeled complete when facts or source coverage are missing.
HTS associations are discovery aids, not AD/CVD scope determinations. Final
liquidation, refund filing and brokerage/logistics charges remain outside scope.


## Read-only production audit checkpoint

[MotherDuck audit](audits/2026-10-23-motherduck/README.md): 267,714,240 live rows,
55 revisions, 240 origins and 97 represented chapters. Structural diagnostics are
not legal validation of every row. Primary-source comparisons found overlapping
revision windows, statutory/model leakage, conditional Section 122 exemptions
broadened to whole codes, stale exact-code Section 338 coverage, and quartz
candidates lost when their legal start falls inside a revision. Local fixes and
regressions are recorded in that report. No timeseries rebuild or cloud write was
performed during this audit. Full rule compilation and consumer migration remain
open; a manual rebuild alone does not clear the release gates.

### IEEPA/232 follow-up

[The next read-only audit](audits/2026-10-23-stacking-followup/README.md) fixes
dated action precedence and inheritance, Hong Kong fentanyl valuation, and
semiconductor statutory/model separation. It records 57,628 priority-pattern
candidates and 77,541 Hong Kong overlap rows for further legal review. Missing
statutory components now leave totals unavailable. Aggregate historical
corrections are stacking-model version 2; the manual rebuild and serving-path
qualification remain pending.


## Conditional-action and serving checkpoint, 2026-10-23

The tracker audit at `docs/audits/2026-10-23-conditional-actions/README.md` retains
37,712 grouped live MotherDuck rows plus 4,840 exact samples across 55 revisions
and 8 origins. Semiconductor technical/end-use liability and automobile-parts
use predicates now come from reviewed source fragments; candidate scopes survive
aggregate suppression. Exact Section 301 scope has real-source regressions, but
full legacy note/amendment reconstruction and its MAX-rate replacement remain open.

The shared R/TypeScript contract exposes rule and authority-coverage decisions,
including source-backed absence, required facts and source citations. The existing
Duty Workspace exact lookup has a version-pinned shipment determination panel;
it makes no aggregate fallback and preserves null complete totals. Legacy financial
consumers, comparisons/bulk/export, HTS Explorer, saved results, Product DNA and PEA
still need full migration. No complete production bundle or deployment is claimed.

This pass's checks: 44 shared conformance fixtures, 35 semiconductor cases with
synthetic companion actions, 97 tracker/API tests, 92 SAIL tests, changed-file lint,
unchanged typecheck baseline and local production build. R full suite has 24/26
passing suites; data-dependent normalized parity and TPC remain unqualified.
The final auto-parts model/total guards passed focused R checks. gstack checks used
an isolated component fixture, not an authenticated production page or live MD.
Timeseries rebuilds remain WJR's manual task. No production activation occurred.
