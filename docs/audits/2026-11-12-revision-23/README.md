# Revision 23 source acquisition and horizon extension

Acquired November 12, 2026. The official USITC release list identifies
`2026HTSRev23` as current with `releaseStartDate=11/10/2026`. The JSON placed by
the 2026-11-11 nightly was re-exported from the current release and is
byte-identical. Chapter 99 was downloaded revision-bound; its header reads
Revision 23 (2026). Hashes and URLs are in `source-manifest.json`.

| Source | Local location |
| --- | --- |
| Current JSON, 35,805 rows | `data/hts_archives/hts_2026_rev_23.json` |
| Chapter 99 PDF | `data/us_notes/chapter99_2026_rev_23.pdf` |
| General Notes 3 and 4 | `data/cache/general_notes/GN3_2026HTSRev23.pdf`, `GN4_2026HTSRev23.pdf` |
| Change Record PDF and text | This directory |
| USTR notices 2026-22925, 2026-22867 | `resources/legal_evidence/2026-22925/`, `2026-22867/` |

## What changed

The [Change Record](https://hts.usitc.gov/reststop/file?release=2026HTSRev23&filename=Change%20Record)
lists seven items, all in Chapter 99 and all by USTR notice. The JSON row diff
against Revision 22 is exactly those seven rows (`json-row-diff.json`).

| Headings | Change | Source |
| --- | --- | --- |
| 9903.88.69, 9903.88.70 | The 178 Section 301 China exclusions run "through January 9, 2027" instead of November 9, 2026 | [FR 2026-22925](https://www.govinfo.gov/content/pkg/FR-2026-11-10/html/2026-22925.htm), 91 FR 72610, Annexes A and B: from 12:01 a.m. eastern time 2026-11-10 to before 11:59 p.m. eastern time 2027-01-09 |
| 9903.91.12 to 9903.91.16 | The maritime duties (+100% on intermodal chassis and ship-to-shore gantry cranes) begin January 10, 2027 instead of November 10, 2026 | [FR 2026-22867](https://www.govinfo.gov/content/pkg/FR-2026-11-10/html/2026-22867.htm), 91 FR 72608, effective 2026-11-09: action further suspended until 2027-01-10 |

`policy_effective_date` is 2026-11-10. The maritime deferral takes effect the
day before the date it defers and the exclusions ran through November 9, so the
law in force on November 9 is the same under both revisions.

## Implementation

- **Exclusions.** `src/section301_sources.py` adds FR 2026-22925 as the fifth
  extension window. Its annexes print plain "eastern time", not standard or
  daylight time; the window parser now reads that as New York local time, so the
  printed and calendar instants agree. The two-minute gap between the previous
  window (before 11:59 p.m. November 9) and this one (from 12:01 a.m. November 10)
  stays an unresolved boundary, as the earlier gaps do.
- **Maritime.** No code change. Maritime headings dated after the Section 301
  extractor's own `audit_cutoff` (2026-10-22) are classed
  `future_beyond_audit_cutoff`; Revision 23's January 10, 2027 start is in that
  class, as Revision 22's November 10 start was. That literal is deliberately not
  tied to `audit_until`: doing so would try to compile Revision 22's November 10
  heading against the 2025 suspension notice and stop.
- **Horizon.** `audit_until` moves to `2026-11-12T00:00:00-05:00`, the date of
  this review (`federal-register-review.json`). The Section 232 automobile review
  carries its cutoff to the same instant with a recorded no-new-instrument window.
- **Heading 9903.01.63.** The Revision 22 forward requirement is resolved in
  `heading-9903-01-63-resolution.json`: no continuation was published, so the
  suspension lapses at 2026-11-10T00:01:00-05:00, with no effect on consumption
  entries because collection ended 2026-02-24.
- **Registration.** `2026_rev_23` carries the curated event, family
  `section_301_china_or_dst` and commentary in `config/revision_dates.csv` and
  the USITC archive map; `revision_sources.json` is regenerated from the map. The
  General Note, provision-status and staged-rate tables carry Revision 23 rows,
  identical in substance to Revision 22's. The rebuild inventory goes to 57.

## Building it

Revision 22 must be rebuilt with Revision 23. It was built as the last revision,
so its legal states run to the series horizon (2026-12-31); with Revision 23
registered it ends 2026-11-09, and the combine refuses a snapshot whose states do
not tile that interval.

```bash
Rscript src/00_build_timeseries.R --start-from 2026_rev_21 --motherduck-only
node frontend/scripts/push-to-motherduck.mjs --only-revisions 2026_rev_22,2026_rev_23
```

The push must include Revision 22, whose `valid_until` changes.

## Limits

Federal Register coverage only; CBP CSMS guidance is not indexed. AD/CVD
notices remain the declared `unresolved_source` slot. No timeseries build,
MotherDuck write or deployment was performed in preparing this receipt.
