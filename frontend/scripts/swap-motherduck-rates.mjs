#!/usr/bin/env node
// Re-schema `rates` by building a new table beside it and swapping, instead of
// widening it in place.
//
// WHY THIS EXISTS: on MotherDuck, ALTER TABLE ... ADD COLUMN materialises the
// whole table. On `rates` (~613M rows) each ADD COLUMN cost ~8.5s, and once the
// table reached 124 columns a SINGLE further ADD COLUMN could no longer complete
// at all -- 67.0 GiB/67.0 GiB on a Pulse duckling, in a fresh process, with the
// already-applied columns skipped as no-ops. So migration 003's remaining 64
// columns cannot be applied that way at any number of retries.
//
// The alternative in push-to-motherduck.mjs is a full rebuild, which works --
// seedTable() derives the 188-column union schema from parquet metadata in one
// cheap LIMIT 0 statement and needs no ALTERs. But it does CREATE OR REPLACE on
// the LIVE table, so `rates` is partial for the hours the load runs and a
// mid-run failure leaves production broken.
//
// This script uses the shape reclusterRatesByPartition() already proves: build
// a new table, fill it one revision at a time, swap at the end. Live `rates` is
// untouched until a sub-second rename, a failure leaves production exactly as it
// was, and revisions that have NOT changed locally are copied CLOUD-SIDE rather
// than re-uploaded -- for the 2019-2024 generation that is ~417M rows that never
// cross the network.
//
// Usage:
//   node scripts/swap-motherduck-rates.mjs --probe        # prove it, change nothing
//   node scripts/swap-motherduck-rates.mjs                # plan only
//   node scripts/swap-motherduck-rates.mjs --confirm      # build and swap
//   node scripts/swap-motherduck-rates.mjs --confirm --local-revisions 2025,2026
//
// --local-revisions picks which revisions are re-read from local parquet (the
// ones whose data actually changed); every other revision already in the cloud
// is copied across inside MotherDuck. Default: 2025,2026.
//
// Env (loaded from ../.env): MOTHERDUCK_TOKEN, MOTHERDUCK_DATABASE.
import path from 'path';
import fs from 'fs';
import { fileURLToPath } from 'url';
import dotenv from 'dotenv';
import { DuckDBInstance } from '@duckdb/node-api';
import { parseArgs } from 'node:util';
import { PARQUET_PATH, productBaseRatesBody } from '../server/db.js';
import { getMotherDuckDatabase } from '../server/config.js';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
dotenv.config({ path: path.resolve(__dirname, '..', '..', '.env') });

const log = (event, extra = {}) =>
  process.stdout.write(JSON.stringify({ ts: new Date().toISOString(), event, ...extra }) + '\n');
const fail = (msg, extra = {}) => {
  process.stderr.write(JSON.stringify({ ts: new Date().toISOString(), event: 'error', msg, ...extra }) + '\n');
  process.exit(1);
};
const SAFE = /^[a-zA-Z0-9_]+$/;

const allGlob = () => `${PARQUET_PATH}/revision=*/*.parquet`;
const revGlob = (rev) => `${PARQUET_PATH}/revision=${rev}/*.parquet`;
const readParquet = (glob) =>
  `read_parquet('${glob}', hive_partitioning = true, union_by_name = true)`;

function localRevisions() {
  return fs.readdirSync(PARQUET_PATH, { withFileTypes: true })
    .filter((e) => e.isDirectory())
    .map((e) => (e.name.match(/^revision=(.+)$/) || [])[1])
    .filter((n) => n && /^20/.test(n))
    .sort();
}

async function one(conn, sql, column = 'v') {
  const rows = (await conn.runAndReadAll(sql)).getRowObjects();
  return rows.length ? rows[0][column] : null;
}

async function columnsOf(conn, sql) {
  const rows = (await conn.runAndReadAll(`DESCRIBE ${sql}`)).getRowObjects();
  return rows.map((r) => String(r.column_name));
}

const { values } = parseArgs({
  options: {
    probe: { type: 'boolean' },
    confirm: { type: 'boolean' },
    'local-revisions': { type: 'string' },
    database: { type: 'string' },
    'memory-limit': { type: 'string' },
    threads: { type: 'string' },
  },
});
const database = getMotherDuckDatabase(values.database);
const localTokens = (values['local-revisions'] ?? '2025,2026').split(',').map((s) => s.trim()).filter(Boolean);
if (!process.env.MOTHERDUCK_TOKEN) fail('MOTHERDUCK_TOKEN is required. Set it in .env.');
process.env.motherduck_token = process.env.MOTHERDUCK_TOKEN;

// The union schema is read by a LOCAL in-memory DuckDB, NOT over the md: link.
// A DESCRIBE of read_parquet() across all 145 partitions on a MotherDuck
// connection hung for over ten minutes with no output; locally the same query
// answers in seconds, because the files are on this disk. Only operations that
// genuinely need the cloud go over the link.
const localInstance = await DuckDBInstance.create(':memory:', { memory_limit: '2GB' });
const localConn = await localInstance.connect();
const unionTyped = (await localConn.runAndReadAll(
  `DESCRIBE SELECT * FROM ${readParquet(allGlob())}`)).getRowObjects()
  .map((r) => ({ name: String(r.column_name), type: String(r.column_type) }));
const unionCols = unionTyped.map((c) => c.name);

const instance = await DuckDBInstance.create(`md:${database}`);
const conn = await instance.connect();
// These three are not optional, and leaving them out is what made the earlier
// attempts look like MotherDuck limits. The "67.0 GiB" ceiling in those errors
// was max_temp_directory_size, which defaults to the AVAILABLE DISK on the drive
// holding temp_directory -- this laptop is at 96% with ~39 GB free. So an
// unconstrained local DuckDB buffers a whole-table operation straight into the
// disk it has left and dies there, cloud compute never being the binding
// constraint. push-to-motherduck.mjs sets all three for exactly this reason:
//   memory_limit  - hard cap on local RAM (spills to disk when exceeded)
//   threads       - fewer threads = less concurrent read buffer
//   preserve_insertion_order=false - lets DuckDB stream instead of buffering
await conn.run(`SET memory_limit = '${values['memory-limit'] ?? '4GB'}'`);
await conn.run(`SET threads = ${values.threads ?? 2}`);
await conn.run('SET preserve_insertion_order = false');
const cloudCols = await columnsOf(conn, 'SELECT * FROM rates');
const missing = unionTyped.filter((c) => !cloudCols.includes(c.name));
const orphans = cloudCols.filter((c) => !unionCols.includes(c));
log('schema', {
  local_union: unionCols.length, cloud_rates: cloudCols.length,
  missing_from_cloud: missing.length,
  in_cloud_only: orphans.length,
});
// A column that exists in the cloud but NOT in the local union would be DROPPED
// by this swap -- silent data loss. Refuse rather than decide that for you.
if (orphans.length) {
  fail(`${orphans.length} column(s) exist in cloud rates but not in the local parquet union; `
     + `the swap would drop them`, { columns: orphans.slice(0, 20) });
}

// ── which revisions come from where ───────────────────────────────────
const cloudRevs = (await conn.runAndReadAll('SELECT DISTINCT revision FROM rates ORDER BY revision'))
  .getRowObjects().map((r) => String(r.revision));
const locals = localRevisions();
const fromLocal = locals.filter((r) => localTokens.some((t) => r === t || r.startsWith(t)));
const fromCloud = cloudRevs.filter((r) => !fromLocal.includes(r));
const newLocal = fromLocal.filter((r) => !cloudRevs.includes(r));
for (const r of [...fromLocal, ...fromCloud]) if (!SAFE.test(r)) fail(`unsafe revision name: ${r}`);
log('plan', {
  from_local_parquet: fromLocal.length, from_cloud_copy: fromCloud.length,
  new_revisions: newLocal, total: fromLocal.length + fromCloud.length,
});


/** Create `table` with the FULL union schema, cheaply.
 *
 * Not from read_parquet (that DESCRIBE hangs over the md: link) and not by
 * widening `rates` (ADD COLUMN there materialises ~613M rows and cannot
 * complete past 124 columns on a Pulse duckling). Instead: clone the existing
 * schema with LIMIT 0, then add the missing columns to the EMPTY table, where
 * each ADD COLUMN has no rows to rewrite and costs nothing. Same 92-statement
 * migration, applied where it is free. */
async function createWithUnionSchema(conn, table, missing) {
  await conn.run(`DROP TABLE IF EXISTS ${table}`);
  await conn.run(`CREATE TABLE ${table} AS SELECT * FROM rates LIMIT 0`);
  const t0 = Date.now();
  for (const col of missing) {
    if (!SAFE.test(col.name)) fail(`unsafe column name: ${col.name}`);
    await conn.run(`ALTER TABLE ${table} ADD COLUMN IF NOT EXISTS "${col.name}" ${col.type}`);
  }
  const cols = await columnsOf(conn, `SELECT * FROM ${table}`);
  log('schema.built', {
    table, columns: cols.length, added: missing.length, elapsed_ms: Date.now() - t0,
  });
  if (cols.length !== unionCols.length) {
    fail(`${table} has ${cols.length} columns, expected ${unionCols.length}`);
  }
  return cols;
}

// NO `ORDER BY` on these inserts. Sorting a revision before inserting it is
// what OOM'd the probe -- even with LIMIT 1000, because the sort runs over the
// whole revision first, and ~4.6M rows x 188 columns does not fit in 67 GiB on a
// Pulse duckling. push-to-motherduck's own insertPartition() has no ORDER BY
// either: it relies on the parquet's natural order (the R combine already writes
// each partition sorted) and leaves clustering to a separate pass. Same here --
// load streaming, cluster later or not at all. An unclustered table answers the
// same queries, just with less zone-map pruning.
const insertLocal = (table, rev) =>
  `INSERT INTO ${table} BY NAME SELECT * FROM ${readParquet(revGlob(rev))}`;
const insertCloud = (table, rev) =>
  `INSERT INTO ${table} BY NAME SELECT * FROM rates WHERE revision = '${rev}'`;

// ── probe: prove the mechanics on a scratch table, then drop it ───────
if (values.probe) {
  const probeLocal = fromLocal[0];
  const probeCloud = fromCloud[0];
  log('probe.start', { probe_local: probeLocal, probe_cloud: probeCloud });
  const probeCols = await createWithUnionSchema(conn, 'rates_probe', missing);
  log('probe.created', { columns: probeCols.length, matches_union: probeCols.length === unionCols.length });

  // A cloud-side copy must bind BY NAME and leave the 64 absent columns NULL.
  if (probeCloud) {
    await conn.run(`${insertCloud('rates_probe', probeCloud)} LIMIT 1000`);
    const n = await one(conn, 'SELECT count(*) AS v FROM rates_probe');
    const absent = unionCols.find((c) => !cloudCols.includes(c));
    const nulls = absent
      ? await one(conn, `SELECT count(*) AS v FROM rates_probe WHERE "${absent}" IS NULL`)
      : null;
    log('probe.cloud_copy', {
      revision: probeCloud, rows: Number(n),
      sampled_absent_column: absent, nulls_in_it: nulls === null ? null : Number(nulls),
      absent_column_is_all_null: nulls !== null && Number(nulls) === Number(n),
    });
  }
  // A local-parquet insert must bind too, including a revision the cloud lacks.
  if (probeLocal) {
    const before = Number(await one(conn, 'SELECT count(*) AS v FROM rates_probe'));
    await conn.run(`${insertLocal('rates_probe', probeLocal)} LIMIT 1000`);
    const after = Number(await one(conn, 'SELECT count(*) AS v FROM rates_probe'));
    log('probe.local_insert', { revision: probeLocal, rows_added: after - before });
  }
  await conn.run('DROP TABLE rates_probe');
  log('probe.done', { note: 'scratch table dropped; live rates untouched' });
  process.exit(0);
}

if (!values.confirm) {
  log('dry_run.done', { note: 'nothing changed; --probe to verify mechanics, --confirm to build and swap' });
  process.exit(0);
}

// ── build ─────────────────────────────────────────────────────────────
await createWithUnionSchema(conn, 'rates_next', missing);

let expected = 0;
const ordered = [...fromCloud, ...fromLocal].sort();
for (const [i, rev] of ordered.entries()) {
  const local = fromLocal.includes(rev);
  const t0 = Date.now();
  const want = Number(await one(conn, local
    ? `SELECT count(*) AS v FROM ${readParquet(revGlob(rev))}`
    : `SELECT count(*) AS v FROM rates WHERE revision = '${rev}'`));
  await conn.run(local ? insertLocal('rates_next', rev) : insertCloud('rates_next', rev));
  expected += want;
  log('build.partition', {
    revision: rev, source: local ? 'local_parquet' : 'cloud_copy',
    rows: want, index: i + 1, of: ordered.length, elapsed_ms: Date.now() - t0,
  });
}

const got = Number(await one(conn, 'SELECT count(*) AS v FROM rates_next'));
log('build.done', { rows: got, expected });
if (got !== expected) {
  fail(`rates_next has ${got} rows, expected ${expected}; leaving it in place and NOT swapping`,
    { note: 'live rates is untouched; inspect rates_next, then DROP TABLE rates_next' });
}

// ── swap ──────────────────────────────────────────────────────────────
// Two renames, not DROP + RENAME: the old table is retained so the swap can be
// undone. It costs storage until dropped.
const prev = `rates_prev_${new Date().toISOString().replace(/[^0-9]/g, '').slice(0, 14)}`;
await conn.run(`ALTER TABLE rates RENAME TO ${prev}`);
await conn.run('ALTER TABLE rates_next RENAME TO rates');
log('swap.done', { previous_table: prev, note: `rollback: DROP TABLE rates; ALTER TABLE ${prev} RENAME TO rates` });

// ── product_base_rates, per revision (a single-shot GROUP BY OOMs Pulse) ──
log('product_base_rates.start');
await conn.run('DROP TABLE IF EXISTS product_base_rates_new');
for (const [i, rev] of ordered.entries()) {
  const body = productBaseRatesBody(`WHERE revision = '${rev}'`);
  await conn.run(i === 0
    ? `CREATE TABLE product_base_rates_new AS ${body} ORDER BY hts10`
    : `INSERT INTO product_base_rates_new ${body} ORDER BY hts10`);
  log('product_base_rates.partition', { revision: rev, index: i + 1, of: ordered.length });
}
await conn.run('DROP TABLE IF EXISTS product_base_rates');
await conn.run('ALTER TABLE product_base_rates_new RENAME TO product_base_rates');
log('done', { database, rows: got, previous_table: prev });
