# MotherDuck Integration

Operational guide for the tariff database: how it works, how to run it locally, how to update it, how it deploys, and how to fix it when it breaks.

This covers two repositories that sit on either side of a single MotherDuck database:

| Repository | Role | Path |
|---|---|---|
| `tariff-rate-tracker` (this repo) | R pipeline + Express API + local prototype UI. Writes parquet; optionally queries either local parquet or MotherDuck. | `GitHub_tariff-rate-tracker/tariff-rate-tracker/` |
| `sail-gtx-prerelease` | Production React frontend. Calls the tariff API cross-origin from the browser. | `GitHub_sail-gtx-prerelease/sail-gtx-prerelease/` |

---

## Contents

1. [Architecture at a glance](#architecture-at-a-glance)
2. [Where the data lives](#where-the-data-lives)
3. [Data flow](#data-flow)
4. [Prerequisites](#prerequisites)
5. [Local development](#local-development)
6. [Database operations](#database-operations)
7. [Deployment](#deployment)
8. [Environment variables reference](#environment-variables-reference)
9. [Verification playbook](#verification-playbook)
10. [Troubleshooting](#troubleshooting)
11. [Future work](#future-work)

---

## Architecture at a glance

```
┌──────────────────────────────────────────────────────────────────────────────┐
│                          tariff-rate-tracker (this repo)                     │
│                                                                              │
│   R pipeline (src/)                                                          │
│       │  Rscript src/00_build_timeseries.R                                   │
│       ▼                                                                      │
│   Partitioned parquet at data/timeseries/rate_timeseries_parquet/            │
│     └── revision=2025_basic/   (184M rows total, ~6.6 GB, 39 revisions)      │
│     └── revision=2025_rev_1/                                                 │
│     └── ...                                                                  │
│       │                                                                      │
│       │  npm --prefix frontend run db:push-to-cloud                          │
│       ▼                                                                      │
│   MotherDuck — database: duty_calculator                                     │
│     ├── main.rates (BASE TABLE, 184,978,080 rows)                            │
│     └── main.product_base_rates (VIEW)                                       │
└──────────────────────────────────────────────────────────────────────────────┘
         ▲                                          ▲
         │ Node/Express API                         │ Node/Express API
         │ (frontend/server.js)                     │ (same, deployed)
         │                                          │
         │ DATABASE_TARGET=local                    │ DATABASE_TARGET=motherduck
         │  or =motherduck                          │
         │                                          │
┌────────┴──────────────┐                  ┌────────┴──────────────────────┐
│ Laptop dev (:3001)    │                  │ Railway (tariff-rate-tracker) │
│ Optional parquet view │                  │ Public domain                 │
└───────────────────────┘                  └──────────┬────────────────────┘
                                                      │ HTTPS + CORS
                                                      ▼
                                   ┌──────────────────────────────────────┐
                                   │  sail-gtx-prerelease frontend        │
                                   │  apiUrl(VITE_TARIFF_API_BASE + path) │
                                   │                                      │
                                   │  /us-tariffs   → Tariff Rates module │
                                   │  /hts-explorer → Duty Calculator     │
                                   └──────────────────────────────────────┘
                                              ▲              ▲
                                              │              │
                                    https://sailgtx.ai    localhost:8080
                                    (Railway + Vercel)    (dev)
```

**Key invariants:**

- **Single source of truth = the parquet output of the R pipeline.** MotherDuck is always a downstream replica. R scripts never write to MotherDuck directly.
- **The browser never holds a MotherDuck token.** All database access is server-side, via the Express API.
- **`DATABASE_TARGET=local|motherduck` toggles the API's backing store.** Handler code is identical — the `connection` object is interchangeable.

---

## Where the data lives

**The only place raw data is generated or stored for editing is your local machine.** MotherDuck is a one-way downstream replica — nothing in the cloud generates data.

### On the dev machine (your laptop)

```
tariff-rate-tracker/
├── src/                                             # R pipeline (the ONLY data generator)
│   ├── 00_build_timeseries.R
│   ├── 06_calculate_rates.R
│   └── ...
├── data/
│   ├── hts_archives/                                # HTS JSON inputs (gitignored, ~200 MB)
│   │   └── hts_2026_rev_5.json
│   └── timeseries/
│       └── rate_timeseries_parquet/                 # ← SOURCE OF TRUTH (gitignored, ~1.5 GB)
│           ├── revision=2025_basic/*.parquet
│           ├── revision=2025_rev_1/*.parquet
│           └── ... (39 partitions)
└── frontend/
    ├── server.js                                     # Express API (both local + Railway)
    └── scripts/push-to-motherduck.mjs                # The sync CLI (the ONLY data pusher)
```

None of these big files are committed to git. They live only on the machine where the R pipeline ran.

### In MotherDuck (cloud replica)

```
duty_calculator (database)
└── main (schema)
    ├── rates (BASE TABLE, 184,978,080 rows)   ← populated by the sync CLI
    └── product_base_rates (VIEW)              ← defined by the sync CLI
```

Created and updated **exclusively** by `npm run db:push-to-cloud` running on your laptop. Neither the Railway backend nor the Vercel frontend ever writes to MotherDuck.

### In Railway (backend runtime)

- Ships only `frontend/server.js` + `frontend/server/*.js` + `node_modules`.
- **Zero parquet files on disk.** `data/` is not bundled.
- Reads from MotherDuck over the network on every API request.

### In Vercel (frontend runtime)

- Ships only the built React bundle (`sail-gtx-prerelease/dist/`).
- No tokens, no database access — the browser hits the Railway API via HTTPS.

### The rules this enforces

| Question | Answer |
|---|---|
| Where do I edit parquet files? | **Nowhere directly.** Edit the R scripts in `src/`, then regenerate parquet. |
| Where do I push new data to MotherDuck? | **From your laptop only**, via `npm run db:push-to-cloud`. |
| Can the Railway API modify `duty_calculator`? | No. It's read-only to the API (the token is read_write but the code never issues writes). |
| Can I regenerate parquet on a cloud machine? | Not today. R doesn't run on Railway or Vercel. The pipeline is laptop-only for now. |
| What happens if my laptop dies? | The MotherDuck copy is intact. To regenerate: clone the repo on a new machine, re-run the R pipeline (it rebuilds parquet from `data/hts_archives/`), then `npm run db:push-to-cloud -- --confirm-drop`. |

### Overwrite vs append semantics

The sync CLI has two modes, both operating on the **local** parquet and writing to the **cloud** `duty_calculator.main.rates` table:

| Mode | What it does | When to use |
|---|---|---|
| **Full rebuild** (default, no `--revision` flag) | `CREATE OR REPLACE TABLE rates AS SELECT * FROM read_parquet('<first partition>')`, then `INSERT INTO rates` for every subsequent revision partition. Full overwrite — the table is dropped and rebuilt. | After a schema change; after regenerating all revisions; on initial setup. Requires `--confirm-drop`. |
| **Incremental** (`--revision <name>`) | `BEGIN; DELETE FROM rates WHERE revision = '<name>'; INSERT INTO rates SELECT * FROM read_parquet('<that partition>'); COMMIT`. Replaces exactly one revision's rows in place. | After regenerating a single revision partition; most dev loops. Transactional — rolls back on failure. |

There is no "append only new rows" mode because revisions are idempotent snapshots, not incremental diffs. If the R pipeline re-emits `revision=2025_rev_25`, that partition is rewritten wholesale — the cloud table follows the same semantic via the `--revision` path.

## Data flow

1. **ETL (R, local only)** — `Rscript src/00_build_timeseries.R` reads HTS archives in `data/hts_archives/`, parses Chapter 99 / products / policy params, calculates rates, writes partitioned parquet under `data/timeseries/rate_timeseries_parquet/revision=*/*.parquet`.
2. **Sync (Node CLI, local only)** — `npm run db:push-to-cloud` runs on your laptop, reads the parquet files from local disk, opens a MotherDuck connection with your `MOTHERDUCK_TOKEN`, and streams the data into `duty_calculator.main.rates` one revision partition at a time.
3. **Serve (Express)** — `frontend/server.js` runs in two places:
   - **Locally** with either `DATABASE_TARGET=local` (in-memory DuckDB over the local parquet files) or `DATABASE_TARGET=motherduck` (connects to `duty_calculator` over the network).
   - **On Railway** always with `DATABASE_TARGET=motherduck`. No local parquet access because the container never has the files.
4. **Consume (browser)** — `sail-gtx-prerelease` calls the API via the URL in `VITE_TARIFF_API_BASE`. In prod that's the Railway backend; in dev it's `localhost:3001` via the Vite dev proxy.

The arrow is strictly **laptop → MotherDuck → Railway/Vercel**. Data never flows the other direction.

---

## Prerequisites

- **Node.js ≥ 20.6** (for `@duckdb/node-api` native bindings and for `process.env.motherduck_token` handling). `nvm use 20` works. Node 18 works too at runtime but without some newer features.
- **R ≥ 4.2** with the `arrow`, `jsonlite`, `dplyr`, and `duckdb` packages — only needed if you'll regenerate parquet locally.
- **MotherDuck account** with a service account named `duty_calculator`. The token is a JWT with `tokenType: read_write`. Get it from [app.motherduck.com](https://app.motherduck.com) → Settings → Access tokens.
- **Railway project** with two services: `tariff-rate-tracker` (backend) and `sail-gtx-prerelease` (frontend).

### Environment files

Put credentials in the repo-root `.env` of each repo (gitignored):

**`tariff-rate-tracker/.env`**
```bash
# API / MotherDuck
DATABASE_TARGET=local            # or "motherduck"
MOTHERDUCK_TOKEN=<jwt>
MOTHERDUCK_DATABASE=duty_calculator
API_PORT=3001
CORS_ALLOWED_ORIGINS=            # leave empty in dev = allow all

# R pipeline (unrelated to API)
DATAWEB_API_TOKEN=<usitc-token>
```

**`sail-gtx-prerelease/.env`** (already has Supabase / OpenAI / etc.; add):
```bash
VITE_TARIFF_API_BASE=            # leave empty in dev → Vite proxy handles /api/*
```

Templates: [`.env.example`](../.env.example) (TRT) and the SGP repo's root.

---

## Local development

The dev loop has three modes depending on what you're debugging.

### Mode A — Everything local (parquet view)

Fastest iteration; no network. Requires the 1.5 GB parquet dataset on disk.

```bash
# Terminal 1: backend in "local" mode (reads parquet directly)
cd tariff-rate-tracker
DATABASE_TARGET=local npm --prefix frontend run dev:api
# → API on http://localhost:3001

# Terminal 2: SGP frontend
cd sail-gtx-prerelease
pnpm dev                           # or npm run dev
# → http://localhost:8080/us-tariffs
```

The SGP Vite config proxies `/api/*` → `http://localhost:3001` when `VITE_TARIFF_API_BASE` is unset, so the frontend's fetches work unchanged.

### Mode B — Local frontend against cloud backend

Catches production data mismatches without deploying. Requires `MOTHERDUCK_TOKEN` configured locally.

```bash
# Terminal 1: backend pointed at MotherDuck
cd tariff-rate-tracker
DATABASE_TARGET=motherduck npm --prefix frontend run dev:api
# → still http://localhost:3001 but querying duty_calculator.rates

# Terminal 2: SGP frontend (same as Mode A)
cd sail-gtx-prerelease
pnpm dev
```

### Mode C — Local frontend against deployed Railway backend

Proves the full cloud path end-to-end. Useful right before a Vercel deploy.

```bash
# In sail-gtx-prerelease/.env:
VITE_TARIFF_API_BASE=https://tariff-rate-tracker-production.up.railway.app

cd sail-gtx-prerelease
pnpm dev
# Requests now go to Railway directly — no local backend needed
```

### Only the tariff prototype UI

Rare, but occasionally useful when debugging API responses without the full SGP chrome:

```bash
cd tariff-rate-tracker
DATABASE_TARGET=local npm --prefix frontend run dev:all
# → API on :3001 AND prototype UI on :5173 (Vite default)
```

---

## Database operations

The sync CLI lives at [`frontend/scripts/push-to-motherduck.mjs`](../frontend/scripts/push-to-motherduck.mjs). All commands run from `tariff-rate-tracker/frontend/` (or use `npm --prefix frontend`).

### Regenerate parquet from the R pipeline

```bash
# Full rebuild (any R script change)
Rscript src/00_build_timeseries.R

# Incremental — resumes from the last completed revision
Rscript src/00_build_timeseries.R --resume

# Re-emit normalized layer only (Phase 3 work)
Rscript src/00_build_timeseries.R --reemit-normalized
```

Output writes to `data/timeseries/rate_timeseries_parquet/revision=<name>/*.parquet`. This directory is gitignored.

### Push parquet → MotherDuck

```bash
cd tariff-rate-tracker/frontend

# Dry run — shows which partitions would be pushed, makes zero writes
npm run db:push-to-cloud:dry

# Full rebuild — drops+rebuilds all revisions. Required on first setup and
# any time the parquet schema changes. Takes ~10 minutes for 184M rows.
# Guards against accidental drops of a populated table: pass --confirm-drop.
npm run db:push-to-cloud -- --confirm-drop

# Incremental — replace one revision only (transactional). Use when the R
# pipeline only regenerated a single revision partition.
npm run db:push-to-cloud -- --revision 2025_rev_25

# Smaller test run — process only the first N partitions
npm run db:push-to-cloud -- --limit 3 --confirm-drop

# Tune for a slower machine (default: memory_limit=4GB, threads=2)
npm run db:push-to-cloud -- --memory-limit 8GB --threads 4 --confirm-drop
```

Key safety rails:

- **Default memory_limit is 4 GB with 2 threads** — larger settings OOM'd a 16 GB laptop during initial testing with the full 184M-row CTAS.
- **`ORDER BY` is deliberately not applied during inserts** — sorting a whole partition in-memory caused OOMs. MotherDuck's row-group min/max statistics still prune effectively on `(hts10, country, revision)` filters because the R pipeline writes parquet in a roughly hts-ordered layout.
- **`--confirm-drop`** is required if the `rates` table already exists AND has rows. Prevents accidental wipes of deployed data.
- **NDJSON logs on stdout** — every event is one JSON line: `{ts, event, ...}`. Parse from R with `jsonlite::stream_in(textConnection(result))`.

### Typical dev-loop example

After tweaking `src/06_calculate_rates.R`:

```bash
# 1. Regenerate parquet
Rscript src/00_build_timeseries.R --resume

# 2. Smoke-test against local parquet (fast, no network)
DATABASE_TARGET=local npm --prefix frontend run dev:api &
curl -s localhost:3001/api/health
kill %1

# 3. Preview what the sync will do
npm --prefix frontend run db:push-to-cloud:dry

# 4. Push just the revision you changed (transactional)
npm --prefix frontend run db:push-to-cloud -- --revision 2025_rev_25

# 5. Validate against MotherDuck before committing
DATABASE_TARGET=motherduck npm --prefix frontend run dev:api &
curl -s 'localhost:3001/api/rates?hts10=0101210000&country=5700' | jq '.data | length'
kill %1
```

### Calling the sync from R (future automation)

NDJSON output makes this a one-liner:

```r
rev <- "2025_rev_25"
result <- system2(
  "npm",
  c("--prefix", "frontend", "run", "db:push-to-cloud", "--", "--revision", rev),
  stdout = TRUE, stderr = TRUE
)
events <- jsonlite::stream_in(textConnection(result))
stopifnot(!"error" %in% events$event)
```

---

## Deployment

Three services, three dashboards. The wiring:

```
Laptop                Railway (same project)                 Vercel
─────────             ──────────────────────                 ──────────
                                                             
(R + sync)   ──push──►  tariff-rate-tracker   ◄──HTTPS───┐   sail-gtx-
MOTHERDUCK_                 │                           │    prerelease
TOKEN                  ┌────┤ DATABASE_TARGET=          │    VITE_TARIFF_
                       │    │   motherduck              │    API_BASE =
                       │    │ MOTHERDUCK_TOKEN          │    (Railway URL)
                       │    │ MOTHERDUCK_DATABASE       │
                       │    │ CORS_ALLOWED_ORIGINS ──►  │
                       │    └───────────────────────────┘
                       │    ▲
                       │    │ calls /api/* with Origin:
                       ▼    │ https://sailgtx.ai
                   MotherDuck
                   (duty_calculator)
```

Both backend and frontend live on Railway, but the frontend can **also** be deployed on Vercel (whichever is in front of `sailgtx.ai`). The backend is Railway-only. The **same-project** placement lets Railway resolve `${{Service.RAILWAY_PUBLIC_DOMAIN}}` reference variables between them.

### Railway — tariff-rate-tracker backend

Configuration files at repo root:
- [`railway.json`](../railway.json) — Nixpacks builder, `/api/health` healthcheck, restart policy.
- [`nixpacks.toml`](../nixpacks.toml) — installs Node 20, runs `cd frontend && npm ci --omit=dev`, starts `cd frontend && npm start`.
- Neither file hard-codes any domains or tokens.

**First-time setup:**

1. **Railway dashboard → your project → New → GitHub Repo → select `tariff-rate-tracker`.** Service starts building from `main` branch automatically.

2. **Generate a public domain.** Service → **Networking** tab → **Public Networking** section → **Generate Service Domain** button.
   - Target port: `8080` (the server reads `process.env.PORT` which Railway auto-injects as `8080`).
   - Copy the resulting URL (e.g. `tariff-rate-tracker-production.up.railway.app`) — you'll paste it into Vercel/SGP next.
   - Do **not** enable Private Networking for this purpose. The browser calls the API cross-origin, which requires a public domain.

3. **Configure variables.** Service → **Variables** tab → **+ New Variable** for each:

   | Variable | Value | Why |
   |---|---|---|
   | `DATABASE_TARGET` | `motherduck` | Forces cloud mode; no parquet on Railway. |
   | `MOTHERDUCK_TOKEN` | `eyJhbGciOiJIUzI1...` (full JWT) | Service-account token with `tokenType: read_write` on `duty_calculator`. |
   | `MOTHERDUCK_DATABASE` | `duty_calculator` | Case-sensitive. |
   | `CORS_ALLOWED_ORIGINS` | `https://sailgtx.ai,https://sail-gtx-prerelease-*.vercel.app,https://sail-gtx-prerelease-production.up.railway.app,http://localhost:8080` | Every origin that will call the API. Comma-separated. No spaces. No trailing slashes. `*` wildcards supported for Vercel preview URLs. |
   | `NODE_ENV` | `production` | Standard. |

   **Do NOT set:**
   - `PORT` — Railway injects this automatically.
   - `API_PORT` — legacy fallback; Railway's `PORT` takes precedence.

4. **Deploy.** Railway redeploys automatically after any variable change. The healthcheck `/api/health` polls until it returns `{"status":"ok","rows":184978080}`. First boot takes ~30s because DuckDB has to warm the MotherDuck catalog.

**Updating tokens / CORS later:**
- Edit the variable → Railway queues a new deploy → old pod drains → new pod takes over. Zero downtime in practice.
- **Never check the MotherDuck token into git.** If leaked, rotate in `app.motherduck.com` → Settings → Access tokens, then update Railway.

### Railway — sail-gtx-prerelease frontend

Use this if you want both services on Railway (single-platform simplicity). Skip to the Vercel section if you're already using Vercel.

1. **New service → GitHub Repo → `sail-gtx-prerelease`.**

2. **Generate Service Domain** (or wire a custom domain like `sailgtx.ai`). Note the URL.

3. **Variables.** Set at least:

   | Variable | Value | Why |
   |---|---|---|
   | `VITE_TARIFF_API_BASE` | `https://${{tariff-rate-tracker.RAILWAY_PUBLIC_DOMAIN}}` | Railway reference variable — auto-resolves to the backend's public URL. Replace `tariff-rate-tracker` with your actual backend service name (case-sensitive). |
   | *(other SGP vars)* | Supabase, OpenAI, etc. | Existing app config, unrelated to this integration. |

4. **After saving the variable, trigger a manual redeploy.** `VITE_*` values are compiled into the JS bundle at **build time** — changing the variable after a build has no effect until the next rebuild.

5. **Crucial: update the backend's CORS.** Go back to `tariff-rate-tracker` service → Variables → append this frontend's URL to `CORS_ALLOWED_ORIGINS`. Save. Backend redeploys with the new allowlist.

### Vercel — sail-gtx-prerelease frontend

1. **Vercel dashboard → your project → Settings → Environment Variables.**

2. **Add `VITE_TARIFF_API_BASE`:**
   - **Value**: exactly `https://tariff-rate-tracker-production.up.railway.app` (or your actual Railway backend domain). Paste it once, check it once, paste-doubling a URL has bitten this project before.
   - **No trailing slash.**
   - **One `https://`.** If your browser pasted `https://https://...`, remove the duplicate.
   - **Environments**: tick **Production**, **Preview**, and **Development** so the var flows to every branch deploy.

3. **Trigger a redeploy.** Vite compiles env vars into the bundle — existing deploys keep the old value forever until rebuilt.
   - Deployments tab → find the production deploy → **⋯ menu → Redeploy**.
   - **Un-tick "Use existing Build Cache"** so the redeploy actually picks up the new env var. The cache would skip the rebuild otherwise.

4. **Update the Railway backend's CORS** to include every Vercel hostname that will call the API. Preview branches look like `https://sail-gtx-prerelease-git-<branch>-<scope>.vercel.app` — the wildcard pattern `https://sail-gtx-prerelease-*.vercel.app` catches all of them. The backend's CORS middleware supports `*` wildcards.

5. **Hard-refresh in the browser** after the deploy completes (Ctrl+Shift+R / Cmd+Shift+R). Otherwise the cached old JS keeps using the stale API base.

**Gotcha**: Vercel treats `/api/*` as serverless functions by default. The tariff module's fetches go through `apiUrl()` which prepends the Railway URL, so they never hit Vercel's `/api/*` handler. If you ever see requests with path `/api/...` on the `sailgtx.ai` origin, `VITE_TARIFF_API_BASE` didn't make it into the build — redeploy without cache.

### What does NOT get deployed

- **Parquet files (1.5 GB)** — never shipped anywhere. MotherDuck stores the data; Railway runs the API with no parquet on disk; Vercel only ships the React bundle.
- **HTS archive JSONs** (`data/hts_archives/`) — gitignored. Server gracefully degrades: `/api/product-info` returns null matches if the dir is absent.
- **The R pipeline scripts** (`src/`) — R doesn't run on Railway or Vercel. Parquet regeneration stays local for now (see [Future work](#future-work)).
- **`sample_rates.json`** — 155 MB preview dataset; intentionally not shipped. Dashboard tab empty-states cleanly without it.
- **`.env` files** — gitignored. Tokens live only in Railway / Vercel dashboards and your laptop's local `.env`.

### Cross-service env var sync at a glance

When the backend URL changes (custom domain, new service, etc.):

1. Update `VITE_TARIFF_API_BASE` in the frontend host (Vercel **and/or** Railway SGP service).
2. If the frontend URL also changed, update `CORS_ALLOWED_ORIGINS` in Railway tariff-rate-tracker.
3. **Both services need a rebuild** — not just an env change — because of Vite's build-time baking.

When the MotherDuck token rotates:

1. Update `MOTHERDUCK_TOKEN` on Railway tariff-rate-tracker. Redeploy.
2. Update `.env` on your laptop for local dev + sync CLI.
3. No frontend impact — token never reaches the browser.

When a new revision is generated locally:

1. `Rscript src/00_build_timeseries.R --resume` (writes parquet locally).
2. `npm --prefix frontend run db:push-to-cloud -- --revision 2025_rev_26` (transactional replace).
3. No deploy needed — Railway backend queries MotherDuck live. Data is immediately visible on `sailgtx.ai`.

---

## Environment variables reference

### Tariff backend (tariff-rate-tracker)

| Variable | Required | Default | Purpose |
|---|---|---|---|
| `DATABASE_TARGET` | yes | `local` | `local` = in-memory DuckDB over parquet files; `motherduck` = cloud MotherDuck. |
| `MOTHERDUCK_TOKEN` | if `motherduck` | — | Service-account JWT. Required when `DATABASE_TARGET=motherduck` or running the sync CLI. |
| `MOTHERDUCK_DATABASE` | no | `duty_calculator` | Target MotherDuck database. |
| `PORT` | no | `3001` | Injected by Railway. Server also accepts `API_PORT` as legacy fallback. |
| `API_PORT` | no | `3001` | Fallback for local dev when `PORT` isn't set. |
| `CORS_ALLOWED_ORIGINS` | no | empty (= allow all) | Comma-separated list of allowed origins. `*` wildcards supported (e.g. `https://*.vercel.app`). Empty list in dev means any origin works. |
| `DATAWEB_API_TOKEN` | only for R pipeline | — | USITC DataWeb API token. Not used by the Node server. |

### SGP frontend

| Variable | Required | Default | Purpose |
|---|---|---|---|
| `VITE_TARIFF_API_BASE` | in production | empty | Base URL of the tariff backend. Empty = same-origin (used in dev with the Vite proxy). Must be set + rebuilt for any deployed environment. **No trailing slash.** |

Every other SGP var (Supabase, OpenAI, etc.) is unrelated to this integration.

---

## Verification playbook

When in doubt, run these in order. Each step fails before the next can pass.

### 1. Token reach

```bash
cd tariff-rate-tracker/frontend
node -e "
import('@duckdb/node-api').then(async ({ DuckDBInstance }) => {
  const fs = await import('fs');
  const path = await import('path');
  const envText = fs.readFileSync(path.resolve('..', '.env'), 'utf-8');
  process.env.motherduck_token = envText.match(/^MOTHERDUCK_TOKEN=(.+)\$/m)[1].trim();
  const c = await (await DuckDBInstance.create('md:duty_calculator')).connect();
  const r = await c.runAndReadAll('SELECT count(*) AS n FROM rates');
  console.log('rates rows:', Number(r.getRowObjects()[0].n).toLocaleString());
})"
```
Expected: `rates rows: 184,978,080` (or whatever your current dataset size is).

### 2. Local API parity

```bash
# Start both modes on different ports
DATABASE_TARGET=local API_PORT=3098 node frontend/server.js &
DATABASE_TARGET=motherduck API_PORT=3097 node frontend/server.js &
sleep 5
diff \
  <(curl -s 'localhost:3098/api/rates?hts10=0101210000&country=5700' | jq -S .) \
  <(curl -s 'localhost:3097/api/rates?hts10=0101210000&country=5700' | jq -S .) \
  && echo "PARITY: OK" || echo "PARITY: DIFFERS"
kill %1 %2
```

### 3. Deployed backend reachable

```bash
curl -s https://tariff-rate-tracker-production.up.railway.app/api/health
```
Expected: `{"status":"ok","rows":184978080}`.

### 4. CORS allows the browser origin

```bash
curl -sI -X OPTIONS \
  -H "Origin: https://sailgtx.ai" \
  -H "Access-Control-Request-Method: GET" \
  https://tariff-rate-tracker-production.up.railway.app/api/rates \
  | grep -i access-control-allow-origin
```
Expected: `access-control-allow-origin: https://sailgtx.ai`.

### 5. Frontend calls the right URL

Open the deployed site → DevTools → Network → do a rate lookup. The `/api/rates?...` request URL should be exactly `https://tariff-rate-tracker-production.up.railway.app/api/rates?hts10=...&country=...` — one `https://`, one domain, no proxying through the frontend origin.

---

## Troubleshooting

### "JSON.parse: unexpected character at line 1 column 1" in browser

The frontend fetched a JSON endpoint but got HTML back. Usually means the request 404'd and Vite/Vercel served the SPA `index.html` fallback with HTTP 200. Check which file — in dev, `Content-Type: text/html` in the Network tab is the giveaway. Fix by either shipping the missing JSON or wrapping the fetch in a content-type guard (see `fetchJson` in [`useTariffData.ts`](../../GitHub_sail-gtx-prerelease/sail-gtx-prerelease/src/modules/tariff-rates/hooks/useTariffData.ts)).

### Request URL has the domain doubled

```
https://tariff-rate-tracker-production.up.railway.apptariff-rate-tracker-production.up.railway.app/api/rates
```

`VITE_TARIFF_API_BASE` was set to a doubled string. Fix in the Vercel/Railway dashboard: exactly `https://<domain>.up.railway.app` — no trailing slash, no repetition. Then **rebuild** — Vite bakes env vars at build time.

### CORS error in browser console

Backend's `CORS_ALLOWED_ORIGINS` doesn't include the frontend's origin. Add it (comma-separated, wildcards OK) and restart the Railway service. Verify with the curl OPTIONS preflight check in the Verification playbook.

### "No rates found for HTS X (Country Y)" in the UI

- First confirm the backend has the data: hit `/api/rates?hts10=...&country=...` directly via curl.
- If backend returns `{"data": [...]}` but the UI shows "No rates found", the frontend is probably using a stale build. Redeploy with cache disabled and hard-refresh.
- If backend itself returns `{"data": []}`, the combination genuinely has no rows (not every HTS × country × revision tuple is populated — the base-MFN synthesis handles many of these). Check with the SQL console in MotherDuck UI.

### OOM during `npm run db:push-to-cloud`

The default 4 GB memory limit is tight. Lower the thread count or raise the memory cap:

```bash
npm run db:push-to-cloud -- --memory-limit 6GB --threads 1 --confirm-drop
```

### Sync fails partway, leaves partial data

The full-rebuild path uses `CREATE OR REPLACE TABLE` on the first revision and `INSERT` on subsequent ones. A failure mid-run leaves a partially-populated table. Recovery:
- Re-run with `--confirm-drop` to wipe and restart.
- Or inspect which revisions landed (`SELECT DISTINCT revision FROM rates`) and `--revision` the missing ones one by one.

The incremental `--revision` path is transactional (`BEGIN; DELETE; INSERT; COMMIT`) and auto-rolls back on failure.

### Vite fails to pre-bundle `apache-arrow` in dev

Symptom: `error loading dynamically imported module: .../apache-arrow.js`. apache-arrow's conditional exports map doesn't play nicely with esbuild. Fix is in [`sail-gtx-prerelease/vite.config.ts`](../../GitHub_sail-gtx-prerelease/sail-gtx-prerelease/vite.config.ts) — apache-arrow is in `optimizeDeps.exclude` so Vite serves it through the full plugin pipeline. If the error returns, clear the Vite cache:

```bash
cd sail-gtx-prerelease
rm -rf node_modules/.vite
pnpm dev
```

### MotherDuck shows more storage than `duty_calculator` actually contains

MotherDuck retains dropped databases in **Historical** storage for a retention window (~7 days) before purging. If you just dropped an old database (e.g. we renamed `tariff_rates` → `duty_calculator`), expect total org storage to be ~2× the active figure until the retention window closes. Check the Storage Lifecycle breakdown in the MD UI.

### Service account can't see a database owned by a personal user

Each MotherDuck account (personal or service) has its own catalog. The `duty_calculator` service account only sees databases it owns or has been granted access to. To drop a database owned by `william@sailgtx.com`, log in to the MD UI as that user — the service account can't do it.

---

## Future work

Unblocked but not implemented yet:

- **Scheduled sync from R.** `00_build_timeseries.R` could invoke `npm run db:push-to-cloud -- --revision <rev>` via `system2()` after writing each partition. NDJSON log format already supports this (see [Calling the sync from R](#calling-the-sync-from-r-future-automation)).
- **`/api/sample-rates` endpoint** — eliminates the need to ship a 155 MB preview file; the Dashboard tab could fetch a 1k-row sample from MotherDuck on demand.
- **HTS archive JSON → MotherDuck** — currently HTS descriptions come from local JSON files that aren't shipped to Railway. Moving them into a `hts_descriptions` table in `duty_calculator` lets `/api/product-info` work in deployed environments.
- **Rotating the service account token** — after six months, rotate `MOTHERDUCK_TOKEN` in MD → update Railway backend + any scripted jobs. The API reads the env var at process start, so a redeploy picks up the new token.
- **Phase 3 normalized layers** — `output/normalized/*.parquet` is already emitted by the R pipeline but currently feature-flagged OFF (`USE_NORMALIZED_GAPFILL`). When flipped on, this layer also needs to land in MotherDuck via a second table in `duty_calculator`.

---

## Quick reference

```bash
# === Local dev, all-local data ===
DATABASE_TARGET=local npm --prefix frontend run dev:api             # tariff-rate-tracker
pnpm dev                                                            # sail-gtx-prerelease

# === Local dev, cloud data ===
DATABASE_TARGET=motherduck npm --prefix frontend run dev:api

# === Regenerate parquet ===
Rscript src/00_build_timeseries.R --resume

# === Push to MotherDuck ===
npm --prefix frontend run db:push-to-cloud:dry                      # preview
npm --prefix frontend run db:push-to-cloud -- --confirm-drop        # full
npm --prefix frontend run db:push-to-cloud -- --revision 2025_rev_25  # incremental

# === Deploy ===
git push                                                             # Railway + Vercel auto-deploy
# After changing VITE_TARIFF_API_BASE, force a rebuild (no cache) in Vercel.

# === Verify deployed backend ===
curl -s https://tariff-rate-tracker-production.up.railway.app/api/health
```
