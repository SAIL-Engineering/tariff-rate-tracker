# Vehicle parts: source decisions, optional elections and historical stacking

This checkpoint implements original listed MHD parts and importer-certified
vehicle parts in the ordinary normalized/Parquet build. It does **not** certify
all Section232 actions, the overall shipment plan or final timeseries readiness.
Implementation base: `13e1919c758f88d6b049e7d8e7d59a5a047cdec6` on local `wjr_dev`.
No production database or active release was changed. Full revision and timeseries
rebuilds remain WJR's manual step after the remaining executable logic is ready.

## Corrected decisions

- Original note38(i)'s 182 mixed HTS8/HTS10 provisions retain their precision.
  Actual MHD-part use, individual USMCA eligibility and knock-down-kit treatment
  select the charged, exempt or non-part reporting role. A statistical-code
  association alone does not select the duty.
- Original note38(j) and note33(p)/(q)/(r) allow additional parts through an
  importer-certified U.S. production/repair election. The original exclusion of
  chapters72/73/76 and of already-listed auto/MHD parts is applied from source
  inventories. There is no economic-sector winner or maximum-rate selection.
- Certification is an explicit optional claim. Ordinary unclaimed entries do
  not need certification answers. A requested election requires the actual IOR
  certification and relevant part/use facts; a declaration alone is insufficient.
  Actual passenger vehicles cannot also use the optional part path.
- Country treatment reuses the source-bound automobile calculator: UK vehicle-use
  condition and combined rate; EU/Japan/Korea/Taiwan native General or applicable
  Special benchmark and actual reporting roles. Korean certified-part treatment
  retains its original November1 retroactivity and Taiwan its May1 amendment.
- The stacking decision uses applicability. Qualifying individual USMCA parts
  remain subject to the action even when its payable amount is zero. MHD parts
  do not erase the separate China drug-emergency action.
- Original metal exclusions are replaced on April6, April23 and June8 at their
  legal instants, independently of the publication date of an HTS revision.
  April23's published **Eastern standard time** is preserved literally.
- The original November annex also adds certified auto-part headings to the
  reciprocal-IEEPA exclusion. Its paragraph13 was absent from the prior
  executable interaction inventory. Korean certified reporting roles likewise
  come from the original country amendment, including a zero-additional role.
- A reporting-only copper remainder is no longer mistaken for an unknown232
  duty in Section122's unlisted-action guard. Source-identified non-part and
  vintage reporting roles are likewise distinct. Literal zero-payable covered
  actions retain their applicability; this is not a general zero-rate filter.
- Previously, automobile extraction checked the part-code list but discarded
  changes to its qualifying introduction. The complete ordinary/offset
  qualification and source-named country references now reconcile too. Extra
  prose, new reporting references, changed rates or disappearing operative MHD
  headings require new source reconciliation rather than an old-rate/zero fallback.

All numeric rates, code membership and legal dates come from retained primary
instruments/native tables. Regression examples do not appear as production
product patches. Aggregate economic calculations keep their own methodology;
shipment rules contain no modeled utilization shares or assembly credits.

## Primary evidence

- [Proclamation10984, original PDF](https://www.govinfo.gov/content/pkg/FR-2025-10-22/pdf/2025-19639.pdf):
  clauses1,3,9,12; AnnexI A(1)/(2), note38(h)-(l), pp48461-48464;
  note33(p)/(q)/(r), pp48470-48474; paragraph13, p48475.
- [Original automobile offset process](https://www.govinfo.gov/content/pkg/FR-2025-06-13/html/2025-10740.htm)
  and [MHD extension/replacement process](https://www.govinfo.gov/content/pkg/FR-2026-05-15/html/2026-09782.htm):
  actual Commerce/CBP approvals, named importer allocations, entry application
  and retroactive HTS introductions. A projected manufacturer accrual is not an
  entry's approved credit.
- [CBP automobile FAQ](https://www.cbp.gov/trade/programs-administration/entry-summary/section-232-additional-faqs-autos)
  and [MHD FAQ](https://www.cbp.gov/trade/programs-administration/entry-summary/section-232-additional-faqs-mhdv)
  independently confirm that USMCA individual-part relief includes certified parts.
  These current interpretive pages are not used to invent amendment dates.
- [April original annex](https://www.govinfo.gov/content/pkg/FR-2026-04-09/pdf/2026-06960.pdf),
  AnnexIV A(8)(b), pp18264-18265;
  [April23 amendment](https://www.govinfo.gov/content/pkg/FR-2026-04-23/html/2026-07987.htm), paragraph8;
  [June original annex](https://www.govinfo.gov/content/pkg/FR-2026-06-04/pdf/2026-11314.pdf),
  AnnexIV A, p34139. The separate January2028 section is outside this audit.

Exact source bytes/hashes, reviewed transcriptions and country source references
are retained in `resources/legal_evidence/section232/vehicle-parts/`,
`section232/autos/review.json`, and the existing April/June evidence manifests.
The full original PDFs were retained before this checkpoint. Reviewed scanned
annex portions were read against rendered original pages, not accepted from OCR
code membership alone.

## Coverage and serving

The source census reconciles all55 configured 2025/2026 snapshots through the
October22 cutoff, with native MHD provisions in29. It retains240 origins,
240-241 listed MHD candidate HTS10s per snapshot and18,115-18,323 potential optional
certification candidates. These are **conditional discovery memberships**, not
counts of errors or a determination that all such products are vehicle parts.
The optional claim's operative window starts November1,2025; earlier source
frames do not charge it.

The normal emitter writes `section232_mhd_parts_rules.json`, the extended
automobile fragment, source candidates and versioned executable decisions.
The usual shipment bundle, wide projection, release and API paths consume them.
Incomplete statutory scalars remain NULL; `modeled_legacy_*` retains the separate
legacy-model values. New optional elections do not change stored historical
saved-result versions or activate a production release.

The read-only MotherDuck comparison uses the central configured tariff catalog
and an explicit read-only transaction. Twelve stored points cover a listed hose
and a wire candidate, three origins and two entry dates. The sampled wire rows
have statutory232=0 and the old table lacks the required shipment version,
status and decision-reference columns. The samples cannot represent the ordinary
copper-content path, a valid certified MHD25percent path or its conditional
USMCA zero-payable alternative. They are not twelve independently proven complete
shipment totals: use, content, certification and other authorities remain relevant.

## Remaining work and release conditions

Known implementation work remains: other Section232 sectors/vehicle paths and
complete negative applicability; approved importer-offset allocation; Chapter98
entitlement/valuation beyond the express full-value exception; privileged-FTZ
historical classification/rate selection; remaining cross-program interactions,
consumer/release integration and final data qualification. The new offset notices
supply law for further implementation. Their existence does not supply a private
importer's approved account balance. Missing law implementation and missing
shipment evidence remain distinct.

The source census and targeted calculations do not replace the all-revision
manual rebuild or exhaustive normalized/wide parity. The old normalized tree
still fails the required-artifact gate, and the TPC input is absent. No complete
R-gate, full-history, production MotherDuck deployment or competitor qualification
claim is made here.

Rollback before deployment is a local revert of this checkpoint; no MotherDuck
rollback is necessary because no data was activated. A later approved deployment
must prepare and validate a versioned complete release, retain the previous active
release, and switch only after its serving-path smoke test.

## Recorded verification

- All55 source snapshots reconciled; source membership receipt retained in `source-census.json.gz`.
- 486 Python tests and1,139 Node tests passed; no Node failures or skips.
- 66 source-bound vehicle-part R/TypeScript cases,62 automotive R cases and10
  automobile/forced-labor composition cases passed. Other affected R suites,
  reporting-only versus zero-payable checks and semiconductor composition passed.
- Two ordinary Parquet cells produced six passing API scenarios across JSON,
  Arrow and batch delivery, version invalidation and tamper rejection.
- Tracker frontend TypeScript and Vite production build passed. The shared SAIL
  interpreter hash matches the tracker's generated copy; no SAIL checkout changes
  were required for these data-defined rules.
- Twelve MotherDuck observations used read-only access.
- The full normalized preflight still fails with791 missing/stale required
  artifacts before parity; the TPC input remains absent.

`verification/summary.json` and its linked logs distinguish these checks from
complete-history or live-release qualification. A fixture initially omitted an
ordinary scenario's no-certification fact; that scenario was corrected and its
suite rerun. Cross-language verification also caught single-element claim arrays
being unboxed by the test helper. The generator now preserves arrays; liability
expectations were not changed to obtain a pass.
