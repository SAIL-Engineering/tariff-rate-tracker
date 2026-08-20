#!/usr/bin/env node
// Preflight for an incremental push: diff the local parquet union schema
// against the MotherDuck `rates` table. The incremental paths (--revision /
// --only-revisions) INSERT BY NAME into the existing table and fail on any
// local column the cloud table lacks; the full-rebuild path derives the
// union schema itself and never needs this check.
//
// Usage:
//   node scripts/check-motherduck-schema.mjs           # report + print ALTERs
//   node scripts/check-motherduck-schema.mjs --apply   # also run the ALTERs
//
// Env (loaded from ../.env by dotenv):
//   MOTHERDUCK_TOKEN      required
//   MOTHERDUCK_DATABASE   defaults to `tariff_rates`
//
// Exit codes: 0 = schemas compatible (or made compatible with --apply),
// 1 = missing cloud columns reported but not applied, 2 = hard failure.

import path from 'path';
import { fileURLToPath } from 'url';
import dotenv from 'dotenv';
import { DuckDBInstance } from '@duckdb/node-api';
import { PARQUET_PATH } from '../server/db.js';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
dotenv.config({ path: path.resolve(__dirname, '..', '..', '.env') });

const apply = process.argv.includes('--apply');
const database = process.env.MOTHERDUCK_DATABASE || 'tariff_rates';

if (!process.env.MOTHERDUCK_TOKEN) {
  console.error('MOTHERDUCK_TOKEN not set (expected in repo-root .env)');
  process.exit(2);
}

const instance = await DuckDBInstance.create(`md:${database}`);
const conn = await instance.connect();

// Union schema across every local partition. LIMIT 0 + DESCRIBE reads parquet
// metadata only — no data scan.
const localReader = await conn.runAndReadAll(`
  DESCRIBE SELECT * FROM read_parquet(
    '${PARQUET_PATH}/revision=*/*.parquet',
    hive_partitioning = true, union_by_name = true)
`);
const local = new Map(
  localReader.getRowObjects().map((r) => [r.column_name, r.column_type]),
);

const cloudReader = await conn.runAndReadAll(`
  SELECT column_name, data_type FROM information_schema.columns
  WHERE table_name = 'rates' AND table_schema = 'main'
`);
const cloud = new Map(
  cloudReader.getRowObjects().map((r) => [r.column_name, r.data_type]),
);
if (cloud.size === 0) {
  console.error(`no \`rates\` table found in ${database} — run a full push first`);
  process.exit(2);
}

const missingInCloud = [...local].filter(([name]) => !cloud.has(name));
const cloudOnly = [...cloud].filter(([name]) => !local.has(name));
const typeMismatch = [...local].filter(
  ([name, type]) => cloud.has(name) && cloud.get(name) !== type,
);

console.log(`local parquet columns: ${local.size}, cloud rates columns: ${cloud.size}`);

for (const [name, cloudType] of cloudOnly) {
  console.log(`cloud-only (stays NULL for re-pushed revisions): ${name} ${cloudType}`);
}
for (const [name, type] of typeMismatch) {
  console.log(`TYPE MISMATCH (insert will cast or fail): ${name} local=${type} cloud=${cloud.get(name)}`);
}

if (missingInCloud.length === 0) {
  console.log('OK: every local column exists in the cloud table — push is safe.');
  process.exit(0);
}

console.log(`\n${missingInCloud.length} local column(s) missing from cloud rates:`);
const alters = missingInCloud.map(
  ([name, type]) => `ALTER TABLE rates ADD COLUMN "${name}" ${type};`,
);
for (const stmt of alters) console.log('  ' + stmt);

if (!apply) {
  console.log('\nRe-run with --apply to execute these, then push.');
  process.exit(1);
}

for (const stmt of alters) {
  console.log('applying: ' + stmt);
  await conn.run(stmt);
}
console.log('done — cloud schema now matches; safe to push.');
