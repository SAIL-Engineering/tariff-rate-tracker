# August copper portions, suspension continuation and the wide-build gap

Local follow-up to `09fb2dc1`, original tracker `wjr_dev`. No full revision or
timeseries build, production MotherDuck write, activation, push or deployment.

[EO 14326 sections 2(a), (e), (g)](https://www.govinfo.gov/content/pkg/FR-2025-08-06/html/2025-15010.htm)
continue the prior non-China suspension until seven days after the July 31
signature, while preserving China's separate suspension. The executable horizon
now ends exclusively **August 7, 2025, 00:01 EDT**. The first minute of that HTS
revision still uses the preceding legal policy. The later country-specific
heading inventory is retained from the original White House Annex II PDF but is
not yet represented as executable coverage by this follow-up.

[Proclamation 10962 clause 4](https://www.govinfo.gov/content/pkg/FR-2025-08-05/html/2025-14893.htm)
requires reciprocal duty on non-copper value from August 1. The compiler binds
the original copper heading to a matched action, excludes its actual covered
value, and reconciles disjoint metals, U.S. content and Chapter 98 intersections.
It does not select a positive duty or a modeled metal share. A known exemption
reporting identity remains available even when the charged component's value
cannot yet be calculated; missing value never becomes zero additional duty.

[CBP CSMS 65794272](https://content.govdelivery.com/bulletins/gd/USDHSCBP-3ebf0e0)
was located through the official IEEPA FAQ and retained with its source hash. It
requires separate content reporting and describes full-entered-value treatment
when copper value cannot be determined or substantiated. That declared state is
different from an omitted input. Full copper action/valuation and automobile
priority compilation remains required; these dependency fixtures use explicitly
synthetic copper amounts and do not attest a complete copper inventory.

The shared R/TypeScript constraint evaluator now asks only for missing operands
until a contradiction is established. Proven contradictions retain their input
correction hints; legal questions and invalid non-boolean constraints remain
source errors. Unsupported selectors, array scopes and invalid HTS precision
fail explicitly. Positive synthetic controls now omit universal scopes rather
than incorrectly serializing them as arrays. SAIL's shared change is committed
and merged locally into `pinecone-hts` at `62e85ee35`; its existing work and newer
commits were preserved. The tracker runtime is generated from that shared source.

Verification: **394 Python**, **558 Node**, **97 reciprocal R cases**, nine new
constraint/scope checks and the affected R authority suites pass. All **55**
configured sources compile with the new bounded horizon. SAIL's configured unit
suite passes **20,714** tests with 45 skips; its focused shared-interpreter suite
passes 50, typecheck gate and local build pass, and focused lint passes. Full
lint still reports errors outside the changed source/test files. Earlier Node18
and missing-environment failures do not qualify the change. Exact evidence is in
`verification.json` and the logs.

A READ_ONLY MotherDuck transaction retrieved **220** rows across four pairs and
55 revisions. France/China ordinary reciprocal components on August 2 remain 0%
instead of 10%. The two copper rows present 51.5% and 96.5% complete totals while
the required valuation/status facts are unspecified. The latter are incomplete
shipment contracts, not findings that either shipment owes a particular corrected
total. No live complete stack is certified.

**Emitting these fragments does not apply them to wide Parquet rates.** The
ordinary wide calculator still uses legacy aggregation/statutory stacking.
Automatic bundle assembly, source-backed coverage, exact-time evaluation,
decision persistence and shipment-field projection are the next required change.
Aggregate series retain their modeling meaning. A final rebuild remains deferred
until that path and the remaining legal interactions are ready.

See [the manual rebuild runbook](../../shipment-duty-manual-rebuild.md). Code
rollback is a local revert of this follow-up; no active release was changed.
