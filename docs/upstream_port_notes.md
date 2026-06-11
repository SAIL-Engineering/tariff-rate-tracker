# Upstream correctness-fix ports (Budget-Lab-Yale @ 2a1763cf)

Five upstream correctness fixes re-expressed in this fork's code on
`wjr_dev` (base: a873aab0). The upstream tree refactored heavily after the
82d3ddb5 divergence point, so logic was PORTED, not cherry-picked. Upstream
`docs/master_fix_integration.md` was used as the impact oracle.

Validation gate for every port: `tests/test_ch99_rules.R` and
`tests/test_rate_calculation.R` green (started 18/18 + 50/50; ended 21/21 +
57/57 with 10 new targeted tests). The pre-existing
`tests/test_normalized_parity.R` Stage-2 failure (212/2008 vs cached
artifacts) is documented separately below.

| # | Port | Upstream ref | Status | Commit |
|---|------|--------------|--------|--------|
| 1 | Revision re-dating to change-record policy dates | 6559c2f | **completed** | beb6030c |
| 2 | USMCA eligibility false-negatives + HS8 share fallback | b3dd1b5 (fix6) | **completed** | 8d5dda2e |
| 3 | IEEPA Annex II date-windowing | eb145ba + c5b2eb1 (fix4+5) | **completed** | c5a8c3fc + 1d8da1c1 |
| 4 | 8-digit leaf HTS retention | cbe646d / 7df20b3 (fix1) | **completed** | e7545219 (+ 1d8da1c1) |
| 5 | §301 exclusion headings, determination-grade | d839e402 (adapted) | **completed** | 1e17948c |

---

## Port 1 — Revision re-dating (beb6030c)

**Files:** `config/revision_dates.csv`, `scripts/audit_revision_dates.R`,
`data/hts_change_record/` (new, 44 PDFs).

`load_revision_dates()` already defaults to `use_policy_dates = TRUE` and
swaps `policy_effective_date` into `effective_date` where populated —
populating the column re-dates the whole series, no loader change needed.

- Mirrored all 44 USITC change-record PDFs (2025 basic..rev_32, 2026
  basic..rev_10) from the official `hts.usitc.gov/reststop/file?release=
  <rel>&filename=Change%20Record` endpoint. Byte-identical to upstream's
  copies where both exist; we additionally hold `2026HTSRev10` (upstream
  did not).
- `scripts/audit_revision_dates.R`: `record_for()` now handles this fork's
  year-prefixed revision ids (`2019_basic`..`2026_rev_10`); audit output
  includes `csv_policy_date` and prints all rows.
- Audit run (`output/revision_date_audit.csv`, gitignored): every populated
  policy date matches the change record's modal item effective date or its
  publication date. Where the modal date is retro/noisy the publication
  date was used, exactly following upstream's reviewed calls
  (2025 rev_4, rev_7, rev_10, rev_13, rev_21, rev_24, rev_30, rev_32).

**Deviations / notable calls**

- *2025_rev_16 correction:* this fork previously had policy date
  2025-06-04 on rev_16. Per the change records the Proclamation 10947 50%
  text entered at **rev_14** (published May 2, items effective Jun 4);
  rev_16 carries the July-1 staged updates. Now rev_14 → 2025-06-04,
  rev_16 → 2025-07-01 (upstream's values).
- *2026_rev_8 EXCLUDED from the series* (row removed): editorial-only vs
  rev_7 (description wording on 9819.11.12, AGOA apparel), zero rate
  impact (upstream's reviewed finding, confirmed by its change record's
  junk modal date). Keeping it would invert interval ordering against the
  retro-dated rev_9. The `hts_2026_rev_8.json` archive and its caches
  remain on disk; only the series membership changed. Code references to
  `2026_rev_8` are doc examples only.
- *2026_rev_9 retro-dated to 2026-05-01* (Taiwan agreement legally
  retroactive to May 1 per its change record), matching upstream.
- *2025_rev_10 `tpc_policy_revision` cleared* (was `2025_rev_7`): with
  correct policy dating the TPC override mapping is unnecessary; upstream
  dropped it in the same commit.
- 2026_rev_5/6/7/10 policy dates were already correct in this fork; kept.
- Both `use_policy_dates = TRUE` and `FALSE` load monotonically (132 rows).

## Port 2 — USMCA eligibility + HS8 share fallback (8d5dda2e)

**Files:** `src/05_parse_policy_params.R` (`extract_usmca_eligibility`),
`src/helpers.R` (`load_usmca_product_shares`), `src/06_calculate_rates.R`
(step-7 application), `tests/test_rate_calculation.R`.

- (a) `special` lives on the 8-digit legal line; statistical suffixes now
  inherit it via a legal-line indent stack (mirrors base-rate inheritance
  in `parse_products()`); sibling branches cannot leak (any line with
  rate/special text resets its level and deeper). Also keeps 8-digit leaf
  lines (padded `00`) and drops non-leaf 8-digit rows — same post-pass as
  Port 4, ported together as upstream did.
- (b) Zero-trade `(hts10, cty)` pairs → `NA` (no claim signal), and the
  value-weighted loader branches attach an HS8 value-weighted share table
  as `attr 'hs8_shares'`; application falls back HTS10 → HS8 → 0 for
  CA/MX.

**Deviations:** upstream patched only the `h2_average` branch (their config
mode). This fork also has a `hybrid_rolling` value-weighted branch with the
identical zero-trade bug — fixed it the same way. The plain single-file
modes (`annual`/`monthly` CSVs without value columns) cannot distinguish
zero-trade from zero-claims and are unchanged (same as upstream).

**Validation:** unit fixtures (inheritance TRUE for children of an S/S+
legal line; no cross-branch leak; 8-digit leaf retained). Loader smoke on
real 2025 H2 data: 20,015 pairs, 22 zero-trade → NA, HS8 fallback table
12,924 pairs. Could not rebuild the full series here; upstream measured
CA −5.3pp / MX −4.0pp at the 2026_rev_2 snapshot for this fix.

## Port 3 — IEEPA Annex II date-windowing (c5a8c3fc, 1d8da1c1)

**Files:** `scripts/build_annex_ii_dates.R`,
`resources/annex_ii_first_appearance.csv` (regenerated),
`resources/ieepa_exempt_products.csv` (stamped + expanded),
`src/helpers.R` (`filter_ieepa_exempt_window`), `src/06_calculate_rates.R`,
`src/expand_ieepa_exempt.R`, `src/generate_etrs_config.R`.

Implemented upstream's full mechanism rather than a join-time prefix
filter: the exempt list itself carries `effective_date_start`/`_end`
columns and the 06 loader windows it per revision (this also windows the
`source` provenance map and the normalized-layer emission, which both
derive from the filtered table).

- `build_annex_ii_dates.R` adapted (fork revision ids; policy-date space
  via `coalesce(policy_effective_date, effective_date)`; preserves the
  fork's `source` column; prefers `data/processed` caches) and RUN against
  all 44 local `data/us_notes/chapter99_*.pdf`. Baseline = `2025_rev_7`.
  Legal overrides identical to upstream: starts rev_10→2025-04-05 (retro
  electronics memo), rev_22→2025-09-08 (EO 14346), rev_29→2025-11-13 (ag
  expansion); ends rev_17→2025-07-31 (copper→232), rev_22→2025-09-07,
  rev_25→2025-10-13 (wood→232).
- Stamping appended 405 HTS10 children of 242 removed copper/wood prefixes
  (their Apr–Oct 2025 exemption windows were previously missing entirely)
  and removed 74 ch06 Swiss-annex contaminants from the universal list
  (Swiss imports remain exempt via the floor-exemption path).
- After the Port-4 parser change, re-ran `expand_ieepa_exempt.R` +
  re-stamp (1d8da1c1): adds the 424 ch98/ch97/ch49 leaf rows.

**Convergence proof:** final `ieepa_exempt_products.csv` is identical to
upstream's reviewed list at the pinned commit — 5052 rows, same
membership, same windows (diffed programmatically: 0 differing windows,
0 membership differences). We additionally retain the `source` column.

`annex_ii_first_appearance.csv` now uses fork-native revision names
(1324 prefixes vs upstream's 1325 — the delta is bookkeeping columns
`first/last_revision` against a slightly different revision set, incl. our
2026_rev_10; the date columns, which are what matters, agree).

**Validation:** unit tests — pre-2025-04-05 date does NOT exempt an
electronics entry windowed at 2025-04-05; end-dated entry exempts through
its last day only; resource CSV invariants (8471* starts 2025-04-05,
ch74 ends 2025-07-31, ch44 ends 2025-10-13, end ≥ start). Active-count
sweep: 4034 @ Apr 2 2025 → 4095 @ Apr 5 (electronics in) → 3982 @ Aug 1
(copper out) → 3602 @ Oct 14 (wood + EO 14346 removals out) → 4076 @
Nov 13 (ag in).

## Port 4 — 8-digit leaf HTS retention (e7545219, 1d8da1c1)

**Files:** `src/04_parse_products.R`, `tests/test_rate_calculation.R`,
plus the exempt-list re-expansion in 1d8da1c1.

8-digit candidates are kept, padded to 10 via `normalize_hts()` (right-pad
zeros), and non-leaf 8-digit rows (grouping rows with 10-digit children)
dropped in a post-pass — upstream's exact rule, applied inside this fork's
richer parser (inheritance stacks/duty-basis columns untouched).

**Validation:** at `2026_rev_2`, +473 hts10 (378 ch98, 95 ch91) — exact
match with upstream's oracle; 0 codes removed; all added codes end `00`;
base rates resolve (183 own-line, rest inherited/NA as upstream).

**Import-weight join (checked, documented, not changed):** Census already
keys true 8-digit leaves as `00`-padded HTS10 (e.g. `9802002000` in
`data/census_imports_2024.csv`), so the `inner_join` coding in
`09_daily_series.R::build_daily_aggregates()` / `08_weighted_etr.R`
aligns for genuinely-leaf lines. Residual gap: (i) the 378 ch98 special
provisions carry no census trade under ANY coding — zero weight is
inherent to the data; (ii) 28 ch91 HS8s were 10-digit-suffixed in the
2024 census vintage but are 8-digit leaves in 2026 HTS — their 2024 trade
(~$0.2M of $1.8T total) cannot match. An HS8 weight fallback would need
double-count guards for ~0.00001% of weight; upstream shipped without one
("~0 on existing universe"). Deferred deliberately.

## Port 5 — §301 exclusion headings, determination-grade (1e17948c)

**Files:** `src/helpers.R` (`extract_expiry_date_offset`,
`build_s301_exclusion_candidates`, `attach_duty_provenance`),
`src/06_calculate_rates.R`, `src/00_build_timeseries.R`,
`tests/test_ch99_rules.R`.

**Deliberate divergence from upstream:** d839e402 Phase 1 zeroes
`rate_301` by `coverage_share` (flagged there as an upper bound). For this
determination-first product, exclusions are description-scoped slices of
a line and claiming one is a fact question — so in-window exclusion
headings emit `ch99_rules_json` rule objects with status
`potentially_applicable_requires_more_facts`, authority `section_301`,
program `s301_exclusion`, the exclusion `ch99_code`, and
`missing_facts: [product_description_match, exclusion_claim_eligibility]`.
`rate_301` is NEVER modified; rules emit only on rows where §301 is
applied (`rate_301 > 0`).

Mechanics shared with upstream: windows are re-read per revision from the
archive's own heading text (`extract_effective_date_offset` +
`extract_expiry_date_offset`, the latter ported verbatim: through /
on-or-before inclusive, bare-before exclusive, latest match wins) with the
registry CSV's `validity_start`/`_end` as curator overrides. The
`9903.88.21–.28` PERMANENT CONDITIONAL derived-rate carve-outs
(US note 20(z)–(gg)) and NEEDS_REVIEW headings with no verifiable window
are never emitted. `coverage_share` is not consumed (it is upstream's
zeroing weight; irrelevant to rule emission).

Wiring mirrors the `ch99_other` pattern (a873aab0): built in
`00_build_timeseries.R` step c2b and passed through
`calculate_rates_for_revision(s301_exclusions = ...)`;
06 self-builds when the caller passes NULL so 09_daily_series and other
entry points also emit.

**Validation:** fixture tests (rule emitted with full vocabulary on the
China row; absent where `rate_301 = 0`; rates bit-identical; builder
date-gates from heading text; `.21` carve-out and windowless `.51` never
emit; pre-window and post-expiry dates emit nothing). Real-cache smoke:
`9903.88.69`/`.70` in-window at 2025-02-04 / 2025-08-07 / 2026-06-08
(144 hts10 pairs); the expired 2023-24 tranches (`.50–.68`) absent.

---

## Known pre-existing failure (unchanged, not addressed)

`tests/test_normalized_parity.R` Stage 2 fails 212/2008 sampled cases
against cached artifacts on the UNMODIFIED tree. None of these ports
rewrite the cached artifacts under test (snapshots/normalized parquets are
build outputs; `data/timeseries` caches were left untouched — new-parser
caches went to gitignored `data/processed/`). The resolver/emitter pair is
versioned together at build time, so per-case parity is unaffected until
the next full rebuild regenerates both sides with the ported logic.

## Environment notes

- Outbound `curl`/`wget`/R `download.file` are blocked in this sandbox;
  upstream references were fetched via the gstack browse daemon
  (per user CLAUDE.md), including binary change-record PDFs pulled from
  the official USITC reststop endpoint via an in-page fetch + base64.
- After these ports, the next full series rebuild
  (`00_build_timeseries.R`) will produce re-dated intervals and the
  corrected USMCA / IEEPA-window / leaf-universe / exclusion-rule outputs;
  expected direction of movement per upstream's by-date comparison:
  CA −3.97pp, MX −3.38pp, China +1.86pp, ~−0.36pp universal tail,
  April-2025 timing shifts up to −8.56pp on individual days.
