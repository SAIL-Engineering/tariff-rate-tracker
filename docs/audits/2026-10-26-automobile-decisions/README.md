# Automobile decisions in the ordinary shipment build

Tracker starting point: `50d900b7` on original `wjr_dev`. Changes are local;
MotherDuck was read-only. The final timeseries rebuild remains WJR's task.
This is additional executable coverage, not completion of the broader plan.
Implementation: `885b0487`; optional-metadata compatibility fix: `6ac38929`.

## Corrections

The native note parser previously rejected 25 of the 55 automobile snapshots
and sometimes absorbed other subdivisions or the following legal note. It now
uses the chapter inventory's outer boundaries, recognizes wrapped references and
Roman subdivisions, and rejects missing/ambiguous outer subdivisions. The source
census reconciles all 55 native schedules against the original product scopes,
unchanged content/use/age conditions and country duty expressions. It does not
evaluate every shipment or certify the complete Section232 inventory.

`section232_autos.py` and its R adapter now emit the original listed vehicle and
parts actions into `07_emit_normalized.R`. The ordinary calculation therefore
includes these decisions in its immutable bundles, decision classes, memberships
and nullable statutory projections. Economic rates retain their methodology.
The calculation never selects a sector maximum or consumes a modeled share,
average vehicle credit or average unit value.
The typed candidate table retains the original prefix/exact-code grain and cites
the original proclamation PDF. Source ordering cannot substitute a country
amendment as the evidence for worldwide original-annex membership.

Original AnnexI supplies the exact 17 vehicle prefixes and mixed-precision parts
scope, including the whole8471 heading. Listed computers, hoses and other machine
components require actual passenger-vehicle/light-truck use. Individual parts
that actually qualify under USMCA differ from knock-down kits/compilations;
neither an origin nor a requested preference establishes eligibility. The vintage
exception compares the actual manufacture year with the entry calendar year.
Around NewYear it requests the year on the actual CBP entry record when that
distinction affects the decision, since a port date can differ from the Eastern legal-clock instant. It does not assume a port
timezone. Fractional and future-year inputs cannot establish liability. Approved vehicle content
requires Commerce approval, actual qualifying content and the relevant CBP
finding history. Unknown or contradictory facts never supply a zero total.

The retained original instruments determine country entry instants:

| Treatment | Operative instant | Original instrument |
|---|---|---|
| Ordinary vehicles | April3,2025 00:01 EDT | Proclamation10908, AnnexI A |
| Original listed parts | May3,2025 00:01 EDT | Proclamation10908, AnnexI B |
| UK quota/list treatment | June30,2025 00:01 Eastern | 2025-12060, AnnexI A/B |
| EU combined treatment | August1,2025 00:01 EDT | 2025-18660, AnnexII A; retroactive |
| Japan combined treatment | September16,2025 00:01 Eastern | EO14345 sec.4 and 2025-17908 AnnexI(c) |
| Korea combined treatment | November1,2025 00:01 Eastern | 2025-21940 AnnexA; retroactive |
| Taiwan listed parts | May1,2026 00:01 Eastern | 2026-10571 Annex1/3; retroactive |

The original proclamation's six image annex pages were previously rendered,
OCRed and visually reviewed; the PDF and extraction remain pinned in the adjacent
source-inventory audit. Country notice bodies are reused from the read-only Trade
Intelligence selection, with source versions/object paths preserved in
`resources/legal_evidence/section232/autos/review.json`. The Japan and UK orders
were additionally read from official GPO HTML using gstack. Text/extraction hashes are
distinct from corpus search/embedding hashes. This evidence is not a replacement
for the required production Trade Intelligence snapshot export.

## Valuation and interactions

Unclaimed combined-rate calculations now inline the complete, revision-specific
Column1-General duty expression from the shared primary base extractor and R
expression parser, retaining legal quantities, constraints and source ownership.
An arbitrary `column1_duty_amount` cannot replace that expression. For example,
the source duty-free computer has a different additional-duty result from a
vehicle with a 2.5percent General duty. Fixed ad-valorem rate bands are compared
as rates, so zero customs value cannot flip a reporting heading. Specific/compound
AVE decisions require the relevant value/quantity evidence.

Korea expressly permits properly claimed Column1-Special treatment, including
its specific/compound calculation. A `COLUMN1_SPECIAL` request requires its own
actual entitlement and proper-claim facts; KORUS is not made conditional on USMCA
eligibility. A USMCA request retains its distinct eligibility question. These
inputs establish only this additional-duty basis, not base-duty relief or complete
preference coverage. The EU instrument refers to MFN; Japan and
Taiwan's specific/compound clauses name General. Unsupported preference or
Chapter98 floor combinations remain explicit questions. No shared average or
automatic lower-rate election reconciles those differences.

The UK parts path is now priced from EO14309 section2(b)-(c) and the original
implementing notice. Its10percent **includes** MFN. Actual use in a UK-produced
automobile is required separately from UK origin of the part. A sourced action
relation suppresses the ordinary base when the combined treatment applies;
the rule retains `valuation_role=combined_ordinary_duty_including_mfn`.
On100USD, a qualifying source-listed hose therefore contributes10USD across base
and automobile duty, rather than adding10USD to its native2.5USD base. A part
for a different automobile retains25USD plus2.5USD base. Non-auto use retains
only the base in that controlled probe. Missing automobile origin cannot leave
an unsupported ordinary base in the known subtotal. Other authorities remain
independently unresolved. These predicates and amounts come from the original
instruments, not the example HTS code.

The composer now expands source-backed `derived_facts` before evaluation. The
IEEPA,122 and338 auto-content/individual-parts aliases resolve from the same
actual automobile facts and value. Old contradictory caller aliases cannot
override those decisions. Aliases require verified source identities; conflicts
and cycles fail. Eight actual-source cross-program cases exercise zero-payable
parts before/at November1 stacking, non-automotive use,122 relief, and338's
September15 amendment. Controlled test inventory attestations support arithmetic
only; they do not attest production authority completeness.

The metal regressions exposed an actual double charge on the listed automobile
spring7320.10.30.00:25percent automotive plus50percent metal. The composed rules
now remove the named metal charge when the automotive action has legal priority;
the same spring used outside an automobile retains its metal decision. Country
annex exclusions are tied directly to the original country action, including its
zero-additional heading. They therefore operate during the EU retroactive window
before a later HTS snapshot contains the new automobile heading. Native amended
note33 exclusions are separately restricted to the identified source-selection
window. The composer tiles at those boundaries and rejects a partially overlapping
untiled window. Source-selection dates do not purport to be legal effective dates.

Russian-content aluminum requires an action-level decision as well. The original
CBP notice2025-09066 footnote1 expressly includes Proclamation10522 in EO14289;
CSMS65054270 explains the earlier payable-duty interpretation. The November
amendment2025-19639 supplies the later subject-to rule, including zero-payable
automobile parts. Proclamation2026-06960 clause8 continues the Russian200percent
rate; that continuation does not by itself repeal the separate stacking rule.
The compiler obtains Russian-content reporting headings from their actual native
descriptions, not a predicted suffix or a selected maximum. Tests retain200percent
for non-auto use and25percent, or the qualifying individual-parts zero, for actual
auto use. The sources and hashes remain in each composed decision.

This removes the competing monetary charge, not every reporting requirement.
Unresolved zero-metal reporting/validation branches can still require weight
fractions. Missing metal reporting facts cannot become another payable charge or
a complete total. One zero-country-heading metal overlap fixture is explicitly
synthetic; it does not assert that its truck is in a metal annex.

## Verification and live comparison

The recorded tests include60 targeted R vehicle/parts/country/valuation cases,
12 cross-program/base-replacement cases and nine metal-interaction cases,
direct/prepared and shared-TypeScript comparisons, and20 actual-source
normal-build calculations (12 for three products/two origins and eight for two
products/two origins). Twelve compiler regressions cover aliases, conditions,
replacement selectors, windows and source validation.
The bounded delivery check exercises Parquet relationships, JSON, Arrow, batch,
dataset invalidation and hash tampering in local/in-memory storage. It explicitly
bypasses production release preparation and is not a live deployment smoke test.
The fixtures omit full trade/model inputs and retain existing aggregate warnings;
they do not qualify aggregate-series reproduction.
Final gate counts and logs are recorded in `verification.json` alongside this
file; intermediate deliberately failing tests are retained separately.

Python423 and Node653 pass; direct/prepared R evaluation agrees on257 cases.
The complete R runner finished62 suites:59OK, twoERROR and oneTPC skip. One
error is the known685 missing/stale normalized-artifact checks. The other exposed
34 absent-versus-null optional metadata differences in the Section301 golden
fixture, with no changed formulas, source decisions or case results. Optional
fields are now omitted when absent; the unchanged Section301 fixture passes its
full source reconstruction suite again, and the added compatibility regression
passes separately. The full62-suite run was not repeated after that representation
fix. Final bounded normal-build/API checks were repeated after it. This is not a
green full-data R gate; the TPC input is still missing and exhaustive normalized
traversal remains unimplemented.

The final read-only MotherDuck snapshot contains440 rows for eight product/origin
pairs and ten dated checks. All ten unconditioned-row nullability checks disagree
with the required incomplete shipment contract; this is not a claim of ten
independently certified numeric total errors. The September2026 Mexico vehicle
row still publishes0.237625, while the source-backed ordinary modern-vehicle
component is25percent when the required use/age/claim facts are established.
Three stored revision-interval overlaps remain. The initial research comparison
used a nonexistent adjacent statistical suffix; the final comparison and fixtures
use published4009.12.00.50. The compiler now rejects nonexistent revision codes.
No source absence or missing row is accepted as legal absence.

## Remaining gates

Do not rebuild for final publication yet. Expanded certified parts outside the
original33(g) list, MHDV sectors/claims, approved offset allocations,
country/content elections, some preferences/Chapter98
valuation and FTZ histories still need executable reconciliation. Other authority
inventories, later reciprocal decisions and financial consumers remain incomplete.
The production release preparer still needs its versioned multi-bundle/index
upgrade and a real evidence snapshot. No complete legal-coverage attestation or
MotherDuck activation was added.

Repeat source extraction only, without rebuilding rates:

```sh
python3 scripts/audit_automobile_history.py /tmp/new-auto-source-census.json
Rscript tests/test_s232_autos.R
Rscript tests/test_s232_auto_interactions.R
Rscript tests/test_s232_auto_metals.R
```

For a bounded normal-build/API fixture, use a new export directory:

```sh
AUTO_PIPELINE_EXPORT=/tmp/new-auto-normal Rscript tests/test_s232_autos_pipeline.R
node frontend/scripts/check-normal-shipment-fixture.mjs --fixture /tmp/new-auto-normal
AUTO_METAL_PIPELINE_EXPORT=/tmp/new-auto-metal-normal Rscript tests/test_s232_auto_metals_pipeline.R
node frontend/scripts/check-normal-shipment-fixture.mjs --fixture /tmp/new-auto-metal-normal
```

Use Node22 as required by the server package. Full manual rebuild and later
approval/rollback instructions remain in `docs/shipment-duty-manual-rebuild.md`.
Production needs no rollback from this work because it was never written. For a
local implementation rollback, revert `6ac38929` followed by `885b0487`, retaining
any generated before/after evidence. Future approved release activation must
retain the previous active release identifier.
