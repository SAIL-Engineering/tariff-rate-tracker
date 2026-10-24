# Executable IEEPA emergency decisions and vehicle stacking

Base: `694f4b33675e225e26ba1ad8b783ee78bacef548`, local `wjr_dev`.
No timeseries rebuild, production write, publication, deployment or push.

## Delivered behavior

`src/ieepa_emergency_rules.py` compiles the extracted Mexico, Canada, China and
Hong Kong drug-emergency actions to the existing R/TypeScript expression
contract. The normal normalized emitter writes `ieepa_emergency_rules.json`.
Rates and reporting headings come from the revision's source and the retained
original amendments, never example HTS corrections, maximum-rate selection,
modeled utilization or credits. The compiler verifies source hashes and rejects
unreviewed heading/note conditions. The reviewed manifest contains 78 distinct
source-condition combinations, not a list of product overrides.

Decisions include ordinary duties, energy and potash carveouts, actual GN11
USMCA claims, humanitarian donations, informational materials, personal baggage,
the separate China transit loading and entry conditions, Canadian CBP evasion
findings, and Chapter 98. Evasion requires both the CBP determination and lack
of USMCA originating status; it replaces the named ordinary/carveout duty.
Qualifying as originating and claiming free entry are distinct inputs.

The source's geographic restriction on Chapter 98 repairs/processing/assembly
is preserved. The compiler requires the actual provision, proper claim and CBP
agreement, bounded values, and operations in the covered origin. A conflicting
origin or mixed-country operation remains unresolved. These rules neither
establish Chapter 98 entitlement nor infer it from the ordinary classification.

The compiler splits exact timestamps within revision intervals. It retains the
old China rate through the first minute of November 10 and the old Canada rate
through the first minute of August 1. March 7 relief and the transit deadline
also retain their minute boundaries. Original March 7 insertions are parsed
independently instead of copying an unrelated future snapshot's exceptions.

## Newly resolved Section 232 interaction

[Proclamation 10984, clauses 1, 8 and 9](https://www.govinfo.gov/content/pkg/FR-2025-10-22/html/2025-19639.htm)
defines the November 1, 2025 00:01 Eastern transition. Clause 9 retains automobile
and medium/heavy vehicle action applicability where USMCA, an offset or a trade
agreement reduces the payable duty to zero. Clause 8 identifies the effective
date by reference to clause 1. Original Annex I.A independently states the
entry instant for its HTS changes. The retained PDF's annex is image-based;
page 9 OCR is retained as corroborating evidence, with its OCR typo in the day
left visible rather than used as an executable date. Visual inspection of the
retained PDF page confirms November 1, 2025; the executable parser uses the
proclamation's text clauses.

The historical metal compiler previously continued using CBP's earlier
positive-payable test after this amendment. `src/section232_stacking.py` now
supplies the dated decision to both metal and emergency compilers. It derives
reporting identities from actual note 33/38 heading records. It does not infer
that every zero heading qualifies: note 33(c) mixes U.S. content and
non-automobiles, and note 33(h) mixes qualifying USMCA parts and non-automotive
parts. Those mixed decisions require the relevant shipment predicate. The
25-year vehicle exception and non-MHD-part heading are not promoted into
stacking exemptions. The first minute of November 1 retains the earlier test.

[Proclamation 10976, clauses 5 and 6](https://www.govinfo.gov/content/pkg/FR-2025-10-06/html/2025-19482.htm)
also supplies the timber priority from October 14 at 00:01 Eastern. This is
applied to the named Canadian/Mexican emergency actions, including potash,
rather than only the abbreviated ordinary heading references in later notes.
The Canadian evasion note independently lists the wood exceptions. China/Hong
Kong emergency duties are not given that Canada/Mexico exemption.

The existing June metal/emergency priority change is exercised with both
compilers. A May USMCA claim can revive metal liability, while June metal
liability can suppress the ordinary emergency charge. Zero metal liability does
not automatically suppress the emergency charge. Missing Section 232 coverage
blocks an asserted emergency known subtotal. Named Section 301 exclusion claims
remain independent; verified Commerce grants permit dependency reevaluation.

## Serving path repair

Release preflight previously counted only `role=exclusion` claim rows. It would
reject the source-backed Chapter 98 valuation rows introduced by the preceding
commit. Preflight now reconciles both inventories, including the cross-origin
maritime NULL-country scope, formulas, input constraints, verification state,
source locator/hash and exact windows. Changed or missing valuation data fails
preflight before release loading. This completes that consistency check within
the existing release-v6 schema; it does not activate a release.

The existing JSON, batch and Arrow routes are exercised against local DuckDB
using the R-generated emergency bundle. They preserve amounts, missing facts,
source errors, components and dataset identity. No interpreter copy, legal
constant or production UI change was introduced.

## Read-only MotherDuck audit

The existing read-only script inspected `duty_calculator`, verified the catalog,
and ran under a read-only transaction. The retained compressed export has raw
SHA256 `0121946474594a95be6a52eb1ec3917ebc15d84fb1126ca2ff23f22a429bb214`.
It contains 562 emergency parameter groups and all 55 stored revision intervals.
The independent source audit reports:

| Candidate finding | Stored groups | Sum of group row counts |
| --- | ---: | ---: |
| Ordinary parameter with missing/different reporting heading | 66 | 608,713 |
| Conditional Canadian 40% parameter in the ordinary field | 40 | 385,293 |
| Ordinary rate inconsistent with the source interval | 2 | 39,490 |

These are parameter/provenance candidates, not complete shipment totals,
unique imports or monetary exposure. Row counts span multiple stored revisions.
Some heading gaps accompany modeled zero rates; that does not supply an ordinary
statutory reporting decision. The audit export and its reconciliation are in
`motherduck-readonly.json.gz` and `motherduck-source-audit/`.

## Verification and remaining work

See `verification.json` for commands, exit codes and retained log hashes.
Final Python and Node suites passed 351 and 428 tests; typecheck and build passed.
The emergency fixture passed 48 R/TypeScript cases, including composition with
the separately emitted evidence fragment. The full R gate exited 1: 40 of 42
suites passed, normalized parity reported 312 missing/stale partitions, and the
TPC comparison lacked `data/tpc/tariff_by_flow_day.csv`. Its summary's 402 counted
assertions does not turn that gate into a pass. After the full R run, the final
FTZ guard refinement and three additional cases were checked by rerunning the
affected R suite, all Python/Node tests and the all-revision compiler sweep.

The all-revision compiler sweep builds 1,094 rules against the full ordinary
HTS10 inventory in each of 55 revisions: 1,082,971 revision/product memberships.
It is a source/compiler coverage sweep, not every possible shipment-fact
combination or an all-authority completeness attestation.

The broader plan remains incomplete. In particular:

- Reciprocal and other country-specific IEEPA actions are not supplied by this
  drug-emergency compiler. Remaining vehicle/sector scopes and claims require
  source-backed fragments; the stacking adapter does not establish their scope.
- FTZ admission status, admission classification, processing and historical rate
  selection remain explicit unresolved paths. De minimis transport/chronology
  also remains unresolved. Neither becomes zero by default. The FTZ guard runs
  before ordinary-entry exemptions and USMCA/Chapter 98 claims, preventing those
  claims from bypassing the missing historical admission decision.
- The legacy wide aggregate adapter still uses its positive-rate approximation.
  Replacing it requires separately emitted action-applicability modeling inputs;
  a modeled share or zero amount cannot substitute for shipment applicability.
  This work changes executable shipment decisions, not the aggregate methodology.
- All-program coverage, additional Section 301 investigations/interactions,
  Section 122/338 FTZ paths, AD/CVD and remaining consumers still need work.
- Composition with a reviewed base bundle and all required authority fragments,
  rebuilt normalized partitions, the actual TPC input and later approved live
  MotherDuck qualification are still required. No full release is certified.

The regression cases intentionally retain `complete_total=null` because their
other-authority inventories are synthetic or incomplete. The new rules are
ready for review and composition, not a declaration that the entire requested
plan or production dataset is complete.

## Reproduction and rollback

Run source-only checks independently of a timeseries rebuild:

```sh
python3 scripts/audit_ieepa_executable.py NEW_EXECUTABLE_AUDIT_DIR
node frontend/scripts/audit-ieepa-emergency-motherduck.mjs .env NEW_MD_EXPORT.json
Rscript scripts/audit_ieepa_emergency.R NEW_SOURCE_AUDIT_DIR NEW_MD_EXPORT.json
Rscript tests/test_ieepa_emergency_rules.R
Rscript tests/test_s232_legacy_rules.R
node --test frontend/tests/shipment-ieepa-emergency.test.mjs frontend/tests/shipment-release.test.mjs
```

WJR retains the timeseries rebuild described in
[the manual runbook](../../shipment-duty-manual-rebuild.md). Existing production
MotherDuck remains unchanged. Local code rollback is a revert of this follow-up
commit; do not replace active data or historical saved results. A future release
must use new dataset identity and retain the previous active release for rollback.
