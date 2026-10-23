/** Read-only all-origin note-16 inventory; never rebuilds or publishes data. */
import fs from 'node:fs/promises';
import crypto from 'node:crypto';
import {gzipSync} from 'node:zlib';
import dotenv from 'dotenv';
import {DuckDBInstance} from '@duckdb/node-api';
import {getMotherDuckDatabase} from '../server/config.js';
const [envFile,outputFile]=process.argv.slice(2);
if(!envFile || !outputFile || process.argv.length!==4)throw new Error('Usage: ENV_FILE NEW_OUTPUT.json.gz');
try {await fs.access(outputFile);throw new Error('Output already exists');}catch(e){if(e.code!=='ENOENT')throw e;}
dotenv.config({path:envFile,quiet:true});process.env.motherduck_token=process.env.MOTHERDUCK_TOKEN;
const database=getMotherDuckDatabase();
const queries={
  scope:`SELECT revision,hts10,s232_annex,s232_metal,min(valid_from)::VARCHAR valid_from,
    count(*)::DOUBLE row_count,count(DISTINCT country)::DOUBLE countries,
    count(*) FILTER (WHERE statutory_total_rate IS NOT NULL)::DOUBLE numeric_statutory_totals,
    count(*) FILTER (WHERE rate_232>0)::DOUBLE positive_modeled_232,
    min(rate_232)::DOUBLE min_modeled_232,max(rate_232)::DOUBLE max_modeled_232
    FROM rates WHERE valid_from>=DATE '2026-04-06' AND valid_from<=DATE '2026-10-22'
    GROUP BY revision,hts10,s232_annex,s232_metal ORDER BY revision,hts10,s232_annex,s232_metal`,
  attribution:`SELECT revision,country,min(valid_from)::VARCHAR valid_from,count(*)::DOUBLE row_count,
    count(*) FILTER (WHERE abs(rate_232-(rate_232_auto+rate_232_steel+rate_232_aluminum+rate_232_copper+rate_232_other))>1e-9)::DOUBLE action_total_disagreement,
    count(*) FILTER (WHERE statutory_rate_232>0 AND ch99_code_232 IS NULL)::DOUBLE positive_without_reporting_code
    FROM rates WHERE valid_from>=DATE '2025-01-01' AND valid_from<=DATE '2026-10-22'
    GROUP BY revision,country ORDER BY revision,country`
};
const result={database,access_mode:'READ_ONLY',started_at:new Date().toISOString(),queries,results:{}};
const db=await DuckDBInstance.create(`md:${database}`,{access_mode:'READ_ONLY'}),c=await db.connect();
try{
  if((await c.runAndReadAll('SELECT current_database() AS db')).getRowObjects()[0].db!==database)throw new Error('Wrong catalog');
  await c.run('BEGIN TRANSACTION READ ONLY');
  for(const [name,sql]of Object.entries(queries)){
    const rows=(await c.runAndReadAll(sql)).getRowObjects();
    if(rows.length>1000000)throw new Error('Audit row limit exceeded');
    result.results[name]=rows;console.log(`${name}: ${rows.length}`);
  }
  await c.run('ROLLBACK');result.finished_at=new Date().toISOString();
  const bytes=JSON.stringify(result)+'\n';await fs.writeFile(outputFile,gzipSync(bytes),{flag:'wx'});
  console.log(crypto.createHash('sha256').update(bytes).digest('hex'));
}finally{c.closeSync();db.closeSync();}
