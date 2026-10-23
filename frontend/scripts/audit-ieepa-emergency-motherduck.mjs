// Read-only inventory for reconciliation with revision-bound note 2 extraction.
// A numeric discrepancy is a candidate finding, not a complete shipment total.
import fs from 'node:fs/promises';
import crypto from 'node:crypto';
import dotenv from 'dotenv';
import {DuckDBInstance} from '@duckdb/node-api';
import {getMotherDuckDatabase} from '../server/config.js';
const [envFile,outputFile]=process.argv.slice(2);
if(!envFile||!outputFile||process.argv.length!==4) throw new Error('Usage: ENV_FILE NEW_OUTPUT.json');
try {await fs.access(outputFile);throw new Error('Output exists');} catch(e) {if(e.code!=='ENOENT') throw e;}
dotenv.config({path:envFile,quiet:true});
process.env.motherduck_token=process.env.MOTHERDUCK_TOKEN;
const database=getMotherDuckDatabase();
const queries={
  schema:'DESCRIBE rates',
  emergency:`SELECT revision,country,valid_from::VARCHAR valid_from,valid_until::VARCHAR valid_until,
    statutory_rate_ieepa_fent, ch99_code_ieepa_fent,
    count(*)::DOUBLE row_count,
    count(*) FILTER(WHERE rate_ieepa_fent>0)::DOUBLE positive_modeled_rows,
    min(hts10) sample_hts10
    FROM rates WHERE valid_from BETWEEN DATE '2025-01-01' AND DATE '2026-10-22'
      AND country IN ('1220','2010','5700','5820')
    GROUP BY ALL ORDER BY revision,country,statutory_rate_ieepa_fent,ch99_code_ieepa_fent`,
  section122_precision:`SELECT revision,hts10,valid_from::VARCHAR valid_from,valid_until::VARCHAR valid_until,
    statutory_rate_s122,statutory_rate_232,ch99_code_s122,
    count(*)::DOUBLE origin_rows
    FROM rates WHERE valid_from<=DATE '2026-07-23' AND valid_until>=DATE '2026-02-24'
      AND (starts_with(hts10,'85051100') OR starts_with(hts10,'90314970'))
    GROUP BY ALL ORDER BY revision,hts10,statutory_rate_s122,statutory_rate_232`,
  interval_coverage:`SELECT revision,min(valid_from)::VARCHAR valid_from,max(valid_until)::VARCHAR valid_until,
    count(DISTINCT valid_from)::DOUBLE legal_intervals,count(*)::DOUBLE row_count
    FROM rates WHERE valid_from BETWEEN DATE '2025-01-01' AND DATE '2026-10-22'
    GROUP BY revision ORDER BY valid_from,revision`
};
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
