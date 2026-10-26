# July reciprocal suspension and UK aircraft/metal decisions

Local tracker follow-up to `67d5fb77`, `wjr_dev`. No timeseries/revision build,
MotherDuck write, activation, push, deployment or workflow change occurred.

The original [EO 14316 sections 1–2](https://www.whitehouse.gov/presidential-actions/2025/07/extending-the-modification-of-the-reciprocal-tariff-rates/)
suspends the enumerated non-China country headings from July 9 through August 1
at 00:01 EDT and expressly leaves the separate China suspension unchanged.
Extraction reconciles the suspended ranges against the original country-heading
inventory. China's original 90-day suspension has its own August 12 endpoint;
a non-China extension cannot silently carry China beyond that separate window.

[Commerce 2025-12060 Annex I C](https://www.govinfo.gov/content/pkg/FR-2025-06-30/html/2025-12060.htm)
creates UK civil-aircraft relief from June 30 00:01 Eastern. The compiler extracts
its 565 distinct eight-digit product references, General Note 6 condition,
reporting heading `9903.96.01`, and the specific additional duties it removes.
The printed heading's blank date is resolved by the independent operative
introduction; it is not predicted from a later snapshot. Proper Chapter 98
classification is considered where the original list enumerates those provisions.

The exemption enters the same rule graph as the named Section 232 duties.
Qualifying aircraft treatment suppresses those duties and reciprocal liability;
unlisted products and other origins retain their own decisions. Actual content
values are still required when pricing non-exempt metal/nonmetal portions.
Neither modeled shares nor assembly credits enter this calculation.

The fragment's legal horizon now ends **exclusively at August 1, 2025, 00:01 EDT**.
The subsequent copper/country policy needs additional source-backed rules. This
boundary is not an expiration or zero-duty determination. FTZ/de minimis histories,
complete authority coverage and other remaining interactions are still unresolved.
Normal builds automatically emit these revised fragments and inventory links;
automatic production-bundle assembly and full shipment-derived wide output remain
separate work. Aggregate methodology was not changed by this follow-up.

Verification retained here:

- **387 Python tests pass**, including source enumeration, July extension and the
  separate China-window guard.
- **87 R conformance cases pass**, including the exact instant before/at June 30,
  July 9 suspension, China, non-UK and unlisted controls, and the next August boundary.
- **517 Node tests pass**, including those shared R/TypeScript fixtures and the
  existing local JSON/batch/Arrow serving checks.
- All **55 configured revisions** pass the source-only compiler sweep. This is
  not an exhaustive priced HTS/origin/fact grid or a timeseries build.
- The fresh full R gate finished with **44 of 46 suites passing**. Normalized
  parity stopped on **685 missing/stale artifacts**, and TPC could not run without
  `data/tpc/tariff_by_flow_day.csv`. Its counted-case subtotal of 427 passing cases
  is not a successful full-data gate. The retained full log records both blockers.

For a real-source UK `7304.31.3000` entry on July 10 with $100 customs value and
$20 steel value, the Section 232/reciprocal **known subtotal** is $13 without
qualifying aircraft treatment and $0 with it. A French control remains $18 under
the same content assumptions. Base and other-authority coverage are deliberately
not certified, so complete totals remain null. These examples test the generic
source-derived rules; their HTS/origin/date values do not control production code.

A new READ_ONLY MotherDuck transaction retrieved 165 rows across three
product/origin pairs and 55 production revisions. France July 10 and China July
20 still return reciprocal component 0% instead of 10%. The ordinary UK steel
parameter (25%) and reporting heading (`9903.81.94`) match the original proclamation
and operative HTS sources. That nominal parameter does not determine an amount
for content-sensitive or qualifying aircraft shipments. No complete live stack
is certified by these component checks.

The retained manifest hashes refer to uncompressed case JSON; stored rows are
compressed as `motherduck-cases.json.gz`. Sources and their hashes, query text,
assumptions and findings accompany the report. Earlier source-discovery queries
are not the verified audit retained here.

Rebuild commands remain in [the manual runbook](../../shipment-duty-manual-rebuild.md).
Use the corrected definitions in the final complete release rather than activating
these fragments independently. Keep the prior validated release for rollback.
