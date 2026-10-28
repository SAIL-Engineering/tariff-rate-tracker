const fs=require('node:fs'),path=require('node:path');
const root='/home/wijreid/Desktop/SAIL/SAIL_Engineering/GitHub_tariff-rate-tracker/tariff-rate-tracker';
const req=require('node:module').createRequire(path.join(root,'frontend/package.json'));
req('dotenv').config({path:path.join(root,'.env'),quiet:true});
if(!process.env.MOTHERDUCK_TOKEN)throw new Error('Missing configured MotherDuck token');
process.env.motherduck_token=process.env.MOTHERDUCK_TOKEN;
(async()=>{const {DuckDBInstance}=req('@duckdb/node-api');const i=await DuckDBInstance.create('md:trade_intel_csms',{access_mode:'READ_ONLY'}),c=await i.connect();try{
 if((await c.runAndReadAll('SELECT current_database() AS catalog_name')).getRowObjects()[0].catalog_name!=='trade_intel_csms')throw new Error('Wrong catalog');
 await c.run('BEGIN TRANSACTION READ ONLY');
 const sql="SELECT csms_number,title,CAST(sent_at AS VARCHAR) sent_at,bulletin_url,source_hash,version_no,is_current,raw_object_path,body_html_object_path,content_sha256,body_text FROM notices WHERE body_text LIKE '%9903.82.06%' OR title ILIKE '%11032%' ORDER BY sent_at,csms_number";
 const params=[];const rows=(await c.runAndReadAll(sql,params)).getRowObjects();
 await c.run('ROLLBACK');
 fs.writeFileSync('/tmp/shipment-gap-closure-20261027/motherduck-note16-csms.json',JSON.stringify({catalog:'trade_intel_csms',access_mode:'READ_ONLY',sql,params,rows},null,2)+'\n',{flag:'wx'});
 for(const r of rows)console.log([r.csms_number,r.sent_at,r.title,r.version_no].join(' | '));
}finally{c.closeSync();i.closeSync();}})().catch(e=>{console.error(e.message);process.exitCode=1;});
