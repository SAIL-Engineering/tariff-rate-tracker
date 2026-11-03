# Revision 22 source acquisition and rebuild boundary

Downloaded November 3, 2026 using gstack `/browse`. The official USITC release
list identifies `2026HTSRev22` as current, with `releaseStartDate=10/30/2026`.
The same current identity was checked before and after acquiring the live JSON.
Chapter 99 and GN3 are revision-bound downloads; their PDF headers identify
Revision 22 (2026). All four responses were HTTP 200.

| Source | Local location |
| --- | --- |
| Current JSON, 35,805 rows | `data/hts_archives/hts_2026_rev_22.json` |
| Chapter 99 PDF | `data/us_notes/chapter99_2026_rev_22.pdf` |
| General Note 3 PDF | `data/cache/general_notes/GN3_2026HTSRev22.pdf` |
| Change Record PDF and text | This audit directory |

Large source archives follow the repository's existing local-cache convention.
`source-manifest.json` retains their exact URLs, sizes and SHA256 hashes. The
release-list snapshots and single changed JSON row are retained here. The USITC
archive listing returned Access Denied; no archive modification-source row or
static JSON filename was fabricated.

The [Change Record](https://hts.usitc.gov/reststop/file?release=2026HTSRev22&filename=Change%20Record)
identifies U.S. note 51(b)(3), subchapter III, Chapter 99, modified October 30
by Proclamation 11076. The
[original proclamation](https://www.govinfo.gov/content/pkg/FR-2026-10-30/html/2026-22292.htm),
91 FR 68861-68871, paragraphs (1)-(2), changes Canada's Section338 motor-vehicle
action product scope at **2026-10-30T00:01:00-04:00** and expressly retains
cumulation with Section232. Both its body and its original graphic annex PDF
are retained here.

The annex is graphic only: the Federal Register text record carries eight
`[GRAPHIC] [TIFF OMITTED]` placeholders (TD30OC26.100-.107) and not one
machine-readable subheading. It was therefore read three independent ways and
the readings compared in `annex-reconciliation.json`:

| Source | Method | Result |
| --- | --- | --- |
| Annex I, Parts A and B | OCR of the scanned prose tables; code column cropped, three segmentation modes required to agree | 22 removed, 100 added |
| Annex II grid | OCR of the numerical grid amending note 51(b)(3) | 22 deleted, 100 inserted |
| Note 51(b)(3) itself | `pdftotext` of the Chapter 99 revision 21 and 22 text layers, diffed. No OCR | 507 to 585 codes; 22 removed, 100 added |

All three identify the same 122 subheadings, in the same order, and all 122
exist in the Revision 22 HTS universe of 18,025 8-digit codes. The net change
of +78 reconciles against 100 inserted less 22 deleted. The third source reads
the applied schedule rather than the instrument and uses no OCR, so the
agreement does not rest on the scan alone. OCR of a scanned legal annex still
does not substitute for human review of the original, which is retained for
that purpose.

The parsed JSON differs from revision 21 in only one row: heading 9903.01.63
loses its compiler suspension annotation. No numeric rate field changes. That
annotation is not decorative -- `inline_provision_status()` derives the
`suspended` status from exactly this text -- so its removal is reconciled in
`heading-9903-01-63-resolution.json` rather than accepted.

The suspension's authority is the executive-order chain, not the printed line.
Each link must state that the heading "shall continue to be suspended until" a
named instant, and the extractor checks the predecessor order and the
chronology of every link. The chain runs from 2025-05-14 to
**2026-11-10T00:01:00-05:00**, so the heading is suspended across the whole
audited window, including Revision 22's own effective instant. The USITC change
record attests one item, note 51(b)(3), and no change to this heading; change
records exclude endnotes and nonsubstantive formatting, which is what the
annotation is. The removal is therefore editorial and establishes no
reactivation, and no `unresolved_source` is needed.

The chain ends seven days after the current horizon, so a later instrument
extending the suspension should be added to the configured suspension documents
to keep it reconciled. A lapse would not by itself resume a reciprocal charge
on consumption entries: collection for EO14257 and all amendments ended
**2026-02-24T00:00:00-05:00** (FR-2026-03832, CBP CSMS 67834313), and
`compile_reciprocal()` already emits a verified `no_applicable_rules`
determination for every interval after that instant, with Sections 232 and 301
independent of it. The suspension and the collection ending are independent
legal events, so neither terminates the other; a lapse would reach only entries
that some later instrument brought back into collection.

The existing guard in `src/ieepa_reciprocal_rules.py` asserts that the
suspension outlasts the collection ending, which it does by eight months. That
guard is against the collection ending, not against `audit_until`.

The material Section338 scope amendment is in note text, so comparison of rate
rows alone would miss it.

The executable build horizon now ends exclusively at
`2026-11-03T00:00:00-05:00` (eastern standard time; daylight saving ended
November 1). Revision 22 is registered in `config/revision_dates.csv` with
`effective_date` 2026-10-30 and the same policy instant, and the rebuild
inventory moves from 55 to **56** revisions.

The horizon lived as a literal in nine places besides the contract, and the
Section 338 amendment exposed what that costs: an action period beginning
2026-10-30 against a compiler still pinned to 2026-10-23 produced an interval
whose end preceded its start, and the bundle carrying it was rejected whole,
far from the file that was actually stale. Those call sites now read
`resources/shipment_rules/build_contract.json` through `src/build_contract.py`
(or `.s301_audit_window()` in R), and the contract is declared in the affected
`compiler_dependencies` so changing it re-compiles.

Revision 22 is therefore **sources reconciled and registered, pending the
timeseries rebuild** -- not yet a validated shipment release. It is not in the
served source map or the weekday publication workflow. No timeseries build,
MotherDuck write, push, workflow dispatch or deployment was performed here.
Local validation commands now cover 56 revisions.

Frontend inspection of SAIL `pinecone-hts` at
`abee0254b6072a6165eac099cb41a7c29f892037` confirms the shared interpreter/client
and the Duty Workspace resolver panel exist. Bulk still calls
`calculateLandedCost` with wide rows; Post-Entry Audit and schedule consumers
still contain legacy reads. Their presence prevents a claim that rebuilding
Parquet alone completes production integration. No SAIL files changed here.

A fresh November3 read-only query of configured catalog `duty_calculator`
returned18 point observations and confirmed that `rates` still lacks
`shipment_contract_version`, `shipment_dataset_version`, `shipment_status` and
`shipment_decision_ids_json`. The query uses `READ_ONLY`, an explicit read-only
transaction, and `ROLLBACK`; its receipt is `motherduck-read-only-points.json`.
No ingestion or release activation was performed.

Local verification recomputed all four downloaded hashes, checked both
revision-bound PDF headers, verified all55 original-cutoff JSON/PDF source
pairs, and syntax-checked both handoff command blocks without executing them.
