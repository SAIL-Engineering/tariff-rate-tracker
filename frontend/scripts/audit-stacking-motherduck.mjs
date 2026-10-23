import fs from 'node:fs/promises';
import crypto from 'node:crypto';
import dotenv from 'dotenv';
import {DuckDBInstance} from '@duckdb/node-api';
import {getMotherDuckDatabase} from '../server/config.js';
const [envFile, outputFile] = process.argv.slice(2);
if (!envFile || !outputFile || process.argv.length !== 4) throw new Error('Usage: node frontend/scripts/audit-stacking-motherduck.mjs .env NEW_OUTPUT.json');
try { await fs.access(outputFile); throw new Error('Output already exists'); } catch(e) { if (e.code !== 'ENOENT') throw e; }
dotenv.config({path:envFile,quiet:true});
process.env.motherduck_token=process.env.MOTHERDUCK_TOKEN;
const database=getMotherDuckDatabase();
const queries={
 groups:`SELECT revision, min(valid_from)::VARCHAR valid_from, country, count(*)::DOUBLE row_count,
 count(*) FILTER (WHERE statutory_rate_ieepa_fent>0 AND statutory_rate_232>0 AND statutory_rate_232_auto=0 AND (substr(hts10,1,2) IN ('72','73','76')) AND statutory_rate_232_steel=0 AND statutory_rate_232_aluminum=0)::DOUBLE metals_suppressed,
 count(*) FILTER (WHERE rate_ieepa_fent>0 AND rate_232>0)::DOUBLE concurrent_fentanyl_232
 FROM rates WHERE valid_from >= DATE '2025-01-01' AND valid_from <= DATE '2026-10-22' AND country IN ('1220','2010','5700','5820') GROUP BY revision,country ORDER BY valid_from,revision,country`,
 cases:`SELECT to_json(r)::VARCHAR row_json FROM rates r WHERE valid_from >= DATE '2025-01-01' AND valid_from <= DATE '2026-10-22' AND country IN ('1220','2010','5700','5820') AND hts10 IN ('7202115000','7326908688','7604291010','8703230190','7408110000','8471500150') ORDER BY hts10,country,valid_from,revision LIMIT 2001`,
 hk:`SELECT to_json(r)::VARCHAR row_json FROM rates r WHERE revision='2025_rev_14' AND country='5820' AND rate_232>0 AND rate_ieepa_fent>0 ORDER BY hts10 LIMIT 12`
};
const started_at=new Date().toISOString(), instance=await DuckDBInstance.create(`md:${database}`,{access_mode:'READ_ONLY'}), c=await instance.connect();
try {
 if ((await c.runAndReadAll('SELECT current_database() AS db')).getRowObjects()[0].db !== database) throw new Error('Wrong audit catalog');
 await c.run('BEGIN TRANSACTION READ ONLY');
 const result={database,access_mode:'READ_ONLY',started_at,queries,results:{}};
 for(const [name,sql] of Object.entries(queries)){ const rows=(await c.runAndReadAll(sql)).getRowObjects();if(name==='cases' && rows.length>2000) throw new Error('Case audit exceeds limit');result.results[name]=name==='groups'?rows:rows.map(r=>JSON.parse(r.row_json));console.log(`${name}: ${rows.length}`); }
 await c.run('ROLLBACK');result.finished_at=new Date().toISOString();const bytes=JSON.stringify(result,null,2)+'\n';
 await fs.writeFile(outputFile,bytes,{flag:'wx'});console.log('sha256 '+crypto.createHash('sha256').update(bytes).digest('hex'));
}finally{c.closeSync();instance.closeSync();}
