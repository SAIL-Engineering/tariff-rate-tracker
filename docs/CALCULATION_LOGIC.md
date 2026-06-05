# Duty Calculation Logic

This document provides a transparent, step-by-step breakdown of how duties are computed in the `tariff-rate-tracker` repository. It is designed to be auditable for correctness and simple to update if tariff regulations or data structures change.

For the full policy methodology, modeling assumptions, and benchmark comparisons, see [methodology.md](methodology.md). For build instructions and pipeline execution, see [build.md](build.md).

---

## Table of Contents

1. [Data Provenance](#1-data-provenance)
2. [Data Transformation Pipeline](#2-data-transformation-pipeline)
3. [Mathematical Logic](#3-mathematical-logic)
4. [Frontend Calculation Engine](#4-frontend-calculation-engine)
5. [Building and Updating](#5-building-and-updating)
6. [Code Reference Index](#6-code-reference-index)

---

## 1. Data Provenance

### 1.1 HTS JSON Archives (Primary Source)

All tariff rates originate from **USITC Harmonized Tariff Schedule JSON archives**, the machine-readable form of the official U.S. tariff schedule.

| Attribute | Value |
|---|---|
| Publisher | U.S. International Trade Commission (USITC) |
| URL pattern | `https://www.usitc.gov/sites/default/files/tata/hts/hts_{year}_{revision}_json.json` |
| Download script | [`src/02_download_hts.R`](../src/02_download_hts.R) |
| Local storage | `data/hts_archives/hts_{year}_{revision}.json` |
| Revision discovery | USITC REST API at `hts.usitc.gov/reststop/releaseList`, scraped by [`src/01_scrape_revision_dates.R`](../src/01_scrape_revision_dates.R) |

Each JSON archive is an array of items. The fields extracted per item are:

| JSON Field | Content | Used By |
|---|---|---|
| `htsno` | HTS code (e.g., `"0201.20.06.00"`) | Product identification |
| `description` | Article description | Display, country-applicability parsing (Ch99) |
| `general` | Column 1 General rate text (e.g., `"4.4¢/kg"`, `"17%"`, `"Free"`) | MFN base rate + rate basis classification |
| `special` | Column 1 Special rate text with program codes (e.g., `"Free (A+,AU,BH,CL)"`) | Preferential rate tiers |
| `other` | Column 2 rate text (e.g., `"25%"`, `"13.2¢/kg"`) | Column 2 rates (Cuba, DPRK, Belarus, Russia) |
| `indent` | Indent level in HTS hierarchy | Rate inheritance for statistical suffixes |
| `footnotes` | List of footnote objects | Chapter 99 cross-references |
| `units` | Statistical reporting units (e.g., `["No.", "kg"]`) | Statistical reporting (nonlegal per USITC preface) |

### 1.2 Policy Configuration

| Input | Path | Role |
|---|---|---|
| Policy parameters | [`config/policy_params.yaml`](../config/policy_params.yaml) | All hardcoded constants: country codes, authority classification ranges, Section 232 programs, IEEPA floor rates, auto rebate parameters, USMCA settings |
| Revision schedule | [`config/revision_dates.csv`](../config/revision_dates.csv) | Maps each HTS revision to its effective date and optional policy effective date |

### 1.3 Committed Resource Files

These are maintained in `resources/` and provide coverage lists that cannot be reliably extracted from the HTS JSON alone:

| File | Content | Refresh Method |
|---|---|---|
| `census_codes.csv` | Census Bureau country codes | Manual |
| `s301_product_lists.csv` | Section 301 China-specific product coverage | `src/scrape_us_notes.R` |
| `s232_derivative_products.csv` | Section 232 derivative products (568 HTS8 prefixes) | Manual / Federal Register |
| `s232_copper_products.csv` | Copper 232 coverage (80 HTS8 prefixes) | `src/scrape_us_notes.R --copper` |
| `ieepa_exempt_products.csv` | IEEPA reciprocal exemptions (Annex A / US Note 2) | `src/expand_ieepa_exempt.R` |
| `s122_exempt_products.csv` | Section 122 Annex II exemptions | Manual |
| `usmca_product_shares_{year}.csv` | Product-level USMCA utilization shares | `src/download_usmca_dataweb.R` |
| `mfn_exemption_shares.csv` | Effective MFN base-rate adjustment (FTA/GSP utilization) | Source trade data |
| `metal_content_shares_bea_hs10.csv` | Per-type metal content (steel/aluminum/copper) for derivative 232 scaling | BEA I-O workflow |

#### General-Note program / country reference data (de-hardcoded)

These drive the frontend's rate-tier and preference-program logic (see [§4.1](#41-rate-tier-selection)). The `gn*` files are **generated and incremental** — extracted per revision from the HTS General Notes by `src/parse_general_note_3.R` (build-wired under `SAIL_EMIT_GN3`); `fta_partners.csv` and `country_name_aliases.csv` are reviewed reference data in the same category as `census_codes.csv`.

| File | Content | Refresh Method |
|---|---|---|
| `gn3_program_symbols.csv` | Special-program symbol → program name (GN 3(c)(i)), per revision | `src/parse_general_note_3.R` (generated) |
| `gn3_column2_countries.csv` | Column 2 (non-NTR) country list (GN 3(b)), per revision | `src/parse_general_note_3.R` (generated) |
| `gn_program_countries.csv` | GSP/AGOA/CBERA beneficiary lists (GN 4/16/7) → census code | `src/parse_general_note_3.R` (generated) |
| `fta_partners.csv` | FTA partner → census code + HTS Special symbols (USMCA, CPTPP, IL, CL, …) | Reviewed; changes by treaty |
| `country_name_aliases.csv` | Reviewed GN-name → census-code spelling/long-form variants | Reviewed |

### 1.4 What Is NOT a Source

- **TPC benchmarks** and **Tariff-ETRs** are comparison/validation tools, not production inputs.
- **Import weights** are optional; they produce weighted ETR outputs but do not affect the rate panel.

---

## 2. Data Transformation Pipeline

The pipeline runs as a sequence of numbered R scripts, orchestrated by [`src/00_build_timeseries.R`](../src/00_build_timeseries.R). Each HTS revision is processed independently.

### 2.1 Overview

```
HTS JSON Archive
     │
     ├─→ Step 02: Download         → data/hts_archives/hts_{year}_{rev}.json
     │
     ├─→ Step 03: Parse Chapter 99 → chapter 99 rates, authorities, country applicability
     │
     ├─→ Step 04: Parse Products   → base rates, special/column 2 tiers, rate basis,
     │                                duty basis units, statistical reporting units
     │
     ├─→ Step 05: Parse Policy     → IEEPA country rates, USMCA eligibility,
     │                                Section 232/301 programs
     │
     └─→ Step 06: Calculate Rates  → product × country rate matrix with all authorities
              │
              └─→ enforce_rate_schema() → canonical output columns
                       │
                       └─→ Parquet (via scripts/combine_snapshots.R) → DuckDB → frontend
```

### 2.2 Step 03: Chapter 99 Parsing

**File:** [`src/03_parse_chapter99.R`](../src/03_parse_chapter99.R), function `parse_chapter99()`

Extracts additional-duty entries from Chapter 99 of the HTS JSON:

1. **Rate extraction**: Parses the `general` field (fallback to `other`) using `parse_ch99_rate()` in [`src/helpers.R`](../src/helpers.R). Recognizes patterns: `+ 25%`, `plus 25%`, `a duty of 50%`, bare `25%`.

2. **Authority classification**: Uses `classify_authority()` in `helpers.R` to map 9903.xx.xx subheadings to authorities:

   | Subheading Range | Authority |
   |---|---|
   | 9903.03.xx | Section 122 |
   | 9903.40–45.xx | Section 201 |
   | 9903.74.xx, 9903.76.xx, 9903.78.xx, 9903.80–85.xx, 9903.94.xx | Section 232 |
   | 9903.86–89.xx, 9903.91.xx, 9903.92.xx | Section 301 |
   | 9903.01.01–01.24 | IEEPA Fentanyl |
   | 9903.01.25–01.75, 9903.02.xx | IEEPA Reciprocal |

3. **Country applicability**: Parses the `description` field to determine which countries are covered:
   - `specific`: Named countries only (e.g., "product of China")
   - `all`: Blanket (all countries)
   - `all_except`: All countries except listed exclusions

### 2.3 Step 04: Product Parsing

**File:** [`src/04_parse_products.R`](../src/04_parse_products.R), function `parse_products()`

Extracts per-product data for each valid 10-digit HTS code:

1. **MFN base rate** from `general` field via `parse_rate()` — returns numeric for simple ad valorem and "Free"; returns NA for specific/compound (flagged as `has_complex_rate`).

2. **Rate basis classification** via `parse_rate_extended()` — returns structured data: `{type, ad_valorem_pct, specific_amount, specific_rate_unit, raw}`. Types: `ad_valorem`, `specific`, `compound`, `free`, `unknown`.

3. **Special rate tiers** via `parse_special_programs_multi()` — handles multiple sub-rate groups in the `special` field (e.g., `"Free (BH,CL) 1.7% (KR) See 9822.04.01 (AU)"`).

4. **Column 2 rates** via `parse_rate_extended()` on the `other` field.

5. **Statistical reporting units** from the `units` array — split into `reported_unit_1` and `reported_unit_2`. These are **nonlegal statistical elements** per the USITC preface and do NOT by themselves drive duty calculation.

6. **Duty basis unit** derived from the legal rate expression (e.g., `"kg"` from `"30.5¢/kg + 8.5%"`). This is the unit that enters the duty math for specific/compound rates. It is null for ad valorem rates because quantity does not drive duty.

7. **Rate inheritance + provenance**: ~59% of HTS10 products are statistical suffixes with empty rate fields. These inherit from the nearest rate-bearing parent in the indent hierarchy (tracked via `htsno_stack`). The `base_rate_source` column records where each base rate came from — `'own'` (the line carries its own rate), `'inherited:<parent_htsno>'` (inherited from the named parent), or `'unresolved'` (neither) — so inheritance is auditable. It backs rate-validation invariant Q4 (see [data-pipeline-README.md §8](data-pipeline-README.md#8-quality-report)).

8. **19 CFR 159.3 rounding rule** assigned via `determine_rounding_rule()`:

   | Rate Basis | Rounding Rule |
   |---|---|
   | Ad valorem / Free | `19cfr159.3_value` |
   | Specific ≤ $1/unit | `19cfr159.3_specific_lte1` |
   | Specific > $1/unit | `19cfr159.3_specific_gt1` |
   | Compound ≤ $1/unit | `19cfr159.3_compound_lte1` |
   | Compound > $1/unit | `19cfr159.3_compound_gt1` |

### 2.4 Step 06: Rate Calculation

**File:** [`src/06_calculate_rates.R`](../src/06_calculate_rates.R), function `calculate_rates_for_revision()`

This is the core rate-building step. It constructs the product × country rate matrix through the following sub-steps:

#### Sub-step 1: Footnote-Linked Rates

Calls `calculate_rates_fast()` to link products to Chapter 99 entries via footnote references. This covers Section 232, 301, fentanyl, Section 201, and other product-specific Ch99 duties.

#### Sub-step 1b: IEEPA Invalidation Gate

If the revision's `effective_date` >= `IEEPA_INVALIDATION_DATE` (configured in `policy_params.yaml`; currently 2026-02-24 per the SCOTUS ruling), IEEPA reciprocal and fentanyl rates are zeroed out.

#### Sub-step 2: IEEPA Reciprocal Tariff

IEEPA is a **blanket tariff** — it applies to ALL products for covered countries (not footnote-linked).

- **Phase stacking**: Phase 2 rates stack across phases; within a phase, country-specific entries supersede group entries, and the max within-phase rate is taken.
- **Floor treatment**: For floor countries (EU-27, Japan, Korea, Switzerland, Liechtenstein):
  ```
  rate_ieepa_recip = max(0, floor_rate − base_rate)
  ```
  The floor deduction uses the effective (post-MFN-exemption) `base_rate`, not the statutory MFN rate.
- **Surcharge treatment**: For surcharge countries:
  ```
  rate_ieepa_recip = ieepa_country_rate
  ```
- **Product exemptions**: Annex A / US Note 2 exempt products and country-specific carve-outs are zeroed.

#### Sub-step 3: IEEPA Fentanyl Tariff

Applies fentanyl surcharges from 9903.01.01–24 entries:
- Canada: +35% (except energy/minerals at +10%, potash at +10%)
- Mexico: +25% (except potash at +10%)
- China: +10%

#### Sub-step 4: Section 232

Applies through a mix of blanket chapter coverage, heading/prefix coverage, and product lists:
- **Steel** (chapters 72–73): 25%
- **Aluminum** (chapter 76): 25%
- **Autos** (heading 8703+): 25%
- **Copper** (chapter 74 headings): 50%
- **Country exemptions**: Pre-March 2025 TRQ agreements (rate = 0, expired 2025-03-12); Russia 200% override.
- **Auto rebate**: `rate_232 = max(0, rate_232 − rebate_rate × us_assembly_share)` where `rebate_rate = 3.75%`, `us_assembly_share = 33%`.
- **Deal rates** (EU/Japan/Korea/UK): Floor mechanism `max(0, floor_rate − base_rate)` or surcharge override.

#### Sub-step 5: Section 232 Derivatives + Metal Scaling

**Function:** `apply_232_derivatives()` within `06_calculate_rates.R`

Products outside primary metal chapters but containing metal content (568 HTS8 derivative products):
- Statutory rate preserved: `statutory_rate_232 = rate_232`
- Scaled by per-type metal content: `rate_232 *= {steel_share | aluminum_share | copper_share}`
- Heading products (auto parts, copper headings) use full product value, not metal-scaled.

#### Sub-step 6a: Section 301 (China)

China-specific tariffs from US Note 20/21/31. Coverage driven by `resources/s301_product_lists.csv`. For products mapping to multiple active 301 entries, the **maximum rate** is taken (supersession, not additive).

#### Sub-step 6b: Section 122

Post-IEEPA blanket authority. 10% rate on all imports (9903.03.01), subject to Annex II exemptions. Active only within its statutory window.

#### Sub-step 6c: MFN Exemption Shares

Adjusts `base_rate` using FTA/GSP preference utilization at HS2 × country level:
```
base_rate = base_rate × (1 − exemption_share)
```
IEEPA floor rates are recomputed after this adjustment.

#### Sub-step 7: USMCA Exemptions

For Canada and Mexico, product-level USMCA utilization shares reduce all applicable rates:
```
rate_reduced = rate × (1 − usmca_share)
```
Auto/MHD products scale differently: `(1 − usmca_share × us_auto_content_share)`.

#### Sub-step 8: Stacking Rules

Recomputes `total_additional` and `total_rate` via `apply_stacking_rules()` (see [Section 3.1](#31-authority-stacking-mutual-exclusion)).

#### Sub-step 9: Finalization

- Adds revision metadata and effective date.
- Joins rate tier columns from products (special, column 2, duty basis, quantity relevance, rounding rules).
- Serializes special program entries to JSON for Parquet compatibility.
- Enforces canonical schema via `enforce_rate_schema()`.

### 2.5 Time Series Construction

**File:** [`src/00_build_timeseries.R`](../src/00_build_timeseries.R)

Per-revision snapshots are combined into an interval-encoded panel:

```
valid_from  = revision's effective_date
valid_until = next revision's effective_date − 1 day
              (final revision extends to series_horizon.end_date)
```

### 2.6 Parquet Dataset Generation

**File:** [`scripts/combine_snapshots.R`](../scripts/combine_snapshots.R)

Reads RDS snapshots, applies `enforce_rate_schema()` (backfills missing columns for old snapshots), joins temporal intervals, and writes per-revision Parquet files partitioned by `revision=` under `data/timeseries/rate_timeseries_parquet/`. Compression: zstd level 3.

The frontend Express server ([`frontend/server.js`](../frontend/server.js)) loads these via DuckDB `read_parquet()` with hive partitioning.

---

## 3. Mathematical Logic

### 3.1 Authority Stacking (Mutual Exclusion)

**Implementation:** `apply_stacking_rules()` in [`src/helpers.R`](../src/helpers.R)

The default production rule is `mutual_exclusion`. Section 232 takes precedence over IEEPA-based authorities on the metal-covered portion of a product.

**For China with Section 232 (`country == '5700'`, `rate_232 > 0`):**

```
total_additional = rate_232
                 + (rate_ieepa_recip × nonmetal_share)
                 + rate_ieepa_fent
                 + rate_301
                 + (rate_s122 × nonmetal_share)
                 + rate_section_201
                 + rate_other
```

Fentanyl stacks in full for China (not scaled by metal share).

**For China without Section 232:**

```
total_additional = rate_ieepa_recip + rate_ieepa_fent + rate_301
                 + rate_s122 + rate_section_201 + rate_other
```

**For non-China countries with Section 232:**

```
total_additional = rate_232
                 + (rate_ieepa_recip × nonmetal_share)
                 + (rate_ieepa_fent × nonmetal_share)
                 + (rate_s122 × nonmetal_share)
                 + rate_section_201
                 + rate_other
```

Fentanyl follows the same content-based split as IEEPA reciprocal for non-China countries.

**For non-China countries without Section 232:**

```
total_additional = rate_ieepa_recip + rate_ieepa_fent
                 + rate_s122 + rate_section_201 + rate_other
```

**In all cases:**

```
total_rate = base_rate + total_additional
```

### 3.2 Metal Share and Nonmetal Share

For products with metal content (Section 232 derivatives):

```
nonmetal_share = 1 − active_type_share    (if rate_232 > 0 and metal product)
               = 0                         (otherwise)
```

Where `active_type_share` is determined by product classification:

| Product Type | `active_type_share` |
|---|---|
| Steel chapters (72, 73) | `steel_share` |
| Aluminum chapters (76) | `aluminum_share` |
| Copper headings | `copper_share` |
| Steel derivatives (outside 72–73) | `steel_share` |
| Aluminum derivatives (outside 76) | `aluminum_share` |
| Other derivative (fallback) | `aluminum_share` |

IEEPA reciprocal, fentanyl (non-China), and Section 122 are then applied only to the nonmetal portion. Section 232 covers the metal portion.

### 3.3 IEEPA Floor Deduction

For floor countries (EU-27, Japan, Korea, Switzerland, Liechtenstein):

```
rate_ieepa_recip = max(0, floor_rate − base_rate)
```

The deduction uses the **effective** `base_rate` (post-MFN-exemption), not the statutory MFN rate. FTA preferences widen the floor gap: if statutory MFN is 5% but effective base is 0.5%, then `rate_ieepa_recip = max(0, 0.15 − 0.005) = 14.5%`.

### 3.4 USMCA Exemption Scaling

For Canada and Mexico:

```
rate = rate × (1 − usmca_share)
```

For auto/MHD products:

```
rate_232 = rate_232 × (1 − usmca_share × us_auto_content_share)
```

Where `us_auto_content_share = 0.40` (from `policy_params.yaml`).

### 3.5 Auto Rebate (Section 232)

```
rate_232 = max(0, rate_232 − rebate_rate × us_assembly_share)
         = max(0, rate_232 − 0.0375 × 0.33)
         = max(0, rate_232 − 0.01238)
```

### 3.6 Rate Basis and Quantity in Duty Calculation

**Critical design principle:** In the U.S. HTSUS, `unit_of_quantity` is modeled as a statistical reporting field, not a duty-calculation field. Duty calculation is driven by the parsed legal rate expression and any controlling legal notes. Quantity enters the duty math only when the applicable duty component is specific or compound, and then only in the legally relevant unit with 19 CFR 159.3 rounding applied.

| Rate Basis | Duty Formula | Quantity Role |
|---|---|---|
| `ad_valorem` | `duty = roundedValue × percent` | Quantity NOT relevant for duty math |
| `specific` | `duty = roundedQty × specificAmount` | Quantity in `duty_basis_unit` (from rate text) drives calculation |
| `compound` | `duty = (roundedQty × specificAmount) + (roundedValue × percent)` | Both quantity and value used |
| `free` | `duty = 0` | Not applicable |

The `duty_basis_unit` comes from the legal rate expression (e.g., `"kg"` from `"30.5¢/kg + 8.5%"`), NOT from the statistical reporting `reported_unit_1`/`reported_unit_2`.

### 3.7 Statutory vs. Effective Base and Totals

The panel carries two base columns: `statutory_base_rate` (Column 1-General MFN, before any preference utilization) and `base_rate` (effective, after the MFN/FTA/GSP exemption-share adjustment in [§2.4 sub-step 6c](#24-step-06-rate-calculation)). Additional duties stack on the **effective** base, but the IEEPA floor deduction is recomputed against it, so the choice of base propagates into the floor (see [§3.3](#33-ieepa-floor-deduction)).

The daily aggregator (`src/09_daily_series.R`) reports both perspectives: the effective (preference-weighted) mean total, and `mean_total_statutory_all_pairs` — the conservative per-shipment total built on the statutory base plus additionals, defensible as the Column 1-General worst case when preference utilization is unknown.

---

## 4. Frontend Calculation Engine

**File:** [`frontend/src/utils/tariffCalculator.ts`](../frontend/src/utils/tariffCalculator.ts)

### 4.1 Rate Tier Selection

`selectApplicableBaseRate(rate, countryCode)` determines which Column 1/2 rate to use:

1. **Column 2 countries** (e.g. Cuba `2390`, DPRK `5790`, Belarus `4622`, Russia `4621`): use `rate_column2`
2. **Special programs**: If country code matches a program code in `special_programs_json`, use the special rate
3. **All others**: use `base_rate` (Column 1 General / MFN)

The Column 2 country set and the program-symbol → program map are **no longer hardcoded constants** — they are generated per revision from the HTS General Notes into `program_symbols.json` / `program_countries.json` (the codes above are illustrative; the authoritative, revision-aware list is the bundle). See [PROVENANCE_PIPELINE.md](PROVENANCE_PIPELINE.md) Path C and [§1.3](#13-committed-resource-files).

### 4.2 19 CFR 159.3 Rounding Rules

**Ad valorem — value rounding** (`roundValuePer19CFR159_3`):

```
if (fraction < $0.50) → round down to even dollar
if (fraction ≥ $0.50) → round up to next dollar
```

**Specific duty — quantity rounding** (`roundQuantityPer19CFR159_3`):

```
if specific_rate > $1/unit:
    exact quantity, fraction to 2 decimal places

if specific_rate ≤ $1/unit:
    if fractional_qty < 0.5 → disregard fraction (round down)
    if fractional_qty ≥ 0.5 → treat as whole unit (round up)
```

### 4.3 Base Duty Calculation

```typescript
// Ad valorem (default) or free
duty = roundValuePer19CFR159_3(customsValue) × effectiveBaseRate

// Specific
duty = specificAmount × roundQuantityPer19CFR159_3(quantity, specificAmount)

// Compound
specificPart = specificAmount × roundQuantityPer19CFR159_3(quantity, specificAmount)
avPart       = roundValuePer19CFR159_3(customsValue) × effectiveBaseRate
duty         = specificPart + avPart
```

### 4.4 Additional Duties (Chapter 99) — Mutual Exclusion Stacking

Chapter 99 duties are computed with **mutual-exclusion stacking**, ported from the R backend (`apply_stacking_rules()` in `src/helpers.R`). Section 232 takes precedence on the metal portion of a product; IEEPA reciprocal, fentanyl (non-China), and Section 122 apply only to the non-metal portion.

**`computeNonmetalShare(rate)`** determines the non-metal fraction based on HTS chapter and per-type metal shares (`steel_share`, `aluminum_share`, `copper_share`, `deriv_type`). Returns 0 when 232 is inactive or the product is pure metal.

**`computeNetAuthorityAmounts(rate, countryCode)`** applies the four-branch stacking formula:

| Scenario | Formula |
|----------|---------|
| China + 232 active | `232 + recip × nonmetal + fent + 301 + s122 × nonmetal + s201 + other` |
| China, no 232 | `recip + fent + 301 + s122 + s201 + other` |
| Others + 232 active | `232 + recip × nonmetal + fent × nonmetal + s122 × nonmetal + s201 + other` |
| Others, no 232 | `recip + fent + s122 + s201 + other` |

**US Content Carveout (EO 14257):** When the user enters >= 20% US content, the IEEPA reciprocal dutiable base is reduced to `customsValue × (1 - usContentPercent)`.

**Authority trigger detection** (`detectAuthorityTriggers()`) determines what extra data each active authority requires:

| Condition | Mode | Fields |
|-----------|------|--------|
| 232 steel derivative (9903.81.91) | `METAL_CONTENT_VALUE_AND_KG` | Steel content value ($), weight (kg) |
| 232 aluminum derivative (9903.85.08) | `METAL_CONTENT_VALUE_AND_KG` | Aluminum content value ($), weight (kg), smelt/cast countries |
| 232 copper heading | `VALUE_ONLY` | Copper content value ($) |
| IEEPA reciprocal active | `US_CONTENT_VALUE` (optional) | US content % or $ value |

### 4.5 Customs Fees

Customs fees are distinct from customs duties and excise taxes. CBP collects all three at import, but they are separate liabilities.

**Merchandise Processing Fee (MPF)** — all transport modes:

```
mpf = clamp(customsValue × 0.3464%, min = $33.58, max = $651.50)
```

**Harbour Maintenance Fee (HMF)** — ocean freight only:

```
hmf = customsValue × 0.125%
```

### 4.6 Landed Cost

```
landedCost = customsValue + totalDuty + mpf + hmf + freight + insurance
```

Where:
```
totalDuty = baseDuty + additionalDuty
```

---

## 5. Building and Updating

For detailed step-by-step instructions, command reference, and troubleshooting, see **[pipeline-operations.md](pipeline-operations.md)**.

### 5.1 Full Build

```bash
Rscript src/00_build_timeseries.R --full
```

This re-runs all pipeline stages for every HTS revision. Each revision is processed independently, then all snapshots are batch-written to partitioned Parquet (one at a time, never all in RAM). Downstream scripts (daily aggregation, frontend data export) run automatically unless `--build-only` is passed.

### 5.2 Updating for a New HTS Revision

```bash
# 1. Discover new revisions via the USITC API
Rscript src/01_scrape_revision_dates.R

# 2. Manually review config/revision_dates.csv — set correct effective_date,
#    policy_event, and clear the needs_review flag

# 3. Download the new JSON archive
Rscript src/02_download_hts.R --year 2026

# 4. Rebuild (incremental + Parquet + frontend data)
Rscript src/00_build_timeseries.R

# 5. Restart the frontend API server to pick up new Parquet
cd frontend && node server.js
```

The build produces partitioned Parquet directly — `scripts/combine_snapshots.R` is no longer a separate required step (it is embedded in the build). It remains available as a standalone script for manual re-generation.

**Important:** The USITC API returns *publication dates*, not policy effective dates. New revisions are marked `[REVIEW]` in `config/revision_dates.csv` with `needs_review = TRUE`. The build refuses to run until this is resolved. See [pipeline-operations.md](pipeline-operations.md) and [policy_timing.md](policy_timing.md).

---

## 6. Code Reference Index

### R Pipeline

| Function | File | Purpose |
|---|---|---|
| `parse_chapter99()` | `src/03_parse_chapter99.R` | Extract Ch99 rates, authorities, country applicability |
| `parse_products()` | `src/04_parse_products.R` | Extract product rates, rate tiers, duty basis, reporting units |
| `calculate_rates_for_revision()` | `src/06_calculate_rates.R` | Build product × country rate matrix for one revision |
| `calculate_rates_fast()` | `src/06_calculate_rates.R` | Footnote-linked rate extraction |
| `apply_232_derivatives()` | `src/06_calculate_rates.R` | Section 232 derivative scaling |
| `apply_stacking_rules()` | `src/helpers.R` | Mutual-exclusion stacking → `total_additional`, `total_rate` |
| `enforce_rate_schema()` | `src/helpers.R` | Canonical schema enforcement with defaults |
| `parse_rate()` | `src/helpers.R` | Simple ad valorem rate parser |
| `parse_rate_extended()` | `src/helpers.R` | Full rate parser (ad valorem, specific, compound) |
| `parse_special_programs_multi()` | `src/helpers.R` | Multi-group special rate parser |
| `determine_rounding_rule()` | `src/helpers.R` | 19 CFR 159.3 rule assignment |
| `classify_authority()` | `src/helpers.R` | Ch99 subheading → authority mapping |
| `parse_ch99_rate()` | `src/helpers.R` | Ch99 rate text parser |
| `build_full_timeseries()` | `src/00_build_timeseries.R` | Orchestrate pipeline, batch-write to Parquet |
| `computeNonmetalShare()` | `frontend/src/utils/tariffCalculator.ts` | Per-type metal share for stacking |
| `computeNetAuthorityAmounts()` | `frontend/src/utils/tariffCalculator.ts` | Four-branch mutual-exclusion stacking |
| `detectAuthorityTriggers()` | `frontend/src/utils/tariffCalculator.ts` | Authority-specific data field detection |

### Frontend

| Function | File | Purpose |
|---|---|---|
| `calculateLandedCost()` | `frontend/src/utils/tariffCalculator.ts` | Full duty + fee calculation |
| `selectApplicableBaseRate()` | `frontend/src/utils/tariffCalculator.ts` | Column 1/2/Special tier selection |
| `roundValuePer19CFR159_3()` | `frontend/src/utils/tariffCalculator.ts` | Ad valorem value rounding |
| `roundQuantityPer19CFR159_3()` | `frontend/src/utils/tariffCalculator.ts` | Specific duty quantity rounding |
| `calculateMPF()` | `frontend/src/utils/tariffCalculator.ts` | Merchandise Processing Fee |
| `calculateHMF()` | `frontend/src/utils/tariffCalculator.ts` | Harbour Maintenance Fee |
| `findRateForDate()` | `frontend/src/utils/tariffCalculator.ts` | Date-based rate period lookup |

### Configuration

| File | Purpose |
|---|---|
| `config/policy_params.yaml` | All policy constants, authority ranges, program definitions |
| `config/revision_dates.csv` | HTS revision schedule with effective dates |
| `config/local_paths.yaml` | Optional: paths to import weights and benchmark data |

### Schema

The canonical rate output schema is defined in `RATE_SCHEMA` in [`src/helpers.R`](../src/helpers.R). Key columns:

| Column | Type | Description |
|---|---|---|
| `hts10` | character | 10-digit HTS statistical reporting number |
| `country` | character | Census Bureau country code |
| `base_rate` | numeric | Effective MFN rate (post-exemption) |
| `statutory_base_rate` | numeric | Statutory MFN rate (pre-exemption) |
| `base_rate_source` | character | Base-rate provenance: `own` / `inherited:<parent_htsno>` / `unresolved` |
| `rate_232` | numeric | Section 232 effective rate |
| `rate_301` | numeric | Section 301 effective rate |
| `rate_ieepa_recip` | numeric | IEEPA reciprocal effective rate |
| `rate_ieepa_fent` | numeric | IEEPA fentanyl effective rate |
| `rate_s122` | numeric | Section 122 effective rate |
| `rate_section_201` | numeric | Section 201 effective rate |
| `rate_other` | numeric | Other Ch99 provisions |
| `metal_share` | numeric | Metal content fraction (for 232 scaling) |
| `s232_annex` | character | 232 annex tier: `annex_1a` (primary metal) / `annex_1b` / `annex_3` (derivative); NA if not 232-covered |
| `s232_metal` | character | Covered metal for the 232 annex: `steel` / `aluminum` / `copper` |
| `total_additional` | numeric | Sum of additional duties (stacked) |
| `total_rate` | numeric | `base_rate + total_additional` |
| `usmca_eligible` | logical | USMCA exemption eligibility |
| `rate_special` | numeric | Primary Column 1 Special rate |
| `rate_column2` | numeric | Column 2 rate (ad valorem component) |
| `rate_basis` | character | `ad_valorem` / `specific` / `compound` / `free` / `unknown` |
| `specific_amount` | numeric | Dollar amount per unit (specific/compound) |
| `specific_rate_unit` | character | Unit from legal rate expression |
| `reported_unit_1` | character | First statistical reporting unit (nonlegal) |
| `reported_unit_2` | character | Second statistical reporting unit (nonlegal) |
| `duty_basis_unit` | character | Unit that drives duty math (null for ad valorem) |
| `is_qty_duty_relevant` | logical | TRUE only for specific/compound |
| `rounding_rule` | character | 19 CFR 159.3 rule code |
| `calc_status` | character | `ok` / `needs_manual_review` / `missing_duty_basis_unit` |
| `revision` | character | HTS revision identifier |
| `valid_from` | date | Start of rate period |
| `valid_until` | date | End of rate period |
