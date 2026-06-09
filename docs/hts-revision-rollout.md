# HTS Revision Rollout — Operational Runbook

The complete path a new USITC HTS revision travels: **discover → download → build →
push to MotherDuck → deploy + flip the app to the new revision**. Phases A–B build
and publish the rate/duty data (queried from MotherDuck); phase C is the
`scripts/hts_automation/` automation that deploys the HTS dataset to
**sail-gtx-prerelease** (Railway API server + Vercel frontend), refreshes the Ragie
RAG index, records the revision in Supabase, and repoints both deployments.

Related docs: data build internals — [data-pipeline-README.md](data-pipeline-README.md);
MotherDuck integration — [MOTHERDUCK.md](MOTHERDUCK.md); provenance bundles —
[PROVENANCE_PIPELINE.md](PROVENANCE_PIPELINE.md).

## Table of Contents

1. [The full sequence (discovery → deploy)](#1-the-full-sequence-discovery--deploy)
2. [Quick start (the deploy phase)](#2-quick-start-the-deploy-phase)
3. [One-time setup: credentials](#3-one-time-setup-credentials)
4. [The 9 deploy steps](#4-the-9-deploy-steps)
5. [Flags reference](#5-flags-reference)
6. [Where everything lands](#6-where-everything-lands)
7. [Resuming after a failed step](#7-resuming-after-a-failed-step)
8. [Troubleshooting](#8-troubleshooting)
9. [Rollback](#9-rollback)
10. [Verifying success](#10-verifying-success)
11. [Security notes](#11-security-notes)
12. [What changed in this automation](#12-what-changed-in-this-automation)

---

## 1. The full sequence (discovery → deploy)

A new revision goes through three phases. **Run them in order** — the deploy phase
does not build rate data or push to MotherDuck, so phases A and B must happen
first or the duty calculator will be missing the new revision's numbers.

### Phase A — Build the rate data (R pipeline, this repo)

```bash
# 1. Discover new revisions from the USITC API → updates config/revision_dates.csv
Rscript src/01_scrape_revision_dates.R

# 2. In config/revision_dates.csv: set the correct effective_date for the new row
#    and clear its needs_review flag.

# 3. Download the HTS archive for the year (skips if already present)
Rscript src/02_download_hts.R --year 2026

# 4. Incremental build — auto-detects the new revision; writes Parquet partitions,
#    daily series, and the frontend JSON exports
Rscript src/00_build_timeseries.R
```

`00_build_timeseries.R` (no flags) is incremental: it only builds revisions not
already in `data/timeseries/rate_timeseries_parquet/`. Use `--full` to rebuild all
revisions (after a schema/logic change). See
[data-pipeline-README.md](data-pipeline-README.md) for the full command set.

### Phase B — Publish rate data to MotherDuck (from your laptop)

The deployed app queries **MotherDuck** for all rate/duty data. This is the step
that makes the new revision's duty numbers live in the calculator.

```bash
cd frontend

# Incremental: replace just the new revision's rows in the cloud `rates` table
# (transactional — DELETE WHERE revision=… then INSERT; rolls back on failure)
npm run db:push-to-cloud -- --revision 2026_rev_10

# Full rebuild instead (after a schema change or regenerating all revisions):
# npm run db:push-to-cloud -- --confirm-drop
```

- Requires `MOTHERDUCK_TOKEN` in the **repo-root `.env`** (the push CLI loads
  `tariff-rate-tracker/.env`). `MOTHERDUCK_DATABASE` defaults to `tariff_rates`.
- Run **from your laptop only** — neither Railway nor Vercel writes to MotherDuck.
- Useful flags: `--dry-run`, `--limit 3` (first N partitions, testing),
  `--only-revisions 2019,2020` (a set/range), `--post-only` (recluster + rebuild
  `product_base_rates` on the existing table), `--memory-limit 8GB`.
- Full details and rebuild semantics: [MOTHERDUCK.md](MOTHERDUCK.md).

### Phase C — Deploy + flip the app to the new revision

```bash
scripts/hts_automation/run_locally.sh
```

This is the 9-step automation detailed in the rest of this document. It commits the
HTS dataset JSON into sail-gtx, swaps the Ragie index, upserts Supabase, and sets
the Railway/Vercel env vars that switch the live app to the new revision.

> Note: phase C also re-runs scrape/download (steps 1–3) for safety, so it works
> even if you skipped phase A locally — but it never builds the timeseries or
> pushes to MotherDuck. Phases A + B are not optional.

---

## 2. Quick start (the deploy phase)

```bash
cd /path/to/tariff-rate-tracker

# one-time: create the secrets file (gitignored) + install Python deps
cp scripts/hts_automation/.env.hts_automation.example scripts/hts_automation/.env.hts_automation
pip install -r scripts/hts_automation/requirements.txt
# ...then edit scripts/hts_automation/.env.hts_automation and fill in every value (section 3)

# roll out the latest published revision
scripts/hts_automation/run_locally.sh

# or a specific revision / a no-write rehearsal
scripts/hts_automation/run_locally.sh --revision 2026_rev_10
scripts/hts_automation/run_locally.sh --dry-run
```

`run_locally.sh` sources `.env.hts_automation` automatically. In CI the same
rollout runs as **`.github/workflows/hts-revision-update.yml`**; `run_locally.sh`
is the manual/local equivalent and the two are kept in lockstep.

---

## 3. One-time setup: credentials

The deploy phase's secrets live in **`scripts/hts_automation/.env.hts_automation`**
— copied from `.env.hts_automation.example`, **gitignored, never committed**. Fill
in all of these (the MotherDuck token for phase B lives separately, in the repo-root
`.env`):

| Variable | Used by (step) | How to get it |
|----------|----------------|---------------|
| `RAGIE_API_KEY` (`tnt_…`) | 5 Ragie swap, 8 doc-id lookup | Ragie dashboard → API Keys |
| `SUPABASE_URL` | 6 Supabase upsert | Supabase project → Settings → API → Project URL (preset in the template) |
| `SUPABASE_SERVICE_ROLE_KEY` (`eyJ…`) | 6 Supabase upsert | Supabase project → Settings → API → the **`service_role`** secret key |
| `SAIL_GTX_REPO_PAT` (`github_pat_…`) | 7 cross-repo commit | GitHub fine-grained PAT — see [3.1](#31-github-pat-sail_gtx_repo_pat) |
| `SAIL_GTX_PRODUCTION_BRANCH` | 7, 8 | sail-gtx branch the deploys read from (e.g. `illegal-transshipment`). Config, not a secret. |
| `RAILWAY_TOKEN` | 8 Railway env | Railway token — see [3.2](#32-railway-token--ids) |
| `RAILWAY_PROJECT_ID` / `_SERVICE_ID` / `_ENVIRONMENT_ID` | 8 Railway env | From the dashboard URL — see [3.2](#32-railway-token--ids) |
| `VERCEL_TOKEN` | 8 Vercel env | Vercel → Account Settings → Tokens → Create Token (scope it to the team owning the project) |
| `VERCEL_PROJECT_ID` (`prj_…`) | 8 Vercel env | Vercel project → Settings → General → Project ID (set `VERCEL_TEAM_ID` too if on a team) |
| `SAIL_GTX_HEALTHCHECK_URL` / `SAIL_GTX_API_BASE` | 9 smoke test | Deployed Railway URLs (preset in the template) |
| `GIT_USER_NAME` / `GIT_USER_EMAIL` | 7 commit author | Optional; defaults to `sail-gtx-bot` |

Phase B also needs **`MOTHERDUCK_TOKEN`** (a JWT) in the **repo-root `.env`** — see
[MOTHERDUCK.md](MOTHERDUCK.md).

### 3.1 GitHub PAT (`SAIL_GTX_REPO_PAT`)

GitHub → your avatar → **Settings → Developer settings → Fine-grained tokens →
Generate new token**:

- **Resource owner:** `SAIL-Engineering`
- **Repository access:** Only select repositories → `sail-gtx-prerelease`
- **Repository permissions → Contents → Read and write** (this is the one that
  matters; `Metadata: Read` is automatic). Nothing else is needed.

Then, because the repo is in an **organization**:

- **Approve the token.** Org-owned fine-grained PATs need an org owner to approve
  them: `SAIL-Engineering` → Settings → Personal access tokens → **Pending
  requests**. Until approved, the token has no access and clone/push 403s.
- **SAML SSO:** if the org enforces SSO, authorize the token for `SAIL-Engineering`
  on the token page.

You can **edit an existing token's permissions** (Developer settings → the token →
Edit) without regenerating it — the token value stays the same, so no `.env`
change is needed; changing permissions may re-trigger org approval.

### 3.2 Railway token + IDs

**Token.** Either an **account/workspace** token (Railway → avatar → Account
Settings → Tokens) or a **project** token (Railway → the project → Settings →
Tokens, scoped to the **production** environment). Both work — the pipeline
auto-detects which header style to use (`Authorization: Bearer` for
account/workspace tokens, `Project-Access-Token` for project tokens).

**The three IDs** all come from the dashboard URL. Open the **`sailgtx-server`**
service in the **production** environment; the address bar reads:

```
https://railway.app/project/<RAILWAY_PROJECT_ID>/service/<RAILWAY_SERVICE_ID>?environmentId=<RAILWAY_ENVIRONMENT_ID>
```

`RAILWAY_SERVICE_ID` is what targets the right service rather than a sibling repo
in the same project — click the correct service before copying.

---

## 4. The 9 deploy steps

`run_locally.sh` runs these in order. Each line names the script and what it touches.

| # | Step | What it does | Needs |
|---|------|--------------|-------|
| 1 | Scrape | `01_scrape_revision_dates.R` polls USITC, updates `config/revision_dates.csv`, clears `needs_review` | — |
| 2 | Resolve target | `latest_revision.R` picks the target revision and resolves its year / number / effective date / `JSON_PATH` / `CSV_PATH` | — |
| 3 | Download | `02_download_hts.R` fetches the HTS JSON + CSV for the year if missing | — |
| 4 | Ragie minimal CSV | `build_hts_minimal.py` trims the CSV for the RAG partition | — |
| 5 | Ragie partition swap | `ragie_sync.py swap` uploads the new CSV to `us_hts_<year>_latest`, waits for `ready`, deletes the old docs | `RAGIE_API_KEY` |
| 6 | Supabase upsert | `supabase_insert_revision.py` upserts the revision row into `hts_revisions` (incl. `ragie_partition_id`) | `SUPABASE_*` |
| 7 | Cross-repo commit | `sail_gtx_commit.py` commits the dataset JSON to sail-gtx — **both** `server/data/hts/` **and** `public/data/hts-explorer/` — + a `hts-<year>-rev<n>` tag | `SAIL_GTX_REPO_PAT`, `SAIL_GTX_PRODUCTION_BRANCH` |
| 8 | Env var update | `update_env_vars.py set` sets `VITE_HTS_REVISION_*` **and** `RAGIE_DOCUMENT_ID` on **Railway + Vercel** (the redeploy), snapshotting prior values to `/tmp/hts-env-snapshot.json` | `RAILWAY_*`, `VERCEL_*`, `RAGIE_API_KEY` |
| 9 | Smoke test | `smoke_test.py` hits the health + API endpoints to confirm the redeploy serves the new revision | `SAIL_GTX_HEALTHCHECK_URL`, `SAIL_GTX_API_BASE` |

> **Step ordering matters.** Step 7 (commit the JSON) must run before step 8
> (env-var change → redeploy). The server asserts the JSON file exists at boot, so
> if the env var flips before the file is committed the redeploy fails its boot
> check. A step-7 failure therefore halts the run before steps 8-9 ever execute.

The Ragie partition name is `us_hts_<year>_latest` (derived from the resolved year
in steps 5/6/8), so a new HTS year automatically uses a new partition. The deployed
app reads the active partition from `supported_countries.ragie_partition_id` in
Supabase (written in step 6), so partitions rotate without an app redeploy.

---

## 5. Flags reference

`run_locally.sh`:

| Flag | Effect |
|------|--------|
| *(none)* | Roll out the latest published revision |
| `--revision <id>` | Target a specific revision, e.g. `--revision 2026_rev_10` |
| `--dry-run` | Run every step but make **no** external writes (clone + diff only; no push, upsert, or env change) |
| `--skip-scrape` | Skip step 1; reuse the existing `config/revision_dates.csv` |
| `--run-classify` / `--skip-classify` | Toggle the optional canary classify (default: skip) |

`update_env_vars.py set` (step 8, also used standalone for resume):

| Flag | Effect |
|------|--------|
| `--year` / `--rev-num` / `--effective-date-label` | The revision identity written to `VITE_HTS_REVISION_*` (required) |
| `--ragie-partition <name>` | Resolve `RAGIE_DOCUMENT_ID` from the current document in this Ragie partition and set it too (e.g. `us_hts_2026_latest`) |
| `--ragie-document-id <uuid>` | Set `RAGIE_DOCUMENT_ID` explicitly (overrides `--ragie-partition`) |
| `--snapshot-out <path>` | Write prior values to this JSON for rollback |

`sail_gtx_commit.py` (step 7, also used standalone for resume):

| Flag | Effect |
|------|--------|
| `--owner` / `--repo` / `--branch` | Target repo + branch |
| `--source <path>` | Local JSON to publish |
| `--dest-path <path>` | Path inside the repo. **Repeatable** — pass it twice to write the same source to `server/data/hts/` and `public/data/hts-explorer/` in one commit |
| `--tag-name <tag>` | Optional lightweight tag |
| `--commit-message <msg>` | Commit message |
| `--dry-run` | Clone + diff locally, do not push |

`push-to-motherduck.mjs` (phase B): `--revision <id>`, `--confirm-drop`,
`--dry-run`, `--limit <n>`, `--only-revisions <list>`, `--post-only`,
`--memory-limit <size>`.

---

## 6. Where everything lands

| Target | What | How |
|--------|------|-----|
| MotherDuck `rates` table | New revision's rate rows (the duty data the app queries) | Phase B (`db:push-to-cloud`) |
| Ragie partition `us_hts_<year>_latest` | New minimal CSV document (old deleted) | Step 5 |
| Supabase `hts_revisions` | Revision row + `ragie_partition_id` | Step 6 |
| sail-gtx `server/data/hts/hts_<y>_revision_<n>.json` | Full dataset for the Railway API server (`HTS_DATA_DIR`) | Step 7 |
| sail-gtx `public/data/hts-explorer/hts_<y>_revision_<n>.json` | Full dataset for the Vercel static frontend (HTS Explorer) | Step 7 |
| Railway + Vercel env | `VITE_HTS_REVISION_YEAR/NUMBER/EFFECTIVE_DATE`, `RAGIE_DOCUMENT_ID` | Step 8 |

Two things are **automatic** and never pushed by hand:

- `public/data/hts-explorer/manifest.json` (tells the frontend which revision to
  load) is regenerated at sail-gtx build time by the Vite `htsManifestPlugin`.
- The Ragie partition the app queries is read from Supabase at job-enqueue time —
  never hardcoded in the app.

> `sail_gtx_commit.py` clones sail-gtx into a **temp dir**, commits, and pushes to
> the **remote** production branch, then deletes the clone. It does **not** modify
> your local sail-gtx checkout — run `git pull` there if you want the files
> locally. (The deploy reads the remote branch, so this is not required.)

---

## 7. Resuming after a failed step

Steps 1-6 are idempotent, so re-running `run_locally.sh` from the top is always
safe (Ragie ends with one ready doc, the Supabase upsert is keyed, the commit
skips byte-identical files). To avoid re-uploading to Ragie (~5 min), resume from
the failed step manually instead. **The Python scripts read secrets from the
environment, so source the env file first, in the same shell:**

```bash
cd /path/to/tariff-rate-tracker
set -a; source scripts/hts_automation/.env.hts_automation; set +a
```

Resolve the exact values (read-only, no external writes):

```bash
Rscript scripts/hts_automation/latest_revision.R --revision 2026_rev_10
# -> YEAR, REV_NUM, EFFECTIVE_DATE, EFFECTIVE_DATE_LABEL, JSON_PATH, CSV_PATH
```

**Step 7 — cross-repo commit:**

```bash
python3 scripts/hts_automation/sail_gtx_commit.py \
  --owner SAIL-Engineering --repo sail-gtx-prerelease \
  --branch "$SAIL_GTX_PRODUCTION_BRANCH" \
  --source data/hts_archives/hts_2026_rev_10.json \
  --dest-path "server/data/hts/hts_2026_revision_10.json" \
  --dest-path "public/data/hts-explorer/hts_2026_revision_10.json" \
  --tag-name "hts-2026-rev10" \
  --commit-message "chore: HTS 2026 Rev 10 dataset (effective 2026-06-08)"
```

**Step 8 — env vars (also repoints `RAGIE_DOCUMENT_ID`):**

```bash
python3 scripts/hts_automation/update_env_vars.py set \
  --year 2026 --rev-num 10 --effective-date-label "June 8, 2026" \
  --ragie-partition us_hts_2026_latest \
  --snapshot-out /tmp/hts-env-snapshot.json
```

**Step 9 — smoke test:**

```bash
python3 scripts/hts_automation/smoke_test.py --year 2026 --rev-num 10
```

(Substitute the year / rev number / effective date / source path for your
revision. `data/hts_archives/hts_<YEAR>_rev_<N>.json` is the value `latest_revision.R`
prints as `JSON_PATH`.)

---

## 8. Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| `ERROR: env var X is required` running a script by hand | `.env` not loaded into the shell; `$VAR` expanded empty | `set -a; source scripts/hts_automation/.env.hts_automation; set +a` **in the same shell**, then re-run |
| Step 7 `Invalid username or token. Password authentication is not supported` | `SAIL_GTX_REPO_PAT` is missing / still the `github_pat_REPLACE_ME` placeholder | Put a real fine-grained PAT in `.env` ([3.1](#31-github-pat-sail_gtx_repo_pat)) |
| Step 7 `403 Write access to repository not granted` (fails at `git clone`) | PAT authenticated but not authorized: **org approval pending**, **SSO not authorized**, **Contents permission not Read+write**, or wrong repo selected | Approve the token in the org's Pending requests; authorize SSO; set Contents: Read and write; confirm the repo is selected ([3.1](#31-github-pat-sail_gtx_repo_pat)) |
| Step 8 `Railway GraphQL: [{"message": "Not Authorized"…}]` | A Railway **project token** sent with `Authorization: Bearer` (project tokens use `Project-Access-Token`), or a token without access to the project | Auto-handled now (the script falls back to `Project-Access-Token`); if it still fails on **both** styles, the token can't access the project/environment — check `RAILWAY_*_ID` point at the right service+production env, or use a SAIL-Team-scoped account token |
| Step 8 sets the `VITE_HTS_REVISION_*` vars but **not** `RAGIE_DOCUMENT_ID` | Older behavior — `set` only handled the revision vars | Pass `--ragie-partition us_hts_<year>_latest` (now wired into the pipeline); or `--ragie-document-id <uuid>` |
| Step 8 `no documents found in Ragie partition` | Step 5 didn't complete, or wrong partition name | Confirm step 5 ran (`ragie_sync.py list --partition us_hts_<year>_latest`); check the partition year |
| Smoke test reports the app still on the old revision | Railway/Vercel redeploy still in flight | Wait ~1 min for the redeploy, then re-run `smoke_test.py --year <Y> --rev-num <N>` |
| Vercel env update 403 / unauthorized | `VERCEL_TOKEN` not scoped to the team owning the project, or missing `VERCEL_TEAM_ID` | Recreate the token scoped to the team; set `VERCEL_TEAM_ID` |
| Duty calculator shows no data / old rates after deploy | Phase B skipped — MotherDuck `rates` table not updated | `cd frontend && npm run db:push-to-cloud -- --revision <id>` |

The token value is **redacted** in all `sail_gtx_commit.py` log output (the clone
URL prints `x-access-token:***@github.com`), so terminal scrollback and CI logs
won't leak it.

---

## 9. Rollback

Step 8 snapshots the prior Railway/Vercel values (including the prior
`RAGIE_DOCUMENT_ID`) before changing anything. To revert the env vars to their
previous values (which redeploys the app back):

```bash
set -a; source scripts/hts_automation/.env.hts_automation; set +a
python3 scripts/hts_automation/update_env_vars.py revert --snapshot /tmp/hts-env-snapshot.json
```

The sail-gtx JSON commit (step 7) is additive and does not need rolling back; the
app only serves a revision once its env var points at it. To roll the MotherDuck
rate data back, re-push the prior revision with `db:push-to-cloud --revision <prev>`.

---

## 10. Verifying success

- **MotherDuck:** the `rates` table contains the new revision
  (`SELECT DISTINCT revision FROM rates ORDER BY revision DESC LIMIT 5;`).
- **sail-gtx remote branch** (run from your local sail-gtx checkout, which has your
  git credentials):
  ```bash
  git fetch origin "$SAIL_GTX_PRODUCTION_BRANCH"
  git log origin/"$SAIL_GTX_PRODUCTION_BRANCH" --oneline -3      # the "chore: HTS … dataset" commit
  git ls-tree origin/"$SAIL_GTX_PRODUCTION_BRANCH" server/data/hts/ public/data/hts-explorer/ | grep revision_<n>
  ```
- **Manifest:** after the Vercel build, `public/data/hts-explorer/manifest.json`
  names the new revision.
- **Env vars:** Railway and Vercel show `VITE_HTS_REVISION_NUMBER` = the new rev and
  `RAGIE_DOCUMENT_ID` = the new document id (the step-8 `[ragie] resolved …` line
  shows what it set).
- **Smoke test** (step 9) passes against the live URLs.

---

## 11. Security notes

- **Never commit `.env.hts_automation` or the repo-root `.env`** — both are
  gitignored. They hold the PAT, the API tokens, and `MOTHERDUCK_TOKEN`.
- **Rotate any token that gets printed.** Tokens are redacted in script output, but
  if one ends up in a log/screenshot, revoke and regenerate it.
- **No hardcoded keys.** Scripts read `RAGIE_API_KEY` (and every other secret) from
  the environment. Do not paste API keys into source — a committed helper with a
  literal key (e.g. an ad-hoc `ragie_List_Documents.py`) is a leak; rotate the key
  and switch it to `os.environ[...]`.
- The `SAIL_GTX_REPO_PAT` scope is intentionally minimal: Contents: Read and write
  on `sail-gtx-prerelease` only.

---

## 12. What changed in this automation

Recent fixes baked into the scripts above (so future rollouts "just work"):

- **Dual-destination commit.** `sail_gtx_commit.py` `--dest-path` is repeatable;
  `run_locally.sh` + the workflow push the dataset to **both** `server/data/hts/`
  (Railway server) and `public/data/hts-explorer/` (Vercel frontend) in one commit.
  Previously only the server path was updated, so the frontend HTS Explorer lagged a
  revision behind.
- **PAT redaction.** `sail_gtx_commit.py` scrubs the token from every echoed command
  and from git stdout/stderr.
- **Railway project-token support.** `update_env_vars.py` tries `Authorization:
  Bearer` then falls back to the `Project-Access-Token` header, so Railway project
  tokens (the kind created in Project → Settings → Tokens) work.
- **`RAGIE_DOCUMENT_ID` propagation.** `update_env_vars.py set` now resolves the
  current document id from the Ragie partition (`--ragie-partition`) and sets
  `RAGIE_DOCUMENT_ID` on Railway + Vercel, and snapshots it for rollback. Previously
  the new document id was never pushed, leaving the app pointed at the deleted old
  document.
- **Year-generalized partition.** Steps 5/6/8 use `us_hts_${YEAR}_latest` instead of
  a hardcoded `us_hts_2026_latest`, so a new HTS year rolls to a new partition
  automatically (the app reads it from Supabase).
