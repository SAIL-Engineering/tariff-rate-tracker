# Reporting-heading investigation, 2026-10-23

The absence of a defensible heading from a calculated row is a research and
extraction finding, not proof that the law supplies no heading. This work replaces
rate/chapter guesses with source-bound conditional decisions. It does **not**
complete all-authority legal coverage or qualify a production release.

## Findings resolved in the note 16 compiler

`src/section232_note16_rules.py` consumes revision-specific Chapter 99 notes and
HTS rate expressions from `section232_sources.py`. The ordinary normalized build
emits `section232_note16_rules.json` for the existing R/TypeScript interpreter.
No test HTS or product-country example is embedded in the production rules.

* Enumerated HTS4/6/8/10 scopes retain their grain and all metal-list memberships.
  Note 16(c) requires aggregate weight of the applicable listed metals; note
  16(e)'s U.S.-origin qualifications are cumulative for overlapping lists.
* The UK qualification remains 95 percent, including the expressly permitted
  Tata Steel UK/Netherlands clarification. The U.S.-origin threshold changes
  from 95 to 85 percent only with the June regime. Quantities are shipment
  inputs, not modeled trade shares.
* No-metal and insufficient-metal cases select the published zero-duty headings
  9903.82.01 and .03. They are distinct from a missing or unsupported heading.
* The April technical correction establishes .01 retroactively for April 6
  entries, even when the earlier HTS snapshot lacks that row. It also removes
  the inconsistent second paragraph of note 16(e). The compiler uses the
  heading's complete copper/derivative scope, not the superseded restriction.
* Ordinary, UK, U.S.-metal, Russian-steel, non-NTR, motorcycle-use and
  equipment-parts alternatives select their own headings. Floor/no-change
  pairs compare the actual applicable column 1 duty amount, never the modeled
  base. Civil-aircraft and Chapter 98 claim effects remain separate work.
* Proclamation 11021 clause 8 expressly retains Russian-aluminum treatment for
  the new annexes. Reading that amendment together with retained note 19(m)
  resolves .85.67/.68 without treating historical cross-references as absence.
  The Russian exception is assessed on full value and is not silently removed
  by the ordinary note 16 weight exception.
* Note 16(j) requires separate reporting of the dutiable and exempt portions.
  The compiler emits .82.20 and .21 with the documented U.S.-produced parts
  value and the source's 40-percent exempt cap; it does not force a single
  scalar code onto both lines. An unclaimed path does not assume USMCA.
* The limited-quantity .18/.19 concessions require the relevant USMCA facts,
  Canadian/Mexican metal production, and actual Commerce authorization.

Primary sources reviewed through gstack:

* [Proclamation 11021, clauses 1–10 and Annex IV, 91 FR 18201](https://www.govinfo.gov/content/pkg/FR-2026-04-09/html/2026-06960.htm).
* [Technical corrections, Annex 1(A) and UK clarification, 91 FR 23056–23057](https://www.govinfo.gov/content/pkg/FR-2026-04-29/html/2026-08297.htm).
* [Proclamation 11032, clauses 2–4 and Annex IV, 91 FR 34085](https://www.govinfo.gov/content/pkg/FR-2026-06-04/pdf/2026-11314.pdf).
* Each revision's complete USITC Chapter 99 and HTS JSON, with hashes and URLs
  carried by the source inventory and compiled fragments.

The annex in the June PDF is scanned. OCR was used to locate its provisions;
the primary PDF page was inspected and retained. OCR is not an executable rate
source. The semantic review catalog pins the reviewed condition text. An unknown
condition amendment fails compilation rather than being silently ignored; rates,
thresholds and product lists are still extracted from the identified revision.

## A source discrepancy remains narrowly identified

For note 16(c)(xi) articles meeting the U.S.-metal qualification, Proclamation
11032 clause 2(c) describes a column-1-inclusive 10-percent floor. Annex IV A(12)
adds (xi) to heading .82.06 without changing its existing **additional** 10-percent
expression; A(14) similarly extends the Russian .82.15 heading. The subsequent
HTS snapshots preserve those expressions. Clause 3(b) requires the lowest
applicable treatment, so the discrepancy can also affect selection against a
partner's .82.22 floor.

Both sources and the affected condition are recorded. A known .06/.15 reporting
identity can survive while its amount remains unresolved. Where the alternative
heading itself depends on that conflict, the compiler does not assert one.
Other shipments are not blocked by this discrepancy. A CBP guidance URL returned
404 and search did not supply a clarifying instruction during this investigation;
that is **not** a determination that clarification cannot be found. Further CBP
instruction/technical-correction research remains required.

## Coverage, serving and evidence limits

The source-only audit enumerates every published Chapter 99 heading in all 55
configured 2025–2026 revisions. `discovery_authority` is the existing routing
classifier's label, **not legal proof**: uncompiled entries remain explicitly
outside this note 16 compiler. The inventory retains descriptions, all duty
columns, source hashes and compiled-rule links. The 17 active note 16 snapshots
compile against the complete configured origin inventory. This is compilation
coverage, not exhaustive evaluation of every shipment fact combination.

The standard normalized emitter now creates the executable fragment. It must be
composed into the identified revision's complete rule bundle before local release
preparation. Stored bundles carry the same expressions and citations through the
existing MotherDuck/API architecture; a local source export is not a replacement
database. No MotherDuck publication or activation occurred.

No complete Section 232 coverage attestation is supplied by this fragment.
Pre-April metal regimes, all other Section 232 actions, inter-action precedence,
remaining preferences/Chapter 98, and other authorities still require their own
verified rules. The current tests deliberately leave the complete total null.
Likewise, the all-heading inventory does not itself finish IEEPA, §§122/301/338,
AD/CVD, or financial-consumer integration. These are remaining implementation
tasks, not findings of legal impossibility.

## Verification

* 35 R heading/amount/input cases, including historical thresholds and the
  retroactive insertion; 32 shared current-period cases also pass TypeScript.
  Contradictory metal weights or U.S.-parts values request corrected shipment
  facts; they are not reported as unresolved legal sources.
* Ten source/compiler Python tests cover exact grains, mixed lists, amendments,
  unknown legal grammar, source-derived rates, order and duplicate invariance.
* All 151 tracker Node contract/API tests pass with native Node and local
  in-memory DuckDB. Sandboxed Node reported only a file wrapper, so that earlier
  run was discarded as test evidence.
* Full R runner: 28 suites pass, normalized parity stops on 312 missing artifact
  errors, and the TPC comparison skips for unavailable built data. The runner's
  `402 passed, 0 failed` assertion count excludes the separate ERROR and SKIP;
  the full run is **not green**. The final 35 heading cases pass in the focused
  R rerun after the input-conflict refinement.
* The affected Python source/amendment suites pass all 34 tests.
* Tracker typecheck/Vite build passed; existing chunk-size warnings remain.

Normalized parity compares wide and normalized representations of the same
model. The 312 errors are six missing files in each of 52 existing revision
directories: `section301_source.json`, `section301_rules.json`,
`section301_scope_decisions.parquet`, `section232_scope_decisions.parquet`,
`ieepa_action_decisions.parquet`, and `claim_effects.parquet`. They are not 312
established incorrect rates. The comparison stops before calculating parity.
Separately, the requested `2026_rev_20` and `2026_rev_21` directories are absent;
the legacy parity directory traversal does not include those in its 312 count.
The release manifest's required-revision check must also pass.

Until rebuilding and reconciling, corrected wide rates could disagree with older
scope/claim data, missing evidence could be mistaken for no duty in a legacy
consumer, and historical corrections could be absent from the served intervals.
The new release preparation rejects missing required artifacts and mixed source
versions. Agreement after rebuild will still not substitute for independent legal
verification: two representations can share the same legal error. Missing
normalized tables must never be interpreted as exemptions or zero duty.

No timeseries or revision rebuild was run. WJR's commands remain in
[the manual runbook](../../shipment-duty-manual-rebuild.md). Tests and source-only
audits do not qualify the later approved MotherDuck deployment.
