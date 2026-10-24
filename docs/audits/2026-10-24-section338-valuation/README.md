# Executable Section 338 and Chapter 98 valuation

Tracker base: `e716bccaf16e52dcad0b016b01bb9efb03d2e648`, original checkout,
branch `wjr_dev`. SAIL and Trade Intelligence are unchanged in this pass. No
timeseries/revision rebuild, MotherDuck write, activation, push, workflow change
or deployment was performed. Test calculator runs use bounded temporary fixtures.

## Original evidence and decisions

The Section 338 compiler reconciles the original Annex I discovery tables with
the Annex II operative tables, then checks the retained CSV projections. It
does not use a later snapshot to determine the earlier effective instant.

- [Proclamation 11046, alcohol action](https://www.govinfo.gov/content/pkg/FR-2026-07-23/pdf/2026-14991.pdf):
  63 original provisions, heading 9903.03.12; note 51(a), (c), (d) supplies the
  common conditions, Chapter 98 treatment and exceptions.
- [Proclamation 11047, dairy action](https://www.govinfo.gov/content/pkg/FR-2026-07-23/pdf/2026-14992.pdf):
  52 original provisions, heading 9903.03.13.
- [Proclamation 11048, motor-vehicle action](https://www.govinfo.gov/content/pkg/FR-2026-07-23/pdf/2026-14997.pdf):
  439 original provisions, heading 9903.03.14. These are action names; membership
  comes from the actual tables, not a classification such as “vehicle parts.”
- [Proclamation 11056, paragraph 1](https://www.govinfo.gov/content/pkg/FR-2026-08-24/html/2026-17294.htm):
  replaces the original August 19 commencement with **August 22, 2026, 00:01
  Eastern daylight time**. Both original proclamation and annex dates must
  reconcile with the replacement operand.
- [September alcohol amendment](https://www.govinfo.gov/content/pkg/FR-2026-09-14/pdf/2026-18838.pdf)
  and [motor amendment](https://www.govinfo.gov/content/pkg/FR-2026-09-14/pdf/2026-18839.pdf):
  effective **September 15, 2026, 00:01 Eastern daylight time**. Source-derived
  deletion/insertion operations preserve HTS8 versus HTS10 precision, leaving
  101 and 513 provisions, respectively. Applying the original note 51(c)
  replacement operands removes the Section 232 exclusion for those two actions;
  the dairy action retains it. This is not a global Section 338 switch.

The three actions remain independent and cumulative. GN6 aircraft relief needs
the source-listed provision and qualifying civilian use, excluding military and
unmanned aircraft. USMCA alone does not remove Section 338. The listed Section
232 decisions use applicability, including named zero-dollar decisions, rather
than a positive-rate heuristic. The qualified vehicle U.S.-content and auto-parts
provisions retain their specific predicates. An unlisted Section 232 decision
or missing inventory cannot prove that the whole article owes Section 338.

Section 301 exclusion claims leave the independent Section 338 action unchanged.
A source-bound Section 232 grant triggers reevaluation: before the September
change, removing the metal action can revive Section 338; after the change the
alcohol/motor action remains additive. Arbitrary claim labels receive no effect.

All five retained codifications containing note 51 (revisions 17–21) reconcile
with the original product tables and amendments. The complete interaction and
aircraft-condition wording is compared, not just the heading inventory. A changed
general clause, rate, product table or condition requires original-source review.
The retained page OCR is an extraction artifact, not replacement legal text.
Motor annex page 25 uses row-preserving OCR to avoid interleaving a table with
the amendment paragraphs. Embedded codes in Annex I descriptions are not scope.

## Chapter 98 valuation and claim completeness

[Proclamation 11012, Annex I, note 2(aa)(i), page 9347](https://www.govinfo.gov/content/pkg/FR-2026-02-25/pdf/2026-03824.pdf)
and Section 338 note 51(a) both distinguish:

- Proper Chapter 98 claim and CBP agreement, rather than eligibility alone.
- Repairs/alterations/processing under 9802.00.40/.50/.60: the specified work's value.
- Assembly under 9802.00.80: assembled article value less qualifying U.S. products.
- Other accepted Chapter 98 provisions: exemption, subject to the authority's
  own exceptions. Section 338 expressly retains liability for subchapter XXIII;
  Section 122 does not import that exception.

The shared compiler parses each authority's own clause and validates the claimed
eight-digit provision against that revision's HTS inventory. Selected Chapter 98
treatment must be evaluated as the `CHAPTER_98` claim across matched duties.
Uncompiled effects on another authority remain `claim_not_priced`; the adapter
does not quietly assume that another charge remains unchanged.

When a Chapter 98 value intersects a Section 232-exempt portion, the importer
must substantiate the **value included in both bases**. Subtracting gross metal
content from repairs alone, or deducting U.S. content twice from an assembly
value, would understate liability. The overlap is bounded by both values and
their shared article value. This is the executable reconciliation of the two
source-prescribed bases, not an additional exemption or modeled content share.

Entitlement itself is not inferred from a number or from a customer declaration.
Missing acceptance, invalid provisions, unsubstantiated values and inconsistent
overlaps preserve incomplete results. Ordinary product/claim exemptions still
avoid questions about irrelevant valuation facts.

## MotherDuck audit

The new read-only connection checked `duty_calculator`, opened a read-only
transaction and rolled it back. It read **122,532 Canadian HTS/interval groups**,
without selecting a list of example products. The retained export SHA256 is
`f6f7cf582798595594d668c728b010229b641989894206337ec87ae1f810a504`.

The source comparison checked **265,486 entry-day groups**, using each stored
interval's endpoints and every Section 338 transition inside it. It found
**1,867 distinct stored groups** with ordinary scope/rate discrepancies:

| Stored revision | Candidate discrepancy | Distinct stored groups |
|---|---|---:|
| 2026 revision 16 | 50% present before the delayed August 22 start | 1,216 |
| 2026 revisions 19, 20, 21 | 0% where the amended ordinary scope calls for 50% | 207 per revision |
| 2026 revisions 19, 20, 21 | 50% retained on removed statistical suffixes | 10 per revision |

There are 7,674 tested entry-day groups requiring a Section 232 shipment decision,
which are deliberately not assigned a definite expected rate from a stored
positive/zero rate. These are raw scope/parameter comparisons, **not confirmed
shipment totals, dollar exposure or unique entries**. Aircraft, Chapter 98, FTZ
and other shipment facts still matter. Stored revision windows can overlap; the
report retains revision identity. Several discrepancies were already corrected
in local aggregate code before this pass and remain in the unpublished live data.

See `source-sweep/report.json`, `motherduck-findings.json.gz` and
`motherduck-read-only.json.gz` under `source-sweep/` for reproduction and coverage.
The source/compiler sweep checks all 55 configured revisions and their complete
ordinary HTS10 inventories; it is not a complete all-authority shipment sweep.

## Pipeline and serving behavior

- The normal emitter writes `section338_source.json` and `section338_rules.json`.
  Existing `authority_product_applicability.parquet` gains action-specific rows,
  exact/prefix precision, source identifiers and entry instants. Published
  percentages are `legal_rate_parameter`; unresolved `statutory_rate` remains NULL.
- Original-source events split aggregate intervals between HTS publications.
  Wide aggregate projections must reconcile against the original tables and
  amendment operations. Existing aggregate aircraft assumptions remain separate.
- A bounded Canada-only pipeline check exposed Section 301 injecting unrequested
  China rows. Both audited and legacy Section 301 seeding now respect requested
  origins. The regression asserts the exact four-product, one-origin grid.
- Existing v1 rule/result and v6 release contracts interpret these data-defined
  expressions. JSON, batch and Arrow checks use actual local route/store code
  and in-memory DuckDB. No new legal constants enter React or a second interpreter.

## Verification, open work and rollback

The final commands, exit codes, counts and log hashes are in `verification.json`.
Python: **341 passed**; Node: **362 passed**; TypeScript and Vite build: passed.
The full R command exited 1: **402 counted assertions passed**, no counted
assertion failures, but normalized parity failed with **312 missing/stale
partitions**, and the TPC comparison was skipped for missing external input.
Suites without numeric totals are not included in the 402 count. The complete
R gate therefore remains unsuccessful.

Bounded fixtures are explicitly distinguished from legal coverage attestations.
No synthetic bundle is eligible to become a production release.

Broader coverage remains unfinished: complete IEEPA action/claim chronology;
remaining Section 232 sector/country/grant/offset definitions; FTZ admission and
classification paths; remaining Section 301 investigations/exclusions and
Chapter 98 interactions; AD/CVD and financial consumers. Section 338's unlisted
offset decisions and FTZ paths remain unresolved. These compilers do not assert
complete authority coverage. Entitlement facts are not replaced by a legal
opinion encoded as a boolean default.

Use the [manual rebuild runbook](../../shipment-duty-manual-rebuild.md) after the
remaining logic/coverage work. The full normalized parity gate still requires
the rebuilt partitions; the TPC comparison requires its actual external input.
This work does not authorize a release or prove production qualification.

Rollback is a local revert before publication. Future publication must prepare
the complete versioned release, validate it, and retain the previous active
release for rollback. MotherDuck's active release was not changed here.
