# Value-sensitive shipment decisions and immutable delivery

Tracker base: `f3a0d3a6` on original `wjr_dev`. SAIL base: `96ffc6036`;
shared-runtime commit `96ea7010d` is locally integrated into original
`pinecone-hts`. Trade Intelligence, production MotherDuck, the active release,
weekday publication and saved results are unchanged. No push, deployment or
full timeseries/revision rebuild was performed.

## Corrected calculation and extraction

The wide projection previously proved only the amount formula's homogeneity.
It ignored value-sensitive applicability/suppression and constraints, including
rules inactive at its USD1 reference value. A synthetic CV > 10 action therefore
projected zero despite a nonzero duty at CV100. The projection now proves the
relevant predicates and transitive rule dependencies invariant under positive
value scaling. Otherwise it retains null and the currently relevant input.
An unanswered outer condition is requested before a potentially irrelevant
value-dependent inner branch. Proportional comparisons, caps and explicit
unclaimed branches remain eligible for scalar proof. The proof is structural,
not sampled, and caches shared graph decisions to prevent exponential expansion.

A separate actual-source regression exposed binary threshold drift. EO 14257
Annex III note 2(v)(xii), printed 90 FR 15107, permits qualifying U.S. content
at least 20% of customs value. USD200.60 on USD1003 is exactly20%. Previous
multiplication compared against200.60000000000002 and rejected relief. The
reciprocal component was100.30 instead of80.24. These are component amounts,
not complete shipment totals. The source remains the original
[Annex III](https://www.govinfo.gov/content/pkg/FR-2025-04-07/html/2025-06063.htm),
retained at `resources/legal_evidence/2025-06063/annex.txt`; no production example
is special-cased.

R and shared TypeScript now preserve exact rational intermediates from each
finite input's shortest round-trip decimal. Comparisons, content sums, floors,
caps, division and cached rule amounts use those intermediates. No epsilon,
assumed customs rounding or cent rounding is applied. Public USD values remain
numbers, converted nearest/ties-even; computed nonzero underflow is unresolved.
Precision already lost upstream is not recovered. R requires `gmp`; its absence
is an explicit unavailable runtime. The tested package's official source and
apt-index hash are recorded in `dependency-verification.json`.

Percentage/cent extraction retains division in the AST. Precomputing13.7/100
was itself a second source of drift; the strict13.7% on500 regression now
returns68.5. Exact internal amounts also feed authority rollups and additional
sums, rather than resumming rounded components or subtracting rounded totals.
Internal rationals do not enter the public JSON/Arrow contract. Shipment JSON
serialization preserves round-trip numeric precision.

## Corrected temporal delivery

The ordinary legal-state merger parsed and pretty-printed immutable bundle JSON
whose SHA256 was already pinned in the index. This invalidated delivery even
when each individual state resolved successfully. It also rewrote raw fragment
bytes referenced by source manifests. The merger now preserves immutable bytes,
rejects conflicting immutable identities and validates staged index-referenced
bundles before replacing the previous revision/shared files. Its merged index
and genuinely merged evidence use full numeric precision.

A two-state regression exercises actual Parquet files, immutable bundle and raw
fragment hashes, exact numeric round trips, reference resolution on both entry
windows and preservation of the previous revision after a failed preparation.
It is a mechanics fixture, not a full revision build or legal inventory oracle.

## Verification and limits

Red/green logs cover value-dependent guards, decimal thresholds, extraction,
roundups, numeric JSON precision, conditional fact requests, shared graph cost
and temporal hash invalidation. R has49 shared conformance cases and98
source-generated reciprocal cases;176 direct/prepared comparisons passed.
408 Python and572 Node tests passed. SAIL's configured gate passed20,722 tests,
with45 skips. Its typecheck ratchet, changed-file lint, production build,
prerender and vendor-neutral guard passed. The tracker prototype build passed;
its generated dist byproducts were restored.

The bounded actual-source normal semiconductor fixture and the local
Parquet/DuckDB/shared-TypeScript/JSON/Arrow/batch checks passed, including cache
version invalidation and tamper rejection. This routing fixture does not use
production release preparation and does not qualify live MotherDuck deployment.

The completed55-suite R gate had53 OK, one normalized-parity ERROR
(685 missing/stale artifacts), and one TPC-input SKIP. It exits1. The runner
counts427 cases from suites that print its expected summary format; this is not
the full case count. The new temporal-delivery suite and existing legal-interval
suite then passed separately after the merge repair. The final56-suite rerun completed with54 OK, the same normalized-parity
ERROR and TPC SKIP, and no implementation-suite failures. It also exits1. The earlier deliberately red threshold development run is not
a final verification result. Missing normalized artifacts and
`data/tpc/tariff_by_flow_day.csv` are not repaired by local unit tests.

A fresh READ_ONLY MotherDuck transaction retrieved55 rows across55 revisions
for the China-fastener May20 case. Four named parameter checks match; the
reciprocal10% parameter is explicitly pre-stacking, not payable duty. Three
stored revision overlaps remain. Base, AD/CVD and the complete total are not
certified by these checks, and earlier semiconductor mismatches remain open.
Queries, findings, timestamps and manifest hashes are retained under
`motherduck/`. The transaction rolled back.

The full plan remains unfinished: broader authority/claim/valuation chronology,
source-clock reconciliation, the v8 production release preparer and remaining
consumers still require work. The final manual timeseries rebuild remains on
hold. Current fixes are generic calculation/data-delivery changes; they do not
establish complete legal coverage.
