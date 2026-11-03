# MHD vehicles and buses: original actions, content and historical priority

This checkpoint closes the ordinary-entry original MHD vehicle/bus calculation
and its identified overlapping part decisions. It does **not** qualify the full
shipment-duty inventory, every FTZ/Chapter98 path or a production release.
Implementation continues from local `6e6af0b6` on `wjr_dev`. No full revision or
timeseries rebuild, production write, release activation or publication ran.

## Source-backed decisions

- Original note38(b) has25 mixed HTS8/HTS10 provisions; note38(c) has10 bus
  provisions. The ordinary additional duties are25percent and10percent,
  respectively, from November1,2025 at00:01 Eastern daylight time. Statistical
  suffix precision is preserved. An adjacent valid statistical code is tested.
- An article within note38(b) still needs actual MHD identity. The original
  non-vehicle role is9903.74.05. A bus within the source's note38(c) table does
  not need a redundant MHD-identity answer or acquire vehicle-only content relief.
- Actual manufacture year, rather than model year or a generic assumed vehicle
  age, controls the25-calendar-year exception. This includes buses. Around New
  Year, the actual CBP entry-record year is requested only when it can affect
  the answer. No port timezone is invented. Vintage reporting uses9903.74.07.
- An explicit `SECTION_232_MHD_US_CONTENT` claim requires the procedure's
  Canada/Mexico origin condition, actual USMCA qualification, a proper SPI S
  claim, and Commerce importer/model authorization covering this entry. The
  authorized non-US entered value comes from that determination; it is not
  reconstructed from a caller's US-content estimate or a utilization percentage.
  The US reporting portion is the residual of full value and that approved value.
  Reporting retains9903.74.03 and9903.74.06, including zero payable duty.
  USMCA alone does not exempt a whole vehicle. An expressly ineligible or
  unapproved request retains the ordinary statutory duty; missing relevant facts
  remain missing. Native Column2's “No change” retains ordinary full-value duty,
  using the primary revision-bound GN3 country inventory.
- Original CBP66665333 initially withheld content reporting. Commerce2026-02049
  established model/importer approvals, discretionary retrospective entry
  authorization and renewal requirements. CBP68559236 subsequently supplies the
  two-line/SPI S instructions and expressly reaches entries from November1,2025.
  May6 publication is not a new liability commencement. A present-day approval
  does not authorize every earlier entry automatically.
- The content election includes the required USMCA election only while its
  source-backed MHD activation applies. A forced inapplicable claim cannot
  discount base duty before commencement or outside its origin/product scope.
  Proper claim and preferential-origin evidence remain required. Section122's
  entered-free conclusion comes from that resolved base rule, rather than a
  conflicting independently supplied alias. Missing base information is not zero.
- An applicable original clause6 CBP overstatement finding charges25percent on
  full vehicle value. Its fact refers to the actual model/importer/entry window,
  through CBP verification of compliance. It is not inferred from an exaggerated
  number supplied to the calculator. Irrelevant content values are not requested
  on that full-value branch.
- Whole vehicles, listed parts and optional certified parts remain separate
  source candidates. Whole MHD identity excludes a competing part path for
  shared chassis provisions. Conflicting passenger/light and medium/heavy
  identities cannot produce two vehicle charges. Those later MHD decisions do
  not suppress earlier auto duties or request MHD facts before November1.
- Cross-program eligibility aliases bind to matched source reporting decisions
  within each consumer's scope/window. A parts answer for an inapplicable action
  cannot remove another duty. The compiler does not expand a global dependency
  on every rule in a full revision.
- Original clause9 applies the automobile stacking rule to MHD vehicles, parts
  and buses. The original defined aluminum action expressly includes
  Proclamation10522's Russian-aluminum duties. That inherited relationship now
  applies to MHD actions, including zero-payable individual USMCA parts.
  Vintage exceptions do not establish that covered-action priority. This does
  not expand the exclusion to the later, separately referenced9903.82.03 action.
- The vehicle metal list follows original note38(a), April8(a), April23 and
  June8 amendments at their legal instants. It is distinct from note38(h)'s
  additional timber row. April23's published Eastern **standard** time remains
  literal. A later HTS book does not select an earlier entry's liability.
- Original Section122 note2(aa)(v) expressly identifies both approved MHD
  content roles. That source-specific exemption is distinct from its qualified
  passenger-vehicle content treatment. Mexico drug-emergency priority and
  reciprocal exemptions are evaluated from actual applicability. The independent
  China301 note20(d)/9903.88.02 charge remains cumulative; an ineligible China
  content request cannot discount either action. Vintage treatment does not
  remove that separate301 charge. No authority-wide discount is applied.

## Primary evidence and reproducibility

- [Proclamation10984, original PDF](https://www.govinfo.gov/content/pkg/FR-2025-10-22/pdf/2025-19639.pdf),
  clauses1,2,6,8-10; AnnexI note38(a)-(g), original reporting table. Original
  scanned pages9-11 and13-14 were read against the retained PDF. Reviewed JSON,
  source hashes and the original PDF hash are under
  `resources/legal_evidence/section232/vehicle-parts/`.
- [April original annex](https://www.govinfo.gov/content/pkg/FR-2026-04-09/pdf/2026-06960.pdf),
  AnnexIV A(8)(a), pp18264-18265;
  [April23 amendment](https://www.govinfo.gov/content/pkg/FR-2026-04-23/html/2026-07987.htm), paragraph8;
  [June original annex](https://www.govinfo.gov/content/pkg/FR-2026-06-04/pdf/2026-11314.pdf), AnnexIV A.
- [Original CBP EO14289 implementation](https://www.govinfo.gov/content/pkg/FR-2025-05-20/html/2025-09066.htm),
  defined actions and footnote1; original MHD clause9 supplies its MHD application.
- [Original Section122 proclamation](https://www.govinfo.gov/content/pkg/FR-2026-02-25/html/2026-03824.htm),
  paragraph4 and original AnnexI note2(aa)(v). The retained original annex and
  revision reconciliation supply the actual reporting references.
- [Commerce2026-02049](https://www.govinfo.gov/content/pkg/FR-2026-02-02/html/2026-02049.htm),
  91FR4504-4506, sectionsII-V/VII;
  [original CBP66665333](https://content.govdelivery.com/accounts/USDHSCBP/bulletins/3f93b75)
  and [subsequent CBP68559236](https://content.govdelivery.com/accounts/USDHSCBP/bulletins/4162184).
  The messages were found through links in the
  [official CBP archive](https://www.cbp.gov/document/guidance/csms-archive).
  Both original reporting restrictions and the subsequent retrospective procedure
  are retained, rather than treating the first restriction as permanently unresolved.
- [CBP69087399](https://content.govdelivery.com/accounts/USDHSCBP/bulletins/41e30a7)
  and [CBP69271650](https://content.govdelivery.com/accounts/USDHSCBP/bulletins/4210062)
  supply further offset and license-balance instructions for the next implementation
  step. Their source bytes are retained; this checkpoint does not claim those
  offsets have been priced.
- Native revision-bound Chapter99 PDF/JSON and GN3 sources retain their hashes
  and legal locators. The55-source census checks note38(a)-(g), original rates,
  actual reporting roles and amendment states. Source changes fail reconciliation
  rather than falling back to an old rate or zero.

The census covers58 MHD and10 bus candidate HTS10s in each configured source
frame,240 origins,55 snapshots, and29 snapshots with native MHD provisions.
These are candidate counts, not counts of incorrect shipments. Actual liability
depends on the legal interval and relevant facts; the MHD action does not charge
entries before its November commencement. Future revisions use the same extraction,
scope matching, reconciliation and evaluator; new law still requires evidence.

## Normal serving path and live comparison

The ordinary emitter now writes `section232_mhd_vehicles_rules.json`, source
candidates, and the corresponding exact-time bundle/class Parquets. Existing
wide projections and JSON/Arrow/batch consumers use those decisions. The generic
unclaimed profile cannot assume manufacture year, use or approved content, so
incomplete shipment scalars remain NULL. Aggregate calculations and separately
named `modeled_legacy_*` fields keep their existing methodology.

Raw fragments requiring claim dependencies or scoped rule-value predicates use
`sail.shipment-rule-fragment/v2` and explicit compiler capability declarations.
Legacy raw readers reject them. The current compiler emits the already supported
primitive AST for the unchanged runtime bundle/result contract. No new React
legal constants or interpreter operation is required. Both inventory and compiler
validate the same capability specification. Dataset hashes include these changes.

The read-only MotherDuck query retains18 observations: three products, three
origins and two dates. Sampled8702.10.31.00 bus rows store statutory232=50percent,
where the original ordinary bus action is10percent for a covered non-vintage
bus. The stored table also lacks all four sampled shipment version/status/decision
fields. This is not a claim that a complete shipment total equals10percent or
that the vehicle rows' stored25percent is always wrong. Other authorities,
vintage status, actual identity and approved content remain material.

The script asserts the configured tariff catalog, opens `READ_ONLY`, uses a
read-only transaction and rolls it back. Local DuckDB is a delivery test artifact,
not a replacement production database. No live data was modified.

## Verification and remaining gates

Machine-readable receipts and raw logs are retained under `verification/`.
The final November3 rerun passed490 Python tests and1201 Node tests;177 R
source/test files parse. The affected R/TypeScript conformance fixtures cover49
MHD vehicle cases and13 content/base cases. The ordinary five-cell emitter and
six JSON/Arrow/batch delivery cases passed. Sixteen core R suites were exercised;
two initially lacked the new explicit fragment-contract fixture metadata and
passed after that fixture repair. Both original and superseding logs are kept.
They separate source reconciliation, legal calculation, technical composition,
normal emission and local delivery from production qualification. The Russian
competing-action fixture and controlled no-other232 composition assumptions are
explicitly synthetic; they cannot attest production coverage.

The existing vehicle-parts R helper contained missing closing parentheses after
its claim-array conversion. Those are corrected here without changing duty
expectations. Affected R source/test files parse; affected calculation suites and
current R/TypeScript fixtures are rerun rather than inheriting the old receipt.

The current normalized gate stops before parity with844 missing required
artifacts, including the new fragment requirement. Normalized revisions20/21
and the TPC aggregate input remain absent. A successful bounded build does not
replace the later manual55-revision rebuild or exhaustive output reconciliation.
The normal build still emits legacy aggregate warnings, retained in its log;
its §201 fallback is not a verified shipment rate for another product/program.

Remaining implementation includes other action/claim inventory and negative
coverage, approved importer-offset application, Chapter98 entitlement and valuation
beyond the express9802.00.60 full-value path, privileged-FTZ classification/rate
history, other authority interactions, evidence reconciliation and remaining
consumer/release qualification. Missing shipment evidence and uncompiled law
remain distinct. This checkpoint is not final rebuild readiness.

Rollback before deployment is a local revert of this checkpoint. No MotherDuck
rollback is needed. A later separately approved deployment must prepare a complete
versioned release, validate it before activation and retain its predecessor.
