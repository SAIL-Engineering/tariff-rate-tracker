# Gap criticality, actual MotherDuck scope and common product closure

Local `wjr_dev`, from `f49ebb8f`. No revision/timeseries rebuild or live write.

## What the counts mean

Missing legal logic is a release blocker. A missing actual shipment fact is a
different issue: a correct rule must request it, rather than assume end use,
metal weight/origin, a preference claim, company treatment or FTZ history.
Counts below measure potential scope, not a count of incorrect rates or of
unresolved actual shipments. One HTS/origin/date can have several lawful stacks.

| Scope | Distinct ordinary HTS10 | Origins | Revisions | HTS/origin/revision cells |
|---|---:|---:|---:|---:|
| Complete audit universe | 20,109 | 240 | 55 | 261,167,040 |
| Revised Section 232 note 16 candidate scope | 1,992 | 240 | 17 | 8,078,640 |
| Note 16(c)(xi), conditional U.S.-metal discrepancy scope | 93 | 240 | 12 | 264,720 |
| Forced-labor action universe, before exemptions | up to 19,926 per revision | 86 | 9 | 15,422,724 |
| Common product exemption closed by this change, ordinary-entry path | 1,554 | 86 | 9 | 1,202,796 |

The cells sum each revision's valid product inventory; multiplying the union
of all historical codes by the number of revisions would overcount. Dates
inside each revision can contain multiple legal intervals. The 93-code issue
requires actual U.S.-metal qualification; its actual shipment prevalence is
unknown. The note 16 counts exclude pre-April metals and other Section 232
sectors. Complete-total qualification remains broader than these individual
branches because every required authority inventory must be reconciled.

`scripts/audit_shipment_gap_impact.py` reproduces the source-scope census without
calculating rates. Exact per-revision counts and source hashes are retained in
`impact/summary.json.gz`.

## Fresh read-only MotherDuck observations

The existing table has **267,714,240 rows**, 20,605 distinct codes including
special chapters, 240 origins and 55 revisions. The ordinary-code portion is
**261,167,040 rows and 20,109 distinct HTS10 codes**, matching the native-source
universe. This is not verification of the amounts.

There are **1,191,087 positive legacy forced-labor statutory parameters** on the
source's common product exemptions in the relevant origin/revision scope. The
ordinary-entry component should be exempt. FTZ classification history and
other duties must still be evaluated; this count does not certify full totals.
Separately, 2,192,070 stored rows have positive Section 232 and forced-labor
statutory columns. That is a review population, not a proven error count.

The current raw date filter is also ambiguous:

| Entry date | Matched rows | Unique HTS/origin pairs | Surplus revision matches |
|---|---:|---:|---:|
| 2026-09-30 | 9,802,560 | 4,901,280 | 4,901,280 |
| 2026-10-10 | 14,703,840 | 4,901,280 | 9,802,560 |
| 2026-10-22 | 14,703,840 | 4,901,280 | 9,802,560 |

The legacy final intervals for revisions 19, 20 and 21 overlap. These counts
cover special and ordinary codes. A plain HTS/origin/date filter cannot select
one validated shipment release. Rebuilding correct intervals and preparing a
mutually consistent, versioned release remain required; choosing an arbitrary
maximum rate or mixing revision rows is not a correction. The existing strict
release path and source-selection bounds are separate from the old live table.
The observed live intervals were not modified.

The exact SQL, public scope parameters, database identity and result rows are
retained under `motherduck/`. Connections and transactions used `READ_ONLY`.

## Closed executable path

The original [USTR final action](https://www.govinfo.gov/content/pkg/FR-2026-07-28/html/2026-15181.htm),
Annex I A(2), note 52(b), contains **863 scope entries: 856 HTS8 and seven exact
HTS10 entries**. Both printed HTS10 forms are preserved. The compiler never
widens a ten-digit entry to its parent, drops it, or substitutes a global CSV.

The original machine-readable USTR table agrees with every operative native
note 52(b) table and condition in the nine revisions. An unexpected scope or
condition amendment stops compilation. Independent OCR of the four published
image-table pages yields 862 exact matches; visual review confirms one OCR
misread, `8101.97.00`. All four pages were visually inspected. The audit-only
reconciliation records the original image hashes; production never uses an
OCR repair or a hardcoded example correction.

The source-backed zero component reports `9903.05.86`. It suppresses the
remaining forced-labor question and Section 232-derived alternative for that
same action, without removing another duty program. The actual computer
regression now demonstrates its own product exemption even when it is not an
automobile part. Actual hose-part cases retain the independent Section 232
interaction. Ordinary entry must be established; FTZ status/classification
questions remain explicit. Unsupported claims remain unpriced.

Fourteen real-source regressions cover exact/adjacent ten-digit children,
eight-digit descendants, different origins, the first legal minute and FTZ
questions. Existing controlled interaction and actual automobile composition
suites pass. A real computer point traverses ordinary Parquet emission,
normalized relationships, R/TypeScript, local DuckDB and JSON/Arrow/batch; its
forced-labor component is sourced zero and its complete total remains NULL.
Modeling inputs cannot change it.

## Verification and remaining work

The checkpoint passes 462 Python and 848 individual Node tests, the 14 new
common-product cases, 50 existing interaction cases and 10 actual automobile
composition cases. The all-55 source census has no conflicts. Evidence,
commands/logs and current source hashes are indexed in `verification.json` and
`evidence-inventory.json`. The full R gate remains unqualified; missing/stale
normalized artifacts and absent TPC input cannot be treated as passing tests.

The remaining work includes the actual note 16 U.S.-metal disagreement,
remaining Section 232 sectors/claims and FTZ paths, forced-labor conditional and
country annexes/caps/claims, Brazil, the other authority interactions, AD/CVD,
complete inventory attestations and serving consumers. A fresh CBP bulletin
has been found for the U.S.-metal investigation; it is not assumed to amend a
conflicting legal instrument.

No branch was pushed, no data/release published, no MotherDuck mutation or
activation performed, and no weekday workflow changed. WJR retains the manual
revision rebuild and approval of production release preparation/activation.
