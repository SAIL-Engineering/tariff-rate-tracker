# `denorm_state` Flow (Step 06 → Step 07)

**Audience:** contributors modifying rate-calculation logic or debugging normalized-layer parity failures.
**Companion to:** [`adrs/001-denorm-state-pattern.md`](adrs/001-denorm-state-pattern.md) (architectural rationale — read that first if you're new to the pattern).

This doc covers the *flow*: where each `denorm_state` slot is populated in `06_calculate_rates.R`, how the state list is assembled, and which emitter sub-function in `07_emit_normalized.R` reads which slot. ADR 001 covers the *why*; this covers the *where*.

## The seven slots

| Slot | Captured at | Consumer in `07_emit_normalized.R` |
|---|---|---|
| `country_ieepa` | `src/06_calculate_rates.R:930-1050` (IEEPA aggregation + baseline-fill block) | `emit_authority_country_rates()` (~line 250) |
| `s232_deals` | `src/06_calculate_rates.R:1385-1470` (auto deal loop) and `:1470-1550` (wood deal loop) | `emit_authority_product_applicability()` (~line 350) |
| `auto_products` | `src/06_calculate_rates.R:1080-1120` (chapter 87 heading-prefix matching) | `emit_authority_product_applicability()`, `emit_authority_exemptions()` |
| `mhd_products` | `src/06_calculate_rates.R:1121-1140` | `emit_authority_exemptions()` |
| `s122` | `src/06_calculate_rates.R:1700-1780` (post in-force gate) | Multiple emitters (country_rates, product_applicability, exemptions) |
| `heading_overlap` | `src/06_calculate_rates.R:1560-1600` (inside `apply_232_derivatives()`) | `emit_authority_product_applicability()` |
| `product_annex` | `src/06_calculate_rates.R:1620-1670` (annex classification) | `emit_products_base()` |

## Assembly + emit

After all nine sub-steps of `calculate_rates_for_revision()` complete:

- Line ~2360: a named list `denorm_state <- list(country_ieepa = ..., s232_deals = ..., ...)` is constructed inline from the locals captured above.
- Line ~2400: `emit_normalized_revision(rev_id, denorm_state, output_dir)` is called.
- Inside `07_emit_normalized.R`, that function dispatches to five sub-emitters (lines 200-700) which each pull only the slots they need from the list.

The list is **passed by value** — emitters cannot mutate it back into step 06. Any value not captured in the list at line 2360 is lost; this is the contract that drives the parity-failure class described in ADR 001 § 3.

## Slot lifecycle

Not every slot is populated on every revision. Specifically:

- `s232_deals` is empty on revisions before the relevant proclamation effective dates (auto and wood deals each have their own gate).
- `mhd_products` only populates when MHD-specific Ch99 codes are active.
- `s122` only populates after the EO 14257 in-force date.
- `country_ieepa`, `auto_products`, `heading_overlap`, `product_annex` populate every revision.

If you're adding a new slot, follow ADR 001 § 4: capture the local at the natural step where the data is first complete, then add it to the list at line 2360 and a corresponding consumer in `07_emit_normalized.R`.

## Parity-failure triage

Normalized-layer parity tests at `tests/test_normalized_parity.R` compare denormalized and normalized rate panels. When a parity test fails:

1. Identify which authority/column the failing rows are in.
2. Trace that column to the slot in the table above.
3. Read the slot's capture range in `06_calculate_rates.R` — most parity bugs are "slot was captured at the wrong line, before some downstream mutation rewrote the local."
4. The fix is almost always to move the capture point later, not to change the emitter.

ADR 001 § 5 has more on this triage pattern.
