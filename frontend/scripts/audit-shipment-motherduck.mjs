#!/usr/bin/env node
// Only SELECTs, on a READ_ONLY connection. Never builds or activates a dataset.
import fs from 'node:fs/promises';
import path from 'node:path';
import crypto from 'node:crypto';
import { createWriteStream } from 'node:fs';
import { createGzip } from 'node:zlib';
import { once } from 'node:events';
import { finished } from 'node:stream/promises';
import { parseArgs } from 'node:util';
import { fileURLToPath } from 'node:url';
import dotenv from 'dotenv';
import { DuckDBInstance } from '@duckdb/node-api';
import { getMotherDuckDatabase } from '../server/config.js';
import { verifyAuditEvidence } from '../server/shipment-audit-evidence.js';
import { AUDIT_CONTRACT, auditQueries, revisionIssues, compareAuditCases } from '../server/shipment-audit.js';
const { values: args } = parseArgs({ options: {
  env: { type:'string' }, out: { type:'string' }, cases: { type:'string' },
  from: { type:'string', default:'2025-01-01' }, through: { type:'string', default:'2026-10-22' },
  sweep: { type:'boolean', default:false },
} });
if (!args.out) throw new Error('Required: --out NEW_DIRECTORY (existing reports cannot be overwritten)');
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
dotenv.config({ path: args.env ?? path.join(root,'.env'), quiet:true });
if (!process.env.MOTHERDUCK_TOKEN) throw new Error('MOTHERDUCK_TOKEN is required');
process.env.motherduck_token = process.env.MOTHERDUCK_TOKEN;
const catalog = getMotherDuckDatabase();
const casesPath = args.cases ?? path.join(root,'resources/shipment_audit/cases.json');
const casesBytes = await fs.readFile(casesPath);
const specification = JSON.parse(casesBytes);
const verifiedSourceIds = await verifyAuditEvidence(specification, root);
const queries = auditQueries(catalog, specification.cases, args);
const startedAt = new Date().toISOString();
await fs.mkdir(args.out, { recursive:false });
const sha256 = bytes => crypto.createHash('sha256').update(bytes).digest('hex');
const artifacts = [];
const write = async (name, value) => {
  const bytes = JSON.stringify(value,null,2)+'\n';
  await fs.writeFile(path.join(args.out,name), bytes, {flag:'wx'});
  artifacts.push({ path:name, sha256:sha256(bytes) });
};
const instance = await DuckDBInstance.create(`md:${catalog}`, {access_mode:'READ_ONLY'});
const conn = await instance.connect();
const output = {};
try {
  const actual = (await conn.runAndReadAll('SELECT current_database() AS name')).getRowObjects()[0].name;
  if (actual !== catalog) throw new Error('Connected catalog differs from configured catalog');
  // A transaction pins a consistent database snapshot across these reads.
  await conn.run('BEGIN TRANSACTION READ ONLY');
  for (const name of ['schema','revisions','cases',...(args.sweep ? ['sweep'] : [])]) {
    const q = queries[name];
    const rows = (await conn.runAndReadAll(q.sql,q.params)).getRowObjects();
    if (name === 'cases' && rows.length > 10000) throw new Error('Case result limit exceeded; narrow the audit window');
    if (name === 'sweep') {
      // Millions of grouped cells must not become one V8-sized JSON string.
      const file = createWriteStream(path.join(args.out,'sweep.ndjson.gz'), {flags:'wx'});
      const gzip = createGzip(); gzip.pipe(file);
      const totals = {};
      for (const row of rows) {
        for (const [key,value] of Object.entries(row)) if (typeof value === 'number') totals[key]=(totals[key]??0)+value;
        if (!gzip.write(JSON.stringify(row)+'\n')) await once(gzip,'drain');
      }
      gzip.end(); await finished(file);
      const bytes=await fs.readFile(path.join(args.out,'sweep.ndjson.gz'));
      artifacts.push({path:'sweep.ndjson.gz',sha256:sha256(bytes)});
      await write('sweep-summary.json',{query:q,groups:rows.length,totals});
    } else {
      output[name] = name === 'cases' ? rows.map(r => JSON.parse(r.row_json)) : rows;
      await write(`${name}.json`, { query:q, rows:output[name] });
    }
    console.log(`${name}: ${rows.length} rows`);
  }
  await conn.run('ROLLBACK');
  await write('findings.json', { interval_issues:revisionIssues(output.revisions),
    cases:compareAuditCases(specification.cases,output.cases,verifiedSourceIds) });
  await write('case-specification.json',specification);
  await write('manifest.json', { contract_version:AUDIT_CONTRACT, database:catalog,
    started_at:startedAt, finished_at:new Date().toISOString(), access_mode:'READ_ONLY',
    from:args.from, through:args.through, sweep:args.sweep, source_case_sha256:sha256(casesBytes),
    legal_stack_status:'not_certified', artifacts:[...artifacts] });
} finally { conn.closeSync(); instance.closeSync(); }
