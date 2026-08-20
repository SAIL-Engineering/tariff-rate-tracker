#!/usr/bin/env node
// Push local parquet → MotherDuck, one revision partition at a time.
//
// Batching by revision keeps peak local memory bounded to a single partition
// (~7M rows) rather than loading all 26 revisions (~180M rows) at once.
//
// Usage:
//   node scripts/push-to-motherduck.mjs                      # full rebuild (all revisions)
//   node scripts/push-to-motherduck.mjs --revision 2025_rev_25
//   node scripts/push-to-motherduck.mjs --only-revisions 2019,2020,2021   # push a set/range (year prefixes or exact rev_ids); one product_base_rates rebuild at the end
//   node scripts/push-to-motherduck.mjs --post-only          # recluster + rebuild product_base_rates on the existing rates table
//   node scripts/push-to-motherduck.mjs --dry-run
//   node scripts/push-to-motherduck.mjs --limit 3            # first 3 partitions only (testing)
//   node scripts/push-to-motherduck.mjs --confirm-drop       # required when `rates` already has data
//   node scripts/push-to-motherduck.mjs --memory-limit 2GB   # cap local DuckDB memory
//
// Env (loaded from ../.env by dotenv):
//   MOTHERDUCK_TOKEN      required
//   MOTHERDUCK_DATABASE   defaults to `tariff_rates`
//
// Logs NDJSON to stdout so R can parse with jsonlite::stream_in(). Exits
// non-zero on any failure.

import path from 'path';
import fs from 'fs';
import { fileURLToPath } from 'url';
import dotenv from 'dotenv';
import { DuckDBInstance } from '@duckdb/node-api';
import { parseArgs } from 'node:util';
import { PARQUET_PATH, productBaseRatesBody } from '../server/db.js';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
dotenv.config({ path: path.resolve(__dirname, '..', '..', '.env') });

function log(event, extra = {}) {
  process.stdout.write(
    JSON.stringify({ ts: new Date().toISOString(), event, ...extra }) + '\n',
  );
}

function fail(msg, extra = {}) {
  process.stderr.write(
    JSON.stringify({ ts: new Date().toISOString(), event: 'error', msg, ...extra }) + '\n',
  );
  process.exit(1);
}

async function count(conn, where = '') {
  const reader = await conn.runAndReadAll(`SELECT count(*) AS n FROM rates ${where}`);
  return Number(reader.getRowObjects()[0].n);
}

async function tableExists(conn, tableName) {
  const reader = await conn.runAndReadAll(
    `SELECT table_name FROM information_schema.tables WHERE table_name = '${tableName}'`,
  );
  return reader.getRowObjects().length > 0;
}

// Drop whichever object type currently holds the `product_base_rates`
// name. DuckDB's DROP VIEW IF EXISTS / DROP TABLE IF EXISTS error when the
// existing object is the *other* type (e.g. "Existing object ... is of
// type Table, trying to drop type View"), so we have to introspect first.
// Steady-state in MotherDuck is a TABLE, but legacy deploys created it as
// a VIEW, and the rename-swap pattern below also needs to clear whatever
// is there.
async function dropProductBaseRatesIfPresent(conn) {
  const reader = await conn.runAndReadAll(
    `SELECT table_type FROM information_schema.tables
     WHERE table_name = 'product_base_rates'`,
  );
  const row = reader.getRowObjects()[0];
  if (!row) return;
  const kind = String(row.table_type).toUpperCase().includes('VIEW')
    ? 'VIEW'
    : 'TABLE';
  await conn.run(`DROP ${kind} product_base_rates`);
}

// Rebuild product_base_rates revision-by-revision, then atomic-swap into
// place. Bounds peak MotherDuck duckling memory to one partition's groups
// (~19K HTS rows out, ~4.8M rate rows in) instead of aggregating all
// ~190M rows in a single shot, which OOMs the Pulse tier (~1 GB heap).
//
// Correctness: the GROUP BY key is (hts10, revision), so a per-revision
// aggregate with WHERE revision = '<rev>' is identical to the slice of
// the global aggregate for that revision. No cross-revision groups exist
// to be broken by batching.
//
// Atomicity: build into product_base_rates_new, then DROP+RENAME. Live
// API queries see the old table for the entire build, with a brief
// sub-second swap window at the end (same pattern as
// reclusterRatesByPartition).
async function rebuildProductBaseRatesBatched(conn) {
  log('exec.product_base_rates.start');

  const revReader = await conn.runAndReadAll(
    'SELECT DISTINCT revision FROM rates ORDER BY revision',
  );
  const revisions = revReader.getRowObjects().map((r) => String(r.revision));
  if (revisions.length === 0) {
    fail('cannot rebuild product_base_rates: rates table is empty');
  }
  log('exec.product_base_rates.partitions', { count: revisions.length });

  await conn.run('DROP TABLE IF EXISTS product_base_rates_new');

  for (let i = 0; i < revisions.length; i++) {
    const rev = revisions[i];
    if (!/^[a-zA-Z0-9_]+$/.test(rev)) {
      fail(`unexpected revision name from catalog: ${JSON.stringify(rev)}`);
    }
    const t0 = Date.now();
    // ORDER BY hts10 so the synthesis-path lookups (`SELECT * FROM
    // product_base_rates WHERE hts10 = X`) hit a contiguous, prunable range
    // instead of scanning the whole table. ~19K rows/revision — trivial sort.
    const body = productBaseRatesBody(`WHERE revision = '${rev}'`);
    if (i === 0) {
      await conn.run(`CREATE TABLE product_base_rates_new AS ${body} ORDER BY hts10`);
    } else {
      await conn.run(`INSERT INTO product_base_rates_new ${body} ORDER BY hts10`);
    }
    log('exec.product_base_rates.partition.done', {
      revision: rev,
      index: i + 1,
      of: revisions.length,
      elapsed_ms: Date.now() - t0,
    });
  }

  await dropProductBaseRatesIfPresent(conn);
  await conn.run('ALTER TABLE product_base_rates_new RENAME TO product_base_rates');
  log('exec.product_base_rates.done');
}

// Scan the local parquet directory and return the list of canonical
// revisions (year-prefixed like "2025_basic", "2025_rev_25"). Legacy
// short-format names (e.g. "rev_2") are skipped — they duplicate the
// canonical rows and are filtered out of the local view too.
function listRevisions() {
  const entries = fs.readdirSync(PARQUET_PATH, { withFileTypes: true });
  const revisions = [];
  for (const e of entries) {
    if (!e.isDirectory()) continue;
    const m = e.name.match(/^revision=(.+)$/);
    if (!m) continue;
    const name = m[1];
    if (!/^20/.test(name)) continue; // skip legacy short revisions
    revisions.push(name);
  }
  // Numeric-aware sort: 2025_basic, 2025_rev_1, 2025_rev_2, ..., 2025_rev_10, ...
  // Year FIRST, then rev number — the previous comparator sorted by rev number
  // alone, interleaving years (…, 2025_rev_16, 2026_rev_16, 2025_rev_17, …)
  // and making the plan line report 2025_rev_32 as "last". Order never affected
  // which partitions load, only the display and physical insert order.
  revisions.sort((a, b) => {
    const ay = parseInt(a.slice(0, 4), 10);
    const by = parseInt(b.slice(0, 4), 10);
    if (ay !== by) return ay - by;
    const an = parseInt((a.match(/rev_(\d+)/) || [])[1] ?? '-1', 10);
    const bn = parseInt((b.match(/rev_(\d+)/) || [])[1] ?? '-1', 10);
    if (an !== bn) return an - bn;
    return a.localeCompare(b);
  });
  return revisions;
}

function revisionGlob(revision) {
  return `${PARQUET_PATH}/revision=${revision}/*.parquet`;
}

// Glob over EVERY revision. Used to derive the union-of-all-revisions schema so
// the target table holds the SUPERSET of columns. Revisions are heterogeneous:
// some columns (e.g. ieepa_recip_ch99, and newer provenance columns) exist only
// in revisions rebuilt after the column was introduced. A positional
// `SELECT *` insert fails with a column-count mismatch; the union schema + an
// INSERT ... BY NAME aligns every revision by name (missing columns -> NULL).
function allRevisionsGlob() {
  return `${PARQUET_PATH}/revision=*/*.parquet`;
}

// Seed the target table from the first revision (CREATE OR REPLACE TABLE).
// We rely on the parquet files' natural row order from the R pipeline — a
// sort-on-insert would buffer the whole partition in local RAM and OOM the
// laptop. MotherDuck derives row-group min/max stats from whatever order the
// data arrives in, so pruning on (hts10, country, revision) still works.
async function seedTable(conn, revision) {
  log('exec.seed.start', { revision });
  // Create the table with the UNION schema across ALL revisions (LIMIT 0 reads
  // parquet metadata only — no data scan), so heterogeneous revisions later
  // insert cleanly BY NAME. Then load the first revision through the same
  // BY-NAME path as every other partition.
  await conn.run(`
    CREATE OR REPLACE TABLE rates AS
    SELECT * FROM read_parquet('${allRevisionsGlob()}', hive_partitioning = true, union_by_name = true)
    LIMIT 0
  `);
  const n = await insertPartition(conn, revision, { seed: true });
  log('exec.seed.done', { revision, rows: n });
  return n;
}

async function insertPartition(conn, revision, { seed = false } = {}) {
  if (!seed) log('exec.insert.start', { revision });
  // INSERT ... BY NAME maps columns by name (missing target columns -> NULL), so
  // revisions with fewer columns load into the union-schema table without a
  // positional column-count mismatch.
  await conn.run(`
    INSERT INTO rates BY NAME
    SELECT * FROM read_parquet('${revisionGlob(revision)}', hive_partitioning = true, union_by_name = true)
  `);
  const n = await count(conn, `WHERE revision = '${revision}'`);
  if (!seed) log('exec.insert.done', { revision, rows: n });
  return n;
}

async function fullRebuildBatched(conn, opts) {
  const { dryRun, confirmDrop, limit } = opts;

  const allRevisions = listRevisions();
  const revisions = limit ? allRevisions.slice(0, limit) : allRevisions;
  log('plan.full_rebuild', {
    total_revisions: allRevisions.length,
    batches: revisions.length,
    first: revisions[0] ?? null,
    last: revisions[revisions.length - 1] ?? null,
  });

  if (revisions.length === 0) {
    fail('no canonical revisions (revision=20*) found under ' + PARQUET_PATH);
  }

  const exists = await tableExists(conn, 'rates');
  const before = exists ? await count(conn) : 0;
  log('plan.existing', { rates_exists: exists, rows_before: before });
  if (exists && before > 0 && !confirmDrop) {
    fail(
      'rates table exists with data; full rebuild would drop it. Re-run with --confirm-drop.',
      { rows_before: before },
    );
  }

  if (dryRun) {
    log('dry_run.skip', { op: 'full_rebuild', would_process: revisions });
    return;
  }

  let cumulative = 0;
  for (let i = 0; i < revisions.length; i++) {
    const rev = revisions[i];
    const rows = i === 0 ? await seedTable(conn, rev) : await insertPartition(conn, rev);
    cumulative += rows;
    log('progress', {
      revision: rev,
      index: i + 1,
      of: revisions.length,
      rows_this_batch: rows,
      rows_cumulative: cumulative,
    });
  }

  await postProcess(conn);

  log('exec.total_rows', { rows: cumulative });
}

// Post-processing: recluster `rates` by (hts10, country) and (re)build the
// materialized `product_base_rates` table. Runs after a full rebuild, and
// can also be invoked standalone via --post-only to recover from a partial
// run (e.g. when the load phase finished but the recluster step died).
//
// Clustering key is (hts10, country) — NOT (country, hts10) — because EVERY
// hot query filters on hts10 (exact 10-digit, or `hts10 LIKE 'prefix%'` for
// rankings/autocomplete) while only some also filter country. hts10-leading
// order makes those the contiguous, zone-map-prunable ranges MotherDuck can
// skip-scan; the all-country /api/rates/arrow lookup in particular goes from a
// full-corpus scan to a narrow seek. Single-country lookups stay fast too: one
// hts10's rows (all countries × revisions) are few, so the country filter is a
// cheap residual within the pruned hts10 range.
//
// Why per-partition, not a single global sort: an earlier version ran
// `CREATE OR REPLACE TABLE rates AS SELECT * FROM rates ORDER BY ...` as
// one statement. MotherDuck returned an internal error (~35 min in)
// trying to sort 185M rows × 50+ columns in a single shot. Sorting one
// revision at a time bounds the sort state to ~4.7M rows, which MD
// handles fine and still gives good zonemap pruning on the final table
// because row groups within each partition are contiguous and sorted.
async function postProcess(conn) {
  await reclusterRatesByPartition(conn);
  await rebuildProductBaseRatesBatched(conn);
}

async function reclusterRatesByPartition(conn) {
  log('exec.rates.cluster.start');

  // Enumerate revisions from the current rates table (avoids re-reading the
  // parquet directory, so --post-only works even if the R pipeline has
  // regenerated local files since the upload).
  const revReader = await conn.runAndReadAll(
    'SELECT DISTINCT revision FROM rates ORDER BY revision',
  );
  const revisions = revReader.getRowObjects().map((r) => String(r.revision));
  log('exec.rates.cluster.partitions', { count: revisions.length });

  // Build a new, sorted table revision-by-revision. CREATE TABLE AS with
  // LIMIT 0 produces an empty table with the same schema. We then append
  // one revision at a time with ORDER BY hts10, country — each pass sorts
  // ~4.7M rows on the MotherDuck side, well within its compute budget.
  await conn.run('DROP TABLE IF EXISTS rates_new');
  await conn.run(`
    CREATE TABLE rates_new AS
    SELECT * FROM rates LIMIT 0
  `);

  for (let i = 0; i < revisions.length; i++) {
    const rev = revisions[i];
    const t0 = Date.now();
    await conn.run(`
      INSERT INTO rates_new
      SELECT * FROM rates
      WHERE revision = '${rev}'
      ORDER BY hts10, country
    `);
    log('exec.rates.cluster.partition.done', {
      revision: rev,
      index: i + 1,
      of: revisions.length,
      elapsed_ms: Date.now() - t0,
    });
  }

  // Swap: drop the unsorted table and rename the sorted one in its place.
  // MotherDuck does not wrap DDL in a single transaction, but the window
  // between DROP and RENAME is short and only affects live /api/rates
  // queries during that sub-second gap.
  await conn.run('DROP TABLE rates');
  await conn.run('ALTER TABLE rates_new RENAME TO rates');
  log('exec.rates.cluster.done');
}

async function incrementalReplace(conn, revision, { dryRun }) {
  if (!/^[a-zA-Z0-9_]+$/.test(revision)) {
    fail(`invalid --revision value "${revision}" (must match [a-zA-Z0-9_]+)`);
  }
  const dir = path.join(PARQUET_PATH, `revision=${revision}`);
  if (!fs.existsSync(dir)) {
    fail(`revision partition directory not found: ${dir}`);
  }
  const exists = await tableExists(conn, 'rates');
  if (!exists) {
    fail('rates table does not exist yet. Run a full rebuild first (no --revision).');
  }

  const before = await count(conn, `WHERE revision = '${revision}'`);
  log('plan.incremental', { revision, rows_before: before });

  if (dryRun) {
    log('dry_run.skip', { op: 'incremental', revision });
    return;
  }

  log('exec.incremental.start', { revision });
  try {
    await conn.run('BEGIN');
    await conn.run(`DELETE FROM rates WHERE revision = '${revision}'`);
    await conn.run(`
      INSERT INTO rates BY NAME
      SELECT * FROM read_parquet('${revisionGlob(revision)}', hive_partitioning = true, union_by_name = true)
    `);
    await conn.run('COMMIT');
  } catch (err) {
    try {
      await conn.run('ROLLBACK');
    } catch {
      // swallow rollback errors — the outer error is what matters
    }
    throw err;
  }
  const after = await count(conn, `WHERE revision = '${revision}'`);
  log('exec.incremental.done', { revision, rows_after: after, delta: after - before });

  // product_base_rates is a materialized TABLE — rebuild it so the
  // replaced revision's rows reflect in the next synthesis query. The
  // batched rebuild aggregates one revision at a time to keep peak
  // duckling memory bounded; a single global GROUP BY OOMs Pulse tier.
  await rebuildProductBaseRatesBatched(conn);
}

// Expand comma-separated tokens to the matching local revision partitions.
// Each token matches an exact rev_id ("2019_basic") OR a year prefix ("2019"
// = all 2019_* partitions). Mirrors the build's --only-revisions semantics.
function matchRevisions(allRevisions, tokens) {
  return allRevisions.filter((name) =>
    tokens.some((t) => name === t || name.startsWith(`${t}_`)),
  );
}

// Replace a SET/range of revisions in one run (e.g. an older-year backfill),
// then rebuild product_base_rates exactly ONCE at the end. Each revision's
// rows are replaced transactionally (BEGIN/DELETE/INSERT/COMMIT) so a failure
// on one revision rolls that revision back without touching the others. The
// existing rows of every revision NOT in the set are left completely untouched.
//
// Why one rebuild at the end: rebuildProductBaseRatesBatched() rebuilds the
// whole materialized table (batched per-revision for memory safety), so calling
// it after every revision — as the single-revision path does — would repeat the
// full rebuild N times. We load all partitions first, then rebuild once.
async function incrementalReplaceMany(conn, revisions, { dryRun }) {
  if (revisions.length === 0) {
    fail('--only-revisions matched no local partitions under ' + PARQUET_PATH);
  }
  const exists = await tableExists(conn, 'rates');
  if (!exists) {
    fail('rates table does not exist yet. Run a full rebuild first (no --revision/--only-revisions).');
  }
  log('plan.incremental_many', {
    count: revisions.length,
    first: revisions[0],
    last: revisions[revisions.length - 1],
    revisions,
  });

  if (dryRun) {
    log('dry_run.skip', { op: 'incremental_many', would_replace: revisions });
    return;
  }

  let totalDelta = 0;
  for (let i = 0; i < revisions.length; i++) {
    const revision = revisions[i];
    if (!/^[a-zA-Z0-9_]+$/.test(revision)) {
      fail(`invalid revision value "${revision}" (must match [a-zA-Z0-9_]+)`);
    }
    const dir = path.join(PARQUET_PATH, `revision=${revision}`);
    if (!fs.existsSync(dir)) {
      fail(`revision partition directory not found: ${dir}`);
    }
    const before = await count(conn, `WHERE revision = '${revision}'`);
    log('exec.incremental.start', { revision, index: i + 1, of: revisions.length });
    try {
      await conn.run('BEGIN');
      await conn.run(`DELETE FROM rates WHERE revision = '${revision}'`);
      await conn.run(`
        INSERT INTO rates BY NAME
        SELECT * FROM read_parquet('${revisionGlob(revision)}', hive_partitioning = true, union_by_name = true)
      `);
      await conn.run('COMMIT');
    } catch (err) {
      try {
        await conn.run('ROLLBACK');
      } catch {
        // swallow rollback errors — the outer error is what matters
      }
      throw err;
    }
    const after = await count(conn, `WHERE revision = '${revision}'`);
    totalDelta += after - before;
    log('exec.incremental.done', {
      revision,
      index: i + 1,
      of: revisions.length,
      rows_after: after,
      delta: after - before,
    });
  }
  log('exec.incremental_many.loaded', {
    revisions: revisions.length,
    total_delta: totalDelta,
  });

  // Rebuild the materialized product_base_rates ONCE (covers all revisions).
  await rebuildProductBaseRatesBatched(conn);
}

async function main() {
  const { values } = parseArgs({
    options: {
      revision: { type: 'string' },
      'only-revisions': { type: 'string' },
      'dry-run': { type: 'boolean' },
      'confirm-drop': { type: 'boolean' },
      'post-only': { type: 'boolean' },
      database: { type: 'string' },
      limit: { type: 'string' },
      'memory-limit': { type: 'string' },
      threads: { type: 'string' },
    },
  });

  const token = process.env.MOTHERDUCK_TOKEN;
  if (!token) fail('MOTHERDUCK_TOKEN is required. Set it in .env.');
  process.env.motherduck_token = token;

  const database = values.database || process.env.MOTHERDUCK_DATABASE || 'duty_calculator';
  const dryRun = !!values['dry-run'];
  const confirmDrop = !!values['confirm-drop'];
  const postOnly = !!values['post-only'];
  const limit = values.limit ? parseInt(values.limit, 10) : null;
  const memoryLimit = values['memory-limit'] || '4GB';
  const threads = values.threads ? parseInt(values.threads, 10) : 2;

  if (postOnly && (values.revision || values['only-revisions'])) {
    fail('--post-only cannot be combined with --revision / --only-revisions');
  }
  if (values.revision && values['only-revisions']) {
    fail('use either --revision (one) or --only-revisions (a set), not both');
  }

  log('start', {
    database,
    mode: postOnly
      ? 'post_only'
      : values.revision
        ? 'incremental'
        : values['only-revisions']
          ? 'incremental_many'
          : 'full_rebuild',
    revision: values.revision ?? null,
    only_revisions: values['only-revisions'] ?? null,
    dry_run: dryRun,
    confirm_drop: confirmDrop,
    post_only: postOnly,
    limit,
    memory_limit: memoryLimit,
    threads,
    parquet_path: PARQUET_PATH,
  });

  // Connect to the default MD instance first so we can create the DB if needed.
  const bootstrap = await DuckDBInstance.create('md:');
  const bootConn = await bootstrap.connect();
  await bootConn.run(`CREATE DATABASE IF NOT EXISTS ${database}`);

  // Reconnect scoped to the target database.
  const instance = await DuckDBInstance.create(`md:${database}`);
  const conn = await instance.connect();

  // Memory-safety knobs so parquet reads don't OOM the laptop:
  //   memory_limit — hard cap on local DuckDB RAM (spills to disk when exceeded)
  //   threads      — fewer threads = less concurrent read buffer
  //   preserve_insertion_order=false — lets DuckDB stream without buffering
  //     the whole partition to preserve row order (sort-at-insert was the
  //     root cause of earlier OOM on the 2025_basic partition)
  await conn.run(`SET memory_limit = '${memoryLimit}'`);
  await conn.run(`SET threads = ${threads}`);
  await conn.run(`SET preserve_insertion_order = false`);

  if (postOnly) {
    const exists = await tableExists(conn, 'rates');
    if (!exists) {
      fail('--post-only requires an existing rates table; none found.');
    }
    if (dryRun) {
      log('dry_run.skip', { op: 'post_only' });
    } else {
      await postProcess(conn);
    }
  } else if (values.revision) {
    await incrementalReplace(conn, values.revision, { dryRun });
  } else if (values['only-revisions']) {
    const tokens = values['only-revisions']
      .split(',')
      .map((s) => s.trim())
      .filter(Boolean);
    const matched = matchRevisions(listRevisions(), tokens);
    await incrementalReplaceMany(conn, matched, { dryRun });
  } else {
    await fullRebuildBatched(conn, { dryRun, confirmDrop, limit });
  }

  log('done', { database });
}

main().catch((err) => {
  fail(err?.message || String(err), { stack: err?.stack });
});
