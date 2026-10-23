// Local preparation only. This command cannot connect to MotherDuck.
import { parseArgs } from 'node:util';
import { DuckDBInstance } from '@duckdb/node-api';
import { readReleaseManifest, prepareRelease, preflightRelease } from '../server/shipment-release.js';
const { values } = parseArgs({ options: {
  manifest: { type: 'string' }, database: { type: 'string' }, preflight: { type: 'boolean' },
} });
if (!values.manifest || !values.database || values.database.startsWith('md:'))
  throw new Error('Provide --manifest and a local --database path; cloud preparation requires separate approval');
const instance = await DuckDBInstance.create(values.database, values.preflight ? { access_mode: 'READ_ONLY' } : {});
const conn = await instance.connect();
try {
  const prepared = await readReleaseManifest(values.manifest);
  const catalog = (await conn.runAndReadAll('SELECT current_database() AS name')).getRowObjects()[0].name;
  const report = await (values.preflight ? preflightRelease : prepareRelease)(conn, prepared, catalog);
  console.log(JSON.stringify(report));
} finally { conn.closeSync(); instance.closeSync(); }
