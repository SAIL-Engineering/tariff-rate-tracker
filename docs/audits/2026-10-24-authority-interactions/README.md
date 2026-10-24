# Taiwan reconciliation and historical cross-program decisions

Tracker base: `6f6a9bccde4a6060c790297e7b8f6cc8ab2c2724`, branch `wjr_dev`.
All implementation is in the original tracker checkout. SAIL and Trade
Intelligence are unchanged in this pass. No timeseries/revision rebuild, live
MotherDuck write, active-release change, push, workflow dispatch or deployment.
The MotherDuck investigation below used the existing read-only audit script.

## Resolved decisions

### Taiwan Section 122 interaction

The published `903.94.67` in the Taiwan notice is retained verbatim. It is neither
executed as a reporting identifier nor automatically repaired. There is an
independent operative basis for the interaction:

- [Proclamation 11012, paragraph 4](https://www.govinfo.gov/content/pkg/FR-2026-02-25/html/2026-03824.htm)
  excludes the part subject to Section 232; the proclamation also contemplates
  later Section 232 actions.
- [Taiwan implementation notice, Annex paragraphs 1 and 3](https://www.govinfo.gov/content/pkg/FR-2026-05-28/html/2026-10571.htm)
  independently establish note 33(u) and the valid `.94.66`–`.94.69` auto-parts
  heading inventory. Paragraph 3 supplies the actual duty table. The original
  entry instant is **May 1, 2026, 00:01 Eastern daylight time**, despite the later
  publication date. Paragraph 6 contains the malformed Section 122 reference.

The legal reconciliation is that these independently established full-article
Section 232 decisions fall under paragraph 4's exclusion. The compiler parses
and reconciles the two substantive heading inventories, bounds the decision to
Taiwan and the original entry instant, and retains provenance for this reasoning.
It does not claim an official correction to the printed annex. An unrelated
origin, an unknown heading, an unverified action, or a premature entry cannot use
this determination. Chapter 98 and FTZ branches remain separate unresolved paths.

The result is a resolved **interaction**, conditional on a defensible underlying
Section 232 rule. It does not by itself compile all Taiwan auto-parts scope,
import-adjustment offsets, or claim valuation. Other malformed Taiwan references,
including the notice's paragraph 13(b), must not be silently repaired by future
sector compilers.

### Ordinary Canadian/Mexican IEEPA versus metals

The legacy metal compiler previously suppressed only `.01.01` and `.01.10` after
June 4. It now derives the complete ordinary/carveout action inventory from each
revision's source-bound IEEPA extraction, including energy and potash. No example
HTS code, maximum rate, or heading-number range selects these actions.

[Proclamation 10947, paragraph 5](https://www.govinfo.gov/content/pkg/FR-2025-06-09/html/2025-10524.htm)
changes EO 14289 priority at **June 4, 2025, 00:01 Eastern daylight time**. The
preceding minute keeps the preceding ordering. The applicable test remains
positive duty for this particular ordering, as described in
[CBP's EO 14289 implementation](https://www.govinfo.gov/content/pkg/FR-2025-05-20/html/2025-09066.htm)
and retained CSMS 65054270; it is not substituted for Section 122's portion rule.
Zero metal liability cannot suppress an otherwise owed emergency charge. Claims
that remove a higher-priority charge cause reevaluation. The source-confirmed
Russian-aluminum action remains included.

[EO 14325, sections 2(d) and 3](https://www.govinfo.gov/content/pkg/FR-2025-08-06/html/2025-14999.htm)
distinguishes the ordinary Canadian rate amendment from the separate CBP-determined
anti-evasion charge. The latter does not automatically inherit ordinary tariff
exemptions; section 3 retains other applicable duties. Its full eligibility,
replacement and subsequent exceptions still require separate executable rules.
China's emergency duty and Section 301 remain independent of this ordinary
Canada/Mexico ordering. Regression fixtures test those separations.

### Emergency commencement, transit and termination

Four published USMCA/potash headings previously had no extracted commencement.
The extractor now reconciles actual new-heading insertions and their heading
rows with the original presidential amendments:

- Canada: [EO 14231 section 2](https://www.govinfo.gov/content/pkg/FR-2025-03-11/html/2025-03990.htm)
  and [CBP notice, Annex paragraph 6](https://www.govinfo.gov/content/pkg/FR-2025-03-11/html/2025-03901.htm).
- Mexico: [EO 14232 section 2](https://www.govinfo.gov/content/pkg/FR-2025-03-11/html/2025-03991.htm)
  and [CBP notice, Annex paragraph 5](https://www.govinfo.gov/content/pkg/FR-2025-03-11/html/2025-03900.htm).

These headings begin **March 7, 2025, 00:01 Eastern standard time**, not the
publication date or the earlier ordinary-tariff commencement. Canada's malformed
paragraph 1 replacement operands are preserved in the source but are not used
to infer the valid inserted heading inventory.

China's transit exemption previously had no extracted end. Its numbered entry
condition supplies **March 7, 2025, 00:01 Eastern standard time**. The separate
February 1 loading/final-transport condition is preserved; it is not mistaken for
an entry cutoff. Source: [original CBP notice, heading .01.23](https://www.govinfo.gov/content/pkg/FR-2025-02-05/html/2025-02293.htm).
This preserves the source's alternatives; it does not compile all transit facts.

All retained emergency headings now have closed collection windows based on
[EO 14389](https://www.govinfo.gov/content/pkg/FR-2026-02-25/html/2026-03832.htm)
and [CBP CSMS 67834313](https://content.govdelivery.com/accounts/USDHSCBP/bulletins/40b11c9):
**February 24, 2026, 00:00 Eastern standard time**. This is midnight, distinct from
Section 122's 00:01 start. Earlier individual expiry dates are retained. The R
selector rejects missing windows and permits an empty post-termination selection
only with termination evidence, rather than treating an absent row as zero.
This models collection at entry; it makes no liquidation or refund determination.

## Fresh MotherDuck findings

The read-only query ran against `duty_calculator` from 2026-10-24 04:20:04Z through
04:20:25Z. It checked the configured catalog, opened a read-only transaction and
rolled it back. The export hash is
`03047fa40a51d67c7201a28c06cb292c6847dd6af807b80bde466a8ecb3a701b`.
The retained export is `motherduck-read-only.json.gz`; source-backed comparisons
are in `motherduck-reconciliation.json`.

| Candidate discrepancy | Groups | Stored rows represented |
|---|---:|---:|
| Ordinary reporting heading differs/missing | 66 | 608,713 |
| Conditional Canadian anti-evasion rate used as ordinary parameter | 40 | 385,293 |
| Ordinary rate chronology mismatch | 2 | 39,490 |

The two chronology groups are China and Hong Kong on November 9, 2025: stored
10% with `.01.20`, versus the source's ordinary 20% `.01.24` before the November
10 amendment. That source chronology was already corrected locally in earlier
work and remains absent from the live release.

The export contains 562 grouped emergency records, 54 Section 122 precision
groups and interval coverage for 55 revisions. These are stored parameter/heading
findings, not a count of proven incorrect final shipment totals or monetary
exposure. A raw statutory field may precede cross-program suppression; actual
shipment facts and complete action coverage are still required. No changes to
MotherDuck were made to make the comparison pass.

## Verification and boundaries

See `verification.json` and the retained logs for final commands, exit codes,
counts and hashes. The source sweeps are separate from a timeseries rebuild:

- `emergency-sources/report.json`: all 55 configured sources; every extracted
  action has bounded entry dates, and every retained inventory ceases at the
  independently sourced collection instant. All original notes/conditions remain
  in the compressed extraction artifacts.
- `section122-source-sweep.json`: all 55 revisions, 18 containing Section 122;
  historical windows and Taiwan's independent operative basis are preserved.
- `legacy-metal-sources/summary.json`: all 55 sources, including full HTS10
  inventory compilation over all configured origins for the 34 March-2025 metal
  regimes (26,016 compiled rules). Four pre-March and 17 replacement-note regimes
  are identified separately, not claimed to be validated by this compiler.
- 335 Python tests pass. The final Node suite passes 305 tests, including 43
  Section 122 and 49 historical-metal R/TypeScript fixture cases and local
  in-memory DuckDB → JSON/batch/Arrow serving checks.
- Exact instants, source disagreements, missing dates, unrelated origins,
  unknown reporting decisions, claim reevaluation, zero-dollar branches,
  source order/duplication and modeling-input independence are exercised.

The final full R gate exits 1: **37 suites OK, one ERROR** for 312 missing/stale
normalized partitions, and **one SKIP** for missing
`data/tpc/tariff_by_flow_day.csv`. Its 402 counted passing assertions do not make
the full gate successful. Tracker typecheck and build pass, with existing bundle
size and Browserslist warnings. TPC is an external
aggregate comparison input (its retained notes describe modeling assumptions),
not a legal oracle. Do not fabricate it or weaken the gate to obtain a pass.
The final verification record states the actual full-gate outcome.

This is not complete legal coverage. Still open: full executable IEEPA ordinary,
transit/content/preference and later sector exceptions; complete Section 232
sector/country/offset/claim definitions and disputed quota references; Section
122 Chapter 98/FTZ and other interactions; full executable Section 338 actions;
remaining Section 301 exclusions/interactions; AD/CVD and financial consumers.
A later source's exception text must not be applied retrospectively merely
because its numeric rate history is reconstructed. Complete inventory
attestations, rebuilt parity and production serving qualification remain gates.

## Rebuild, delivery and rollback

The changes use the normal extraction/compiler paths across revisions. They are
not HTS/example overrides. The normalized emitter continues to emit the corrected
entry windows and source artifacts and Section 122/legacy-metal rule fragments.
Aggregate methodology is unchanged; no aggregate difference is quantified because
WJR's timeseries rebuild was not run.

No served contract or interpreter syntax changed in this pass. Existing v1
bundles/results and release v6 remain in use. New compiler/source hashes and a
new dataset version are required for any later release; old generated artifacts
are not thereby qualified. No SAIL or Trade Intelligence code change is needed
for these data/compiler corrections.

Use [the manual rebuild runbook](../../shipment-duty-manual-rebuild.md) after
remaining logic/coverage gates are ready. Restore the actual TPC input before
requiring that comparison gate. Prepare and validate the complete local release
before separately approving MotherDuck synchronization and activation. The
previous active release must remain available for rollback.

Rollback before publication is a local revert of this tracker commit. Nothing
in MotherDuck or the deployed readers changed. Do not replace the active release
with a partially rebuilt set of normalized partitions.
