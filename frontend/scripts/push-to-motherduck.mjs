#!/usr/bin/env node
// Push local parquet → MotherDuck, one revision partition at a time.
//
// Batching by revision keeps peak local memory bounded to a single partition
// (~7M rows) rather than loading all 26 revisions (~180M rows) at once.
//
// Usage:
//   node scripts/push-to-motherduck.mjs                      # full rebuild (all revisions)
//   node scripts/push-to-motherduck.mjs --revision 2025_rev_25
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
import { PARQUET_PATH, PRODUCT_BASE_RATES_VIEW_SQL } from '../server/db.js';

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
  revisions.sort((a, b) => {
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

// Seed the target table from the first revision (CREATE OR REPLACE TABLE).
// We rely on the parquet files' natural row order from the R pipeline — a
// sort-on-insert would buffer the whole partition in local RAM and OOM the
// laptop. MotherDuck derives row-group min/max stats from whatever order the
// data arrives in, so pruning on (hts10, country, revision) still works.
async function seedTable(conn, revision) {
  log('exec.seed.start', { revision });
  await conn.run(`
    CREATE OR REPLACE TABLE rates AS
    SELECT * FROM read_parquet('${revisionGlob(revision)}', hive_partitioning = true)
  `);
  const n = await count(conn, `WHERE revision = '${revision}'`);
  log('exec.seed.done', { revision, rows: n });
  return n;
}

async function insertPartition(conn, revision) {
  log('exec.insert.start', { revision });
  await conn.run(`
    INSERT INTO rates
    SELECT * FROM read_parquet('${revisionGlob(revision)}', hive_partitioning = true)
  `);
  const n = await count(conn, `WHERE revision = '${revision}'`);
  log('exec.insert.done', { revision, rows: n });
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

  log('exec.product_base_rates.start');
  await conn.run(PRODUCT_BASE_RATES_VIEW_SQL);
  log('exec.product_base_rates.done');

  log('exec.total_rows', { rows: cumulative });
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
      INSERT INTO rates
      SELECT * FROM read_parquet('${revisionGlob(revision)}', hive_partitioning = true)
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

  // product_base_rates is a view — recreate to heal any schema drift.
  await conn.run(PRODUCT_BASE_RATES_VIEW_SQL);
  log('exec.product_base_rates.refreshed');
}

async function main() {
  const { values } = parseArgs({
    options: {
      revision: { type: 'string' },
      'dry-run': { type: 'boolean' },
      'confirm-drop': { type: 'boolean' },
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
  const limit = values.limit ? parseInt(values.limit, 10) : null;
  const memoryLimit = values['memory-limit'] || '4GB';
  const threads = values.threads ? parseInt(values.threads, 10) : 2;

  log('start', {
    database,
    mode: values.revision ? 'incremental' : 'full_rebuild',
    revision: values.revision ?? null,
    dry_run: dryRun,
    confirm_drop: confirmDrop,
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

  if (values.revision) {
    await incrementalReplace(conn, values.revision, { dryRun });
  } else {
    await fullRebuildBatched(conn, { dryRun, confirmDrop, limit });
  }

  log('done', { database });
}

main().catch((err) => {
  fail(err?.message || String(err), { stack: err?.stack });
});
