// Read-only inventory for revision-bound historical metal scope reconciliation.
// A numeric discrepancy is a candidate finding, not a complete shipment total.
import fs from 'node:fs/promises';
import crypto from 'node:crypto';
import dotenv from 'dotenv';
import {DuckDBInstance} from '@duckdb/node-api';
import {getMotherDuckDatabase} from '../server/config.js';
const [envFile,outputFile,mode]=process.argv.slice(2);
const preMarch=mode==='--pre-march';
if(!envFile||!outputFile||process.argv.length!==(preMarch?5:4)||(mode&&!preMarch)) throw new Error('Usage: ENV_FILE NEW_OUTPUT.json [--pre-march]');
try {await fs.access(outputFile);throw new Error('Output exists');} catch(e) {if(e.code!=='ENOENT') throw e;}
dotenv.config({path:envFile,quiet:true});
process.env.motherduck_token=process.env.MOTHERDUCK_TOKEN;
const database=getMotherDuckDatabase();
const queries={
  schema:'DESCRIBE rates',
  primary_chapter_scope:`SELECT revision,hts10,valid_from::VARCHAR valid_from,valid_until::VARCHAR valid_until,
    count(*)::DOUBLE origin_rows,
    count(*) FILTER(WHERE rate_232_steel>0 OR rate_232_aluminum>0)::DOUBLE positive_metal_rows,
    count(*) FILTER(WHERE rate_232_auto>0 OR rate_232_copper>0 OR rate_232_other>0)::DOUBLE other_action_rows,
    min(rate_232)::DOUBLE min_modeled_232,max(rate_232)::DOUBLE max_modeled_232,
    count(*) FILTER(WHERE statutory_rate_232>0)::DOUBLE positive_statutory_rows
    FROM rates WHERE valid_from>=DATE '2025-03-12' AND valid_from<DATE '2026-04-06'
      AND substr(hts10,1,2) IN ('72','73','76')
    GROUP BY ALL ORDER BY revision,hts10`,
  metal_components:`SELECT revision,country,valid_from::VARCHAR valid_from,valid_until::VARCHAR valid_until,
    duty_basis_232,ch99_code_232,count(*)::DOUBLE row_count,
    count(*) FILTER(WHERE rate_232_steel>0 AND rate_232_aluminum>0)::DOUBLE mixed_metal_rows,
    count(*) FILTER(WHERE rate_232_steel>0 OR rate_232_aluminum>0)::DOUBLE positive_metal_rows
    FROM rates WHERE valid_from>=DATE '2025-03-12' AND valid_from<DATE '2026-04-06'
    GROUP BY ALL ORDER BY revision,country,ch99_code_232`
};
if(preMarch) {
  for(const key of ['primary_chapter_scope','metal_components']) queries[key]=queries[key].replaceAll(
    "valid_from>=DATE '2025-03-12' AND valid_from<DATE '2026-04-06'",
    "valid_from<DATE '2025-03-12' AND (valid_until IS NULL OR valid_until>=DATE '2025-01-01')");
  queries.shipment_candidates=`SELECT revision,hts10,country,valid_from::VARCHAR valid_from,valid_until::VARCHAR valid_until,
    rate_232::DOUBLE rate_232,rate_232_steel::DOUBLE rate_232_steel,rate_232_aluminum::DOUBLE rate_232_aluminum,
    statutory_rate_232::DOUBLE statutory_rate_232,ch99_code_232,duty_basis_232
    FROM rates WHERE valid_from<DATE '2025-03-12' AND (valid_until IS NULL OR valid_until>=DATE '2025-01-01')
    AND hts10 IN ('7208101500','7202115000','7210706030','7317005503','7317005590','7604101000','7605290000')
    ORDER BY revision,hts10,country`;
}
const started_at=new Date().toISOString();
const instance=await DuckDBInstance.create(`md:${database}`,{access_mode:'READ_ONLY'}),c=await instance.connect();
try {
  if((await c.runAndReadAll('SELECT current_database() AS db')).getRowObjects()[0].db!==database) throw new Error('Wrong audit catalog');
  await c.run('BEGIN TRANSACTION READ ONLY');
  const result={database,access_mode:'READ_ONLY',started_at,queries,results:{}};
  for(const [key,sql] of Object.entries(queries)) {
    result.results[key]=(await c.runAndReadAll(sql)).getRowObjects();
    console.log(`${key}: ${result.results[key].length} groups`);
  }
  await c.run('ROLLBACK');result.finished_at=new Date().toISOString();
  const bytes=JSON.stringify(result,null,2)+'\n';
  await fs.writeFile(outputFile,bytes,{flag:'wx'});
  console.log('sha256 '+crypto.createHash('sha256').update(bytes).digest('hex'));
} finally {c.closeSync();instance.closeSync();}
