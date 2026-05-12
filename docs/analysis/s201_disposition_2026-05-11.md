# Section 201 disposition: the 18 unresolved Ch99 entries

**Date:** 2026-05-11
**Branch:** `nx_stacking_harness` off `wjr_dev@039cc011`
**Related:** Huddle item 4 from William's 2026-04-09 priorities list — "investigate the 18 truly-unresolved s201 entries (radial tires, leather, ADP machines, electropneumatic hammers, color TVs, S201 quota lists). Decide: parse them, route them to `handled_by_s201_config`, or document them as known-not-modeled."

## Headline

**All 18 entries are expired (or just-expired) Section 201 safeguards whose HTS codes haven't been cleaned out of Chapter 99 yet.** No current duty impact. Recommendation: **document-as-not-modeled** for all 18. Build an extractor only if/when a *new* Section 201 action lands.

## Codebase state today

S201 has the column wiring but no policy logic. From the exploration:

- `src/03_parse_chapter99.R:219` — `classify_resolution_status()` flags codes `9903.40`, `9903.41`, `9903.45` as `'unresolved_s201'`. The label is informational; nothing downstream consumes it.
- `config/policy_params.yaml:70` — only configuration: `section_201: [40, 41, 42, 43, 44, 45]` (Ch99 ranges). No rates, no product lists, no country scope, no effective dates.
- `src/helpers.R:1300-1430` — `rate_section_201` is in `RATE_SCHEMA` and the stacking formula, treated identically to `rate_other`.
- `src/06_calculate_rates.R` — initializes `rate_section_201 = 0` and never modifies it.
- **No `s201_products.csv` or similar resource file exists.**

Net: `rate_section_201` is always 0 for every (HTS, country, revision) row in the parquet. The 18 Ch99 codes exist in the HTS book but the pipeline doesn't extract or apply any rate from them. The triage CSV correctly logs them as `country_type = 'unknown', resolution_status = 'unresolved_s201'` — the parser can't infer country applicability from the description alone.

## The 18 entries with policy history

Grouped by the original Section 201 action they descend from.

### Tires — Proclamation 8414 (2009 → expired 2012)

| Ch99 code | HTS subheading | Description |
|---|---|---|
| 9903.40.05 | 4011.10.10, 4011.20.10 | Radial tires for motor cars / light trucks |
| 9903.40.10 | 4011.10.50, 4011.20.50 | Other tires for motor cars / light trucks |

President Obama imposed Section 201 tariffs on Chinese passenger tires in September 2009 (Proclamation 8414): 35% Year 1, 30% Year 2, 25% Year 3. **Expired 2012-09-26.** No current duty.

### Leather, ADP machines, hammers, TVs — 1976-1980s vintage safeguards

| Ch99 code | HTS subheading | Description | Original action |
|---|---|---|---|
| 9903.41.05 | 4104, 4107 | Bovine/equine leather | USITC investigations 1980s |
| 9903.41.15 | 8471 series | ADP machines (legacy computer) | Late 1990s |
| 9903.41.20 | 8471.49.10, 8471.50 | ADP machines >8MB | 1990s |
| 9903.41.25 | 8471.49.10, 8471.50 | ADP machines ≤8MB | 1990s |
| 9903.41.30 | 8467.29 | Electropneumatic hammers | 1976 USITC OMA on Korea/Taiwan |
| 9903.41.35 | 8467.21, 8467.29 | Other hammers | 1976 same |
| 9903.41.40 | 8528 series | Color TVs, 45-50cm diagonal | 1977 Carter OMA on Japan |
| 9903.41.45 | 8528 series | Color TVs, 50-52cm diagonal | 1977 same |

All long-expired (latest is the late-1990s ADP action, also expired by ~2002). The HTS code subheadings still exist as historical residue. No current duty.

### Washing machine safeguard — Proclamation 9694 (2018 → expired 2023)

| Ch99 code | Description |
|---|---|
| 9903.45.01 | Washer quota entry 1 — within quarterly TRQ (300K units) |
| 9903.45.02 | Washer quota entry 1 — overflow |
| 9903.45.05 | Washer quota entry 2 — within annual TRQ |
| 9903.45.06 | Washer quota entry 2 — overflow |

Trump-era Section 201 on imported large residential washers under HTS 8450.11/12/19/20. Proclamation 9694, effective 2018-02-07. 3-year safeguard with one-year extension (President Biden, January 2021). **Final expiry 2023-02-07.** No current duty.

### Solar PV — Proclamation 9693 (2018 → extended 2022 → expired 2026-02-06)

| Ch99 code | Description |
|---|---|
| 9903.45.21 | Solar cells/modules — annual aggregate ≤12.5 GW (TRQ within-quota) |
| 9903.45.22 | Solar cells/modules — overflow |
| 9903.45.27 | Crystalline silicon photovoltaic cells |
| 9903.45.29 | Bifacial solar panels |

Trump-era Section 201 on imported crystalline silicon photovoltaic cells/modules. Proclamation 9693, 2018-02-07 (30% Year 1 → 15% Year 4). Biden extended February 2022 for 4 more years at 14.25%/14%/14%/14%. **Extension expired 2026-02-06**, three months before today's date.

The HTS codes still exist in `2026_rev_7` because the HTS book lags the policy by a revision cycle. They'll likely be removed in a future revision.

## Disposition: document-as-not-modeled (all 18)

**Why not parse them:**
- No current duty impact. Building an extractor today would model zero rates everywhere.
- Each safeguard has its own quota mechanics (washers had quarterly TRQs; solar had annual GW limits). A general-purpose S201 extractor would need to encode product-specific TRQ logic for safeguards that aren't even active. Disproportionate cost.
- All current Trump 2.0 trade actions go through Section 232, 301, IEEPA, S122 — not Section 201. The relevant authorities are already covered.

**Why not route to a config table:**
- A `s201_config.csv` mapping Ch99 → (rate, dates, scope) is the right shape *if a future S201 action lands*. Building the table today produces an empty file.
- Defer the table until there's a real action to fill it with.

**What "document-as-not-modeled" looks like:**
1. This memo as the standing reference for the 18 entries.
2. A harness regression case asserting `rate_section_201 = 0` for one representative HTS (solar). Locks in current behavior. If a future S201 action comes in and the pipeline silently starts emitting non-zero `rate_section_201`, this test fails and we know.
3. (Future hook, when convenient) Federal Register API watch for new USITC Section 201 determinations. We have warm muscle on the FR API from today's ch87 work — when the time comes, the same fetch pattern works for `topics=trade-agreements,tariffs` filtered to USITC.

## Recommendation for the parser warning

The build log emits `[WARN] Truly unresolved entries (18): 9903.40.05 [section_201] ...` per revision. With this memo on file, the warning is now expected behavior, not a build defect.

Options for cleaning up the warning:
- **Keep as-is** (recommended) — the warning is a real signal. If the count changes (drops below 18 or rises above 18), that's information. Suppressing it loses that signal.
- **Demote to INFO** — if William finds the WARN noisy, downgrade. Same content.
- **Suppress entirely** — not recommended. Loses the early-warning property.

## Open questions for William

1. **Sign-off on document-as-not-modeled?** The alternative is "build the S201 infrastructure now, eat the cost of zero-row output for months/years." This memo recommends against that.
2. **Is the parser warning useful to keep?** My read: yes, but flagging in case the noise bothers you.
3. **If/when a new Section 201 action lands** (USITC investigation → presidential proclamation), do we want a notification hook via the Federal Register API? Same plumbing as the ch87 verification used today.

## Test coverage tying back

One harness case at `tests/cases/stacking_cases.csv` will assert `rate_section_201 = 0` for a representative solar HTS (e.g., 8541 series + China + 2026_rev_7). When (if) the pipeline grows an S201 extractor and starts emitting non-zero rates here, the test fails — surfacing the change before it ships.
