# Semiconductor action chronology and normal-build delivery

Local tracker follow-up to `9c16504d`, original `wjr_dev` checkout. No full
revision/timeseries build, MotherDuck write, activation, push, deployment or
publication-workflow change occurred.

The original [Proclamation 11002 Annex](https://www.govinfo.gov/content/pkg/FR-2026-01-20/pdf/2026-01052.pdf)
and [CBP CSMS 67400472](https://content.govdelivery.com/accounts/USDHSCBP/bulletins/4047318)
require both precise product scope and actual technical/end-use facts. The
published 25% parameter does not make every shipment in `8471.50`, `8471.80` or
`8473.30` dutiable at 25%. The compiler reuses the reviewed interpreter template,
checks the original technical table against the first native note, and rejects
changed technical, claim, valuation, reporting or stacking grammar.

Four later instruments amend note 39(a). They determine the dated reporting
targets; a later HTS snapshot cannot be applied backwards:

| Effective entry instant | Original operative provision | Result |
|---|---|---|
| January 15, 2026, 00:01 EST | Proclamation 11002 Annex, note 39 | Original semiconductor charge, technical/use exclusions and listed interactions |
| April 6, 00:01 EDT | [Proclamation 11021 Annex IV A(9), p.18265](https://www.govinfo.gov/content/pkg/FR-2026-04-09/pdf/2026-06960.pdf) | Replace old copper/aluminum/steel targets with `.82.02` and `.82.04–.17` |
| April 23, 00:01 **EST** | [2026-07987 Annex paragraph 9](https://www.govinfo.gov/content/pkg/FR-2026-04-23/html/2026-07987.htm) | Extend the listed range through `.82.19`; published fixed EST means 01:01 EDT |
| May 1, 00:01 Eastern | [2026-10571 Annex paragraph 17](https://www.govinfo.gov/content/pkg/FR-2026-05-28/html/2026-10571.htm) | Add Taiwan auto-parts targets `.94.66–.69`, retroactively before publication |
| June 8, 00:01 EDT | [Proclamation 11032 Annex IV A, p.34138](https://www.govinfo.gov/content/pkg/FR-2026-06-04/pdf/2026-11314.pdf) | Extend the metal range through `.82.26` |

The same June Annex IV B reverses the latter change in **2028**, outside this
audit. Its references are not used to determine 2026 liability. Original note
2(x)/(z) amendments independently support the Brazil/India interactions and
remain in each period. Section 301 and other unlisted additional duties remain
independent. An investigation-specific Section 301 exclusion does not remove the
semiconductor duty.

The compiler preserves nine separate technical/use decisions in each of five
periods. It selects neither a maximum rate nor the aggregate's winning product
candidate. Scope remains exact revision-valid HTS10 descendants of the original
HTS6 list. Changing modeled shares, metal shares or assembly credits cannot
change shipment evaluation. Unknown FTZ history prevents both pricing and
unsubstantiated displacement of other duties. USMCA does not waive this charge.
The explicit Chapter 98 full-value exception is executable; other Chapter 98
provision terms remain precisely unresolved before priority is determined.

Normal 2026 builds now emit `section232_semiconductors_rules.json`, retain
source-derived candidates in `authority_product_candidates.parquet`, and link
all dated rules and executable questions into `chapter99_provisions.parquet`.
The bounded two-product build test verifies that conditional statutory fields
remain unavailable. The aggregate calculation is unchanged. Do not compose the
original static January template into a current production release.

The READ_ONLY MotherDuck comparison retrieved **220 rows** across four HTS/origin
pairs and 55 revisions. Twelve dated checks, each with two conditional shipment
fields, found **24 mismatches**: every stored Section 232 statutory rate was 0,
while stored numeric totals ranged from 0% to 35%. Without the required technical,
use and FTZ facts, those values cannot be certified as shipment rates/totals.
This is a conditional-contract defect, not a finding that every shipment owes
25% or that any particular claimed exemption is available. The audit now
distinguishes an explicitly unavailable null from an absent field and from zero.

Verification commands and exact results are retained in `verification.json` and
the accompanying compressed logs. Source-only all-revision reconciliation does
not calculate the exhaustive shipment grid. The API checks use an in-memory
DuckDB release and exercise JSON, batch and Arrow serialization; they do not
qualify a production release or browser deployment.

Broader work remains open: reciprocal executable decisions after August 1,
all-sector/country interactions, complete Chapter 98/FTZ histories, later
Secretary-approved uses, and production bundle assembly. CBP also requires
conditional reciprocal/Brazil/India exemption reporting and prioritizes
`9903.01.33` over Annex II `9903.01.32` for charged `8473.30` goods. The fragment
retains this precise reporting question; its later emergency-action inventory
must be executable before claiming a complete stack. Coverage attestations
remain empty, and complete totals remain null in these partial tests.

The complete manual rebuild remains WJR's task after the remaining logic is
ready; see [the runbook](../../shipment-duty-manual-rebuild.md). Revert this local
follow-up to roll back code; no active database release was changed. A later
approved activation must retain the prior validated release identifier.
