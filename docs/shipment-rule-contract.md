# Shipment rule contract v1

`sail.shipment-rules/v1` is a declarative input to independent R and TypeScript
interpreters. It contains no modeled trade shares or assembly credits. Aggregate
outputs remain separate. A bundle is pinned by `dataset_version`, `revision`,
`evidence_snapshot_id`, source hashes and an inclusive/exclusive UTC validity
interval. Entry timestamps require an explicit offset; date-only input cannot
resolve a 12:01 eastern boundary.

Each rule identifies one `action_id`, an `authority`, `scope`, a `when` predicate,
an amount `formula`, `reporting_codes`, and `source_ids`. Multiple actions under
the same authority are cumulative. The evaluator never chooses a maximum rate.
An explicit `suppressed_when` predicate implements exclusions or precedence and
is evaluated anew for the supplied facts and claims. Dependencies refer to other
rules' amounts; cycles and missing references are source errors.

Scope has `hts_exact` and/or `hts_prefixes` (union, never silently truncated),
`countries`, and `from`/`until` timestamps. Null or omitted scope restrictions
mean all. Empty arrays mean none. Bundles also carry the complete revision's
`products` list, `coverage_requirements` and scoped `coverage` attestations.
Missing products, unverified sources and unverified authority coverage cannot
produce a complete total.

Every coverage attestation requires `determination` (`rules` or
`no_applicable_rules`) and an explicit `rule_ids` array. All referenced actions
must exist, belong to the attested authority, and account for every rule matched
by product/origin/entry window. Verified absence is an empty rule inventory plus
`no_applicable_rules`; it cannot coexist with a matched action. Older attestations
without an inventory are incomplete, even if their source status says verified.

Each claim definition's `rule_ids` records the actions whose claim effect has
been reviewed, including actions unchanged by the claim. Every scope-matched
action must be included for a requested claim. The evaluator performs this check
before predicates/suppression, so a claim that might revive a suppressed action
cannot disappear from the calculation. Missing claim effects yield
`claim_not_priced:<claim>:<rule>` and keep `complete_total` null. Synthetic shared
conformance fixtures exercise these failure states; they are not legal oracles.


Expressions are JSON objects with exactly one discriminator:

- `{ "value": number | boolean | string }`
- `{ "fact": "customs_value" }`: validated using `fact_definitions` (type,
  minimum/maximum or enum). Missing/invalid facts remain missing inputs.
- `{ "claim": "USMCA" }`: membership in the explicit `facts.claims` array;
  omitted claims means no claims. A claim's eligibility remains a separate fact.
- `{ "rule_amount": "rule-id" }`: evaluated amount, including suppression.
- `{ "authority_covered": "section_232" }`: true only when that authority's
  declared coverage requirement has a verified, complete matched rule inventory.
  Otherwise the expression is unresolved; it never returns false/zero or reads
  caller facts. A dependent duty cannot assume omitted actions are absent.
  A separately established exemption may bypass this dependency.
- `{ "rule_applies": "rule-id" }`: actual applicability after scope, source,
  claims and suppression, independent of valuation/amount. Use for exclusions
  conditioned on liability; zero/missing customs value cannot revive an action.
  Cycles in applicability or amount dependencies remain unresolved.
- `{ "op": ..., "args": [...] }`: `add`, `subtract`, `multiply`, `divide`,
  `min`, `max`, `eq`, `lt`, `lte`, `gt`, `gte`, `and`, `or`, `not`, `if`.
  `if` evaluates only its selected branch. False `and` and true `or` do not
  request irrelevant missing facts. Unknown operators fail closed.

Amounts are USD, rates are fractional multipliers, and quantities use the exact
unit declared by the fact definition. The formula explicitly supplies valuation
bases, floor/cap calculations and quantity factors. Interpreters do not perform
implicit unit conversions or substitute an ad-valorem equivalent for a specific
duty. Rounding policy must be represented by a future explicitly supported
operator or an unresolved source; this version does not silently round amounts.

`sail.shipment-result/v1` returns resolved components, formulas, reporting codes,
source citations, applied/suppressed rules, missing inputs, source errors and
versions. `known_subtotal` sums resolved components; `complete_total` is null
unless all applicable rules and coverage are resolved. Status is `complete`,
`needs_inputs`, or `unresolved_source` (which takes precedence). An absent bundle
is unsupported, never a zero-duty bundle. AD/CVD components use kind `deposit`;
final liquidation is outside this contract.

Duplicate identical rules are idempotent. Conflicting definitions of the same
rule identifier invalidate the bundle. Rule order has no legal significance.


## Decision provenance and conditional action fragments

Results also require `required_facts`, `rule_decisions` and `coverage_decisions`.
Fact definitions carry type, range/enum, unit, label, description and source IDs;
only currently missing, relevant definitions appear in `required_facts`.
Every scope-matched rule records its predicates, outcome, sources/citations and
missing inputs, including a false/not-applicable outcome. Authority coverage
records matched rule IDs and the source-backed attestations used to establish
coverage or verified absence. This supplies provenance for zero as well as duty.
JSON and batch preserve these objects; Arrow uses the corresponding `_json`
columns. Older responses missing required fields are unsupported, not aggregate
fallbacks. The active version is rediscovered for each explicit calculation.

`scripts/compile_shipment_rules.R BASE_BUNDLE OUTPUT_BUNDLE FRAGMENT...` composes
reviewed `sail.shipment-rule-fragment/v1` files, verifies source artifact SHA256,
rejects conflicting identifiers/fact semantics and applies explicit suppression
or required-predicate relations by reporting code. Adding an action does not
attest complete authority coverage. These fragments do not replace the complete
source chronology or production bundle compiler.

Relations can also bind `suppress_by_reporting_codes` to the assembled bundle's
actual trigger actions. `trigger_test: "positive_duty"` tests each trigger's
resolved amount after claims; the default `applicability` tests its applicability.
Single-trigger `suppress` supports the same distinction. A zero-duty floor or
relief is not a positive-duty trigger. Optional `target_rule_ids` restricts the
reviewed reporting-code targets to particular temporal actions, preventing old
and new precedence orders from creating a false cycle across an amendment.
The composer rejects unknown IDs and mixed independent reporting headings.

An `unchanged_claims` relation names a `claim_authority`, `target_rule_ids` and
evidence `source_ids`. It extends only registered claims whose candidate rules
all belong to that authority; a claim-name prefix is insufficient. This records
reviewed unchanged liability without inventing a discount, supplying eligibility,
or granting authority coverage. Dependent actions still reevaluate per shipment.

The release artifact hash covers the original rule file. Stored `bundle_sha256`
covers the exact serialized `bundle_json` bytes and is checked on every read.
Reformatting/corrupting stored rules without a new release cannot silently change
the evaluation. Preparation never switches the active release.

## Revision extraction and release contract v2

`sail.section301-extraction/v1` preserves each revision's Chapter 99/HTS hashes,
bounded legal note subdivisions, exact HTS8 or HTS10 scope, set differences,
description predicates and charge inventory. The normal build compiles its
`section301_rules.json` fragment; legal rates come from the revision's headings.
Technology-transfer and maritime investigations remain distinct cumulative actions.
An unresolved legal time-zone conflict emits an unverified rule only for the
ambiguous interval; it cannot inflate the known subtotal.

Fragments may declare `supported_from`/`supported_until`. Composition refuses
a base interval outside those bounds. Current reconstructed fragments are bounded
to the audit period and do not attest complete authority or claim coverage.
Source artifacts may be absolute local paths during compilation; production
evaluation reads stored rules and source metadata, without those local files.

`sail.tariff-release/v2` adds `section301_scope_decisions` to each immutable release
schema. Preflight requires that partition, checks source/product/program/origin
relationships and reconciles it with wide modeled/statutory fields. Missing rates
cannot stand for zero, and conditional scope cannot carry a known statutory rate.
PDF/HTS hashes must occur in the composed bundle. The rule/result contracts remain
v1 because the interpreter schema is unchanged. The release version participates
in stored-release compatibility checks; dataset versions continue to identify
corrected data and cache entries. v1 release rollback requires compatible code.

This preparation contract is not the separate legal coverage/validation gate:
source-backed exclusion history, all-authority compilation and exhaustive parity
must still pass before a prepared release can be marked validated or activated.

## Exclusion chronology extension (release v3)

`sail.tariff-release/v3` additionally requires `claim_effects.parquet` for every
2025/2026 revision. Rows retain claim/rule identity, HTS10/origin, named charge
heading, suppression effect, exact entry interval, condition JSON, source IDs,
locator and composite scope hash. Preflight requires VARCHAR columns and exact
agreement with executable exclusion rules, including their `claim_id`,
`target_reporting_codes` and `source_scope_sha256` provenance. An empty partition
is valid only when the bundle has no exclusion effects. No missing partition is
interpreted as no exclusions. Old release versions require their matching reader.

Rule/result contracts retain v1 with two additive capabilities. The expression
`{"unresolved_source":"reason"}` returns a source error only when relevant to
evaluation. It permits an optional claim's conflicting operative boundary to
remain unresolved without contaminating the unclaimed path. Older interpreters
reject an unsupported expression rather than turning it into zero.

Claim definitions may include `candidate_rule_ids`. The result's optional
`claim_options` contains only in-scope candidates: ID, label, matching rule IDs
and citations. These are potential claims, not eligibility findings or promises
of complete pricing. Existing explicit `rule_ids` still identify every action
whose claim treatment has been reviewed. Other actions remain `claim_not_priced`.
Arrow carries the additive `claim_options_json` column. Historical saved v1 results
without choices remain valid; they are not silently recalculated.

## Source decision partitions (release v4)

`sail.tariff-release/v4` additionally requires `section232_scope_decisions` and
`ieepa_action_decisions`. Note 16 decisions retain every exact-grain list/metal
membership and source hash; they must agree with the candidate inventory and
cannot be paired with a falsely unconditional wide statutory metal rate.
IEEPA decisions retain retired/selected/candidate state, actual expression,
origin, amendment identity/hash and operative timestamp. Country-rate partitions
retain independent reciprocal and country-EO parameters and reporting identities.
An excluded reciprocal origin has an explicit zero parameter and its published
exclusion heading. A missing country parameter is an unsupported projection,
not a zero. Evidence may retain a blank source duty cell only for an explicit
zero passthrough country exclusion; charged actions require their expression.
Preflight rejects missing fields, inconsistent revisions/types and source hashes
absent from the bundle. These are release-integrity checks, not legal-coverage
attestations. Source fragments must be composed before preparing the release.

The source-generated note 16 fragment uses the existing expression vocabulary.
Known reporting identities can coexist with a narrowly scoped unresolved formula.
A split-content treatment emits separate reporting components rather than a
guessed scalar heading. Predicate compilation distinguishes shipment inputs from
source discrepancies and rejects unknown legal condition grammar. The fragment's
limited revision horizon and absent authority attestation prevent its being
misrepresented as complete Section 232 chronology or all-action coverage.

The v6 release contract, now superseded by v7, It preserves v5's
wide/normalized legal-state grid validation and adds DATE `state_valid_from` and
`state_valid_until` to every `section232_scope_decisions` partition. Historical
notes 16/19 and post-April note 16 share one column/type schema, including empty
partitions. The extra historical conditions remain in their source and rule
objects. Each decision must match a wide legal state, an exact-grain candidate,
and the bundle's source hashes. Conditional metal scope cannot carry a numeric
wide statutory Section 232 rate. A v5 release is unsupported; do not manufacture
missing dates at read time. Preparing v6 is local and does not activate a release.

The pre-March 2025 metal fragment is now emitted through the same v6 release
path. It retains all 196 archived quota categories, exact statistical exceptions,
and the general approved exclusion tables. The fragment distinguishes tariff-rate
quota admission from absolute-quota admission. A rejected absolute quota supplies
no lawful over-quota duty alternative and cannot produce a complete total.
Partial quota allocation requires separate entry lines; a utilization share is
never used as a shipment allocation.

Country, melt/smelt, Ukrainian certificate, TRQ eligibility, Russian-material,
and exclusion decisions are evaluated before choosing a reporting heading. A
source-backed zero may correctly have no Section 232 heading. General approved
exclusions are claims, expire at the operative March transition, and do not erase
ordinary MFN/column-2 base, Section 301 or emergency duties. Preference-sensitive
base treatment is not covered by this independence statement. Individual Commerce
grants remain unpriced without the reviewed snapshot described below. An irrelevant grant
claim does not block independently established country relief.

`unchanged_claims` composition may name explicit `claim_ids` and
`target_authorities` instead of `target_rule_ids`. It still requires source IDs
and verifies the candidate rules' authority. This resolves against the actual
assembled rules; it does not recognize a claim by its string prefix. The public
result and rule bundle remain v1; no runtime expression was added. New dataset
versions and newly composed bundles are required before preparing a release.

Individual Commerce decisions use the [grant evidence contract](section232-grant-evidence.md).
The legacy compiler accepts a pinned reviewed snapshot and emits ordinary rule
expressions; no new runtime operator was introduced. Composition and release
preparation retain and check that evidence dependency. An ordinary base rule
must explicitly declare `base_treatment: column1_general` or `column2` before a
metal exclusion's unchanged-base relation can cover it. GSP/AGOA and unreviewed
base rules remain outside that attestation.

## Source-bound reporting dependencies

A fragment may use `reporting_predicate` as a **compiler-only** expression with
an explicit authority, exact reporting-code list, inclusion/exclusion direction,
and applicability/positive-duty test. The composer resolves it to action IDs,
rejects mixed reporting decisions, and avoids disjoint product/country/time scopes.
It does not create an absence attestation from an empty match. Dependent amounts
must still require `authority_covered`. Uncomposed predicates are unsupported by
the runtime.

Claim relations may explicitly `reevaluate` dependent actions. This records a
reviewed interaction, rather than a claim leaving liability unchanged. Required
candidate metadata can restrict the relation to independently verified Commerce
grants; a claim-name prefix or any arbitrary Section 232 claim is insufficient.


The current release contract is **`sail.tariff-release/v7`**. It additionally
requires `ieepa_reciprocal_scope_decisions` with revision, exact HTS10, original
scope code/grain, condition and full condition text, reporting code, source ID,
locator/hash, exact exclusive entry window, termination source ID, and revision
PDF/HTS hashes. `scope_grain` is INTEGER; the remaining fields are VARCHAR.
The matching source chronology is pinned in the rule bundle's
`evidence_dependencies.reciprocal_scope`. The ordinary emitter supplies an
evidence fragment for composition; this is not a reciprocal coverage attestation.

The additional `ieepa_reciprocal_initial_rules.json` fragment supplies original
reciprocal country/claim decisions from April 5 through August 1, 2025 (exclusive,
00:01 Eastern), including the June 4 metal-value amendment, June 30 UK aircraft
relief and July 9 suspension extension. It uses the existing
rule DSL and does not change release v7 or result v1. Its revision support window
is not a legal-coverage declaration: `legal_horizon` and each rule's exact scope
bound the implemented decisions; `coverage` remains empty. Later policy requires
additional verified rules. An empty fragment must never become a zero-duty
coverage record.

`RECIPROCAL_US_CONTENT` and `RECIPROCAL_TRANSIT` are action-specific claims.
Their effects leave other authorities unchanged; Section 232 claims instead
reevaluate reciprocal reporting dependencies. Chapter 98 claims are evaluated
across the stack. The evaluator requests actual content values and intersections
only on applicable branches. In particular, it must not infer metal value from a
Section 232 charge, deduct U.S. content twice, or substitute modeled shares.
FTZ and de minimis paths remain explicitly unresolved in this fragment. These
limits survive bundle composition and serving; they cannot be cured by a numeric
aggregate column or by setting an unsupported authority's coverage to verified.

UK aircraft relief preserves the original note 35 product enumeration and General
Note 6 predicate. It removes only the additional duties named by the original
annex, including the specified metal actions. The reporting heading's printed
blank date is resolved by the annex's independent operative introduction. A
non-China suspension extension cannot carry China beyond its separate source
window. Neither the August boundary nor an empty later fragment establishes zero
liability under the subsequent copper/country policy.

Preflight reconstructs the complete exact-product inventory from that pin and
compares every column before loading. Missing rows, extra rows, widened scope,
changed descriptions, mixed revisions, absent sources and changed dates fail.
The prepared release stores both the typed table and the bundle pin. The API
rule/result contract remains v1; dataset/release identifiers continue to control
cache isolation. Readers reject v6 rather than synthesize missing decisions.
