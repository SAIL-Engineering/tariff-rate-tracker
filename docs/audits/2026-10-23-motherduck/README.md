# Live MotherDuck duty-stack audit, 2026-10-23

**Status: defects confirmed; full legal-stack qualification remains open.**
Database: `duty_calculator`. Audit window: 2025-01-01 through 2026-10-22.
The audit used a READ_ONLY connection and one read-only transaction. No cloud
schema, row, active release or publication was changed. Exact UTC retrieval times,
queries and artifact SHA256s are recorded in `manifest.json` and the query files.

## Coverage and limits

The structural sweep covers **267,714,240 rows**, all **55 revisions**, **240
origins** and **97 represented chapters**, grouped into 1,280,400
revision/chapter/origin cells (`sweep.ndjson.gz`). These are published revision
rows, not 267 million independently adjudicated shipments. Publication windows do
not capture all legal action boundaries. The audit retrieved 990 actual rows for
21 targeted HTS/origin/date cases, plus 83 rows in `targeted-followup.json` and 496 Chapter 98 rows in
`chapter98-followup.json`.

Live storage contains `rates` and `product_base_rates`; it does not yet contain
the versioned shipment-rule/release contract. A non-null statutory total in this
schema is not proof that scope, quantity, claims, content, quotas or AD/CVD have
been resolved. No complete shipment stack is certified by this report.

## Source-verified comparisons

Rates below are fractional duties expressed as percentages for readability.
The comparison assumes no preference claim. Expected values are component
expectations, not complete-total oracles. Source files and locators are pinned in
`resources/shipment_audit/cases.json`; `legal-comparison.json` records the local
comparison against the unchanged live snapshot.

| Entry date, HTS10, origin | Live observation | Primary-source finding | Root-layer response |
| --- | --- | --- | --- |
| 2026-10-09, 8703230190, Mexico | Statutory 232 = 23.7625%; forced-labor 301 = 10% | Auto 232 is 25%; note 52(f) excludes the auto action from forced-labor 301 | Preserve assembly credit outside statutory rate and apply action-specific exclusion; earlier local fixes await rebuild |
| 2026-03-10, 3917330000, China | Statutory 122 = 3.2059712424% | No GN6 claim: 10% Section 122; civil-aircraft usage share is a model input | Earlier statutory correction plus conditional normalized metadata; measured share emitted separately |
| 2026-03-10, 65 HTS10 children of 11 description-limited exemption codes, China | Statutory 122 = 0% on every retrieved child | CBP 9903.03.04 exempts named articles/uses, not every article classified in those codes | Preserve description/use predicates; no unconditional statutory exemption; aggregate assumption retained explicitly |
| 2026-10-09, 8537109120 / 2208306085 / 9507100080, Canada | Statutory 338 = 50% | September 15 exact-code amendments remove these lines; component should be zero | Earlier exact HTS10 amendment extractor awaits rebuild; neighboring retained codes remain covered |
| 2026-10-09, 8537109130 / 2208306075 / 9507100040, Canada | Statutory 338 = 50% | Retained adjacent codes remain 50% | Positive boundary controls, not exceptions in production arithmetic |
| 2026-10-09, 2203000030, Canada | 232 = 0%; 338 = 50%; forced-labor 301 = 10%; numeric total = 60% | Beer is in April metals Annex II and original 338 note 51(b)(1); verified components are 232 zero and 338 50% | The handoff's 40% is not a valid oracle. A complete 60% total is **not certified**; other applicability/claim/deposit facts remain to reconcile |
| 2026-10-09, 5205111000, El Salvador | Statutory forced-labor 301 = 10%; aggregate = zero | The unclaimed statutory component is 10%; claim/aggregate treatment is separate | This particular live statutory field already matches; retain as regression |
| 2026-08-14 to 08-21 revision, quartz-code products, China/India | No quartz candidates; numeric 201 zero | Proc. 11051 starts August 15 at 00:01 Eastern, inside revision 16 | Extract before revision-date filtering; preserve exact operative window, product scope, quota and covered-value inputs |
| 2026-03-10, 14 statistical children of four adjusted-value Chapter 98 provisions, China | Statutory 122 = zero on every retrieved child | CBP Chapter 98 guidance retains the surcharge on repair, alteration, processing or foreign assembly value after the specified adjustment | Replace unconditional exemption with explicit valuation/claim conditions; preserve prior aggregate treatment as a disclosed modeling assumption |
| Latest revision, same quartz candidates | Both 25% and 50% candidates; numeric 201 zero and numeric statutory total | Note 41 requires scope and quota allocation, not automatic zero or maximum-rate selection | Missing tiers/resources now fail extraction. The versioned evaluator must price the resolved action; legacy numeric totals remain unsuitable |

Section 122's eleven conditional codes are derived from the saved CBP notice in
tests. Their use in audit fixtures is not hardcoding production examples. Quartz
rates are extracted from both headings and checked against a source-backed window
resource. The first safeguard year is verified; later windows must be reconciled
before this extractor can accept them. Canada provides an exempt-origin control.

## Temporal defect

Live revision 19 ends 2026-12-31; so do revisions 20 and 21. Their respective
starts are 2026-09-15, 2026-09-29 and 2026-10-09. All three match an October 9
lookup. Updating only a new partition left its predecessors stale. New
synchronization preflight validates the projected set of intervals and rejects
this condition before replacing any partition. All affected neighboring
partitions must be included when a future publication is approved.

## Structural diagnostics (not individual legal findings)

| Diagnostic | Rows |
| --- | ---: |
| Statutory 232 differs from sum of attributed 232 actions | 7,375,798 |
| Positive statutory 232 assigned to unidentified `other` | 4,874,301 |
| Aggregate 232 differs from sum of attributed actions | 2,278 |
| Positive statutory 122 below 10% | 1,689,840 |
| Specific/compound base with numeric statutory total | 25,074,240 |

These flags overlap. A fractional duty can reflect a lawful valuation rule;
a numeric rate does not establish a correct amount; an `other` bucket requires
attribution review. None of these counts alone proves a legal overcharge or
undercharge. Zero AD/CVD-candidate flags do not establish absence of AD/CVD scope.

## What changed locally and what remains

Extraction now separates Section 122 description/GN6 predicates from modeled
shares, retains quartz operative dates and facts, and rejects incomplete quartz
source/rate coverage. The R and shared TypeScript interpreters require coverage
attestations to enumerate their actions. Claims must explicitly account for all
matched actions, including unchanged and revived actions. Deleted/unreviewed
rules cannot inherit a complete result. The serving contract still returns
unresolved when the new release is unavailable.

Production rule compilation, all-authority legal reconciliation, evidence-snapshot
qualification, remaining statutory/model leaks, and the SAIL financial-consumer
migration are unfinished. This audit does not turn the legacy wide table into an
executable rule bundle. The manual rebuild is necessary but not sufficient for
publication. See `../../shipment-duty-implementation.md` and
`../../shipment-duty-manual-rebuild.md`.

## Reproduce

Run the read-only audit from the tracker checkout, supplying its existing `.env`:

```sh
node frontend/scripts/audit-shipment-motherduck.mjs \
  --env .env --out output/shipment-audit-NEW --sweep
```

The output directory must not already exist. Use `--cases PATH` for additional
exact-code cases. Each expected component requires a primary-source verification
record, locator and matching saved-file hash. Structural queries are SELECT-only;
the tool never builds rates, writes MotherDuck, or activates a release.

For offline reconciliation, without querying MotherDuck:

```sh
node frontend/scripts/reconcile-shipment-audit.mjs \
  --snapshot docs/audits/2026-10-23-motherduck \
  --out output/shipment-reconciliation-NEW.json
```

The committed snapshot retains the original case specification used at retrieval.
The later `legal-comparison.json` is separately versioned evidence of reconciliation,
not a modification of the retrieved data. `targeted-followup.json` is a separate
read-only transaction and carries its own retrieval time and exact query.


The Chapter 98 follow-up confirms an additional scope defect, not a completed
Chapter 98 evaluator: a valid claim, ordinary classification and legally adjusted
valuation still have to be resolved together. The corrected condition resource
does not authorize a full-value shortcut or establish a complete total. Interactions
with independent civil-aircraft exclusions and other authorities remain part of
rule compilation and legal review.


A serving-path review also found that legacy Arrow and batch serialization replaced
null numeric values with zero, null booleans with false, and absent strings with
empty text. Both paths now share a serializer that preserves null and unions the
fields of all rows. IPC round-trip tests check unknown versus true zero. Legacy
base-MFN synthesis and aggregate-based consumers still require the planned
migration; serializer correctness alone does not certify their shipment totals.


## Verification of this checkpoint

- Node/API: 54 passed, including 38 R/TypeScript conformance cases, local
  Parquet/release/API JSON/Arrow/batch tests, audit integrity, interval preflight,
  and legacy Arrow null preservation.
- R: 19 of 21 suites passed (389 counted legacy assertions plus the uncounted
  expression, inheritance, amendment and shipment suites). Normalized parity
  failed all 2,008 selected cases for absent rebuilt normalized artifacts; TPC
  skipped for missing inputs. This is not a clean full-data suite result.
- SAIL: 48 affected tests passed, including the concurrently changed Chapter 99
  panel. Changed-file lint and the existing typecheck ratchet passed. Typecheck
  retains 229 existing app errors within baseline and zero server errors.
- SAIL build, prerender and vendor-neutral guard passed; tracker prototype build
  passed. Initial commands using the system Node 18 were rerun under installed
  Node 22; pure panel tests used inert local Supabase placeholders at import.
- Full SAIL lint still has the previously recorded baseline failures; authenticated
  browser acceptance and live release smoke testing remain pending.

Logs and SHA256s are in `verification/` and `verification.json`. No timeseries
rebuild was run. The manually run rebuild, aggregate difference review, full legal
rule compilation and production consumer migration remain necessary.
