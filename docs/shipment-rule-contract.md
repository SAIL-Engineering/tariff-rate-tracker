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

Expressions are JSON objects with exactly one discriminator:

- `{ "value": number | boolean | string }`
- `{ "fact": "customs_value" }`: validated using `fact_definitions` (type,
  minimum/maximum or enum). Missing/invalid facts remain missing inputs.
- `{ "claim": "USMCA" }`: membership in the explicit `facts.claims` array;
  omitted claims means no claims. A claim's eligibility remains a separate fact.
- `{ "rule_amount": "rule-id" }`: evaluated amount, including suppression.
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
