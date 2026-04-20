# Scripts

## `push-to-motherduck.mjs` — local parquet → MotherDuck

Syncs the R pipeline's partitioned parquet output at
`data/timeseries/rate_timeseries_parquet/` into a MotherDuck cloud database.
Pushes one revision partition at a time so peak local RAM stays bounded.

### Prereqs

- `MOTHERDUCK_TOKEN` in repo-root `.env` (see `.env.example`).
- `MOTHERDUCK_DATABASE` (optional; defaults to `duty_calculator`).
- Parquet dataset present locally (regenerate with `Rscript src/00_build_timeseries.R`).

### Commands (run from `frontend/`)

```bash
# Full rebuild — 39 revision partitions, one at a time. Safe to re-run.
# Requires --confirm-drop only if `rates` already has data.
npm run db:push-to-cloud

# Preview without writing. Lists planned partitions.
npm run db:push-to-cloud:dry

# Replace a single revision (transactional DELETE + INSERT).
npm run db:push-to-cloud -- --revision 2025_rev_25

# Test with just the first N partitions.
npm run db:push-to-cloud -- --limit 3 --confirm-drop

# Tune memory/parallelism if the default (4GB, 2 threads) is wrong for your
# machine. Lower both if you see OOMs; raise them if you want faster syncs.
npm run db:push-to-cloud -- --memory-limit 8GB --threads 4
```

### Dev loop

```bash
# 1. Regenerate parquet (when R scripts change)
Rscript src/00_build_timeseries.R

# 2. Local smoke-test (fast, no network)
DATABASE_TARGET=local npm --prefix frontend run dev:api
curl localhost:3001/api/health

# 3. Push to cloud
npm --prefix frontend run db:push-to-cloud -- --confirm-drop

# 4. Smoke-test against the cloud copy before deploy
DATABASE_TARGET=motherduck npm --prefix frontend run dev:api
curl localhost:3001/api/health
```

### Log format

The script emits NDJSON to stdout so R / scheduled jobs can parse it via
`jsonlite::stream_in()`. Errors go to stderr. Exit code is non-zero on any
failure.

Key events:

- `start` — run kickoff + config echo
- `plan.full_rebuild` — partition count + first/last names
- `progress` — per-partition row count + cumulative
- `exec.total_rows` — final count after all partitions
- `error` — any failure; process exits 1

### Calling from R (future automation)

```r
# After the R pipeline writes a new revision, push just that one:
rev <- "2025_rev_26"
result <- system2(
  "npm",
  c("--prefix", "frontend", "run", "db:push-to-cloud", "--", "--revision", rev),
  stdout = TRUE, stderr = TRUE
)
# Parse the NDJSON:
events <- jsonlite::stream_in(textConnection(result))
```
