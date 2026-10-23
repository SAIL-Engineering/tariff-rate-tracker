# Shipment-duty local integration checkpoint

This integrates the implementation completed so far. It does **not** complete the
shipment-duty plan, certify legal completeness, or activate corrected data.
The audit cutoff remains 2026-10-22.

## Integrated commits

| Repository | Local destination | Integration merge |
| --- | --- | --- |
| tariff-rate-tracker | `wjr_dev` | `82d337a811fb1b4a7b7ed61b126ff3ee5f655d7f` |
| sail-trade-intel-data | `main` | `eeb29da3c327a6c5509ca6557f69e95e1481f460` |
| sail-gtx-prerelease | `pinecone-hts` | `a6654a2067b1172bd288f6f3c68ca8d47cf5edd9` |

Each destination contains all commits from its shipment-duty working branch.
The original tracker branch is spelled `wjr_dev`; there is no local `wjr-dev`.
Working copies are durable directories under `SAIL_Engineering/sor-lanes/`, named
`shipment-duty-tracker`, `shipment-duty-evidence`, and `shipment-duty-ui`.
The original SAIL checkout's untracked work was preserved, including the challenged
Product Intelligence plan. No branch was pushed and no publication was dispatched.

The SAIL integration selectively reuses commit
`ae8e8ff85c5d3b2958521ecca12987e4e75b9328` as `cb25c49bb`: a three-file existing
fix that prevents compiler crashes from appearing as successful typechecks and
removes three type errors outside the app baseline. It does not merge that whole
hotfix branch. The source branch is preserved.

## Local verification

- Trade Intelligence: 1,304 offline Python tests ran successfully with one existing
  live-source-fixture skip. Six snapshot/export tests and six workflow/publication
  helper tests also passed. No live MotherDuck test or publication occurred.
- Tracker release/API: 38 tests passed, including 32 shared conformance fixtures,
  immutable preparation, validation/activation separation, rollback, hashes,
  missing versions, JSON/Arrow/batch, and reopening a read-only database after
  deleting its interchange files. Attempts to write to that reader were rejected.
- R: 18 of 20 suites passed. These include 386 counted legacy assertions and the
  new expression, inheritance, amendment and 32-case shipment-conformance suites.
  Normalized parity failed because its 2,008 selected cases require revision
  outputs absent from this worktree; the comparison suite needing built TPC data
  skipped. This is not a passing full-data or 55-revision qualification.
- SAIL: the full unit run passed 20,582 tests with 49 skipped; three additional
  suites could not load missing generated export-control fixtures. After reusing
  the existing fixtures, those three suites passed all 45 tests. The reused
  typecheck fix then passed all 219 affected request/error-handling tests.
- SAIL typecheck: the hardened gate passed with zero server errors and 229 app
  errors across 57 files, all within the committed baseline. The original base
  and the shipment branch before the reused fix each had the same 232 errors.
  A simulated compiler exit 134 correctly failed the hardened gate, without PASS.
- Both production builds passed locally, including SAIL prerender and its vendor
  neutral release guard. No build was deployed.
- Changed shipment files passed lint. The complete SAIL lint command remains red
  on existing code elsewhere (590 errors, 311 warnings); the baseline was not
  weakened and unrelated code was not rewritten to conceal this result.
- Authenticated browser acceptance remains pending. The repo intentionally refuses
  `vite preview`; its approved local/staging development environment must be used.
  No authentication or environment guard was bypassed.

These checks establish the stated local behavior only. Synthetic conformance
fixtures are not statutory oracles, and old generated data is not a corrected
historical release. The exploratory revision 21 build is not the final artifact.

## MotherDuck and completion boundary

MotherDuck remains the intended production store, with the API reading a complete
versioned release across the configured revisions. A pinned evidence snapshot
makes a release reproducible; it does not permanently restrict serving to one
revision. Local exports and DuckDB tests do not replace either production database.

The full primary-source audit, real rule-bundle compilation, all remaining claim
and action interactions, SAIL financial-consumer migration, historical AD/CVD
reconciliation, all 55 rebuilt revisions, full coverage/parity sweeps and live
qualification are still open. See the implementation/integration status document
in this repository. No complete at-entry total may be inferred from partial work.

Review the concrete migrations, prepared release, preflight report, evidence
versions, coverage and rollback with WJR **after** these gates are complete.
Production MotherDuck writes, active release switches, pushes, deployments and
workflow dispatches still require WJR's explicit approval.

## Rollback

No active database release was changed, so there is no live data rollback to run.
For a local code rollback, preserve any later work and revert the applicable merge
from the table with `git revert -m 1 <integration-merge>`. Do not reset or delete
other worktrees. The previous release remains the rollback target when a future
approved activation is eventually performed; that activation is not part of this
checkpoint.


## Additional MotherDuck audit checkpoint, 2026-10-23

The follow-up audit and corrections are documented in
[audits/2026-10-23-motherduck/README.md](audits/2026-10-23-motherduck/README.md),
with the raw read-only snapshot, primary evidence, reconciliation and verification
logs committed alongside it. The new schema fields and strengthened rule inventory
are documented in `normalized-schema.md` and `shipment-rule-contract.md`.
Timeseries rebuilds are WJR's manual task; see
[shipment-duty-manual-rebuild.md](shipment-duty-manual-rebuild.md).

The original integration SHAs above remain historical checkpoints. Follow-up
commits preserve those bases and the concurrent SAIL commit `04b71480b`; inspect
the local branch log for the later audit integration. No active release changed.


## Conditional-action integration, 2026-10-23

| Repository | Base at start of this pass | Implementation commit | Local integration merge |
| --- | --- | --- | --- |
| Tracker `wjr_dev` | `42a3bb5f631a816f5a5d19d0d80d9644e9481609` | `11ae7503acf07212262fc9363f17c2db5ff60b79` | `5ca4d121b02f78d6936eb99671880607627a4bb1` |
| SAIL `pinecone-hts` | `2d0d25b23ef69949629a3d38496677f1157a7fb9` | `f9e2fe7d5f4669f1fc4595c799fce54a2539edc6` | `5d8e5b430a43c67c6b2f3522e1f20d5a95be6cc7` |
| Trade Intelligence `main` | `766334b6b41dd5f45cfd3df583b7c5d53447ae1a` | No new change | Unchanged; contains the evidence branch |

These merges are in the original checkouts, not only the durable worktrees.
SAIL's two pre-existing untracked entries remain unchanged. Both merge trees
match their tested implementation commits. The shared interpreter SHA256 is
`a57d64d9ecf259d6710761e52409aca6f140549ee3d60b0b5af0648171524ab8`;
the tracker generated runtime identifies that same SAIL source hash.

See [the conditional-action audit](audits/2026-10-23-conditional-actions/README.md)
for source findings, 37,712 grouped live rows/4,840 exact samples, contract changes,
retained test/browser evidence and remaining gaps. All retained audit files are
tracked and their hashes verified. No timeseries revisions were regenerated.
The manual rebuild runbook remains the command source for WJR.

Local rollback, after preserving later work, is `git revert -m 1` with the
applicable integration merge in the table. Coordinate the R/TypeScript/result
contract rollback across both repos. No live rollback is needed: no production
release, MotherDuck table, deployment or published object changed. Do not activate
partial fragments or bypass the remaining all-authority/consumer/rebuild gates.
