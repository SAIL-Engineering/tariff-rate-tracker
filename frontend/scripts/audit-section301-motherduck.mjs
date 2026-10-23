/** Read-only, all-HTS China charge audit; does not rebuild or publish rates. */
import fs from 'node:fs/promises';
import crypto from 'node:crypto';
import { gzipSync } from 'node:zlib';
import dotenv from 'dotenv';
import { DuckDBInstance } from '@duckdb/node-api';
import { getMotherDuckDatabase } from '../server/config.js';

const [envFile, outputFile,mode] = process.argv.slice(2);
if (!envFile || !outputFile || (mode && mode!=='--maritime') || process.argv.length>5)
  throw new Error('Usage: ENV_FILE NEW_OUTPUT.json.gz [--maritime]');
try { await fs.access(outputFile); throw new Error('Output already exists'); } catch(e) { if(e.code!=='ENOENT')throw e; }
dotenv.config({path:envFile,quiet:true});
process.env.motherduck_token=process.env.MOTHERDUCK_TOKEN;
const database=getMotherDuckDatabase();
const query=mode==='--maritime' ? `SELECT hts10,country,revision,valid_from::VARCHAR valid_from,valid_until::VARCHAR valid_until,
 rate_301,statutory_rate_301,ch99_code_301,statutory_total_rate FROM rates
 WHERE valid_from<=DATE '2025-11-10' AND valid_until>=DATE '2025-11-08'
 AND (starts_with(hts10,'84261900') OR hts10='8716390090' OR starts_with(hts10,'87169030') OR starts_with(hts10,'87169050'))
 ORDER BY revision,hts10,country` : `SELECT hts10, revision, valid_from::VARCHAR valid_from, valid_until::VARCHAR valid_until,
 rate_301, statutory_rate_301, ch99_code_301 FROM rates
 WHERE country='5700' AND valid_from>=DATE '2025-01-01' AND valid_from<=DATE '2026-10-22'
 ORDER BY revision,hts10`;
const result={database,access_mode:'READ_ONLY',mode:mode??'china_technology_transfer',started_at:new Date().toISOString(),query};
const db=await DuckDBInstance.create(`md:${database}`,{access_mode:'READ_ONLY'}),c=await db.connect();
try {
  if((await c.runAndReadAll('SELECT current_database() AS db')).getRowObjects()[0].db!==database)throw new Error('Wrong catalog');
  await c.run('BEGIN TRANSACTION READ ONLY');
  result.rows=(await c.runAndReadAll(query)).getRowObjects();
  await c.run('ROLLBACK'); result.finished_at=new Date().toISOString();
  const bytes=JSON.stringify(result)+'\n';
  await fs.writeFile(outputFile,gzipSync(bytes),{flag:'wx'});
  console.log(JSON.stringify({rows:result.rows.length,sha256:crypto.createHash('sha256').update(bytes).digest('hex')}));
} finally { c.closeSync(); db.closeSync(); }
