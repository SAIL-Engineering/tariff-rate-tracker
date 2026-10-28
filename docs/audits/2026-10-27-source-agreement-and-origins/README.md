# Conditional metal amounts, origin identity and remaining release gaps

Local tracker `wjr_dev`, from `a4fc6bc9`. No timeseries/revision rebuild,
MotherDuck mutation, activation, push or deployment. Only bounded shipment
fixtures and source censuses were generated. This extends the
[gap-impact audit](../2026-10-27-gap-impact/README.md).

## Criticality and measured scope

Unresolved legal applicability or valuation is a release blocker for a complete
total. Missing shipment evidence must instead remain an explicit input request.
HTS, origin and date cannot establish actual material origin/content, end use,
preference entitlement, quota allocation, producer identity or FTZ history.
The correct result can be conditional; neither uncertainty may become zero.

| Candidate scope | Distinct HTS10 | Origins | Revisions | Product/origin/revision cells |
|---|---:|---:|---:|---:|
| Ordinary audit universe | 20,109 | 240 | 55 | 261,167,040 |
| Post-April Section 232 note 16 | 1,992 | 240 | 17 | 8,078,640 |
| Note 16(c)(xi) benchmark gap, closed for supported ordinary-entry paths | 93 | 240 | 12 | 264,720 |
| Forced-labor common product exemption, closed ordinary-entry component | 1,554 | 86 | 9 | 1,202,796 |

These are potential populations, not counts of erroneous rates or unresolved
actual shipments. The metal population excludes older metals and other sectors.
The xi issue requires qualifying U.S. metal; its actual shipment prevalence is
unknown. Counts sum revision-valid products rather than multiplying historical
unions. Legal sub-day intervals can add decisions within a revision. The current
ingestion resolver now supplies the impact census; no old audit's country map
is reused. `impact.json.gz` and `scope-counts.json` preserve the census.

## Closed source and calculation paths

### Original-source agreement and a benchmark supplied by native data

[Proclamation 11032](https://www.govinfo.gov/content/pkg/FR-2026-06-04/html/2026-11314.htm),
clauses 2(b), 2(c), 3(b), 4 and Annex IV, contains a discrepancy: the body
describes a Column 1 inclusive floor for qualifying xi articles, while the
annex/native `9903.82.06` and `.82.15` expressions describe an additional 10%.
[CBP CSMS 68855869](https://content.govdelivery.com/accounts/USDHSCBP/bulletins/41aa83d)
also describes an additional 10%. It confirms collection instructions but is
not an amendment resolving the different proclamation wording.

The compiler retains all three formulations and prices only source agreement.
The complete historical census found that all **1,103 xi product/revision
records** (93 distinct codes, 12 revisions) have a published Column 1 General
expression of **Free**. The native hierarchy extractor preserves each actual
expression owner and row index. This supplies the zero benchmark and makes the
different published formulations produce the same amount for supported ordinary
entries. Partner treatment also requires the source-defined lowest applicable
treatment. The USMCA alternative has a 15% minimum, so the agreed 10% U.S.-metal
amount needs no irrelevant U.S.-parts value question.

This is generalized propagation of an explicitly published Free expression
through note 16, including its other floor formulas. No HTS/rate examples enter
production logic, no absence becomes zero, and an importer/model benchmark
cannot override that source. The reference is independent of a final base
component suppressed or replaced by another action. Source changes and unknown
expressions cannot become Free. Native source hashes and exact expression
ownership accompany the reference decisions. The original wording discrepancy
is retained; it has not been declared legally amended or ignored.

Nonzero and compound benchmark derivation across preferences and altered
valuation remains unfinished. Such cases retain their actual-benchmark or
source question. They cannot use an economic AVE or the final base component
after suppression. FTZ histories and unreviewed claim effects remain separate.
Applicability/reporting identity remains separate from an unpriced amount:
an established metal reporting heading can still establish the separately
source-named forced-labor exemption when shipment value is unknown. Eleven
R/TypeScript cases exercise this distinction, native benchmarks, origin
alternatives, FTZ and model invariance.

The queried Trade Intelligence CSMS corpus had no matching records for the
specific search retained in `motherduck-note16-csms.json`. The primary bulletin
was independently acquired and pinned in `resources/legal_evidence/section232/`.
This does not establish that the entire corpus lacks relevant evidence.

### Qualified origin identities and disjoint investigations

The original [USTR notice](https://www.govinfo.gov/content/pkg/FR-2026-07-28/html/2026-15181.htm)
distinguishes investigation 23, Hong Kong, China, from the China investigation;
its operative determination expressly names products of Hong Kong. Comma
tokenization had expanded that one qualified identity into Hong Kong and China.
It assigned the Hong Kong action to mainland China as well.

A sourced identity registry is now consumed by exact resolution, country-list
extraction and the Chapter 99 universe matcher. The latter uses its existing
longest-match semantics. Genuine coordinated lists remain lists. A new compiler
invariant rejects overlapping original investigation origin mappings. The
source census confirms Hong Kong maps only to 5820, China to 5700, with the
same overall 86-origin roster. The potential duplicate-China population is
179,334 ordinary product/revision cells across nine operative revisions before
exemptions; this is not a claim that the live database double-charged that many.

The identity audit additionally found Cape Verde mapped to Algeria's 7210 in
one ingestion alias, and `UK` resolving by prefix to Ukraine. Ingestion now
reuses the existing Census/curated aliases, exact resolution recognizes UK,
and ambiguous unmatched names cannot select the first substring match. Every
canonical Census name round-trips to its own code. Country registry inputs are
included in fragment dependency/source pins and the build context.

### Ordinary entry versus FTZ capability

[Proclamation 11021](https://www.govinfo.gov/content/pkg/FR-2026-04-09/html/2026-06960.htm),
clause 12, requires separate FTZ admission/status/classification consideration.
Modern note 16 declares an ordinary-entry-only capability. The generic composer
enforces it before cross-program binding. Unknown context requests the fact;
an FTZ withdrawal reports the precise unimplemented history decision. An
inapplicable predicate or unrelated product asks no context fact. Existing
verified legacy/pre-March FTZ branches retain their own decisions.

This prevents an ordinary current-entry amount from appearing as a known FTZ
amount. It does not implement all FTZ histories or claim to close those paths.

## Verification and limitations

The frozen production-code checkpoint passes 465 Python and 859 individual
Node tests. Source-backed R checks pass: 35 existing metal cases, 11 source
agreement/composition cases, 14 common product cases, 50 controlled Section
301/232 cases, 10 actual automobile composition cases, 32 civil-aircraft cases,
18 country-universe invariants, the complete 240-name identity round-trip,
entry-context guards and emergency chronology/interactions. Three older R
composition probes incorrectly reused already bound bundles; rebuilding those
fixtures from original inputs preserves the compiler guard and passes their
9 automobile/metal, 49 legacy-metal and 35 pre-March cases plus claim assertions.
The refreshed
forced-labor source census reconciles 101 original/amended heading definitions
across all 55 revisions with no conflicts. That is a source census, not complete
all-authority legal qualification.

Eight actual-source ordinary-build automobile/metal scenarios pass normal
Parquet relationships, R/TypeScript results, local DuckDB, JSON/Arrow/batch,
dataset invalidation and bundle tamper rejection. Complete totals remain NULL
where required authority evidence is unqualified. Aggregate warnings about
missing Section 201 staged data, parsing and inactive IEEPA denormalization
remain visible; the shipment evaluator does not adopt those fallback values.
Six additional actual mobile-equipment scenarios pass the same Parquet,
DuckDB and JSON/Arrow/batch delivery checks. They supply no Column 1 benchmark,
and include contradictory caller/model values, nonqualifying U.S. metal,
missing shipment value, unknown entry context and FTZ withdrawal. The forced-
labor exemption still follows known applicability when value is missing.

The full R gate is **not qualified**. The current normalized prerequisite check
finds 685 missing-artifact assertions: 367 Parquet files, 316 source/rule JSON
files and two configured revision directories (2026 revisions 20 and 21).
These are missing generated artifacts, not 685 demonstrated legal errors.
`data/tpc/tariff_by_flow_day.csv` is also absent. The full-suite execution status
is recorded separately in `verification/status.json`; no running or failed
gate is counted as passing. Logs and reproduction commands are retained under
`verification/`.

The previous read-only MotherDuck audit found positive legacy forced-labor
parameters on 1,191,087 common-exemption rows and three overlapping revision
matches for each of 4,901,280 HTS/origin pairs on October 22. Those observations
remain release blockers. Live data were not changed. Broader authority/claim,
annex and FTZ reconciliation and complete release validation remain unfinished.
No complete unresolved-shipment count is asserted from triples without facts.

## Rebuild and rollback boundary

WJR retains all timeseries/revision rebuilds and live release decisions. These
changes participate in the normal extraction/composition/projection path across
revisions, rather than modifying a few generated rows. Local fixture success
does not activate a MotherDuck release. A later rebuild must produce mutually
consistent rates, decision memberships/classes, sources and rule bundles before
validation/activation. Keep the previous active release for rollback. Before
publication, source changes can be rolled back with a local revert and fresh
artifact generation; do not reuse artifacts produced from another source hash.
