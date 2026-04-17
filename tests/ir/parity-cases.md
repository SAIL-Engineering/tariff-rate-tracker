# Parity edge case catalog

A living record of every failure class the normalized parity harness has
surfaced, why it happened, and where it's tested. Every new failure
signature that the triage script (`scripts/triage_parity_failures.R`)
identifies gets a new section here with a permalink to the fix commit and
a canonical representative case that can be replayed against future
harness runs.

**Purpose.** When the parity harness goes red, this document is the first
place to check: if the new failure signature matches an existing section,
the bug is either a regression of a known fix or a related case that the
original fix missed. If the signature is new, add a section so the next
maintainer has an audit trail.

**Structure.** Each section captures (1) a one-line symptom, (2) the root
cause, (3) one representative case `(hts10, country, revision, column)`
that can reproduce it, and (4) the fix — emitter change, resolver change,
or both — with a file:line pointer.

---

## 1. S301 applied to non-China countries

**Symptom.** `rate_301` norm value is 0.075 (S301 list 4a rate) or higher
for countries that aren't China. Denorm has `rate_301 = 0`.

**Root cause.** The emitter wrote S301 list rows into
`authority_product_applicability.parquet` with `country = NA`, losing the
China-only scope that's built into S301 by statute. The resolver's
layer-3 lookup matched the row for any country.

**Fix.** Added a `country_scope` column to layer 3. The S301 emitter block
sets `country_scope = '5700'` (China census code) on every list row. The
resolver's `.compute_authority_rate` strsplits the scope on `|` and
returns NA for countries not in the allowed set. Works uniformly for any
future country-restricted authority.

- Emitter: [src/07_emit_normalized.R](../../src/07_emit_normalized.R) — S301 block sets `country_scope`
- Resolver: [src/resolve_rate_normalized.R](../../src/resolve_rate_normalized.R) — `.compute_authority_rate` scope gate

**Representative cases:**
- `8543709860` / `4351` / `2025_rev_7` — Czechia, rate_301 should be 0
- `7208510030` / `4010` / `2025_rev_10` — Brazil steel
- `8703230120` / `2010` / `2025_rev_20` — Mexico auto

---

## 2. IEEPA reciprocal aggregation order

**Symptom.** `rate_ieepa_recip` norm = denorm + 0.1 exactly, on EU / Japan /
Korea floor countries. E.g. denorm 0.125094, norm 0.225094.

**Root cause.** My first emitter re-implemented the denorm aggregation with
`arrange(desc(phase_rate))` before `first(rate_type)`. That inverted the
denorm semantics: denorm uses an `active_rank` filter that drops
`phase1_apr9` entries entirely when `phase2_aug7` / `country_eo` exist,
then within each surviving phase sorts by `type_priority` (floor < surcharge
< passthrough). My sort picked the highest-rate phase's rate_type, which
for an EU country's phase2 floor was 'floor' BEFORE the floor override
mask could convert it — so the floor value was never clamped to the 0.15
floor_rate and the stored statutory_rate was `sum(phase1 + phase2) = 0.25`,
not the intended 0.15 floor.

**Fix.** The emitter no longer re-aggregates. `calculate_rates_for_revision`
captures the post-aggregation `country_ieepa` tibble as
`denorm_state$country_ieepa` and the emitter serializes it directly.
Single source of truth for IEEPA recip aggregation lives in the denorm
pipeline at [src/06_calculate_rates.R:572-697](../../src/06_calculate_rates.R#L572-L697).

- Capture: [src/06_calculate_rates.R](../../src/06_calculate_rates.R) — `denorm_state_country_ieepa` assignment after the baseline fill
- Emitter: [src/07_emit_normalized.R](../../src/07_emit_normalized.R) — `emit_authority_country_rates` IEEPA block reads `denorm_state$country_ieepa`

**Representative cases:**
- `8703230120` / `4759` / `2025_rev_31` — Spain (EU), rate_ieepa_recip should be 0.125094
- `8708220000` / `4330` / `2025_rev_25` — Germany
- `8708805100` / `4330` / `2025_rev_30` — Germany, auto part

---

## 3. Section 232 country deal floors and surcharges

**Symptom.** `rate_232` norm = 0.237625 (auto blanket post-rebate) but
denorm = 0.15, 0.125, 0.185233, or various other deal-specific values.

**Root cause.** Denorm step 4c (`src/06_calculate_rates.R:1291-1361`)
walks `s232_rates$auto_deal_rates` and `wood_deal_rates`, expands each
deal to (census_codes, deal_products), and applies a floor (`max(0,
deal_rate - base_rate)`) or surcharge (flat) to matching rows. The
original emitter had zero coverage for this path.

**Fix.** `calculate_rates_for_revision` captures each deal's expansion as
`denorm_state$s232_deals[[i]] = list(program, census_codes, deal_products,
rate, rate_type)`. The emitter walks this list and emits one layer-3 row
per deal product at precedence 10 (beats derivative at 5, beats blanket
at 1) with `country_scope` = `|`-joined census codes and
`rate_type = 'floor'|'surcharge'`. The resolver's `.apply_rate_type`
helper handles both semantics.

- Capture: [src/06_calculate_rates.R](../../src/06_calculate_rates.R) — `denorm_state_s232_deals` list append inside the auto / wood deal loops
- Emitter: [src/07_emit_normalized.R](../../src/07_emit_normalized.R) — `emit_authority_product_applicability` S232 deal block
- Resolver: [src/resolve_rate_normalized.R](../../src/resolve_rate_normalized.R) — `.apply_rate_type` handles floor semantics

**Representative cases:**
- `8703230120` / `4759` / `2025_rev_20` — Spain, EU auto floor, should be 0.125
- `8708295125` / `2010` / `2025_rev_30` — Mexico, auto part, should be 0.305113
- `8708800500` / `2010` / `2025_rev_26` — Mexico, should be 0.208342

---

## 4. Section 122 missing from layer 3

**Symptom.** `rate_s122` denorm = 0.1, norm = 0. Revisions 2026_rev_4+.

**Root cause.** The emitter had an `S122_ACTIVE` stub in
`emit_authority_country_rates` but no layer-3 blanket row in
`emit_authority_product_applicability`. The resolver had no winner for
section_122 even when layer 2 had the rate, so it never fired.

**Fix.** Added an `S122` denorm_state slot capturing `in_force`, `rate`,
and `exempt_hts8`. The emitter now writes three coordinated rows when
in-force: (1) a layer-3 blanket `section_122` row with statutory_rate=NA,
(2) per-country layer-2 rows carrying the flat rate, (3) layer-4
`s122_exempt_hts8` rows at full exemption for every exempted HTS8 prefix.
The resolver routes `section_122` through the layer-2 lookup alongside
`ieepa_reciprocal` / `ieepa_fentanyl`.

- Capture: [src/06_calculate_rates.R](../../src/06_calculate_rates.R) — `denorm_state_s122` built inside the S122 block
- Emitter: [src/07_emit_normalized.R](../../src/07_emit_normalized.R) — three blocks: country rates, blanket applicability, HTS8 exempt rows
- Resolver: [src/resolve_rate_normalized.R](../../src/resolve_rate_normalized.R) — `section_122` in `layer2_authorities`

**Representative case:**
- `8703400045` / `1220` / `2026_rev_4` — Canada, rate_s122 should be 0.1

---

## 5. USMCA preference shares not applied to base_rate

**Symptom.** `base_rate` norm = 0.025 but denorm ≈ 0.0035 for Mexico /
Canada auto products with high USMCA utilization.

**Root cause.** Denorm at [src/06_calculate_rates.R:1881-1899](../../src/06_calculate_rates.R#L1881-L1899)
reduces `base_rate` (and `rate_ieepa_recip`, `rate_ieepa_fent`,
`rate_s122`, and 232 auto/MHD) by the per-product usmca_share loaded from
`usmca_product_shares`. The emitter only wrote layer-4 USMCA rows for
`ieepa_reciprocal` and `ieepa_fentanyl` — base_rate was never reduced in
the normalized path.

**Fix.** Two changes. Emitter: extended the USMCA loop in
`emit_authority_exemptions` to also emit layer-4 rows for `section_122`,
and to emit a separate `usmca_section_232_auto` row with `exemption_share
= usmca_share * us_auto_content_share` for auto/MHD products. Resolver:
after the MFN exemption step, query layer 4 for `(hts10, country)` with
`authority='ieepa_reciprocal'` and `exemption_type='usmca_eligible'`, then
reduce `base_rate` by that share. Same source of truth as the authority
rows.

- Emitter: [src/07_emit_normalized.R](../../src/07_emit_normalized.R) — expanded USMCA loop, new `usmca_section_232_auto` row
- Resolver: [src/resolve_rate_normalized.R](../../src/resolve_rate_normalized.R) — USMCA base_rate reduction after MFN step

**Representative case:**
- `8703105060` / `2010` / `2025_rev_25` — Mexico passenger car, base_rate should be ~0.0035

---

## 6. Auto assembly rebate compounded with deal floor instead of replaced

**Symptom.** `rate_232` norm = 0.142575 (0.15 * 0.9505) but denorm = 0.15
exactly, for EU/JP/KR auto deal floor countries.

**Root cause.** Denorm step 4b applies the assembly rebate
(`rate_232 -= rebate_deduction`) and then step 4c REPLACES `rate_232`
with `max(0, deal_rate - base_rate)` for deal countries. The emitter
originally modeled the rebate as a layer-4 exemption at share 0.0495, and
the resolver's stacking compounds layer-4 shares multiplicatively —
producing `deal_floor * (1 - 0.0495)` instead of just `deal_floor`.

**Fix.** Baked the rebate into the layer-3 auto blanket statutory_rate
directly. For products in `denorm_state$auto_products`, the emitter
writes `statutory_rate = auto_rate - rebate_deduction` on the auto /
passenger / light_truck rows. Deal-country winners at precedence 10
cleanly REPLACE this value. Removed the layer-4 `auto_assembly_rebate`
exemption entirely.

- Emitter: [src/07_emit_normalized.R](../../src/07_emit_normalized.R) — auto programs block bakes rebate into statutory_rate; no layer-4 auto_assembly_rebate row

**Representative cases:**
- `8708946000` / `4330` / `2025_rev_25` — Germany, rate_232 should be 0.15 (EU floor)
- `8708806000` / `4351` / `2025_rev_25` — Austria

---

## 7. Section 232 heading + derivative overlap products

**Symptom.** `rate_232` norm = 0 or 0.237625, denorm = 0.5 for auto parts
(8708*) that are also in the steel derivative prefix list.

**Root cause.** Denorm [src/06_calculate_rates.R:430-444](../../src/06_calculate_rates.R#L430-L444)
takes `pmax(heading_rate, derivative_full_rate)` for products that match
BOTH a heading product list and a derivative prefix, then sets
`metal_share = 1.0` (no scaling) for the overlap set. The emitter emitted
the derivative prefix row with `scaling_dimension='steel_share'`
unconditionally, so the resolver multiplied the 0.5 steel deriv rate by
the per-product steel_share — giving the wrong answer for any overlap
product with steel_share < 1.

**Fix.** `apply_232_derivatives` now returns a `heading_overlap` tibble
with one row per overlap hts10, carrying the post-pmax `rate_232` value
directly from the rates tibble and the assigned `deriv_type`. The
emitter writes these as per-hts10 layer-3 override rows at precedence 7
(beats derivative prefix at 5, loses to country deals at 10) with
`scaling_dimension='none'` and `statutory_rate = post_pmax_value`.
Single source of truth: the pmax formula stays in `apply_232_derivatives`.

- Capture: [src/06_calculate_rates.R](../../src/06_calculate_rates.R) — `apply_232_derivatives` returns `heading_overlap`, call site saves `denorm_state_heading_overlap`
- Emitter: [src/07_emit_normalized.R](../../src/07_emit_normalized.R) — `s232_heading_overlap` block

**Representative case:**
- `8708806510` / `4280` / `2025_rev_28` — Sweden, steel-containing auto part, rate_232 should be 0.5

---

## 8. S232 annex classification missing from resolver wide tibble

**Symptom.** Post-2026-04-06 revisions show a cluster of ~2pp diffs on 232
products because the post-annex `nonmetal_share = 0` override in
`apply_stacking_rules` never fires in the normalized path.

**Root cause.** The upstream fix in `helpers.R` makes `apply_stacking_rules`
read `s232_annex` from its input tibble:
```r
if ('s232_annex' %in% names(df)) {
  df <- df %>% mutate(nonmetal_share = if_else(
    !is.na(s232_annex) & rate_232 > 0, 0, nonmetal_share))
}
```
The resolver's wide tibble had no `s232_annex` column, so the `if` was
always false. Post-annex products kept their phantom nonmetal fraction
and IEEPA / S122 / fentanyl leaked through on every annex-era 232
product.

**Fix.** Annex classification is per-hts10 and country-invariant.
`calculate_rates_for_revision` captures distinct `(hts10, s232_annex)`
pairs as `denorm_state$product_annex` after the annex block finishes.
The emitter attaches the column to `products_base.parquet` (layer 1) via
a left-join inside `emit_products_base`. The resolver reads
`base_row$s232_annex` and sets it on the wide tibble; the upstream
override fires uniformly across both code paths.

- Capture: [src/06_calculate_rates.R](../../src/06_calculate_rates.R) — `denorm_state_product_annex` assembly after annex block
- Emitter: [src/07_emit_normalized.R](../../src/07_emit_normalized.R) — `emit_products_base` left_join
- Resolver: [src/resolve_rate_normalized.R](../../src/resolve_rate_normalized.R) — `s232_annex_val` read and wide tibble set

**Representative case:**
- Any post-2026-04-06 revision, steel derivative auto part — verify post-annex ETR drops by ~2pp vs. the previous harness run

---

## Template for new entries

```markdown
## N. <short symptom headline>

**Symptom.** <one-line observed failure pattern>

**Root cause.** <why the normalized path diverged from denorm>

**Fix.** <emitter and/or resolver change, with file:line pointers>

- <file>: <change>
- <file>: <change>

**Representative case(s):**
- `<hts10>` / `<country>` / `<revision>` — <expected value>
```
