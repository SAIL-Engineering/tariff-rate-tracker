import fs from 'node:fs/promises';
import crypto from 'node:crypto';
import dotenv from 'dotenv';
import {DuckDBInstance} from '@duckdb/node-api';
import {getMotherDuckDatabase} from '../server/config.js';
const [envFile, outputFile] = process.argv.slice(2);
if (!envFile || !outputFile || process.argv.length !== 4) throw new Error('Usage: ENV_FILE NEW_OUTPUT.json');
try { await fs.access(outputFile); throw new Error('Output already exists'); } catch(e) { if(e.code!=='ENOENT')throw e; }
dotenv.config({path:envFile,quiet:true}); process.env.motherduck_token=process.env.MOTHERDUCK_TOKEN;
const database=getMotherDuckDatabase();
const scope="country IN ('1220','2010','5700','5820','4280','4120','5880','5830') AND valid_from>=DATE '2025-01-01' AND valid_from<=DATE '2026-10-22'";
const queries={
 groups:`SELECT revision,country,substr(hts10,1,6) hts6,min(valid_from)::VARCHAR valid_from,count(*)::DOUBLE row_count,
 count(*) FILTER (WHERE statutory_rate_232=0)::DOUBLE zero_statutory_232,
 count(*) FILTER (WHERE statutory_rate_232>0)::DOUBLE positive_statutory_232,
 count(*) FILTER (WHERE statutory_rate_ieepa_fent>0)::DOUBLE positive_statutory_fentanyl,
 count(*) FILTER (WHERE statutory_rate_ieepa_recip>0)::DOUBLE positive_statutory_reciprocal,
 count(*) FILTER (WHERE statutory_total_rate IS NOT NULL)::DOUBLE numeric_statutory_total
 FROM rates WHERE ${scope} AND substr(hts10,1,6) IN ('847150','847180','847330','840991','840999','848340','870840','853710','630790') GROUP BY revision,country,substr(hts10,1,6) ORDER BY valid_from,revision,country,hts6`,
 cases:`SELECT hts10,country,revision,valid_from::VARCHAR valid_from,valid_until::VARCHAR valid_until,statutory_base_rate,statutory_rate_232,statutory_rate_232_auto,statutory_rate_ieepa_fent,statutory_rate_ieepa_recip,statutory_rate_301,statutory_rate_s122,statutory_rate_s338,statutory_total_rate,rate_232,rate_301,rate_ieepa_fent,rate_ieepa_recip,ch99_code_232,ch99_code_301,metal_share FROM rates WHERE ${scope} AND hts10 IN ('8471500150','8471500110','8471801000','8473301180','8409915080','8409999990','8483409000','8708407580','8537109120','6307909891','6307909870','6307909842') ORDER BY hts10,country,valid_from,revision LIMIT 6001`
};
const result={database,access_mode:'READ_ONLY',started_at:new Date().toISOString(),queries,results:{}};
const db=await DuckDBInstance.create(`md:${database}`,{access_mode:'READ_ONLY'}),c=await db.connect();
try {
 if((await c.runAndReadAll('SELECT current_database() AS db')).getRowObjects()[0].db!==database)throw new Error('Wrong catalog');
 await c.run('BEGIN TRANSACTION READ ONLY');
 for(const [name,sql]of Object.entries(queries)) { const rows=(await c.runAndReadAll(sql)).getRowObjects(); if(rows.length>6000)throw new Error('Audit limit exceeded'); result.results[name]=rows; console.log(`${name}: ${rows.length}`); }
 await c.run('ROLLBACK'); result.finished_at=new Date().toISOString();
 const bytes=JSON.stringify(result,null,2)+'\n';await fs.writeFile(outputFile,bytes,{flag:'wx'});console.log(crypto.createHash('sha256').update(bytes).digest('hex'));
} finally {c.closeSync();db.closeSync();}
