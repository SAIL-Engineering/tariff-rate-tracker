# Normalized rate schema (Phase 2)

## Purpose

The production parquet dataset at `data/timeseries/rate_timeseries_parquet/` is a
**denormalized wide table**: one row per `(hts10, country, revision)` carrying the
final rate per authority after stacking. This shape is efficient for bulk analytics
but suffers from two structural problems:

1. **Sparse by accident, not by design.** The pipeline only materializes pairs that
   attract an additional duty. Non-IEEPA-listed countries (CZ and ~200 others) have
   no rows in early-2025 revisions, so a point lookup for CZ + 2025-03-14 returns
   zero rows even though base MFN legally applies. Phase 1 patched this at the
   server read path via `product_base_rates` synthesis, but the fix is a read-time
   heuristic — the underlying data model still conflates "no information" with
   "no duty."
2. **Difficult to extend to historical revisions.** Adding 2018–2024 HTS revisions
   for historical duty analysis requires the pipeline to run the full
   rate-calculation path for every past revision, including blanket application
   logic that evolved over time. The current procedural design makes this
   awkward.

Phase 2 normalizes the schema into **five layers** that decompose cleanly along the
axes of actual rate information. Each (product, country, date) lookup becomes a
compositional query over small, indexed tables. Absence has a single, legally
correct meaning: if layer 3 has no applicability row, the authority does not apply.

The denormalized parquet remains in place as a **materialized view** for analytics
consumers; the normalized layers become the source of truth for point lookups and
historical coverage.

## Layers

### Layer 1 — `products_base`
One row per `(hts10, revision)`. Country-independent product metadata from HTSUS.
Columns mirror the per-product fields in `RATE_SCHEMA` at
[src/helpers.R:1297-1312](../src/helpers.R#L1297-L1312).

| Column | Type | Notes |
|---|---|---|
| `hts10` | varchar(10) | PK part 1 |
| `revision` | varchar | PK part 2; FK → `revisions` |
| `base_rate` | double | HTSUS Column 1 General ad-valorem rate (post-FTA/GSP preference averaging). For a row-level lookup prefer `statutory_base_rate`. |
| `statutory_base_rate` | double | HTSUS Column 1 General *before* preference-share adjustments. This is what CBP assesses on an entry with no preference claim. |
| `rate_column2` | double | HTSUS Column 2 ad-valorem rate. Used for CU/KP/BY/RU. |
| `rate_column2_raw` | varchar | Original text (e.g. `"35%"`). |
| `rate_special` | double | Column 1 Special ad-valorem (blended across special programs). |
| `rate_special_raw` | varchar | Original text. |
| `special_programs_json` | varchar | JSON-encoded per-program special rates (see `parseSpecialPrograms` in [frontend/src/types/tariff.ts](../frontend/src/types/tariff.ts)). |
| `rate_basis` | enum | `ad_valorem \| specific \| compound \| free \| unknown` |
| `specific_amount` | double | For specific/compound rates. |
| `specific_rate_unit` | varchar | Legal unit from rate text (e.g. `"kg"`, `"pf.liter"`). |
| `reported_unit_1` | varchar | Statistical reporting unit 1. |
| `reported_unit_2` | varchar | Statistical reporting unit 2. |
| `duty_basis_unit` | varchar | Legally relevant unit for quantity-based duty math. |
| `is_qty_duty_relevant` | boolean | TRUE when `rate_basis ∈ {specific, compound}`. |
| `quantity_source` | varchar | `rate_text \| chapter_note \| override` |
| `rounding_rule` | varchar | 19 CFR 159.3 rule code. |
| `calc_status` | varchar | `ok \| needs_manual_review \| missing_duty_basis_unit` |
| `effective_date` | date | Revision effective date. |
| `valid_from` | date | Revision start. |
| `valid_until` | date | Revision end. |

**Cardinality**: ~19k products × 32 revisions ≈ 600k rows. With parquet dictionary
encoding on revision + sort-by-hts10, typical size ~30-50 MB.

**Sourcing**: direct projection from `products` tibble in
[src/06_calculate_rates.R:461+](../src/06_calculate_rates.R#L461), with
revision-level metadata joined.

### Layer 2 — `authority_country_rates`
One row per `(revision, authority, program, country, ch99_code)`. Country-specific
rate inputs for each authority. This is where IEEPA reciprocal country floors,
IEEPA fentanyl general rates per (CA/MX/CN), s232 country overrides (deals), and
s301's China-only scoping live.

| Column | Type | Notes |
|---|---|---|
| `revision` | varchar | FK |
| `authority` | enum | `section_232 \| section_301 \| ieepa_reciprocal \| ieepa_fentanyl \| section_122 \| section_201 \| other` |
| `program` | varchar | Sub-program inside authority (e.g. `ieepa_recip_country`, `fent_general`, `s232_steel_country_override`, `s301_blanket_china`) |
| `country` | varchar | Census code, or `NULL` for "all countries" (layer 3 blanket) |
| `ch99_code` | varchar | 8-digit Ch99 code authorizing this country's participation |
| `statutory_rate` | double | Pre-exemption ad-valorem rate this country pays under this authority |
| `rate_type` | enum | `surcharge \| floor \| passthrough \| override` |
| `phase` | varchar | Policy phase tag (`phase2_aug7`, `country_eo`, etc.) — for IEEPA; nullable |
| `valid_from` | date | |
| `valid_until` | date | |

**Primary key**: `(revision, authority, program, country, ch99_code)`

**Cardinality**: ~15k rows total across all revisions. Dominated by IEEPA
reciprocal country entries (~240 countries × revisions with an active entry). Tiny
compared to layer 1.

**Sourcing**: `ieepa_rates`, `fentanyl_rates`, `s232_rates` (country overrides),
`s301` product list (China-wide blanket rate) from
[src/05_parse_policy_params.R](../src/05_parse_policy_params.R) and
[src/06_calculate_rates.R](../src/06_calculate_rates.R).

### Layer 3 — `authority_product_applicability`
One row per `(revision, authority, program, hts_match, ch99_code)`. Declares
which products are covered by each authority program. This is the table that
fixes the "implicit applicability" problem in the denormalized schema.

| Column | Type | Notes |
|---|---|---|
| `revision` | varchar | FK |
| `authority` | enum | Same set as layer 2 |
| `program` | varchar | `steel_base`, `alum_base`, `copper_base`, `steel_deriv`, `alum_deriv`, `auto_passenger`, `auto_parts`, `s301_list_1`, `s301_list_3`, `s301_list_4a`, `s301_list_4b`, `s201_safeguard`, `s122_blanket`, `ieepa_recip_blanket`, `fent_general`, `fent_ca_energy_carveout`, etc. |
| `hts10` | varchar(10), nullable | Specific product match |
| `hts_prefix` | varchar, nullable | Prefix match (`"72"`, `"8703"`). Alternative to `hts10`. One of the two must be set unless blanket. |
| `ch99_code` | varchar | 8-digit Ch99 code that authorizes the rate for this program |
| `statutory_rate` | double, nullable | Ad-valorem rate. NULL for blanket authorities whose rate is supplied by layer 2 (e.g., IEEPA reciprocal — rate is country-specific). |
| `rate_kind` | enum | `ad_valorem_full \| ad_valorem_metal_scaled \| ad_valorem_fixed_bucket \| specific` |
| `scaling_dimension` | enum, nullable | `none \| metal_share \| steel_share \| aluminum_share \| copper_share` — which column in `product_metal_content` multiplies `statutory_rate` |
| `deriv_type` | enum, nullable | `steel \| aluminum \| copper` — consumed by stacking engine for IEEPA non-metal fill |
| `precedence` | smallint | Higher wins for same (authority, matched product). Carve-outs outrank general programs. Default 1. |
| `usmca_exempt` | boolean | Whether this program is waived for USMCA-qualified shipments |
| `valid_from` | date | |
| `valid_until` | date | |

**Primary key**: `(revision, authority, program, COALESCE(hts10, hts_prefix, ''))`

**Match semantics at query time**:
```sql
WHERE (apa.hts10 = :hts10)
   OR (apa.hts10 IS NULL AND apa.hts_prefix IS NULL)              -- blanket
   OR (apa.hts_prefix IS NOT NULL AND :hts10 LIKE apa.hts_prefix || '%')
```

**Precedence**: highest `precedence`, ties broken by specificity (explicit hts10 >
longest hts_prefix > blanket). Applies per `(authority, product)` — multiple
authorities stack independently.

**Cardinality**: ~7k programs × 32 revisions ≈ 220k rows. Smaller than layer 1.

**Sourcing**: combination of `heading_product_lists` (autos, copper, wood, MHD),
`s232_headings` (chapters 72/73/76), the s301 product CSV at
`resources/s301_product_lists.csv`, and inline blanket rows (IEEPA recip, s122,
fent CA/MX/CN).

### Layer 4 — `authority_exemptions`
One row per exemption, keyed broadly. Product-wide, country-wide, or
product×country-specific. Also used for fractional exemptions (USMCA utilization).

| Column | Type | Notes |
|---|---|---|
| `revision` | varchar | FK |
| `authority` | enum, nullable | NULL = applies to all authorities (rare) |
| `program` | varchar, nullable | Scope to specific program within an authority |
| `hts10` | varchar, nullable | Specific product |
| `hts_prefix` | varchar, nullable | Prefix product match |
| `country` | varchar, nullable | Specific country (Census code) |
| `country_group` | varchar, nullable | `eu \| japan \| korea \| swiss` for floor-country exemptions |
| `exemption_type` | enum | `annex_a \| floor_country \| usmca_eligible \| duty_free_treatment \| column2_override \| auto_usmca_rebate \| s301_exclusion` |
| `exemption_share` | double | Default 1.0. Fractional shares (<1.0) compound multiplicatively: `1 - ∏(1 - share_i)` |
| `rate_override` | double, nullable | For `auto_usmca_rebate` specifically: replace rate rather than reduce it |
| `source` | varchar | Provenance (e.g. `annex_a_csv`, `dataweb_spi_2024`, `floor_notes_2025_rev_7.csv`) |
| `valid_from` | date | |
| `valid_until` | date | |

**Cardinality**: ~10k rows. Dominated by Annex A (~1087 product entries per revision
where they apply) and USMCA per-product shares.

**Sourcing**: `ieepa_exempt_products`, `floor_exempt_products`,
`usmca_product_shares`, the Annex A list from `resources/ieepa_exempt_products.csv`.

### Layer 5 — `revisions`
One row per HTS/policy revision. Static registry consumed by date-to-revision
lookups.

| Column | Type | Notes |
|---|---|---|
| `revision` | varchar | PK |
| `effective_date` | date | When the revision took effect |
| `valid_from` | date | Inclusive start of this revision's window |
| `valid_until` | date | Inclusive end of this revision's window |
| `policy_event` | varchar, nullable | Short label for the notable event that drove this revision |
| `ieepa_invalidated` | boolean | TRUE if this revision falls on/after the IEEPA invalidation date (SCOTUS ruling) |

**Cardinality**: ~32 rows today, extensible to ~150 when historical 2018-2024
revisions land (Phase 5).

### Supporting — `product_metal_content`
One row per `hts10`. Physical metal composition for 232 derivative scaling and
IEEPA non-metal fill calculations.

| Column | Type | Notes |
|---|---|---|
| `hts10` | varchar(10) | PK |
| `metal_share` | double | Aggregate, 0-1 |
| `steel_share` | double | |
| `aluminum_share` | double | |
| `copper_share` | double | |
| `other_metal_share` | double | |

**Cardinality**: ≤ 19k rows. Typical non-zero subset ~2k rows. Not partitioned by
revision because metal composition is a physical property; restatements are rare.

**Sourcing**: `load_metal_content()` in
[src/helpers.R](../src/helpers.R), which reads BEA metal content analysis output.

### Supporting — `country_group_membership`
Maps abstract country groups (`eu`, `japan`, `korea`, `swiss`) to concrete Census
country codes. Used when resolving `country_group` references in layer 4.

| Column | Type |
|---|---|
| `country_group` | varchar |
| `country` | varchar |

**Cardinality**: ~35 rows (EU has 27, others have 1-2 each).

## On-disk layout

```
output/normalized/
  revisions.parquet                    # layer 5 (all revisions in one file)
  product_metal_content.parquet         # supporting (static)
  country_group_membership.parquet      # supporting (static)
  {revision}/
    products_base.parquet               # layer 1
    authority_country_rates.parquet     # layer 2
    authority_product_applicability.parquet  # layer 3
    authority_exemptions.parquet        # layer 4
```

Layers 1-4 partition by revision, mirroring the existing rate dataset convention.
Layer 5 and the supporting tables are singleton files.

## Query pattern (single date lookup)

Given `(:hts10, :country, :date)`:

1. Lookup revision from layer 5.
2. Fetch layer 1 row for `(hts10, revision)` → base_rate, specific-rate metadata.
3. Fetch all matching layer 3 rows for `(revision, hts10)` via the match rule.
   Group by `authority`, pick highest-precedence row per authority (tiebreak:
   explicit hts10 > longest hts_prefix > blanket).
4. For each layer-3 winner, join to layer 2 on `(authority, program, country)`
   to get the country-specific statutory rate (if layer-3 rate is null) or use
   layer-3's rate directly.
5. Apply layer-4 exemptions: compound `exemption_share` over matching rows, apply
   `rate_override` if present, zero out if any full exemption matches.
6. Join `product_metal_content` for scaled rates: multiply `statutory_rate` by the
   field named in `scaling_dimension`.
7. Pass the resulting per-authority rates + `deriv_type` into the same stacking
   engine as today (`apply_stacking_rules`) to get `total_additional` and
   `total_rate`.

Result: a struct matching `RATE_SCHEMA`. For the CZ + 8543.70.9860 + 2025-03-14
example: layer 1 returns `base_rate = 0.026`, layer 3 returns only the
`ieepa_recip_blanket` row (no steel/auto/s301 matches), layer 2 has no
`ieepa_recip_blanket + country=CZ + rev_6` row (CZ wasn't IEEPA-listed yet), so
no authority rate is produced. Stacking returns `total_additional = 0`,
`total_rate = 0.026`. **Correct without any read-side heuristic.**

## Decisions and open questions

**D1. Why `statutory_rate` can be null in layer 3.**
Blanket authorities (IEEPA recip, s122) don't have a product-specific rate — the
rate is country-specific and lives in layer 2. Layer 3 just asserts coverage.
Query logic must `COALESCE(apa.statutory_rate, acr.statutory_rate)`.

**D2. `hts_prefix` vs fully-materialized `hts10` lists.**
For S301 buckets (products enumerated by HS8 in a CSV), we prefer `hts_prefix`
to keep row count low. For the steel/alum blanket that covers entire chapters,
`hts_prefix = '72'` is a single row instead of ~2000. Fully-materialized per-hts10
rows are reserved for the derivative CSV lists, where the mapping is inherently
per-product.

**D3. Metal content table is `hts10`-only, not per-revision.**
The assumption is that BEA metal content is a physical property. If metal
restatements ever ship, add `revision` as a second PK column and query the latest
row at-or-before the requested revision. Keep the single-column PK for now.

**D4. `precedence` defaults to 1; carve-outs use 10.**
Explicit integer scale rather than an enum. Future exotic programs can slot in at
5 or 15 without requiring enum schema migration.

**D5. Fentanyl carve-outs as precedence, USMCA auto rebate as layer 4.**
Fentanyl CA energy gets a *different rate* (10% vs 35%) — modeled as a separate
layer-3 program row with higher precedence. USMCA auto content rebate is a
*reduction* of the statutory 232 rate — modeled as layer-4 `auto_usmca_rebate`
with `rate_override` or `exemption_share`. Both mechanics are supported; use the
one that's structurally closer to the legal text.

**D6. Open — deriv_type tiebreak when steel and aluminum derivatives both match.**
Current pipeline says steel wins. Encode as a hardcoded rule in the stacking
engine, or via `precedence` on the steel_deriv row. Decide during prototype.

**D7. Open — `base_rate` vs `statutory_base_rate` in layer 1.**
The denormalized pipeline's `base_rate` is preference-share-adjusted; its
`statutory_base_rate` is the raw HTSUS Column 1 General. For a point-lookup that
needs to answer "what would CBP assess on a shipment that doesn't claim FTA
preference," `statutory_base_rate` is correct. For weighted-average analytics,
`base_rate` is correct. Layer 1 carries both columns so downstream consumers pick
the right one. Phase 1 synthesis already picks statutory.

## Migration path (condensed — see plan file for full phases)

| Phase | Deliverable | Depends on |
|---|---|---|
| 2a | This document | — |
| 2b | `src/07_emit_normalized.R` dual-write emitter | 2a |
| 2c | `tests/test_normalized_parity.R` parity harness | 2b |
| 2d | `src/resolve_rate_normalized.R` query engine | 2a |
| 3  | Server `/api/rates` cutover via feature flag | 2b+2c+2d |
| 4  | Pipeline cleanup — remove dead code | 3 (stable for 1+ release) |
| 5  | Historical ingest (2018-2024) | 4 |

Phase 2b is **additive**: the emitter writes the normalized parquets alongside
the existing denormalized output. Nothing reads the new files yet. Phase 3 is
where risk concentrates, gated by a feature flag and parity-clean harness runs.

---

## Addendum (2026-04-14) — Decisions resolved during Phase 2b implementation

This addendum supersedes any conflicting language in the D1–D7 section above.
It is referenced from the `docs/adrs/001-denorm-state-pattern.md` ADR and from
the `tests/ir/parity-cases.md` edge catalog.

### D-resolutions

| # | Original question | Resolution |
|---|---|---|
| **D5** | Auto USMCA rebate: layer-3 rate override or layer-4 exemption share? | **Split.** The flat `rebate_deduction = pp$auto_rebate$rebate_rate * pp$auto_rebate$us_assembly_share` (country-agnostic) is **baked into layer-3 `statutory_rate`** on every auto / passenger / light_truck heading row for products in `denorm_state$auto_products`. The CA/MX-only USMCA content factor `(usmca_share * us_auto_content_share)` is **layer-4** as `exemption_type='usmca_auto_content'`. Reason: country-deal floor rows at precedence 10 REPLACE (not compound) the layer-3 rate; a layer-4 rebate would incorrectly multiply the replaced value. Bake eliminates the composition problem. |
| **D6** | Derivative + heading overlap `pmax(heading_rate, deriv_rate)` | **Layer-3 hts10-specific override at precedence 7.** Beats the prefix derivative row at precedence 5, loses to country-deal rows at precedence 10. The statutory_rate is captured from the post-step-5 `rates` tibble in `apply_232_derivatives`, so the `pmax` formula lives in exactly one place. `scaling_dimension = 'none'` prevents the resolver from applying metal scaling. |
| **D7** | `base_rate` vs `statutory_base_rate` in layer 1 | **Layer 1 carries `base_rate`** (pre-MFN adjustment, the HTSUS Column 1 General rate). The resolver applies MFN exemption shares (from `mfn_exemption_shares.parquet`) and per-product USMCA shares (from layer 4) to `base_rate` at query time, producing the same value the denorm pipeline stores. `statutory_base_rate` is preserved as the pre-adjustment value on the wide tibble for downstream consumers who need it. |

### New schema additions (not in the original layer tables above)

**Layer 1 `products_base.parquet`** — new column:

| Column | Type | Notes |
|---|---|---|
| `s232_annex` | varchar, nullable | Annex classification (`annex_1a`, `annex_1b`, `annex_2`, `annex_3`) for post-2026-04-06 revisions. Populated from `denorm_state$product_annex`. Read by the resolver and forwarded to `apply_stacking_rules` so the post-annex `nonmetal_share = 0` override fires uniformly across both code paths. Pre-annex revisions: every row NA. |

**Layer 3 `authority_product_applicability.parquet`** — new columns:

| Column | Type | Notes |
|---|---|---|
| `country_scope` | varchar, nullable | `|`-delimited census code list scoping the row to specific countries. NA = all countries eligible. Used by S301 (China-only) and S232 country deals. The resolver splits on `|` and short-circuits for non-matching countries before applying any rate. |
| `rate_type` | enum, nullable | `surcharge \| floor \| passthrough` semantics. NA = use `statutory_rate` verbatim (default). For `floor`, the resolver computes `max(0, statutory_rate - base_rate)`. Used by S232 country deal floor rows. Same semantics as the layer-2 `rate_type` column. |

**Precedence tiers** (layer 3 `precedence` column):

| Precedence | Source | Notes |
|---|---|---|
| 1 | blanket authority (S232 steel/aluminum base, IEEPA recip blanket, S122 blanket, fent general) | Default |
| 5 | S232 derivative prefix rows | Metal-scaled |
| 7 | Heading + derivative overlap override | Per-hts10, `scaling_dimension='none'`, statutory_rate pre-computed as `pmax(heading_rate, deriv_rate)` |
| 10 | Country-scoped deals (S301 list buckets, S232 country deal floors/surcharges) + fentanyl carveouts | Highest priority, replaces lower tiers when country_scope matches |

**Layer 4 `authority_exemptions.parquet`** — `exemption_type` enum additions:

| Value | Semantics |
|---|---|
| `annex_a` | Full exemption (share = 1) for Annex A products from IEEPA reciprocal |
| `floor_country` | Full exemption for floor-country product-specific carve-outs |
| `usmca_eligible` | Fractional exemption using the per-`(hts10, country)` USMCA utilization share. Emitted for `ieepa_reciprocal`, `ieepa_fentanyl`, and `section_122`. The resolver ALSO reads the `ieepa_reciprocal` row to reduce `base_rate` by the same share. |
| `usmca_auto_content` | Fractional exemption at `share = usmca_share * us_auto_content_share`, restricted to `section_232` on products in `auto_products ∪ mhd_products`. Compounds multiplicatively with (nothing else currently; see D5). |
| `auto_assembly_rebate` | **Historical / deprecated.** Phase 2b originally emitted this; the refactor baked the rebate into layer-3 statutory_rate. New emissions will not write this type. Readers should tolerate its absence. |
| `s122_exempt_hts8` | Full exemption for HTS8 prefixes in `s122_exempt_products.csv` |
| `duty_free_treatment` | Reserved |
| `column2_override` | Reserved |

### `denorm_state` contract (the emitter's input)

The emitter consumes a single `denorm_state` list captured by
`calculate_rates_for_revision` right before the emit call. Every slot has a
named producer in the denorm pipeline and one or more named consumers in the
emitter. See `docs/adrs/001-denorm-state-pattern.md` for the architectural
rationale.

| Slot | Producer | Consumers | Shape |
|---|---|---|---|
| `country_ieepa` | Post-baseline fill in the IEEPA block | `emit_authority_country_rates` | Tibble with `census_code`, `ieepa_country_rate`, `ieepa_type`, optional `ch99_code` |
| `s232_deals` | Step 4c auto/wood deal loops | `emit_authority_product_applicability` | List of `list(program, census_codes, deal_products, rate, rate_type)` |
| `auto_products` | Step 4 heading matching, post-blanket-chapter-exclusion | `emit_authority_product_applicability`, `emit_authority_exemptions` | Character vector of HTS10 |
| `mhd_products` | Step 4 heading matching | `emit_authority_exemptions` | Character vector of HTS10 |
| `wood_softwood_products` | Step 4 heading matching | reserved (future wood deal expansion) | Character vector |
| `wood_furn_products` | Step 4 heading matching | reserved | Character vector |
| `s122` | Post in-force gate in step 6b | `emit_authority_country_rates`, `emit_authority_product_applicability`, `emit_authority_exemptions` | `list(in_force: bool, rate: numeric, exempt_hts8: chr)` |
| `heading_overlap` | End of `apply_232_derivatives` | `emit_authority_product_applicability` | Tibble `(hts10, rate_232, deriv_type)` with post-`pmax` values |
| `product_annex` | End of annex classification block | `emit_products_base` | Distinct `(hts10, s232_annex)` pairs |

**Invariant.** `src/denorm_state_contract.R::validate_denorm_state(ds)` is
called as a postcondition of `calculate_rates_for_revision` and asserts every
slot is present with the expected shape. Missing slots fail the build loudly
rather than silently emitting incomplete layers.

### Static parquet additions (next to `output/normalized/`)

| File | Producer | Consumer | Purpose |
|---|---|---|---|
| `mfn_exemption_shares.parquet` | `emit_normalized_statics` | Resolver `base_rate` reduction | Per-`(hs2, cty_code)` FTA/GSP preference erosion shares. Mirrors `load_mfn_exemption_shares()` from `helpers.R`. Populated only when `pp$MFN_EXEMPTION$method == 'hs2'`; CA/MX rows filtered out when `exclude_usmca_countries = TRUE` (the default) so layer-4 USMCA shares own the CA/MX reduction. |

