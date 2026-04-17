# ADR 001 — Emitter as serializer of `denorm_state`

**Status:** Accepted
**Date:** 2026-04-14
**Supersedes:** Original Phase 2b guidance in `docs/normalized-schema.md`

## Context

The Phase 2 normalized emitter (`src/07_emit_normalized.R`) initially
followed the guidance in the original Phase 0–5 plan: "emitters extract
from intermediates, not from the denormalized rates tibble." The intent
was good — both denorm and the emitter reading from the same raw inputs
(`ieepa_rates`, `s232_rates`, etc.) would avoid rebuilding-on-top-of-a-bug.
In practice this meant the emitter re-implemented each transformation the
denorm pipeline performed: per-country IEEPA aggregation, floor override,
baseline fill, S232 deal expansion, auto rebate, USMCA share application,
S232 annex classification, heading/derivative overlap `pmax`.

That approach produced 916 parity failures on the first end-to-end run.
The root cause pattern was consistent: the emitter's re-implementation
drifted from the denorm pipeline's logic in ways that were
order-sensitive, silent, and hard to catch by inspection. One example,
from the IEEPA aggregation bug:

- Denorm uses `arrange(type_priority, desc(rate))` inside each
  (census_code, phase) group, then `first(rate_type)` in the cross-phase
  summarise. `type_priority` sorts floor < surcharge < passthrough.
- My first emitter used `arrange(desc(phase_rate))` — picked the
  highest-rate phase's rate_type, not the type-priority-first phase's.
- For an EU country whose phase2 floor was 0.15 and phase1 surcharge was
  0.10, the emitter picked 'floor' as the type, skipped the floor
  override mask (which only applies to 'surcharge'), and stored
  `statutory_rate = 0.25` (sum of phases) with `rate_type = 'floor'`.
  The resolver then computed `max(0, 0.25 - base_rate) = 0.225`, off by
  exactly +0.1 from denorm's correct 0.125.

The bug wasn't a typo — it was a faithful but subtly wrong
reinterpretation of a multi-step algorithm. Every transformation the
emitter reimplemented had the same class of risk.

## Decision

**The emitter is a serializer of denorm's computed intermediate state,
not a parallel computation.**

Concretely:

1. `calculate_rates_for_revision` (`src/06_calculate_rates.R`) captures
   its post-aggregation intermediates into named local variables with
   the prefix `denorm_state_*` at the point in the function where each
   value becomes final.
2. Right before the emit call, those locals are assembled into a single
   `denorm_state` list with stable slot names.
3. `emit_normalized_revision` receives `denorm_state` as a named
   parameter. Each subordinate emitter function (`emit_authority_country_rates`,
   `emit_authority_product_applicability`, `emit_authority_exemptions`,
   `emit_products_base`) reads its slot directly and writes parquet rows
   with no re-computation.

The normalized layers become a **projection** of denorm's internal state
at a specific point in the pipeline. Any future regulation change flows
through the denorm code path and propagates into the normalized output
automatically.

## Consequences

### Positive

- **Zero-drift guarantee.** As long as `denorm_state` captures the
  values at the correct point in the denorm pipeline, the emitter
  cannot diverge. The only way to break parity is to change denorm
  without also updating the slot's capture point — and that's caught
  by the parity harness on the next run.
- **Smaller emitter.** `emit_authority_country_rates` IEEPA block shrank
  from ~130 lines of re-aggregation logic to ~15 lines of column
  projection after the refactor.
- **Easier onboarding.** New contributors reading the emitter see
  direct tibble → parquet transformations, not a second implementation
  of the rate-computation algorithm.
- **Future regulation changes are localized.** Add a new rate type?
  Edit `apply_232_derivatives` once; the capture pipes the new column
  through automatically.

### Negative

- **Emitter is not self-contained.** You can't run
  `emit_normalized_revision` without first running the denorm pipeline
  to produce `denorm_state`. This is an acceptable tradeoff: the dual
  write is the entire purpose of the emitter at this phase.
- **`denorm_state` becomes an implicit contract.** If a denorm refactor
  removes or renames a slot, the emitter silently drops the
  corresponding layer. Mitigated by `src/denorm_state_contract.R` (see
  Phase 2.5d) which asserts every expected slot exists and has the
  expected shape immediately before emit.
- **Re-emit from cache is not yet supported.** The `reemit_normalized_for_cached`
  path in `src/00_build_timeseries.R` re-runs the emitter against
  cached parse results WITHOUT running the denorm pipeline. That path
  currently has no `denorm_state` available and will produce incomplete
  normalized layers. Fix: persist `denorm_state` alongside the
  snapshot RDS files, or deprecate the re-emit path in favor of a
  full rerun (which is fast with `--parallel`).

### Neutral

- **Responsibility boundary.** Bugs in the normalized path are now one
  of: (a) the slot capture point is wrong (denorm side), (b) the
  emitter doesn't read the slot correctly (emitter side), (c) the
  resolver interprets the serialized form incorrectly (resolver side).
  These are distinguishable classes; (a) and (b) show up as diff
  patterns that track denorm changes, (c) shows up on stable data.

## The seven slots (as of 2026-04-14)

Each slot is produced by a specific block in `calculate_rates_for_revision`
and consumed by specific functions in `emit_normalized_revision`. When a
future contributor adds a new slot, they MUST update this table so the
contract is auditable.

| Slot | Producer (line) | Consumer | What it carries |
|---|---|---|---|
| `country_ieepa` | post-baseline fill in the IEEPA block | `emit_authority_country_rates` | Post-floor-override, post-baseline per-country IEEPA recip rates with `ieepa_type` classification |
| `s232_deals` | inside step 4c auto/wood deal loops | `emit_authority_product_applicability` | List of `(program, census_codes, deal_products, rate, rate_type)` tuples per deal |
| `auto_products` | step 4 heading product matching (post-blanket-chapter-exclusion) | `emit_authority_product_applicability`, `emit_authority_exemptions` | HTS10 vector of products subject to S232 auto classification + rebate |
| `mhd_products` | step 4 heading product matching | `emit_authority_exemptions` | HTS10 vector of medium/heavy-duty truck products |
| `wood_softwood_products` | step 4 heading product matching | reserved | HTS10 vector of softwood products |
| `wood_furn_products` | step 4 heading product matching | reserved | HTS10 vector of furniture/cabinet products |
| `s122` | post in-force gate in step 6b | `emit_authority_country_rates`, `emit_authority_product_applicability`, `emit_authority_exemptions` | `list(in_force, rate, exempt_hts8)` |
| `heading_overlap` | end of `apply_232_derivatives` | `emit_authority_product_applicability` | Tibble `(hts10, rate_232, deriv_type)` with the post-`pmax` value for heading+derivative overlap products |
| `product_annex` | end of annex classification block | `emit_products_base` | Distinct `(hts10, s232_annex)` classification per product |

## Enforcement

1. **`src/denorm_state_contract.R`** defines `validate_denorm_state(ds)`
   that asserts every slot from the table above is present and has the
   expected shape. Called as a postcondition in
   `calculate_rates_for_revision` right before emit. Fails loudly with
   a named error — not a silent drop.
2. **The parity harness** (`tests/test_normalized_parity.R`) is the
   ultimate safety net. Any capture point drift shows up as a parity
   failure on the next run. The triage script
   (`scripts/triage_parity_failures.R`) categorizes failures by
   signature so drift manifesting as "everyone in EU is off by +0.1" is
   immediately legible.
3. **`tests/ir/parity-cases.md`** catalogs every failure class that's
   been fixed so future regressions can be matched against known
   root causes.

## Rollback

If this pattern turns out to be unsustainable (e.g., because the denorm
pipeline needs a radical refactor that makes slot capture impractical),
the rollback is: revert the emitter's `denorm_state` reads to inline
re-aggregation. The original re-implementation code is in git history
through the commit that introduced this ADR. All parity fixes that
depend on this pattern would need to be re-landed.

Expected lifespan: this pattern is foundational for Phase 2-4. Phase 4a
formalizes `denorm_state` further by making it a first-class return
value of `calculate_rates_for_revision` instead of a bag of locals.

## References

- Original plan draft (pre-revision) — `docs/normalized-schema.md` D1–D7
- Root cause analysis for the 916 failures — this session's conversation
- Triage tooling — `scripts/triage_parity_failures.R`
- Contract validator — `src/denorm_state_contract.R`
- Edge case catalog — `tests/ir/parity-cases.md`
