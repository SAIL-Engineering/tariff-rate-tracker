# Floor-Exemption Fallback Chain

**Audience:** policy analysts maintaining the exemption list, engineers debugging floor-country (EU-27, Japan, Korea, Switzerland, Liechtenstein) IEEPA rates.

Floor exemptions are product-specific carve-outs from the IEEPA reciprocal-rate floor that applies to "floor countries." When a (HTS, country) pair is on the exemption list for a given revision, its IEEPA reciprocal rate is set to 0 instead of `max(0, floor_rate − base_rate)`.

## Fallback chain

`load_revision_floor_exemptions(revision_id)` at `src/helpers.R:2033-2047` resolves the exemption list with two-step fallback:

1. **Per-revision file** at `data/us_notes/floor_exempt_{revision}.csv`. Used if it exists.
2. **Static fallback** at `resources/floor_exempt_products.csv`. Used otherwise.

The function returns a tibble; downstream code is unaware of which source fed it. Per-revision files exist for revisions where the proclamation (or related US Notes update) introduced exemptions specific to that revision; for steady-state revisions, the static file is canonical.

## CSV schema

Both files share the same columns:

| Column | Type | Meaning |
|---|---|---|
| `hts8` | string (8 digits) | HTS subheading the exemption applies to |
| `category` | string | Source category — e.g. `ptaap`, `eu_general`. Semantics not fully documented internally. **Open question for William.** |
| `country_group` | string | Group key — e.g. `swiss`, `eu27`. Maps to the floor countries the exemption applies to |
| `ch99_code` | string | Linked Chapter-99 entry that authorizes the exemption |

The `category` field's enumerated values aren't documented in the codebase; `ptaap` appears for Swiss pharma-related exemptions but the abbreviation is unconfirmed. Treat as policy metadata that William maintains; don't synthesize new values without his sign-off.

## Application in the rate engine

In `src/06_calculate_rates.R:1005-1020`, after the IEEPA reciprocal rate is computed for floor-country rows, the exemption list joins on `(hts8, country_group)` and zeros out matching pairs:

- `hts8` join: prefix match on the first 8 digits of `hts10`
- `country_group` join: country-code → group lookup (the country-group mapping itself lives in `config/policy_params.yaml`)

The floor *rates* themselves (e.g., EU 15%, Japan 10%) are configured at `config/policy_params.yaml` lines ~350-400, separate from the exemption list. Exemptions zero the rate; the rate definition is unchanged.

## Maintenance

To add an exemption:

1. Add a row to `resources/floor_exempt_products.csv` with the four columns above. Use an existing `category`/`country_group` value if applicable.
2. If the exemption is revision-specific (introduced by a particular proclamation), create `data/us_notes/floor_exempt_{revision}.csv` instead and copy in the static file's relevant rows plus the new ones.
3. Re-run the pipeline for affected revisions; the change appears in the IEEPA reciprocal column.

No automated validation today. A `category`-enumeration check would be a useful follow-up.
