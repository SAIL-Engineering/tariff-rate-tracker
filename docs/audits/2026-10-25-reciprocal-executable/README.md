# Reciprocal executable chronology, valuation and cross-program decisions

Base: `d68c0526616e26420ac561681ba4013c3ea3766f`, original tracker checkout,
`wjr_dev`. This change is local to the tracker. No timeseries/revision rebuild,
MotherDuck write, release activation, push, workflow change or deployment occurred.
The small pipeline fixtures write temporary outputs; the 55-revision compiler
check reads sources and compiles one exact product, without calculating rates.

## Implemented legal decisions

The compiler reads the original EO 14257 Annex III heading tables and independently
reconciles their country rates with the note. Its 34 country headings cover 57
country-note entries. Runtime country mappings reuse the ingestion resolver and
retain its Census, EU and revision-specific General Note 3 inputs. Reporting
headings come from source identities; a numeric rate never selects a heading.

| Source | Implemented decision |
| --- | --- |
| [EO 14257 and Annex III](https://www.govinfo.gov/content/pkg/FR-2025-04-07/pdf/2025-06063.pdf) | April 5 baseline and April 9 country actions, original exceptions, Chapter 98 valuation, U.S. content threshold and Section 232 relationships. |
| [EO 14259](https://www.govinfo.gov/content/pkg/FR-2025-04-14/html/2025-06378.htm) | China heading's 34% predecessor replaced with 84% at April 9 00:01 EDT. The replaced 34% never becomes an operative shipment rate. |
| [EO 14266](https://www.govinfo.gov/content/pkg/FR-2025-04-15/html/2025-06462.htm) | China replacement to 125% from April 10 00:01 EDT; other country actions suspended to the 10% baseline. |
| [EO 14298](https://www.govinfo.gov/content/pkg/FR-2025-05-21/html/2025-09297.htm) | China suspension to 10% and the baseline reporting heading from May 14 00:01 EDT. |
| [Original CBP transit instruction](https://content.govdelivery.com/accounts/USDHSCBP/bulletins/3daf1b6), [superseding instruction](https://content.govdelivery.com/accounts/USDHSCBP/bulletins/3e2e66d) | Separate pre-April-5 zero and pre-increase 10% vessel paths; updated June 16 00:01 EDT entry deadline. Original May 27 versus later-described May 28 discrepancy retained. |
| [Proclamation 10947, clause 6](https://www.govinfo.gov/content/pkg/FR-2025-06-09/html/2025-10524.htm) | From June 4 00:01 EDT, reciprocal duty attaches to non-steel/non-aluminum value. Actual metal value determines the excluded portion; positive payable Section 232 duty is insufficient. |
| [CBP steel instructions](https://content.govdelivery.com/accounts/USDHSCBP/bulletins/3e36d96), [aluminum instructions](https://content.govdelivery.com/accounts/USDHSCBP/bulletins/3e36ea5) | Metal/nonmetal reporting and reciprocal portion treatment, reconciled with operative HTS headings. |
| [Commerce UK annex, section C](https://www.govinfo.gov/content/pkg/FR-2025-06-30/html/2025-12060.htm) | June 30 00:01 Eastern begins a new sector policy. This fragment stops there; that boundary is not expiration of reciprocal duty. |

All documents and hashes are retained under `resources/legal_evidence`. The current
[CBP FAQ](https://www.cbp.gov/trade/programs-administration/trade-remedies/IEEPA-FAQ)
is retained as interpretation of transit and preference predicates, not as a new
historical tariff amendment. Original actions supply the operative dates.

Before June 4, named metal decisions can establish the reciprocal exception even
with zero Section 232 payable duty. The non-auto decision `9903.94.06` does not.
Original EO section 3(b)(ii) also covers the amended Russian-aluminum action,
although the original note's reporting enumeration omits those separate headings.
From June 4, the actual nonmetal value remains exposed even when that Russian
Section 232 action charges on the whole article's value.

The steel CSMS prints `9903.91.98` for a UK derivative decision. This is not repaired
by guessing a nearby code. The actual HTS note 16(u), heading description and the
subsequent Commerce annex independently identify `9903.81.98`. The malformed CSMS
text remains unchanged in evidence. Its example-rate inconsistency is likewise
not used to set the legal charge.

U.S. content relief requires its source-defined 20% threshold and actual values.
Chapter 98 assembly value already deducted cannot be deducted again. Repair value,
metal value and qualifying U.S. content use bounded intersections on the same
valuation basis, including lower bounds that reject mathematically impossible
disjoint portions. General Note 3 preference claimed through Chapter 98 does not
establish the separate special-classification reciprocal exemption.

Claims are action-specific. Reciprocal transit/content claims leave other duties
unchanged. Section 232 grant decisions trigger reciprocal reevaluation. Missing
Section 232 inventory cannot become an assumed reciprocal charge or exemption.
FTZ and de minimis paths remain explicit unresolved decisions.

## Read-only MotherDuck comparison

`motherduck-manifest.json` records READ_ONLY access, the database, timestamps and
artifact hashes. Case-row hashes refer to uncompressed `motherduck-cases.json.gz`.
The retained case specification records the sources and ordinary commercial-entry
assumptions. Queries returned 330 rows, covering six origin/product pairs across
55 production revisions. Nine entry-date expectations checked only the reciprocal
component for HTS `0106.19.9120`; they do not certify complete stacks.

| Origin and entry date | Live reciprocal component | Source-backed component |
| --- | ---: | ---: |
| Australia, April 6 | 0% | 10% |
| France, April 9 | 0% | 20% |
| China, April 9 | 0% | 84% |
| China, Hong Kong, Macao, April 10 | 0% each | 125% each |
| France, April 10 | 0% | 10% |
| China, May 14 | 0% | 10% |
| Canada, April 10 | 0% | 0% |

Eight mismatches and one match confirm that the production artifact still carries
the legacy false exemption addressed in the preceding scope correction. The
bounded normal-calculator regression now returns the expected rates. Three
overlapping late-2026 production revision intervals also remain. MotherDuck was
not changed; these observations are not post-publication qualification.

A separate read-only query retrieved 55 revision rows for the real-source
`7318.15.8085 / China / May 20` cross-program case. The live Section 232, drug-IEEPA
and Section 301 statutory parameters match 25%, 20% and 25%. Its raw reciprocal
parameter is 10%, but the live additional-duty total is 70%, consistent with
suppression of reciprocal liability. Adding those four raw rate columns would
incorrectly give 80%. This is a consumer-contract distinction, not evidence that
the live total is wrong. The corrected rule output explicitly resolves the
reciprocal exemption and reporting code. AD/CVD scope and a complete shipment
total are not certified by this comparison. The separate `motherduck-cross-*`
artifacts retain this query and the parameter expectations.

## Delivery and verification boundaries

The ordinary normalized emitter adds `ieepa_reciprocal_initial_rules.json`.
Composition uses the shared R/TypeScript interpreter and existing release v7 /
result v1. No rate, scope or claim constant was added to React or API consumers.
The compiler deliberately emits no full-authority coverage attestation. Consumers
must distinguish its revision support interval from its narrower legal horizon.

`source-sweep.json` records source/compiler hashes for all 55 configured revisions,
including 2026 revisions 20 and 21. It proves successful source compilation for
one exact HTS10 across the country inventory, not exhaustive shipment pricing.
The full product/origin/date grid and aggregate reconciliation require the later
manual rebuild and additional coverage work. Test logs accompany this audit.

The new reciprocal fixtures cover country replacements, exact minute boundaries,
retroactive electronics, transit supersession, actual metal values, Chapter 98,
U.S. content, invalid intersections and missing inventory. Synthetic Section 232
decisions isolate dependency/valuation arithmetic and are labeled as such. A
separate real-source composition checks steel + drug-emergency IEEPA + Section
301 + reciprocal decisions: the additional-duty known subtotal is $70 per $100
on the tested China steel fastener entry, with the base duty deliberately not
certified. Model shares/credits and source/rule ordering cannot alter that result.
The local stored-bundle serving regression also checks the June 4 boundary,
content claim and missing metal value through JSON, batch and Arrow. It uses
in-memory DuckDB and real route handlers with a synthetic release, not a deployed
MotherDuck release or browser/authentication qualification.

Completed checks retained as compressed logs:

- `/usr/bin/python3 -m pytest -q tests/python`: **374 passed**.
- `Rscript tests/test_ieepa_reciprocal_rules.R --emit`: **74 passed**; emits the
  checked-in R/TypeScript fixture, not a timeseries build.
- `node --test frontend/tests/*.test.mjs`: **504 passed**, including the new
  stored-bundle JSON/batch/Arrow regression.
- `Rscript tests/run_all_tests.R --require-data`: **43 of 45 suites passed**;
  normalized parity failed and TPC comparison skipped because
  `data/tpc/tariff_by_flow_day.csv` is absent. Overall exit code is **1**.
- `Rscript tests/test_normalized_parity.R`: **exit 1**, 526 missing required
  artifacts; no numeric parity evaluation. This includes the absent normalized
  directories for 2026 revisions 20 and 21 and new per-revision rule files.
- The source-only compiler sweep succeeds for **55 revisions** with exact product
  membership, source hashes and no inferred coverage attestation.
- A separate full-inventory source compilation for `2025_rev_8` covers **20,206
  products**, including 473 valid eight-digit leaf lines represented by `00`
  statistical suffixes, and emits **526 rules**. The exact product inventory
  reconciles; no rate/timeseries build ran. See `full-products.json` and its script.
- Both MotherDuck audits completed read-only transactions and rolled them back.

Broader executable coverage is still unfinished: reciprocal policy after June 30,
FTZ/de minimis histories, remaining sector/claim interactions, full Sections
122/338/301 qualification and downstream consumers. Existing missing normalized
artifacts and TPC input also prevent a successful full R release gate. No complete
all-authority total or readiness for publication is asserted.

Manual commands are in [the rebuild runbook](../../shipment-duty-manual-rebuild.md).
Rebuild all configured revisions only when the remaining rate-affecting work is
ready. Within release v7, keep the prior validated release for atomic rollback.
There is no new live release to roll back in this change; local rollback is a
reviewed revert of its commit and regeneration of affected artifacts. Do not use
the synthetic fixture bundle as production data.
