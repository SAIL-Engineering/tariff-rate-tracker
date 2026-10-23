# Emergency actions, legal intervals, and Section 122 precision

Local tracker work on `wjr_dev`, based on
`93315d1cdb48a4fb253e9e621186b4cce98fbd7d`. No timeseries/revision build,
publication, workflow dispatch, or MotherDuck write was performed. Other
repositories were not modified in this pass. This audit is not a certificate of
complete shipment-duty coverage.

## Source-backed corrections

1. **Canadian emergency duties:** ordinary covered articles carry 25% before
   August 1, 2025, and 35% from 00:01 EDT that day. The separate 40% replacement
   requires a CBP transshipment-evasion determination. The previous maximum-rate
   selector promoted that conditional action into the ordinary rate. Extraction
   now binds origin from the full revision's note, retains separate actions, and
   reconstructs the rate windows from [EO 14325 sections 2 and 3](https://www.govinfo.gov/content/pkg/FR-2025-08-06/html/2025-14999.htm).
   The ordinary and conditional rates do not establish applicability of all other
   claims, content exceptions, or interacting duties.
2. **China/Hong Kong emergency chronology:** a snapshot can already contain a
   future amendment. [EO 14357 section 2](https://www.govinfo.gov/content/pkg/FR-2025-11-07/html/2025-19825.htm)
   explicitly replaces 20% with 10% in 9903.01.24 from November 10, 2025 at
   00:01 EST. Both intervals are reconstructed from the amendment, rather than
   choosing a maximum or reusing February's 9903.01.20 heading. The original
   operative notes and native duty expression remain in the evidence record.
3. **Reporting and origin:** emergency exemptions and the Canadian energy heading
   retain their full notes, valuation clauses, entry windows and source hashes.
   An origin cannot be inferred from a heading-number block. The applicable
   energy/potash heading is carried forward instead of being relabeled general.
   Ambiguous ordinary actions, missing origins and malformed time zones fail.
4. **Changes between revisions:** the ordinary build now reevaluates each known
   legal state in the same HTS revision. This includes the November 14 country
   amendments in [the Korea implementation notice](https://www.govinfo.gov/content/pkg/FR-2025-12-04/html/2025-21940.htm),
   Section 301 charge/exclusion windows, configured activations, and Section 338
   amendment dates. The source audit finds **65 daily states in 55 revisions**.
   Exact instants remain separately available for shipment rules. Daily outputs
   represent the day's parameter state; they do not resolve the first minute of
   an entry day. This calendar inventories known extracted/configured events; it
   does not prove that every legal amendment has been acquired.
5. **Section 122 product scope:** full revision note 2(aa) replaces the global
   eight-digit exemption list in production calculations. All 55 source revisions
   were inspected: 18 contain 1,655 scopes (1,098 unconditional, 546 GN6 use
   conditions, 11 description conditions). The table specifies **8505.11.0070**,
   not all of 8505.11.00; the legacy list also contains **9031.49.70**, absent from
   these revision tables. The parser preserves exact statistical suffixes,
   reporting headings, descriptions and hashes, and rejects unfamiliar grammar.
   See [USITC 2026 revision 4, note 2(aa)](https://hts.usitc.gov/reststop/file?release=2026HTSRev4&filename=Chapter+99)
   and [CBP CSMS 67844987](https://content.govdelivery.com/accounts/USDHSCBP/bulletins/40b3b7b).
   Later snapshots retain expired provisions, including a warning about subsequent
   amendments to subdivision (v); they must not be used to rewrite an earlier
   entry's Section 232 exemptions. Nonproduct predicates remain verbatim evidence.
6. **Section 338 evidence:** amendment loading now verifies the retained primary
   PDF hash before applying a dated change and rejects competing amendments at
   the same program/time. Source order is immaterial. The existing August 22
   activation, exact HTS10 changes and action-specific Section 232 exclusions
   remain covered by tests. This does not automate the image-only annex
   transcription or certify every Section 338 interaction.

These are extraction/selection changes across source revisions. No regression
HTS, origin or entry-date example is used as a production correction lookup.
Aggregate utilization and credit inputs remain separate; changed aggregate values
must be measured after WJR's rebuild. Source scope and parameter corrections can
change aggregates while preserving their modeling method.

## Read-only MotherDuck findings

`motherduck.json.gz` retains queries, schema, capture times and results from
`duty_calculator`. Decompressed SHA256:
`e6ba2a29e025eeb0d753b3cb799e32fb269db4bc3160a27122a5880714d510e9`.
The connection and transaction were read-only and ended with rollback.

- **385,293 Canadian rows in 20 revisions** carry the conditional 40% as a
  statutory parameter; 275,839 have a positive modeled emergency amount.
- **39,490 China/Hong Kong rows on November 9** carry 10%, before the notice's
  November 10 reduction. They are two origins, not 39,490 distinct products.
- **608,713 rows** are flagged for an ordinary-parameter/reporting-heading
  mismatch across 34 revisions. These are diagnostic candidates: product
  carveouts and claim effects still require separate evaluation.
- **8,640 rows** for four adjacent magnet classifications, 240 origins and nine
  revisions carry zero statutory Section 122 despite falling outside the exact
  statistical exemption. The live rows also carry zero statutory Section 232.
- The stale optical-instrument line carries a fractional statutory Section 122
  value, approximately 8.2536%, and no Section 122 reporting heading.
- Production has 96 wide columns and lacks `modeled_s122_exempt_share`. Missing
  fields were recorded as unavailable; no modeled zero was synthesized.

These counts concern stored component parameters, not complete duty totals,
actual entries, overpayments, refunds or financial losses. Diagnostic categories
can overlap and must not be added together.

## Delivery and tests

Release contract **v5** preserves daily states rather than assuming one row per
product/origin/revision. It requires emergency note provenance and legal windows,
rejects partial/duplicate grids and mismatched normalized windows, checks Section
301 parameters at the applicable state, and preserves the previous active release.
The source-only Section 122 evidence is emitted as `section122_source.json`;
normalized exemptions carry exact product matches and conditions. This is not a
complete executable Section 122 rule bundle.

The main build, normalized re-emission, Parquet combine, daily aggregation,
diagnostic metal variant, and TPC date selection use the same state windows.
Staged normalized assembly preserves prior revision/shared files on failure.
The TPC benchmark receives only its requested date's state. Provenance ledgers
are saved per legal-state date; replay requires a date when more than one state
exists. Unknown ledger amounts remain missing, with a separate known subtotal. A normalized-only
re-emission does not regenerate wide snapshots and cannot qualify a release.

Test evidence is retained in `verification/`. Native Node API/JSON/Arrow/release
checks pass, as do Python extraction tests and the focused R tests. The complete
R runner still exits unsuccessfully: old normalized artifacts are missing 312
required partitions, so parity does not reach row comparisons; TPC requires
unavailable built inputs. No rebuild was used to disguise these gaps.

## Remaining legal/release gates

- Pre-April Section 232 product-bound headings, Russian metal provenance,
  vehicles/parts/semiconductor factual predicates, and remaining country deals.
- Resolution of the previously recorded note 16(xi) formula conflict from
  authoritative implementation guidance. Reporting-code identification alone
  does not resolve the amount.
- Complete IEEPA scope, transit, content, preference and stacking interactions;
  complete Section 122/232 interactions, including zero-duty Section 232 branches.
- Remaining Section 301 investigations/interactions, Section 338 Chapter 98/GN6
  predicates and complete automatic annex reconciliation.
- Full rule bundles and coverage attestations, exhaustive normalized/wide sweeps,
  remaining SAIL consumers, rebuild/aggregate comparison, and approved live
  MotherDuck release smoke tests.

Do not replace these gates with synthetic fixtures or a successful build. Manual
commands are in [the rebuild runbook](../../shipment-duty-manual-rebuild.md).
