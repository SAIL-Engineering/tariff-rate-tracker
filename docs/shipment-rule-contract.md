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

The release artifact hash covers the original rule file. Stored `bundle_sha256`
covers the exact serialized `bundle_json` bytes and is checked on every read.
Reformatting/corrupting stored rules without a new release cannot silently change
the evaluation. Preparation never switches the active release.
