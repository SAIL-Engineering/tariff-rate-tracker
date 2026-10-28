const fs=require('node:fs'),path=require('node:path');
const root='/home/wijreid/Desktop/SAIL/SAIL_Engineering/GitHub_tariff-rate-tracker/tariff-rate-tracker';
const req=require('node:module').createRequire(path.join(root,'frontend/package.json'));
req('dotenv').config({path:path.join(root,'.env'),quiet:true});
if(!process.env.MOTHERDUCK_TOKEN)throw new Error('Missing configured MotherDuck token');
process.env.motherduck_token=process.env.MOTHERDUCK_TOKEN;
(async()=>{const {DuckDBInstance}=req('@duckdb/node-api');const i=await DuckDBInstance.create('md:duty_calculator',{access_mode:'READ_ONLY'}),c=await i.connect();try{
 if((await c.runAndReadAll('SELECT current_database() AS catalog_name')).getRowObjects()[0].catalog_name!=='duty_calculator')throw new Error('Wrong catalog');
 await c.run('BEGIN TRANSACTION READ ONLY');
 const sql="WITH entry_days(entry_day) AS (VALUES (CAST(? AS DATE)),(CAST(? AS DATE)),(CAST(? AS DATE))), origins(country) AS (VALUES (?),(?),(?),(?)) SELECT d.entry_day::VARCHAR entry_day,o.country,r.revision,r.valid_from::VARCHAR valid_from,r.valid_until::VARCHAR valid_until,r.statutory_rate_232,r.statutory_rate_s301fl FROM entry_days d CROSS JOIN origins o LEFT JOIN rates r ON r.hts10=? AND CAST(r.country AS VARCHAR)=o.country AND r.valid_from<=d.entry_day AND r.valid_until>=d.entry_day ORDER BY d.entry_day,o.country,r.revision";
 const params=["2026-06-07", "2026-06-09", "2026-09-15", "5700", "5880", "2010", "4621", "8427104090"];const rows=(await c.runAndReadAll(sql,params)).getRowObjects();
 await c.run('ROLLBACK');
 fs.writeFileSync('/tmp/shipment-gap-closure-20261027/motherduck-mobile-points.json',JSON.stringify({catalog:'duty_calculator',access_mode:'READ_ONLY',sql,params,rows},null,2)+'\n',{flag:'wx'});
 console.log(JSON.stringify(rows));
}finally{c.closeSync();i.closeSync();}})().catch(e=>{console.error(e.message);process.exitCode=1;});
