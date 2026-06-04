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

Runs both generators; writes to both repos. Override the sail-gtx location with
`SAIL_GTX_REPO=/path/to/sail-gtx-prerelease`. **Then commit the regenerated
`constants/*.json` in the sail-gtx repo** so Vercel picks them up.

### Auto-regenerate on commit (recommended)

```bash
scripts/install-hooks.sh      # one-time: sets core.hooksPath = scripts/git-hooks
```

After this, committing a change to `config/duty_citations.yaml`,
`config/legal_reference.yaml`, or `resources/ch99_legal_refs.csv` runs the
generators and re-stages this repo's bundles automatically. (It can't reach the
sail-gtx repo's git, so it prints a reminder to commit those too.)

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
| `resources/ch99_legal_refs.csv` | machine-extracted HTS-Note authorities per revision |
| `scripts/emit_duty_citations.R` | → `dutyCitations.json` (both repos) |
| `scripts/emit_legal_refs_json.R` | → `legalRefs.json` (both repos) |
| `scripts/emit_frontend_bundles.sh` | runs both generators |
| `scripts/check_bundles_fresh.sh` | drift check (CI + manual) |
| `scripts/git-hooks/pre-commit` | auto-regenerate on YAML change |
| `scripts/install-hooks.sh` | install the hook (`core.hooksPath`) |
| `.github/workflows/bundles-fresh.yml` | CI drift check |
| `frontend/scripts/push-to-motherduck.mjs` | parquet → MotherDuck `rates` |
| `frontend/server.js` | `/api/rates` (per-row provenance) |
