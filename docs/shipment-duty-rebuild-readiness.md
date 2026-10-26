# Shipment-duty rebuild readiness

Initially reviewed against tracker `wjr_dev`, `e3d83219a81f9ab7ee5ef83c7f1af74d5e1d8b70`,
October 25, 2026; inventory and reciprocal-horizon updates are noted below. This is a code-path and retained-evidence audit, not a completed
legal census or a new production-data qualification. No timeseries build ran.

**Continue correcting rules and their build integration before the final full
rebuild.** A diagnostic rebuild can measure selected corrections, but cannot yet
produce verified shipment stacks throughout 2025–2026. Missing generated artifacts
are a consequence of the deferred rebuild; they are not the main reason to wait.

## Confirmed implementation gaps

| Gap | Current evidence | Required correction |
| --- | --- | --- |
| The normal build does not produce a complete evaluated shipment contract | `06_calculate_rates.R` computes wide rates and statutory totals, then calls `07_emit_normalized.R`. The emitter writes separate executable fragments. `scripts/compile_shipment_rules.R` still requires a separately supplied base bundle and fragment list. | Automatically assemble reviewed, revision/event-bound production bundles; construct coverage from an independently reconciled action inventory; emit shipment applicability/decisions alongside the aggregate projections. Never manufacture coverage from the presence of fragments. |
| Competing Section 232 candidates still collapse in the aggregate path | `06_calculate_rates.R:1411–1438` chooses a maximum rate and its winning program by HTS, and combines USMCA eligibility with `any()`. | Preserve each candidate's product, origin, use, dates and claim conditions. Legal precedence chooses the shipment action. Retain the old aggregate approach only in explicitly modeled outputs, with versioned methodology changes when verified corrections require them. |
| Statutory totals still pass through aggregate-style stacking | `helpers.R:3213–3288` uses positive `rate_232`, modeled metal shares and chapter/type fallbacks. `compute_statutory_totals()` calls that same stacking function with substituted statutory columns; its comment acknowledges the content-modeling limitation. | Derive shipment amounts from source-backed applicability and legal value portions. Do not repair this by changing a global rate threshold or guessing a content share. Existing NA guards prevent some false totals but do not make the remaining calculation a complete shipment evaluator. |
| Reciprocal executable chronology stops at August 1, 2025 | The subsequent implementation adds June 30 UK aircraft relief and the July 9 suspension extension. `ieepa_reciprocal_rules.py` now ends at the August 1 copper/country-policy boundary. Later source-derived product-exemption history exists, but is not a complete country/claim/sector evaluator. | Compile the subsequent original amendments, country measures, sector exceptions and reporting transitions through the collection end, with effective dates independent of HTS publication dates. |
| Drug-emergency IEEPA is not all IEEPA | `ieepa_emergency_rules.py` handles the identified emergency actions, explicitly leaving FTZ/de minimis histories unresolved. Its audit excludes other country-specific IEEPA actions from that compiler. | Inventory every distinct action; reconcile its origin coverage, replacement/cumulation, transit, preference and sector treatment. Do not treat an authority rollup as one legal action. |
| Section 232 coverage and claims remain incomplete | Legacy-metals and note-16 compilers emit empty coverage attestations; note-16 explicitly requires separate civil-aircraft/Chapter 98 and other-action composition. Sector candidates and conditional fragments do not prove a complete sector inventory. | Establish complete source-backed decisions for vehicles/parts, machinery/derivatives, semiconductors, copper, timber, MHD and other enumerated sectors; resolve country deals, floors/caps, offset treatment, grants and historical quota discrepancies. Investigate reporting references against original annexes and operative notes before accepting unresolved status. |
| Sections 122 and 338 have explicit uncompiled paths | `section122_rules.py` rejects unlisted Section 232 interactions and FTZ; its limitations include import-adjustment offsets. `section338_rules.py` rejects unlisted Section 232 decisions and FTZ. | Reconcile all operative annex versions and action references. Define whole-article versus portion treatment and Chapter 98 overlaps for each action/window; remove an unresolved path only after its legal interpretation is executable and tested. |
| Section 301 compiler scope is narrower than complete coverage | `section301_sources.py` identifies notes 20/31, named Chapter 98 targets, note 20(vvv)/(www), and 9903.91.09/.10 claims, while explicitly excluding remaining exclusions/investigations. | Reconcile the full charge/exclusion inventory, reinstatements, extensions, retroactivity and investigation-specific interactions. An exclusion may remove only the duties its source names. |
| Exhaustive verification does not exist yet | `tests/test_normalized_parity.R --full` explicitly rejects exhaustive traversal; the default performs a sample after artifact checks. | Implement all-cell/action-interval coverage checks and deterministic fact-branch tests, then compare normalized decisions, evaluated shipments and applicable wide projections. Sample tests and source-count sweeps cannot substitute for this. |

The maximum-rate and positive-rate operations above are confirmed code paths,
not a claim that every aggregate number they produce is wrong. They become unsafe
when used as legal applicability or shipment-pricing decisions. Some affected
shipment columns already return NA; that is safer than a fabricated answer but
still incomplete implementation.

## Next work, in dependency order

1. **Create a machine-checkable legal action/coverage inventory.** For each action
   retain authority, original instrument/annex/note, source hashes, reporting
   headings, exact scope grain, origin rule, legal entry window, publication and
   retroactive amendment evidence, required facts, valuation, and interactions.
   Reconcile every potentially operative Chapter 99 item. Classify it as compiled,
   superseded, independently verified not applicable, or unresolved with a precise
   source/question. An empty rate row is never evidence of non-application.
2. **Complete Section 232 candidate decisions and later reciprocal chronology
   together.** Machinery, auto parts, mixed-metal derivatives and semiconductors
   are the priority cross-program cases. Preserve competing candidates until facts
   and legal relations resolve them. Resolve earlier quotas/grants and later
   sector/country measures from sources, not rate maxima. Compile reciprocal
   country/sector changes from August 1 rather than carrying forward initial rules.
3. **Close remaining IEEPA/122/338/301 interactions.** Include each claim's effect
   on every matched action; zero-payable and excluded actions; nonmetal portions;
   Chapter 98 and U.S.-content overlaps; floors/caps using actual resolved base
   duty; transit and FTZ admission/withdrawal histories. Do not assume every
   program uses country of origin alone when smelt/cast or processing facts matter.
4. **Connect those definitions to the ordinary Parquet build.** Build complete
   production bundles and normalized action/decision records automatically.
   Shipment columns must originate in the legal evaluator. Aggregate columns
   retain their explicitly modeled meaning. Preserve exact legal instants even
   where the economic series is daily. Synchronization must carry a mutually
   consistent bundle/table/base/evidence release to MotherDuck.
5. **Prove coverage before asking for the full rebuild.** Sweep every valid HTS10,
   origin and legal interval for missing/conflicting action membership. Test the
   instant before, at and after each amendment; representative valid/invalid
   fact combinations; claims; zero duty; overlapping content; and source-order/
   duplication invariance. Perform read-only MotherDuck comparisons across the
   affected sectors. Explain discrepancies using matched legal decisions rather
   than treating existing totals as an oracle.

Base duties, preferences, specific/compound units, Chapter 98 entitlement, quotas
and AD/CVD scope/company/instruction windows also need a defensible decision
before a result may claim to be a complete at-entry total. Missing shipment facts
may legitimately remain `needs_inputs`; missing legal implementation must remain
`unresolved_source`. They are different release/coverage issues.

## Required Parquet behavior

HTS10 + origin + entry instant selects the candidate legal stack. It cannot always
select one numeric total without value, quantity, use, content, claims, producer,
quota or FTZ facts. For those rows, persist formulas and conditions, not an average
pretending to be a statutory amount. A zero, suppression, and out-of-scope decision
each need their own explanation.

Use the existing normalized tables and rule contract. Extend them where needed
to retain action identity, reporting code/role, exact product/origin/time scope,
source/locator, valuation expression, required facts, claim/precedence effects,
completeness, dataset/contract version and evidence snapshot. Precomputed shipment
amounts must identify their fact assumptions. Unconditional and conditional
decisions must not collapse into one unexplained wide-column rate.

The last retained MotherDuck fastener audit demonstrates why: 25% Section 232,
20% emergency IEEPA, 25% Section 301 and a 10% reciprocal *parameter* coexist on
one row, but its additional-duty subtotal is 70%, because reciprocal liability is
suppressed. Summing the raw columns would give 80%. The eight separate reciprocal
false-exemption findings remain real discrepancies under their stated assumptions.
See [the retained audit](audits/2026-10-25-reciprocal-executable/README.md).

## Rebuild decision and acceptance

Begin the final manual rebuild when the ordinary build uses the corrected
definitions, required ordinary-entry legal paths are implemented or precisely
scoped as unresolved, and the new exhaustive checks can run against its outputs.
Do not wait for every importer to supply its facts, and do not require an incorrect
complete total for genuinely indeterminate cases. Do require an explicit outcome
for every candidate action and proof of verified non-application.

Then regenerate all 55 configured revisions, including normalized revisions 20
and 21, run full output reconciliation and aggregate differences, prepare the
complete local release, and seek separate approval for MotherDuck activation.
The currently missing 526 artifacts should be regenerated, not waived. The actual
TPC input is a separate aggregate check, not a source of customs law.

Primary-source checks behind the portion distinction:
[Section 122 proclamation, paragraph 4](https://www.govinfo.gov/content/pkg/FR-2026-02-25/html/2026-03824.htm)
and [Proclamation 10947, clause 6](https://www.govinfo.gov/content/pkg/FR-2025-06-09/html/2025-10524.htm).
Both require a legal value-portion decision; a generic positive-rate predicate is
not a substitute. No new legal interpretation is declared complete by this memo.
