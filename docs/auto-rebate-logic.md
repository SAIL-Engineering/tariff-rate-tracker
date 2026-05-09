# Auto Rebate (1.24pp on Chapter 87)

**Audience:** engineers tuning auto tariffs; analysts validating ETRs exports.

Chapter 87 (motor vehicles, parts) products receive a per-product rebate against `rate_232` reflecting the policy intent to credit US assembly. The visible reduction is approximately **1.24 percentage points** off the Section 232 ad-valorem rate. This doc traces where the number comes from and the pipeline-stack ordering that matters for debugging.

## Magic number

```
rebate_deduction = us_assembly_share × auto_rebate_rate
                 = 0.33 × 0.0375
                 = 0.012375
                 ≈ 1.24 pp
```

Both factors come from `config/policy_params.yaml:427-445`:

```yaml
auto_rebate:
  rebate_rate: 0.0375          # 3.75% rebate per Proclamation
  us_assembly_share: 0.33      # fraction of vehicle assembled in US
  us_auto_content_share: 0.40  # fraction of auto value that is US/USMCA-origin
```

**Note the asymmetry:** the rebate formula uses `us_assembly_share` (0.33), but the config also exposes `us_auto_content_share` (0.40). Only the former is read by the rebate code path; the latter is read elsewhere (USMCA scaling for autos). Don't conflate the two when debugging — they answer different policy questions. *Open question for William: confirm the policy distinction between "assembly share" and "auto content share" so this doc can cite a definitive source.*

## Implementation

`src/06_calculate_rates.R:1334-1358` (step 4b):

```r
auto_cfg <- pp$auto_rebate
deduction <- auto_cfg$rebate_rate * auto_cfg$us_assembly_share
rates <- rates %>%
  mutate(rate_232 = if_else(
    hts10 %in% auto_products,
    pmax(rate_232 - deduction, 0),
    rate_232
  ))
```

The `pmax(..., 0)` clamps the floor to zero — a pre-rebate `rate_232` below 1.24pp lands at 0 rather than a negative.

## Step ordering matters

Step 4b runs **before** step 5 (S232 derivatives + metal-content scaling) and **before** step 7 (USMCA share scaling). For chapter-87 auto products that are also S232 derivatives (e.g., aluminum-cased components), the rebate applies to the full pre-scaled rate. If you're debugging an auto rate and seeing values that don't match `25% − 1.24pp = 23.76%`, the most common cause is metal-scaling at step 5 having already run.

## Auto product scope

`auto_products` is the set of chapter-87 HTS codes captured at `src/06_calculate_rates.R:1080-1120` via heading-prefix matching. The same set feeds the `auto_products` slot in `denorm_state` (see [`denorm-state-flow.md`](denorm-state-flow.md)).

## ETRs export

`src/generate_etrs_config.R:1159-1160` exports `auto_rebate_rate = 0` and `us_auto_assembly_share = 0.33` to the downstream Tariff-ETRs benchmarking config. The `auto_rebate_rate = 0` is **deliberate** — the rebate has already been applied locally; setting the export value to 0 prevents Tariff-ETRs from double-applying it. Don't "fix" this to match `policy_params.yaml`.
