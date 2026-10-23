# Historical metal scope and reporting investigation

This batch corrects source extraction, model scope and executable shipment
decisions for the March 12, 2025–April 5, 2026 steel/aluminum regime. It was
implemented locally on `wjr_dev`, based on
`b334780655e9ed6d461c03ca799348c88996eb8c`. No revision/timeseries rebuild,
MotherDuck write, release activation, push or deployment was performed.

## Independent MotherDuck comparison

The read-only export queried the configured `duty_calculator` catalog inside a
read-only transaction, then rolled it back. Its queries, timestamps and results
are retained in `motherduck-read-only.json.gz`; the uncompressed SHA256 is
`c5c21a4241537095c028b63f67a22b4b187ad1fcf6f08de24131aff9a6fc3746`.
The export contains 41,310 primary-chapter HTS/revision groups and 105,690
revision/origin/reporting-code/valuation-basis groups. It is an audit interchange
artifact, not the production database or a replacement evidence corpus.

Comparison with the enumerated historical notes found **749,649 positive modeled
metal-duty rows in 3,142 HTS/revision groups outside both extracted metal scopes**.
These are steel/aluminum component findings, not shipment totals, declarations,
refund amounts or findings about another Section 232 action. The full findings
and their source-export hash are in `sources/motherduck-comparison.json`.
For example, broad chapter assignment included primary iron/ferroalloy headings
that the operative metal lists did not enumerate. Test examples only demonstrate
the general source-membership fix; they do not control production scope.

## Root corrections

* Primary scope comes from notes 16(j)/(q) and 19(g)/(o), including explicit
  exceptions and the limited castings/forgings description. Chapter 72, 73 or 76
  alone is insufficient. Both model assignment branches and normalized model
  applicability use the same exact product inventory.
* Historical derivative lists are extracted from the matching complete notes,
  retaining HTS4/6/8/10 grain, statistical complements, multiple metal memberships,
  UK alternatives and description predicates. Context references such as motor
  vehicle headings do not become additional scope. Unknown table grammar fails.
* Retired and pre-effective metal headings cannot seed a rate through the fast
  footnote pass. Different legal rates are not reconciled by selecting a maximum.
  The new historical model adapter does not reuse the static derivative CSV.
* Shipment rules select the source's primary/derivative/UK headings, declared
  content valuation, U.S.-metal relief, Russian origin or smelt/cast treatment,
  and distinct privileged-FTZ headings. Russian aluminum treatment remains on
  full value. Mixed metals retain separate actions. Material and limited product
  predicates are shipment facts, never modeled shares or credits.
* The primary steel heading expressly yields to named derivative headings.
  Remaining genuinely overlapping categories retain a source discrepancy rather
  than choosing a rate or broadening a scope. A reporting identity may be known
  while its amount still needs a declared content value.
* March commencement is 00:01 Eastern on March 12. The June 4 rate/content/stacking
  amendment is also effective at 00:01, independently of the midnight daily
  calendar. The June fragment imports the preceding revision's verified treatment
  for its first minute, preserving the old heading, amount and ordering together.
* Positive auto duties suppress the reviewed metal and Canada/Mexico emergency
  actions. Before June 4, positive Canada/Mexico emergency duties precede metals;
  after the amendment, the named positive metal charges precede the general
  Canada/Mexico emergency headings. A claim that removes the prior action causes
  the dependent action to be evaluated again. A zero-dollar duty is not a positive
  duty trigger. Relations bind to actual bundle rules, with temporal target IDs
  where old and new ordering differ; they do not invent a missing action.
  CBP's implementation notice expressly includes the Russian-aluminum action,
  so it also participates in this ordering despite the annex's shorter code list.
* Registered Section 301 exclusions leave the reviewed legacy metal actions
  unchanged. The same explicit review now covers the post-April note 16 actions;
  separately retained Russian headings are not silently included in that latter
  review. A claim-name prefix alone does not establish an exclusion's authority.

The semantic catalog pins 53 normalized clause/description variants encountered
in these archives. It is a fail-closed grammar guard, not an all-authority legal
coverage attestation. Rates and product lists remain source data. Compiler,
dependency, source and semantic-review hashes travel with the emitted artifacts.

## Sources and legal distinctions

Primary sources were reviewed through gstack `/browse` and retained with hashes:

* [Proclamation 10895, aluminum, 90 FR 9807](https://www.govinfo.gov/content/pkg/FR-2025-02-18/html/2025-02832.htm)
  and [Proclamation 10896, steel, 90 FR 9817](https://www.govinfo.gov/content/pkg/FR-2025-02-18/html/2025-02833.htm):
  March 12 commencement, revised scope, country treatment and exclusion changes.
* [Proclamation 10947, 90 FR 24199](https://www.govinfo.gov/content/pkg/FR-2025-06-09/html/2025-10524.htm):
  clauses 1–7, June 4 rates, UK treatment, content valuation and amended EO 14289
  priority. Its annex images and subsequent matching HTS notes must be read
  together; plain HTML alone is not the annex rate table.
* [CBP CSMS 65054270](https://content.govdelivery.com/accounts/USDHSCBP/bulletins/3e0a63e):
  positive duty owed, action ordering, USMCA reevaluation, and cumulative Section
  301/China emergency duties. Retained in the preceding stacking audit.
* [CBP implementation of EO 14289, 90 FR 21487–21489](https://www.govinfo.gov/content/pkg/FR-2025-05-20/html/2025-09066.htm):
  footnote 1 expressly includes Proclamation 10522's Russian-aluminum 200-percent
  treatment in the covered action. This is independent evidence for its
  participation in both the original and June-amended priority order.
* [CBP CSMS 65236645](https://content.govdelivery.com/accounts/USDHSCBP/bulletins/3e36ea5):
  June aluminum headings and declared content treatment. If content value is
  unknown, CBP permits declaring the full entered value. The current input model
  requires a declared value; missing value is not silently converted to zero.
* Every applicable revision's full USITC Chapter 99 PDF and matching HTS JSON.
  Source paths/hashes and paragraph locators are retained in `sources/` and in
  the emitted normalized artifacts. Post-April claim independence relies on the
  separately reviewed note 16(b), not an inferred discount convention.

The March proclamations terminate general approved exclusions but preserve
previous individual grants through their applicable expiry/quantity limit.
Those grants need their own source-backed claim objects. Their absence from
this compiler is not evidence that every pre-existing grant ceased on March 12.

## Build and serving integration

The normal R build loads this evidence automatically for each applicable legal
state. It emits `section232_legacy_source.json`, `section232_legacy_rules.json`,
the exact candidate inventory and `section232_scope_decisions.parquet`.
Candidates with unresolved shipment predicates have null statutory rates and
no fabricated scalar reporting heading. Aggregate inputs remain separate.

The executable fragment must be composed with the identified base and other
authority fragments. It intentionally grants **no complete authority coverage**.
The existing R and TypeScript interpreters execute the same formulas and action
dependencies; there is no new React arithmetic or copied legal rate table.

Release **v6** requires DATE `state_valid_from`/`state_valid_until` on Section 232
scope decisions. Preflight reconciles those windows with the wide legal states,
candidate inventories and bundle source hashes. The v1 rule/result API contract
is unchanged. Old v5 releases are unsupported by the v6 reader. Versioned local
preparation remains separate from eventual approved MotherDuck activation.

## Verification and limits

The source-only audit traversed all **55** configured revisions: 34 historical
metal snapshots, 4 pre-March snapshots retained for research, and 17 superseded
by the new note 16 regime. The 34 applicable snapshots compile **18,783** rules
against the complete 240-origin inventory and each snapshot's HTS10 inventory.
There are 112,828 scope memberships, including UK/ordinary and overlapping metal
memberships; that number is not a count of distinct products or verified totals.
Hashes/counts are in `sources/summary.json`. This is not the requested exhaustive
HTS10 × origin × entry interval × shipment-fact evaluation.

* 31 real-source legacy heading/amount/input cases pass in R and TypeScript,
  including statistical neighbors and exact March/June boundaries. Separate
  synthetic action fixtures test ordering, zero charges, claim revival and
  Section 301 independence; their artificial charge is not a legal rate oracle.
* The three-product, one-origin calculator/normalized-export fixture passes.
  It writes to a temporary output directory and is not a revision build.
* All 297 Python tests and 184 Node tests pass. The focused release suite also
  rejects both v1 and v5 manifests after the final compatibility assertion.
* Full R: 35 suites, **33 OK, 1 ERROR, 1 SKIP**. The ERROR is normalized parity's
  unchanged 312 missing artifacts; TPC fixtures are unavailable. The 402/0
  assertion summary does not make this run green. Existing missing normalized
  revisions 20/21 remain separately subject to required-revision validation.
* Tracker typecheck and Vite build pass, with the existing bundle-size warnings.
  Browser UI behavior, SAIL consumers and a later approved live release smoke
  test are not newly qualified by these local checks.

The canonical Canadian beer **complete total remains unresolved**. Its fixture
checks a separately valued aluminum component only; neither 40% nor 60% is used
as a total oracle. Full reciprocal/non-metal and other action treatment must
still be reconciled.

Remaining work includes pre-March quota/exclusion decisions; individual exclusion
grants; civil-aircraft and Chapter 98 interactions; all other Section 232 actions;
the remaining IEEPA/Section 122/Section 338 predicates, content allocation and
chronology; further Section 301 interactions; AD/CVD; complete bundle compilation
and authority attestations; exhaustive parity and financial consumers. Other
amendments and the minute before the April/June 2026 note 16 transitions are not
resolved by the June 2025 fix. These are investigation/implementation tasks,
not determinations that a legal heading or answer cannot be found.

No aggregate totals were regenerated, so the eventual aggregate differences
remain to be measured. The root scope correction will change affected modeled
outputs on the manual rebuild; shares/credits retain their aggregate meaning.
WJR's [manual rebuild commands](../../shipment-duty-manual-rebuild.md) remain the
next build procedure once the remaining legal and serving gates are ready.
Rollback before deployment is a local revert. After any approved deployment,
retain the preceding immutable release and its compatible reader together.
