# Shipment-duty action reconciliation

Spec: the user's five-step instruction and `docs/shipment-duty-rebuild-readiness.md`.
Base: `c0320c90` on the original `wjr_dev` checkout. The user authorized local
commits on this branch. Full timeseries/revision builds remain manual. Production
MotherDuck is read-only; no push, publication, activation or workflow change.

## Task 1: Reconcile the Chapter 99 inventory

Extract every numbered Chapter 99 provision from each of the 55 identified
PDF/JSON archives, preserving structural parents, inherited expressions, source
locators, temporal evidence and exact references. Link emitted rule definitions
without treating their presence as coverage. Retain precise unresolved questions
for missing authority/scope/origin/role/windows/valuation/interactions. Missing or
conflicting source inventories fail. Emit the inventory through the normal build.
Verify omission, duplicate conflict, unlinked-rule, historical expiry, snapshot
versus legal date, exact HTS10, source mutation and conditional-rule regressions.
Expected: Python inventory tests pass; a source-only all-revision census succeeds;
normal-emitter fixture retains the typed inventory without generating zero duty.

## Task 2: Complete dependent Section 232 and reciprocal decisions

Use the inventory to prioritize unlinked sector/country/claim decisions and
post-June-30 reciprocal chronology. Reconcile original annexes and amendments.
Preserve candidate actions and conditional valuation instead of model maxima.
Expected: source-backed targeted and adjacent-case R/TypeScript tests pass; all
remaining gaps identify their precise legal question and affected interval.

## Task 3: Close other claims and valuation interactions

Reconcile remaining IEEPA/122/338/301 decisions, including Chapter 98, transit,
FTZ, zero-payable actions, offsets and action-specific exclusion chronology.
Expected: complete legal predicates and bounded source/fact failures are exercised
by independent source and cross-program regressions.

## Task 4: Connect the ordinary Parquet build

Assemble production bundles, coverage evidence and decision partitions from the
same definitions; preserve aggregate modeling separately. Extend local release
schema/preflight and serving contracts if necessary. Expected: local DuckDB and
JSON/Arrow/batch checks preserve conditions, provenance and completeness.

## Task 5: Exhaustive checks and rebuild handoff

Implement all-action inventory/interval checks and fact-branch boundary tests;
run read-only MotherDuck comparisons and required regression gates. Retain exact
coverage limits and manual rebuild commands. Expected: no silent missing action,
source, input or unexplained component; full rebuild and live activation remain
user-controlled. Complete the work before claiming legal or release completion.
