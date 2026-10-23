# Conditional-action extraction and shipment decisions, 2026-10-23

This checkpoint addresses extraction scope, applicability and decision provenance.
It does not certify the complete 2025–2026 legal stack or activate a dataset.
Cutoff: 2026-10-22. No revision/timeseries rebuild, MotherDuck write, publication,
workflow dispatch, push or deployment was performed.

## Read-only production observations

`frontend/scripts/audit-conditional-actions.mjs` queried `duty_calculator` using
READ_ONLY plus a read-only transaction, 2026-10-23 15:06:18–15:06:27 UTC. The SQL
and results are retained in `motherduck.json.gz`; uncompressed SHA256:
`abc27677f25579d248ce9d0b5aa81a7b4f5ed4a5cba19bc4c9f5e7070ffa4f23`.

- 55 revisions; 8 origins: Canada, Mexico, China, Hong Kong, Germany, UK, Japan,
  Taiwan. Nine HTS6 groups cover machine/auto parts, semiconductors and textiles.
- 3,960 group rows represent 37,712 rate rows; all have numeric statutory totals.
  This is an observation of stored values, not proof that all those totals are wrong.
- 4,840 exact HTS10/origin/revision samples. Of 12 requested HTS10s, 11 were present;
  `8409915080` was absent. Absence is not a zero rate. Semiconductor groups account
  for 4,400 rows in the grouped sample.

| Stored example | Observation | Legal decision still needed |
| --- | --- | --- |
| 8471500150 / Mexico / 2026-01-15 revision | 232 = 0; fentanyl = 25%; total = 25% | Note 39 technical/end-use facts and actual action liability |
| Same / China | 232 = 0; fentanyl = 10%; 301 = 25%; total = 35% | Same conditional 232/IEEPA exclusion; independently verify remaining actions |
| Same / Mexico / 2026-02-24 revision | total = 0 | Zero aggregate/old statutory fields cannot establish semiconductor exemption |
| 8708407580 / Mexico / 2026-01-15 revision | raw 232 = 25%, raw fentanyl = 25%, total = 27.5% | Source-backed suppression and actual auto-parts use; summing raw columns is wrong |
| 6307909891 / China / 2026-10-09 revision | 301 = 50%, reporting 9903.91.07 | The reviewed note 31(h) enumeration does not contain this HTS10 |

The full stored intervals extend beyond the audit cutoff in revision 21; no
post-cutoff legal correctness is asserted. Legacy numeric output is not the oracle.

## Primary-source findings and implemented corrections

1. **Semiconductor liability, not a matching prefix or positive amount, controls
   exclusions.** Proclamation 11002 clause 3 and Annex notes 39(a)–(d), 2(v)(xvi),
   2(x)(xv), 2(z)(xiii), [91 FR 2443](https://www.govinfo.gov/content/pkg/FR-2026-01-20/pdf/2026-01052.pdf),
   confirmed against [CBP CSMS 67400472](https://content.govdelivery.com/accounts/USDHSCBP/bulletins/4047318).
   The data fragment models exact effective time, both strict TPP/DRAM windows,
   all-IC review, seven end-use exceptions, >100 MW new AI load and the explicitly
   enumerated excluded headings. Exempt/nonqualifying articles reevaluate other
   actions. `rule_applies` is independent of customs value; missing or zero value
   cannot revive an excluded duty. Model shares cannot establish liability.
2. **Automobile parts need a use predicate.** Proclamation 10908 Annex I note
   33(g)/(h)(ii), [90 FR 14712–14713](https://www.govinfo.gov/content/pkg/FR-2025-04-03/pdf/2025-05930.pdf),
   explicitly distinguishes listed articles that are not parts for passenger
   vehicles/light trucks. A verified relation constrains an existing 9903.94.05
   action; it supplies no guessed rate, date or country treatment. The R pipeline
   now leaves conditional auto-parts statutory 232/totals unavailable, while
   retaining the aggregate projection. Both auto and semiconductor candidates
   survive extraction even where aggregate modeling removes one.
3. **Configured product sources cannot silently widen.** Missing scope files now
   fail; a valid exact list with no products in a revision remains an empty match.
   Exact HTS10 membership remains exact. Source paths/hashes and matching scope
   are emitted in `authority_product_candidates.parquet` before model suppression.
   Its rows say `candidate_requires_legal_predicates`, never verified liability.
4. **Section 301 scope extraction was lossy.** [89 FR 76581, Annex C](https://www.govinfo.gov/content/pkg/FR-2024-09-18/html/2024-21217.htm)
   note 31(h) lists five exact mask/respirator HTS10s. The existing HTS8 conversion
   broadens those codes; scanning until another heading also ingests unrelated
   provisions. A real-source bounded-span regression preserves all five HTS10s
   and their descriptions and excludes adjacent 6307909891. Guards reject lossy
   6/10-to-8 conversion, retain chapters 19/20, exclude Chapter 98/99 references,
   and replace complete snapshots instead of unioning deleted entries back in.
   **The legacy cross-note scanner and maximum-rate selection still need full
   reconstruction; existing Section 301 CSVs/rates were not rebuilt or certified.**
   Annex C paragraphs 9/19 and 20–22 demonstrate why dated exclusions/deletions
   must be applied explicitly. No replacement full-stack rate is asserted here.

Primary PDFs/text, hashes and locator-bearing fragments are retained under
`resources/legal_evidence/` and `resources/shipment_rules/`. Source verification
does not attest that all later amendments or all authorities are covered.

## Contract and serving changes

R and TypeScript return per-rule decisions (including not-applicable rules),
source citations, required fact definitions, and per-authority coverage decisions.
A verified absence of actions has its own attestation/citations. The composer
verifies retained source hashes and merges action relations without inventing
coverage. It is a fragment composer, not the unfinished all-authority compiler.

The release manifest now requires candidate partitions with valid product/scope/
source relationships. Preparation retains them in immutable versioned tables.
Stored JSON rules are hash checked on reads. JSON/Arrow/batch preserve decision
traces and metadata; client calls discover then pin the active dataset version.
Missing contract, changed version or corrupted rules cannot fall back to aggregate
values. A prepared release is still not an activated or legally validated release.

SAIL's existing `/us-tariffs` lookup now has an exact-shipment determination panel
using this contract, dynamic facts and explicit totals/subtotals/unavailable states.
It runs independently of legacy history availability. Authentication is forwarded
through the existing session. The legacy calculator, comparisons, scenarios,
bulk/export, `/hts-explorer`, Product DNA, saved results and PEA are **not yet all
migrated**; this addition is not completion of consumer integration.

## Verification and limits

- Tracker Node/API: 97 tests passed, including local DuckDB → JSON/Arrow/batch,
  source/hash corruption, candidate relationship failures, versions and rollback.
- Shared conformance: 44 R/TypeScript cases; 35 source-backed semiconductor
  condition cases use **synthetic other actions**, plus four R auto-use/revival
  checks. They are not full-stack statutory oracles.
- R full suite: 24/26 suites passed (402 counted legacy assertions plus newer
  suites). Normalized parity errors on 2,008 missing-output cases; TPC skipped.
  The final auto-parts scope/model/total checks also passed after the full run.
- SAIL: 92 affected tests, affected lint and hardened typecheck gate passed.
  Server: 0 errors; app: unchanged 229 errors/57 baseline files. No baseline edit.
  Production build, prerender and vendor-neutral guard passed. Full historical
  lint/test baseline limitations remain documented in the earlier checkpoint.
- gstack `/browse`: isolated actual-panel fixture exercised required facts,
  technical/end-use decisions, stale-result clearing, known subtotals and coverage
  display; no console errors. Screenshots are unstyled fixture evidence, **not**
  authenticated-page visual acceptance, real API/MD smoke tests or legal oracles.
  $45/$40 subtotals include synthetic 10% companion actions and must not be quoted
  as legally correct shipment totals.

No regenerated revisions or measured aggregate differences are delivered: WJR
runs those manually using `docs/shipment-duty-manual-rebuild.md`. This change
preserves modeled rates; stricter source checks can stop previously permissive
builds, and conditional wide statutory totals now become unavailable. Rebuild
and reconciliation are required to measure the resulting data changes.

## Remaining release dependencies

Complete the Section 301 note/amendment reconstruction and verified action bundle
compiler, all-authority/claim inventory (including 122/338, mixed metals, quotas,
Chapter 98 and AD/CVD), historical source chronology, full consumer migration,
all 55 manual revision builds and exhaustive interval/row/aggregate comparisons.
The Canadian beer dispute remains unresolved. Do not activate these fragments or
partially rebuilt tables as a complete production release.

This pass starts from tracker `42a3bb5f631a816f5a5d19d0d80d9644e9481609` and SAIL
`2d0d25b23ef69949629a3d38496677f1157a7fb9`. Original task bases and local merge
destinations are in `docs/shipment-duty-implementation.md`. Trade Intelligence
has no changes in this pass. Integration SHAs are recorded after local merges.
