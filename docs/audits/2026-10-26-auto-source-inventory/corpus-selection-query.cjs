const fs=require('node:fs');const path=require('node:path');
const root=path.resolve(__dirname,'../../..');
const req=require('node:module').createRequire(path.join(root,'frontend/package.json'));
req('dotenv').config({path:path.join(root,'.env'),quiet:true});
if(!process.env.MOTHERDUCK_TOKEN)throw new Error('Missing configured MotherDuck token');
process.env.motherduck_token=process.env.MOTHERDUCK_TOKEN;
const ids=JSON.parse(fs.readFileSync(process.argv[2])).results.map(r=>r.document_number);
const sql=`SELECT document_number,title,CAST(publication_date AS VARCHAR) AS publication_date,source_url,official_document_url,source_hash,content_sha256,version_no,is_current,raw_object_path,raw_text_object_path,full_text FROM documents WHERE document_number IN (${ids.map(()=>'?').join(',')}) ORDER BY document_number`;
(async()=>{const {DuckDBInstance}=req('@duckdb/node-api');const inst=await DuckDBInstance.create('md:trade_intel_fr',{access_mode:'READ_ONLY'});const conn=await inst.connect();try{
 const catalog=(await conn.runAndReadAll('SELECT current_database() AS catalog_name')).getRowObjects()[0].catalog_name;
 if(catalog!=='trade_intel_fr')throw new Error('Unexpected catalog');
 await conn.run('BEGIN TRANSACTION READ ONLY');
 const rows=(await conn.runAndReadAll(sql,ids)).getRowObjects();
 await conn.run('ROLLBACK');
 const out={kind:'research_evidence_selection_not_release_snapshot',catalog,table:'documents',access_mode:'READ_ONLY',captured_at:new Date().toISOString(),sql,params:ids,rows};
 fs.writeFileSync(process.argv[3],JSON.stringify(out,null,2)+'\n',{flag:'wx'});
 console.log(JSON.stringify({catalog,requested:ids.length,found:rows.length,nonempty_text:rows.filter(r=>r.full_text).length,original_present:rows.some(r=>r.document_number==='2025-05930')}));
}finally{conn.closeSync();inst.closeSync();}})().catch(e=>{console.error(e.message);process.exitCode=1});
