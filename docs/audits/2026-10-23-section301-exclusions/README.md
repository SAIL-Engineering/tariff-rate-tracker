# Section 301 exclusions, chronology and serving contract

Audit cutoff: October 22, 2026. This is a locally verified implementation checkpoint,
not completion of the all-authority shipment plan or approval to activate data.

Tracker base: `b53e1f2aa844fa5673e8fcb9be437a5d1c139328` on `wjr_dev`.
SAIL implementation base: `5d8e5b430a43c67c6b2f3522e1f20d5a95be6cc7` on
`codex/shipment-duty-correctness-ui`, integrated locally into `pinecone-hts`.
Trade Intelligence remains at `766334b6b41dd5f45cfd3df583b7c5d53447ae1a` on
`main`; this checkpoint does not change its evidence schema or pipeline.

## Source and calculation changes

The ordinary 2025/2026 build now extracts 164 note 20(vvv) descriptions and 14
note 20(www) descriptions from each revision's Chapter 99 source. It combines
these with the original grants, three extensions, and five retroactive amendments
in the September/October 2026 notices. Literal amendment operations are applied
idempotently to older schedules; entry eligibility follows the amendment's
operative date, not publication date. Historical classification references retain
separate intervals, including comma-separated replacement clauses.

Two direct exclusions are also compiled: heading 9903.91.09's crane contract and
certification conditions, and heading 9903.91.10's enteral-syringe description.
The crane exclusion suppresses both source-enumerated investigations where they
apply. Its expiration uses calendar Eastern time, fixing a generic parser that
previously imposed a winter UTC offset on every expiration date.

Exclusion conditions target named reporting headings. Multiple descriptions for
the same HTS10 and target are alternatives: one established qualifying description
does not require answers to the others. Claim selection reevaluates action
applicability. Unclaimed statutory charges and aggregate modeling are unchanged;
no utilization share or assembly credit participates in shipment evaluation.

Conflicts between printed time-zone names, operative minutes, and heading calendar
windows remain explicit `source_discrepancy` intervals when a claim is requested.
The interpreter can evaluate those discrepancies conditionally, so an unrequested
claim does not make a known unclaimed component unavailable. These are unresolved
source interpretations, not silently normalized legal timestamps.

The composer flattens boolean relations and indexes their named targets. This
avoids a C-stack overflow and quadratic scanning when hundreds of exclusions are
composed. Source hashes, exact products, conditions, target charges and dates
remain attached to each rule and normalized claim-effect row.

Primary evidence retained under `resources/legal_evidence/`:

- [2024-11904](https://www.govinfo.gov/content/pkg/FR-2024-05-30/pdf/2024-11904.pdf): original 164 exclusions; PDF and text layer retained because HTML omits annex graphics.
- [2024-21217](https://www.govinfo.gov/content/pkg/FR-2024-09-18/html/2024-21217.htm): solar equipment, crane and syringe provisions, including Annex D certification.
- [2025-10203](https://www.govinfo.gov/content/pkg/FR-2025-06-05/html/2025-10203.htm), [2025-16733](https://www.govinfo.gov/content/pkg/FR-2025-09-02/html/2025-16733.htm), and [2025-21671](https://www.govinfo.gov/content/pkg/FR-2025-12-01/html/2025-21671.htm): successive extensions.
- [2026-17925](https://www.govinfo.gov/content/pkg/FR-2026-09-02/html/2026-17925.htm) and [2026-20511](https://www.govinfo.gov/content/pkg/FR-2026-10-07/html/2026-20511.htm): retroactive statistical-code amendments.
- [2025-19568](https://www.govinfo.gov/content/pkg/FR-2025-10-16/html/2025-19568.htm): maritime investigation's explicit crane-claim interaction.

## Read-only MotherDuck comparison

All 55 revision source pairs parsed successfully, producing 8,028 candidate
HTS10/revision/heading pairs. The read-only capture selected the source-derived
product universe plus any previously stored Section 301 exclusion candidates.
It captured 8,063 China product/revision rows at 18:29 UTC on October 23, 2026.

The final comparison finds **152 missing candidate attributions**, with no removed
candidates: 77 from the five retroactive amendments, 42 crane-contract candidates,
and 33 enteral-syringe candidates. The 77 amendment rows cover seven changed
statistical codes across 11 revisions. These are candidate-attribution differences,
not proof that those entries qualify, nor measured over/underpayments.

The audit caught a new parser defect in the LCD historical-code clause; after
fixing it, the existing LCD exclusion is preserved in all 55 revisions. The
retained comparison is the corrected result. `scope.json` pins the extractor,
audit script, PDF/HTS hashes, enumerated boundaries, snapshot hash and capture
interval. `differences.json` retains every changed candidate.

## Release and UI delivery

`sail.tariff-release/v3` requires `claim_effects.parquet` alongside the v2
partitions. Read-only preflight checks column types, exact inventory, product,
origin, rule, claim, condition, target, source and interval relationships against
the composed bundle. Preparation creates immutable versioned tables and leaves
the active identifier untouched. Missing or mismatched rows reject preparation.

The shared R/TypeScript result adds optional `claim_options`: only claims with
candidate rules in this HTS/origin/time scope are offered. The existing Duty
Workspace panel displays these choices and their sources, asks for relevant facts,
and preserves unavailable/known-subtotal states. JSON, Arrow and batch carry the
same metadata. The SAIL validator rejects malformed choices and accepts historical
v1 results without the additive field. No browser receives database credentials.

The browser evidence exercises the actual panel with source-derived fixture rules:
unclaimed $25 known subtotal, requested exclusion, alternative description facts,
and $0 known subtotal after a qualifying answer. All remain incomplete because
the fixture does not attest all-authority coverage. This is an isolated unstyled
fixture, not authenticated-page acceptance or a production smoke test.

## Verification and remaining gates

`verification.json` records final local test evidence. All 55 source pairs were
parsed, not rebuilt. Existing normalized outputs lack corrected artifacts;
normalized parity remains a failed release gate, and TPC coverage requires built
data. The full timeseries rebuild remains WJR's manual step.

This checkpoint does not finish other Section 301 investigations/claims, the
complete IEEPA/232/122/338 review, Chapter 98, quotas, AD/CVD scope and instruction
chronology, all-authority bundle compilation, or remaining financial consumers.
Tariff Schedule, comparisons, scenarios, bulk/export, saved results, Product DNA
and Post-Entry Audit still require the planned integration. No complete authority
coverage is inferred from parsing these exclusions. No aggregate differences have
been measured from a new rebuild.

## Reproduction, manual rebuild and rollback

```sh
python3 scripts/audit_section301_exclusions.py --out /tmp/s301-scope-new
node frontend/scripts/audit-section301-motherduck.mjs .env /tmp/s301-live-new.json.gz \
  --exclusions /tmp/s301-scope-new/scope.json
python3 scripts/audit_section301_exclusions.py --snapshot /tmp/s301-live-new.json.gz \
  --out /tmp/s301-comparison-new
```

Use [the manual rebuild commands](../../shipment-duty-manual-rebuild.md) for all
55 revisions, including normalized revisions 20/21. Source changes apply through
the ordinary build; no example HTS row is hardcoded into production corrections.
Compose each resulting fragment into a reviewed full bundle before preparing a
release. Production evaluation reads stored MotherDuck rules, not this local
snapshot or one permanently pinned HTS revision.

No timeseries rebuild, production write, publication, activation, deployment,
workflow dispatch or push occurred. Future activation requires WJR's approval
and all remaining legal/data gates. Retain the previous validated release for
rollback within v3. Rolling back to v1/v2 requires its compatible reader code as
well as the old release; switching identifiers alone is insufficient. Local
rollback must preserve subsequent work before reverting these commits.
