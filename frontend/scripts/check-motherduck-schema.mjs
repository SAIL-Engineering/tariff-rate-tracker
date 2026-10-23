#!/usr/bin/env node
// Preflight for an incremental push: diff the local parquet union schema
// against the MotherDuck `rates` table. The incremental paths (--revision /
// --only-revisions) INSERT BY NAME into the existing table and fail on any
// local column the cloud table lacks; the full-rebuild path derives the
// union schema itself and never needs this check.
//
// Usage:
//   node scripts/check-motherduck-schema.mjs           # report + print ALTERs
//   This command is read-only. Review and apply migrations separately.
//
// Env (loaded from ../.env by dotenv):
//   MOTHERDUCK_TOKEN      required
//   MOTHERDUCK_DATABASE   defaults to `duty_calculator` (shared runtime config)
//
// Exit codes: 0 = schemas compatible,
// 1 = missing cloud columns reported but not applied, 2 = hard failure.

import path from 'path';
import { fileURLToPath } from 'url';
import dotenv from 'dotenv';
import { DuckDBInstance } from '@duckdb/node-api';
import { PARQUET_PATH } from '../server/db.js';
import { getMotherDuckDatabase } from '../server/config.js';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
dotenv.config({ path: path.resolve(__dirname, '..', '..', '.env') });

if (process.argv.includes('--apply')) {
  console.error('Schema preflight is read-only; use a separately reviewed migration.');
  process.exit(2);
}
const database = getMotherDuckDatabase();

if (!process.env.MOTHERDUCK_TOKEN) {
  console.error('MOTHERDUCK_TOKEN not set (expected in repo-root .env)');
  process.exit(2);
}

const instance = await DuckDBInstance.create(`md:${database}`, { access_mode: 'READ_ONLY' });
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
    AND table_catalog = '${database}'
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

if (typeMismatch.length > 0) {
  console.error('Incompatible types require an explicit migration; preflight failed.');
  process.exit(2);
}

if (missingInCloud.length === 0) {
  console.log('OK: column names and types are compatible. Release coverage and source validation are separate gates.');
  process.exit(0);
}

console.log(`\n${missingInCloud.length} local column(s) missing from cloud rates:`);
const alters = missingInCloud.map(
  ([name, type]) => `ALTER TABLE rates ADD COLUMN "${name}" ${type};`,
);
for (const stmt of alters) console.log('  ' + stmt);

console.log('\nReview these statements as an explicit migration; preflight made no changes.');
process.exit(1);
