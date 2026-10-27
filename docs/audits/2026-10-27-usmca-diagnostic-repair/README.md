# Empty-seed USMCA join and diagnostic delivery repair

Base `85b409f7` on original tracker `wjr_dev`. The user ran the bounded diagnostic
from frozen `a653c4aa`;2025 completed and2026 stopped. This repair changes the
ordinary calculator and diagnostic output, not legal rates or action dates.

## Root cause

The first footnote calculation returned no rows for the2026 cohort. Its empty
table was passed through `enforce_rate_schema()`, which adds the output/default
`usmca_eligible` column. Grid expansion then populated that table. Step7 joined
the actual source-extracted eligibility table without replacing the placeholder,
so dplyr created `.x`/`.y` columns. The next expression requested the now-absent
bare name. Earlier normal-pipeline fixtures passed `usmca=NULL`, leaving this
ordinary driver path untested.

Step7 now replaces that schema/output field with the supplied source table
before joining. The many-to-one relationship and subsequent country treatment
remain intact. It does not OR a default with evidence, reinterpret missing
shipment facts, or change modeled preference shares. The source claim framework
still determines shipment eligibility independently. No HTS, origin or date
example enters production logic.

The launcher previously printed only the last25 log lines. R's warnings and
backtrace displaced the actual error from that excerpt. It now shows the root
error block and keeps the complete log.

## Additional serving-path finding

The actual-source transport check found identical missing facts in different
orders inside R and TypeScript components. R previously sorted only top-level
diagnostics; the shared interpreter sorts every combined set. R now sorts and
deduplicates diagnostics before caching each resolved rule. Components and rule
decisions therefore have the same stable order in both runtimes. This does not
alter duty amounts. A small shared conformance fixture covers nested missing
facts and unresolved-source questions without weakening the transport comparison.

## Verification and limits

The actual-source six-cell regression reproduced the missing-column error
before the change. It now passes across two HTS products and Canada, Mexico and
Germany, using the same non-null source table as the diagnostic driver. Sourced
eligibility flags survive and no suffix columns escape. Complete shipment
totals remainNULL when required source coverage or facts are unresolved.

Fresh checks passed437Python tests,684Node tests,151rate-calculation tests,
279direct/prepared evaluator cases, and the affected rules, constraints,
projection and legal-interval suites. The six-cell Parquet fixture passes
JSON/Arrow/batch, dataset invalidation and bundle-tampering checks and stages a
local v8 `prepared_diagnostic` release. It cannot activate or qualify production.

The completed2025 output from WJR's run was independently validated read-only:
88grid cells,176 memberships,75classes and2bundles agree with their saved rules.
It remains evidence at its original dataset version. It cannot be mixed into a
corrected release with a different source/dataset version.

The same11-product/eight-origin2026cohort is additionally checked at the failing
entry date through one ordinary point-calculator invocation. This is separate
from the revision/timeseries builder, which remains WJR-only. Its source inputs
are independently parsed and version-pinned before use. Full-cohort reconciliation
and the final replacement source snapshot are recorded in `verification.json`.
All88cells pass reconciliation; the full point fixture also stages successfully
as a local `prepared_diagnostic` release with176memberships,106classes and2bundles.

The corrected source pin is `2738d79fa0eaa158539e6d20649a9824fe83b4fb`.
Its complete source package is already prepared at
`/tmp/wjr-shipment-source-2738d79fa0ea-v2`; its dataset identity matches both
the passing point calculation and local release. The driver's source-only plan
also passes there. Use the single updated command in
[DIAGNOSTICS.md](../2026-10-26-indexed-release/DIAGNOSTICS.md), since the original
`a653c4aa` pin deliberately retains the older calculator code. No cleanup of the
original failed runs is required.

The earlier partial88-cell attempt was stopped before editing the interpreter
to correct nested diagnostic ordering; it is not counted as verification.
The final calculation uses frozen code for the entire run.

The complete R gate is not claimed green. Historical normalized artifacts and
TPC input still require the user's rebuild/input; broader legal coverage and
legacy safeguard/scope/citation warnings remain open. Source-version changes
require a new diagnostic pin. No production MotherDuck write, publication,
workflow change, push or revision/timeseries rebuild was performed by Codex.
