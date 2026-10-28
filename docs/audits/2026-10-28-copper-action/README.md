# Original copper action and source transparency

Tracker base `5271fcb8`, branch `wjr_dev`. This follow-up is local only. No push,
production MotherDuck mutation, release activation, workflow dispatch or full
revision/timeseries rebuild was performed. The current shared SAIL interpreter
is reused without a new frontend/runtime change.

The [source map](../../shipment-duty-sources.md) distinguishes structured HTS
data, original legal instruments, CBP instructions, corpus evidence and commercial
content/calculation products. Most remaining executable gaps are engineering or
reconciliation work, not evidence that the law is missing or unknowable.

## Implemented

The original [Proclamation10962](https://www.govinfo.gov/content/pkg/FR-2025-08-05/html/2025-14893.htm)
and its actual annex supply all80 HTS8 provisions, the reporting roles and the
50percent coefficient. The three native duty columns reconcile independently
with the original heading table. Full native clauses, unknown references,
additional conditions, residual table text and product validity are checked;
an unfamiliar amendment cannot be discarded or converted to a silent zero.

[CBP-CSMS65794272](https://content.govdelivery.com/bulletins/gd/USDHSCBP-3ebf0e0)
supplies the separate documentary/value decisions:

- Supported copper-content value is the duty basis for a mixed article.
- An article composed only of copper uses entered value.
- An explicitly declared inability to determine value, or insufficient
  documentation, uses full entered value under the CBP instruction.
- An omitted state/value is **not** one of those declared states. It remains
  missing input; it cannot become zero or full-value duty by default.
- Copper-free and non-copper portions have their own zero-dollar reporting
  role. A two-line reporting requirement is not an additional charge or credit.

One source-valued expression is bound into the copper action and the existing
reciprocal/Section122 portion calculations. A supplied legacy
`copper_content_value` alias cannot override the supported declared value.
Modeled copper shares and assembly credits are not inputs to these rules.

The original August1,2025 00:01Eastern commencement and April6,2026 00:01Eastern
replacement delimit this action. The original April annex expressly deletes
note36 and headings9903.78.01/.02: both original pages were rendered and visually
reviewed, with hashes in `primary-proof.json`. The first minute of the April
source frame retains the old copper action; the new note16 begins at00:01.

Original automobile/parts and country-specific parts scopes are disjoint from
the80-provision copper table. This is checked from the source inventories;
classification alone is not used to guess automotive use. The separately compiled
EU/Japan/Korea aircraft concessions are reused. Their actual copper intersection
is7413.00.90.00 and retains the country, use and entry-window predicates.
No blanket aircraft exemption is applied to all copper.

An uncompiled Chapter98 claim now blocks applicability before another action can
use the copper reporting decision to exclude value. It is not treated solely as
an unknown amount after a supposedly settled stack. FTZ histories likewise
precede current zero exemptions. Traditional Section301 exclusions leave this
independent copper action unchanged.

The ordinary normalized emitter now writes `section232_copper_rules.json`,
source-backed candidate memberships, exact rule windows and the bundle data.
The generated-artifact prerequisite gate requires that file. Shipment projections
remain nullable/conditional when facts or authority coverage are unresolved.
No production example is special-cased, and aggregate methodology is unchanged.

## Source and database audit

The reproducible source-only census reconciles55 configured revisions:
80 original HTS8 provisions,118 exact native HTS10 identities,21 native heading
snapshots and240 Census origins. These are source/candidate populations, not a
count of incorrect shipments or a complete all-authority coverage certificate.
`scripts/audit_section232_copper.py` reproduces `source-census-final.json.gz`.

The read-only query in `motherduck-copper-points.cjs` uses the same catalog
configuration as the tariff API, `READ_ONLY`, an explicit read-only transaction
and rollback. Its twelve rows and parameters are retained in
`motherduck-copper-points.json.gz`.

For8544.42.90.90/France on August2,2025, stored `statutory_rate_232` is
0.24569516464730964, exactly50percent times the modeled copper share
0.4913903292946193. On April5,2026, that stored column is0 and the modeled share
is0, although the original copper action and scope remain operative. Neither row
contains the shipment's actual copper value. These stored values cannot price
an individual ordinary entry. In the supported mixed-article test at value100
and declared copper value20, the original copper component is10, independently
of either modeled share. This is a component comparison, not a certified total.

All twelve rows also lack the sampled shipment contract/version/completeness and
decision-reference columns. They are not a supported corrected shipment contract.
Their daily intervals cannot represent the April first-minute transition.

The existing Trade Intelligence CSMS corpus was queried read-only for copper
notices before the cutoff and returned0 records. The directly verified public
CBP notice exists and is reused from retained primary evidence. This is an
evidence-acquisition coverage gap, not proof that instructions are unavailable.
The bounded discovery SQL/export is `csms-copper-snapshot.json.gz`; it does not
replace the production corpus.

## Verification and limits

-480 Python tests and1073 individual Node tests pass. Nine source-parser tests
  cover precision, chronology, native reconciliation, unknown exceptions,
  unexpected editorial text, source mutation and a later reappearance of a
  terminated heading. A future reappearance requires new legal reconciliation;
  it cannot inherit the old action's expired clock or become zero by omission.
-33 R/TypeScript cases cover content states, reporting, content/value limits,
  origin treatment, missing facts, preferences, aircraft relief, Chapter98
  dependency reevaluation, order/duplicate invariance and exact entry instants.
-Seven product/origin cells in three ordinary-emitter source frames are checked
  across two bounded runs: August2025, April5,2026 and the April6 minute boundary.
  Nine scenarios pass Parquet relationships, local DuckDB, R/TypeScript, APIJSON,
  Arrow, batch, version invalidation and bundle-tamper rejection.
-The conditional reciprocal test uses actual copper and reciprocal rules with
  an explicitly synthetic no-other-232 coverage assumption. It produces10+8 at
  the supported value basis. The normal build does **not** receive that
  attestation: its reciprocal amount stays unresolved while full232 coverage is
  unqualified. No synthetic coverage is emitted to production artifacts.

The full R gate has not been requalified. The earlier91-suite invocation is
documented in the preceding audit; two fixture errors were corrected there.
The current fast generated-artifact gate fails before parity on738 missing
artifacts. This is the earlier685 plus53 missing copper rule objects in existing
revision directories; the two wholly missing directories20/21 remain separate
directory failures. The TPC input remains absent. Existing old artifacts were
not silently edited to satisfy the gate.

The initial normal fixture exposed a claim-label mismatch and then an omitted
ordinary-procedure fact/coverage assumption in the test. The label was aligned
with the existing contract and the facts were made explicit. No coverage guard
was cleared. A later test-file edit while R was still reading it caused a trailing
parse error after the assertions; the final run used an immutable script copy.
Only completed current runs are counted above. One early Node fixture encoded an
empty facts object as an array; correcting that transport fixture did not weaken
runtime validation.

Still unfinished: privileged-foreign historical rate/classification selection,
certified medium/heavy-duty parts paths, selected Chapter98 intersections and
the complete authority inventory. The medium/heavy-duty certified-parts provision
is broader than its enumerated product list; no disjoint-list finding is used to
deny that separate provision. Missing importer facts and unimplemented law remain
different causes. This follow-up does not qualify the final timeseries rebuild.

No active release was changed. A future approved release must load separate
versioned tables, validate its related partitions/bundles and retain the prior
release before activation. Rollback for this local code checkpoint is a local
revert; no database rollback is currently necessary.
