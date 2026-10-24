// Entire Canadian product inventory, not selected example codes. Read-only.
import fs from 'node:fs/promises';
import crypto from 'node:crypto';
import dotenv from 'dotenv';
import {DuckDBInstance} from '@duckdb/node-api';
import {getMotherDuckDatabase} from '../server/config.js';
const [envFile,outputFile]=process.argv.slice(2);
if(!envFile||!outputFile||process.argv.length!==4)throw new Error('Usage: ENV_FILE NEW_OUTPUT.json');
try{await fs.access(outputFile);throw new Error('Output exists');}catch(e){if(e.code!=='ENOENT')throw e;}
dotenv.config({path:envFile,quiet:true});process.env.motherduck_token=process.env.MOTHERDUCK_TOKEN;
const database=getMotherDuckDatabase(),started_at=new Date().toISOString();
const sql=`SELECT revision,hts10,country,valid_from::VARCHAR valid_from,valid_until::VARCHAR valid_until,
 statutory_rate_s338,rate_s338,ch99_code_s338,statutory_rate_232,ch99_code_232,s232_annex,
 count(*)::DOUBLE row_count
 FROM rates WHERE country='1220' AND valid_from<=DATE '2026-10-22' AND valid_until>=DATE '2026-08-19'
 GROUP BY ALL ORDER BY valid_from,revision,hts10`;
const instance=await DuckDBInstance.create(`md:${database}`,{access_mode:'READ_ONLY'}),c=await instance.connect();
try{
 if((await c.runAndReadAll('SELECT current_database() db')).getRowObjects()[0].db!==database)throw new Error('Wrong audit catalog');
 await c.run('BEGIN TRANSACTION READ ONLY');
 const rows=(await c.runAndReadAll(sql)).getRowObjects();await c.run('ROLLBACK');
 const bytes=JSON.stringify({database,access_mode:'READ_ONLY',started_at,finished_at:new Date().toISOString(),sql,rows})+'\n';
 await fs.writeFile(outputFile,bytes,{flag:'wx'});
 console.log(`${rows.length} groups; sha256 ${crypto.createHash('sha256').update(bytes).digest('hex')}`);
}finally{c.closeSync();instance.closeSync();}
