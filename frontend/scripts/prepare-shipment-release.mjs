// Local preparation only. This command cannot connect to MotherDuck.
import { parseArgs } from 'node:util';
import fs from 'node:fs/promises';
import { DuckDBInstance } from '@duckdb/node-api';
import { readReleaseManifest, prepareRelease, preflightRelease } from '../server/shipment-release.js';
const { values } = parseArgs({ options: {
  manifest: { type: 'string' }, database: { type: 'string' }, preflight: { type: 'boolean' },
  progress: { type: 'boolean' }, report: { type: 'string' },
} });
if (!values.manifest || !values.database || values.database !== values.database.trim() || /^md:/i.test(values.database))
  throw new Error('Provide --manifest and a local --database path; cloud preparation requires separate approval');
// Reserve the report before touching the database; never overwrite earlier evidence.
const reportFile = values.report ? await fs.open(values.report, 'wx') : null;
const instance = await DuckDBInstance.create(values.database, values.preflight ? { access_mode: 'READ_ONLY' } : {});
const conn = await instance.connect();
try {
  const prepared = await readReleaseManifest(values.manifest);
  if (values.progress) prepared.onProgress = event => console.error('DIAGNOSTIC_PROGRESS '+JSON.stringify(event));
  const catalog = (await conn.runAndReadAll('SELECT current_database() AS name')).getRowObjects()[0].name;
  const report = await (values.preflight ? preflightRelease : prepareRelease)(conn, prepared, catalog);
  if (reportFile) await reportFile.writeFile(JSON.stringify(report)+'\n');
  console.log(JSON.stringify(report));
} finally { conn.closeSync(); instance.closeSync(); if (reportFile) await reportFile.close(); }
