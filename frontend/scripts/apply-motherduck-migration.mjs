#!/usr/bin/env node
// Execute a reviewed .sql migration against MotherDuck, one statement at a time.
//
// check-motherduck-schema.mjs refuses --apply on purpose ("preflight is
// read-only; use a separately reviewed migration") and opens the catalog
// READ_ONLY, so nothing in this repo could actually apply one. The push then
// fails on the first revision with a Binder Error naming the first missing
// column, which is the correct behaviour but reads like a push bug rather than
// an unapplied migration.
//
// Dry by default: it prints the file's sha256, every statement it would run, and
// exits WITHOUT connecting read-write unless --confirm is passed. The sha256 is
// printed so the thing you reviewed and the thing you ran can be shown to be the
// same file.
//
// Usage:
//   node scripts/apply-motherduck-migration.mjs --file migrations/003_rates_add_missing_columns.sql
//   node scripts/apply-motherduck-migration.mjs --file migrations/003_... --confirm
//
// Env (loaded from ../.env by dotenv):
//   MOTHERDUCK_TOKEN      required with --confirm
//   MOTHERDUCK_DATABASE   defaults to `duty_calculator`
//
// Logs NDJSON to stdout. Exits non-zero on any failure, naming the statement
// that failed. Statements are applied in file order and not wrapped in one
// transaction: DuckDB/MotherDuck DDL does not roll back as a unit, so the
// recovery is to fix the file and run it again. That is safe precisely because
// every statement must be idempotent — see the ADDITIVE_ONLY guard below.
import path from 'path';
import fs from 'fs';
import crypto from 'crypto';
import { fileURLToPath } from 'url';
import dotenv from 'dotenv';
import { DuckDBInstance } from '@duckdb/node-api';
import { parseArgs } from 'node:util';
import { getMotherDuckDatabase } from '../server/config.js';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
dotenv.config({ path: path.resolve(__dirname, '..', '..', '.env') });

const log = (event, extra = {}) =>
  process.stdout.write(JSON.stringify({ ts: new Date().toISOString(), event, ...extra }) + '\n');
const fail = (msg, extra = {}) => {
  process.stderr.write(JSON.stringify({ ts: new Date().toISOString(), event: 'error', msg, ...extra }) + '\n');
  process.exit(1);
};

// Only statements that cannot destroy or rewrite data, and that are safe to run
// twice. A migration that needs anything else does not belong in this runner:
// the point is that an interrupted run is recovered by re-running the file.
const ADDITIVE_ONLY = [
  /^ALTER\s+TABLE\s+[\w."]+\s+ADD\s+COLUMN\s+IF\s+NOT\s+EXISTS\s+/i,
  /^CREATE\s+TABLE\s+IF\s+NOT\s+EXISTS\s+/i,
  /^CREATE\s+SCHEMA\s+IF\s+NOT\s+EXISTS\s+/i,
  /^CREATE\s+(UNIQUE\s+)?INDEX\s+IF\s+NOT\s+EXISTS\s+/i,
];

/** Strip `--` comments and split on `;`, keeping only real statements. */
function statementsOf(sql) {
  return sql
    .split('\n')
    .filter((line) => !line.trim().startsWith('--'))
    .join('\n')
    .split(';')
    .map((s) => s.trim())
    .filter((s) => s.length > 0);
}

const { values } = parseArgs({
  options: { file: { type: 'string' }, confirm: { type: 'boolean' }, database: { type: 'string' } },
});
if (!values.file) fail('--file <path to .sql> is required');
const file = path.resolve(process.cwd(), values.file);
if (!fs.existsSync(file)) fail(`no such file: ${file}`);

const sql = fs.readFileSync(file, 'utf8');
const sha256 = crypto.createHash('sha256').update(sql).digest('hex');
const statements = statementsOf(sql);
if (statements.length === 0) fail('file contains no statements');

const offending = statements.filter((s) => !ADDITIVE_ONLY.some((re) => re.test(s)));
if (offending.length) {
  fail(`${offending.length} statement(s) are not additive-and-idempotent; this runner applies only `
     + `ADD COLUMN IF NOT EXISTS / CREATE ... IF NOT EXISTS`,
    { first: offending[0].slice(0, 160) });
}

const database = getMotherDuckDatabase(values.database);
log('plan', { file, sha256, statements: statements.length, database, confirm: !!values.confirm });

if (!values.confirm) {
  for (const [i, s] of statements.entries()) log('dry_run.statement', { index: i + 1, sql: s });
  log('dry_run.done', { note: 'nothing was applied; re-run with --confirm' });
  process.exit(0);
}

if (!process.env.MOTHERDUCK_TOKEN) fail('MOTHERDUCK_TOKEN is required. Set it in .env.');
process.env.motherduck_token = process.env.MOTHERDUCK_TOKEN;

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
await conn.run(`SET memory_limit = '${'4GB'}'`);
await conn.run(`SET threads = ${2}`);
await conn.run('SET preserve_insertion_order = false');

let applied = 0;
for (const [i, statement] of statements.entries()) {
  try {
    await conn.run(statement);
    applied += 1;
    log('applied', { index: i + 1, of: statements.length });
  } catch (err) {
    fail(`statement ${i + 1} of ${statements.length} failed: ${err.message}`,
      { sql: statement.slice(0, 200), applied,
        note: 'every statement is idempotent - fix the file and run it again' });
  }
}
log('done', { file, sha256, applied, database });
