# Duty Provenance & Legal-Reference Pipeline

How the duty-provenance / legal-traceability data flows from this repo to the
deployed frontend, how to keep it in sync, and a changelog of recent changes.

**Audience:** anyone editing the legal/citation data or wondering why the
"Resources & Sources" panel shows what it shows.

---

## 1. Two independent data paths

The provenance panel ("Resources & Sources") combines **two** sources. They fail
independently — knowing which is which saves hours of debugging.

### Path A — static legal registry (committed JSON bundles)

```
config/duty_citations.yaml ──┐
config/legal_reference.yaml ─┼─►  scripts/emit_duty_citations.R   ─►  dutyCitations.json
resources/ch99_legal_refs.csv┘    scripts/emit_legal_refs_json.R  ─►  legalRefs.json
                                                                      │
                            written to BOTH repos ◄───────────────────┘
   • tariff-rate-tracker/frontend/public/data/*.json        (local duty explorer)
   • sail-gtx-prerelease/src/modules/tariff-rates/constants/*.json   (the Vercel app)
```

The frontend **imports these JSON files directly** (`dutyProvenance.ts`) — it
**never reads the YAML**. The YAML lives only here, as the source of truth.
The bundles are committed in each repo and bundled into the Vite build, so the
**Vercel deployment ships whatever JSON is committed in the sail-gtx repo.**

What's in them: the citation registry (reason_code → legal authority / narrative),
the audited reference table (proclamations / EOs / CBP messages with FR cites and
verification status), the machine-extracted HTS-Note authorities per revision, and
the **IEEPA refund / recovery 4-layer block** (`ieepa_refund`).

### Path C — General Note program data (the rate universe, de-hardcoded)

```
HTS General Note 3(b)/3(c) ─┐                          ┌► programSymbols.json
  (per revision, reststop)  ├► src/parse_general_note_3.R   (symbol→program map,
HTS General Notes 4/16/7 ───┘     │  emits resources/:        Column 2 names+codes)
  (GSP/AGOA/CBERA lists)          │  • gn3_program_symbols.csv
resources/fta_partners.csv ───────┤  • gn3_column2_countries.csv   ┌► programCountries.json
  (reviewed FTA reference)        │  • gn_program_countries.csv    │   (census_code →
resources/country_name_aliases ───┘  scripts/emit_program_symbols.R┤    FTA + GSP/AGOA/
  (reviewed spelling variants)        scripts/emit_program_countries.R   CBERA memberships,
                                                                         codes + GN + provenance)

config/program_requirements.yaml ─► scripts/emit_program_requirements.R ─► programRequirements.json
  (curated, GN-anchored eligibility;     (symbol keys validated against     (per-program "missing
   symbols, value-content, certs)         the gn3 symbol map)                facts" behind a suggestion)
```

This **de-hardcodes the rate universe**: the frontend's program-symbol map, the
Column 2 country list, and the country→preference-program membership table are no
longer constants in app code — they are generated from the HTS General Notes we
already fetch. `parse_general_note_3.R` is **incremental + build-wired** (runs in
`00_build_timeseries.R` under `SAIL_EMIT_GN3`, only fetching revisions not already
extracted, carrying forward over reststop gaps), so a **new HTS revision updates
the data with no code change and no Claude in the loop**.

- **Census mapping is precision-first**: a General-Note country name that doesn't
  match a census code exactly (or via the reviewed `country_name_aliases.csv`) is
  emitted name-only with **no** code — it asserts no eligibility, so a miss falls
  back to the safe base-NTR/MFN default rather than fabricating a preference.
- **`fta_partners.csv`** is reviewed reference data (FTA partner → census code +
  HTS codes), the same category as `census_codes.csv`; FTA partners change only by
  treaty, never per-revision.
- Consumed by `utils/tradeAgreements.ts` (`COUNTRY_MEMBERSHIPS`,
  `programCodesForCountry`, `getAgreementStatus`, `isUSMCACountry`) and
  `types/tariff.ts` (`COLUMN2_COUNTRY_CODES`). Beneficiary memberships
  (GSP/AGOA/CBERA) are **new** surfaceable info — previously only FTAs were mapped.
- **`programRequirements.json`** is the third bundle: curated, General-Note-anchored
  eligibility requirements per program (origin, value-content, certification,
  shipment, eligibility) — the "missing facts" the opportunity model shows behind a
  *suggested* preference. Its source is `config/program_requirements.yaml` (the only
  hand-curated input on Path C); the emitter validates every declared symbol against
  the parsed `gn3_program_symbols.csv`, so it can't invent a program the HTS doesn't
  list.

### Path B — per-row provenance (live, from the API)

```
R pipeline ─► rate_timeseries_parquet (duty_provenance_json column)
           ─► MotherDuck `rates` table (via scripts/push-to-motherduck.mjs)
           ─► API server (frontend/server.js, DATABASE_TARGET=motherduck)
           ─► Vercel frontend (VITE_TARIFF_API_BASE → /api/rates)
```

`duty_provenance_json` is a per-(hts10, country, revision) column. It is **not a
file** and lives in neither repo's source — it is served live. If the panel says
"Duty provenance is not available," it is almost always **Path B**: the row was
served from the base-MFN synthesis fallback (`synthesizeBaseMfnRow`, which has no
provenance), or the **API server is running stale code / needs a redeploy**. The
static legal registry (Path A) being present does not help if Path B is empty.

---

## 2. The golden rule: never hand-edit the generated JSON

> **Edit the YAML, then regenerate. Do NOT hand-edit `constants/*.json`.**

The generator **duplicates** each authority entry into the `reference` map (keyed
by reason). If you hand-edit one copy in the JSON you will miss the duplicate, and
the bundle becomes **internally inconsistent**. This actually happened: an
`eo_14389` URL was fixed in `authorities` but not in `reference`, so the same
authority showed two different Federal Register links depending on where it was
read. Regenerating from the YAML fixes it because there is a single source.

If you only have access to the deployed bundle and not this repo, send the change
here so it can go into the YAML — otherwise it will be silently reverted the next
time anyone regenerates.

---

## 3. Keeping the bundles in sync

### Regenerate (after editing any YAML/CSV source)

```bash
scripts/emit_frontend_bundles.sh
```

Runs all five generators (`emit_duty_citations`, `emit_legal_refs_json`,
`emit_program_symbols`, `emit_program_countries`, `emit_program_requirements`);
writes to both repos. Override the sail-gtx location with
`SAIL_GTX_REPO=/path/to/sail-gtx-prerelease`. **Then commit the regenerated
`constants/*.json` in the sail-gtx repo** so Vercel picks them up.

### Auto-regenerate on commit (recommended)

```bash
scripts/install-hooks.sh      # one-time: sets core.hooksPath = scripts/git-hooks
```

After this, committing a change to any bundle source runs the generators and
re-stages this repo's bundles automatically. The watched sources are
`config/duty_citations.yaml`, `config/legal_reference.yaml`,
`config/program_requirements.yaml`, `resources/ch99_legal_refs.csv`, the three
`resources/gn*` CSVs (`gn3_program_symbols`, `gn3_column2_countries`,
`gn_program_countries`), `resources/fta_partners.csv`, and
`resources/country_name_aliases.csv`. (It can't reach the sail-gtx repo's git, so
it prints a reminder to commit those too.)

### Drift check (CI + manual)

```bash
scripts/check_bundles_fresh.sh    # exits non-zero if committed JSON ≠ YAML output
```

`.github/workflows/bundles-fresh.yml` runs this on PRs that touch the YAML or the
bundles, so a stale or hand-edited bundle fails CI. The check is **textual** (it
regenerates and `git diff`s) — that is deliberate: it catches stale content *and*
hand-edit inconsistencies, because it requires the committed JSON to be exactly
the generator's output.

> First run after this doc lands will report the sail-gtx bundles as changed —
> that is the one-time reconciliation (regenerate + commit the consistent
> bundles). After that, the generator is deterministic and the check stays green.

---

## 4. Recent changes (changelog)

Newest first. These are the substantive updates behind the current provenance /
duty-stack behavior.

### Backend — §232, copper, IEEPA refund

- **§232 provenance re-architected.** `s232_reason` now derives from the annex
  tier (`s232_annex`) + the covered metal (`s232_metal`, emitted by 06 from the
  annex product list's `metal_type`), not the ambiguous 9903.82 reporting code.
  Added `s232_copper` / `s232_copper_derivative` reasons. (`src/helpers.R`,
  `src/06_calculate_rates.R`, `RATE_SCHEMA`.) Per-metal trade-weighted shares are
  0 in the unweighted build — see `docs/GAPS.md`.
- **Copper proclamation chain** in `config/legal_reference.yaml`: founding
  `proc_10962` (9903.78 / Note 36), `proc_11021` (annex), and `proc_11032`
  (eff. 2026-06-08, 9903.82.20–26, `source_status: …pending_publication`).
- **IEEPA refund / recovery layer** (`ieepa_refund` in `legal_reference.yaml`):
  4-layer model — duty authority → ended-collection status → **CBP CAPE refund
  process** (CSMS #68340863: CAPE in ACE, 9,999-entry CSV, interest under
  19 CFR 24.36, ~60–90 day refunds, Phase 1 exclusions) → litigation risk. Plus
  five country IEEPA EOs (`eo_14245` … `eo_14382`). Phrasing is legally reviewed —
  no dollar figure, refunds not automatic/guaranteed, scope being litigated.
- **MotherDuck push fixed** (`frontend/scripts/push-to-motherduck.mjs`): revisions
  are column-heterogeneous (e.g. `ieepa_recip_ch99`, `s232_annex` exist only in
  newer revisions). Seed now uses the **union schema** + `INSERT … BY NAME` so
  every revision loads regardless of column set.
- **API arrow serialization hardened** (`frontend/server.js`): the response column
  set is now the **union of all rows' keys** (was `Object.keys(rows[0])`), so a
  synthesized first row can't drop `duty_provenance_json` for the whole batch.
- **`docs/GAPS.md`** — what we don't have (data/logic/unresolved Ch99), each
  tagged by whether it's closeable via PDF/HTS parsing.

### Frontend (sail-gtx-prerelease)

- **Legally-binding rounding** (`tariffCalculator.ts`): per-line, even-dollar value
  (19 CFR 159.3) × full-precision rate, rounded to the cent, summed — matches a
  broker/CBP entry summary and removes sub-cent drift. Documented as a footer in
  the Duty Stack table.
- **2-decimal display** everywhere (`formatRateShort`, `formatPct`).
- **Statutory→effective on additional duties explained** (DutyStackBreakdown): the
  IEEPA reciprocal-floor mechanism (`base + reciprocal = floor`) with its source,
  distinct from the base rate's FTA/GSP preference blend.
- **IEEPA "active" pill** split into "applied — in force this period" +
  "collection ended 2026-02-24"; `IeepaRefundNotice` rendered in the provenance
  panel and the broker reconciliation.
- **Rate Periods table**: Statutory MFN is primary, effective is a footnoted
  secondary; the Total uses the **statutory** base (correctly leaving a
  reciprocal-floor total at the floor).
- **Layout**: bulk results grid sits flush with the BottomBar (no 3rd scrollbar);
  the line-detail drawer ends at the bar's top edge with rounded interior corners;
  the reconciliation table fills its container (label column flex-grows).

---

## 5. File map

| Path | Role |
|------|------|
| `config/duty_citations.yaml` | reason_code → citation/narrative; sources; program indicators |
| `config/legal_reference.yaml` | audited authorities (proclamations/EOs/CBP), `ieepa_refund` block |
| `config/program_requirements.yaml` | curated, GN-anchored eligibility requirements per program (only hand-curated Path C input) |
| `resources/ch99_legal_refs.csv` | machine-extracted HTS-Note authorities per revision |
| `src/extract_legal_refs.R` | → `resources/ch99_legal_refs.csv` from each revision's Ch99 PDF (incremental, build-wired under `SAIL_EMIT_LEGAL_REFS`) |
| `scripts/emit_duty_citations.R` | → `dutyCitations.json` (both repos) |
| `scripts/emit_legal_refs_json.R` | → `legalRefs.json` (both repos) |
| `src/parse_general_note_3.R` | GN 3(b)/3(c) + GSP/AGOA/CBERA lists → `resources/gn3_*.csv`, `gn_program_countries.csv` (incremental, build-wired under `SAIL_EMIT_GN3`) |
| `resources/fta_partners.csv` | reviewed FTA partner → census code + HTS codes |
| `resources/country_name_aliases.csv` | reviewed GN-name → census-code spelling/long-form variants |
| `scripts/emit_program_symbols.R` | → `programSymbols.json` (symbol map + Column 2 names/codes, both repos) |
| `scripts/emit_program_countries.R` | → `programCountries.json` (census_code → FTA + GSP/AGOA/CBERA, both repos) |
| `scripts/emit_program_requirements.R` | → `programRequirements.json` (per-program eligibility requirements; validates symbols against gn3 map) |
| `src/emit_rate_validation.R` | per-row rate provenance / reference-data invariants (C1–Q6) → `output/quality/rate_reconciliation_base*.csv` |
| `scripts/emit_frontend_bundles.sh` | runs all five generators |
| `scripts/check_bundles_fresh.sh` | drift check (CI + manual) |
| `scripts/git-hooks/pre-commit` | auto-regenerate on YAML change |
| `scripts/install-hooks.sh` | install the hook (`core.hooksPath`) |
| `.github/workflows/bundles-fresh.yml` | CI drift check |
| `frontend/scripts/push-to-motherduck.mjs` | parquet → MotherDuck `rates` |
| `frontend/server.js` | `/api/rates` (per-row provenance) |
