import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
import {execFile} from 'node:child_process';
import {promisify} from 'node:util';
import {DuckDBInstance} from '@duckdb/node-api';
import {readReleaseManifest,preflightRelease,prepareRelease,activateRelease,NORMALIZED_RELEASE_COLUMNS,RELEASE_MIGRATION} from '../server/shipment-release.js';
import {activeShipmentRelease,resolveStoredShipment} from '../server/shipment-store.js';
const exec=promisify(execFile),hash=x=>crypto.createHash('sha256').update(x).digest('hex');
const q=x=>`'${x.replaceAll("'","''")}'`;
async function fixture(fn,{hive=false}={}) {
 const root=await fs.mkdtemp(path.join(os.tmpdir(),'index-release-'));
 const instance=await DuckDBInstance.create(':memory:'),conn=await instance.connect();
 try {
  await exec('Rscript',['tests/test_shipment_partition_validation.R'],{cwd:new URL('../../',import.meta.url),env:{...process.env,SHIPMENT_PARTITION_FIXTURE_DIR:root},maxBuffer:2e6});
  const index=JSON.parse(await fs.readFile(path.join(root,'shipment_rules.json')));
  const revision={revision:index.revision};
  const type=(table,k)=>k==='terminated'||k==='derivative'?'BOOLEAN':k==='scope_grain'&&['section232_scope_decisions','ieepa_reciprocal_scope_decisions'].includes(table)?'INTEGER':
   k==='rate'||k.endsWith('_parameter')?'DOUBLE':k.startsWith('state_valid_')||['valid_from','valid_until'].includes(k)&&['products_base','authority_country_rates','authority_product_applicability','authority_exemptions'].includes(table)?'DATE':'VARCHAR';
  for(const [table,columns] of Object.entries(NORMALIZED_RELEASE_COLUMNS)) {
   if(table==='rates')continue;
   const target=path.join(root,table+'.parquet');
   const sql=table==='products_base'?`SELECT hts10,revision,valid_from,valid_until,'5%' duty_expression_raw,'10%' rate_column2_raw FROM read_parquet(${q(path.join(root,'rates.parquet'))}) GROUP BY ALL`:
    `SELECT ${columns.map(k=>`NULL::${type(table,k)} AS "${k}"`).join(',')} WHERE FALSE`;
   await conn.run(`COPY (${sql}) TO ${q(target)} (FORMAT PARQUET)`);
  }
  for(const [table,fields] of Object.entries({chapter99_provisions:['revision','reporting_code','native_record_sha256','pdf_sha256','hts_sha256','rule_links_json','status'],chapter99_notes:['revision','note_id','source_text','source_text_sha256']}))
   await conn.run(`COPY (SELECT ${fields.map(k=>`NULL::VARCHAR ${k}`).join(',')} WHERE FALSE) TO ${q(path.join(root,table+'.parquet'))} (FORMAT PARQUET)`);
  const descriptor=async name=>({path:name,sha256:hash(await fs.readFile(path.join(root,name)))});
  for(const table of [...Object.keys(NORMALIZED_RELEASE_COLUMNS),'chapter99_provisions','chapter99_notes','shipment_decision_classes','shipment_decision_membership'])revision[table]=[await descriptor(table+'.parquet')];
  if(hive) {
   const folder=path.join(root,'rates','revision='+index.revision);await fs.mkdir(folder,{recursive:true});
   await conn.run(`COPY (SELECT * EXCLUDE(revision) FROM read_parquet(${q(path.join(root,'rates.parquet'))})) TO ${q(path.join(folder,'data.parquet'))} (FORMAT PARQUET)`);
   revision.rates=[await descriptor(path.relative(root,path.join(folder,'data.parquet')))];revision.rates_partitioning='hive_revision';
  }
  revision.bundle_index=await descriptor('shipment_rules.json');
  const manifest={contract_version:'sail.tariff-release/v8',preparation_mode:'diagnostic',dataset_version:index.dataset_version,evidence_snapshot_id:index.evidence_snapshot_id,required_revisions:[index.revision],revisions:[revision]};
  const file=path.join(root,'release.json'),save=()=>fs.writeFile(file,JSON.stringify(manifest));await save();
  const catalog=(await conn.runAndReadAll('SELECT current_database() AS name')).getRowObjects()[0].name;
  await fn({root,conn,file,index,manifest,revision,catalog,save,descriptor});
 } finally {conn.closeSync();instance.closeSync();await fs.rm(root,{recursive:true,force:true});}
}
test('v8 stages every exact-time bundle and serves the declared rules without activation',()=>fixture(async({conn,file,index,catalog})=>{
 const p=await readReleaseManifest(file);assert.equal(p.manifest.contract_version,'sail.tariff-release/v8');
 const pre=await preflightRelease(conn,p,catalog);assert.equal(pre.revisions,1);assert.equal(pre.shipment_verification[0].grid_cells,4);
 const report=await prepareRelease(conn,p,catalog);assert.equal(report.status,'prepared_diagnostic');
 assert.equal(Number((await conn.runAndReadAll(`SELECT count(*) n FROM "${p.schema}".rule_bundles`)).getRowObjects()[0].n),2);
 assert.equal(await activeShipmentRelease(conn),null);
 const r=await resolveStoredShipment(conn,{schema_name:p.schema,dataset_version:index.dataset_version,evidence_snapshot_id:index.evidence_snapshot_id},
  {hts10:'1234567890',country:'2010',entry_at:'2026-01-01T10:00:00Z',facts:{customs_value:100}});
 assert.equal(r.known_subtotal,5);assert.equal(r.complete_total,null);
 await conn.run("UPDATE tariff_releases SET status='validated'");
 await assert.rejects(activateRelease(conn,p.releaseId,null),/diagnostic/i);
 assert.equal(await activeShipmentRelease(conn),null);
 await conn.run('INSERT INTO tariff_active_release(singleton,release_id) VALUES (1,?)',[p.releaseId]);
 assert.equal(await activeShipmentRelease(conn),null,'A manually forged pointer cannot serve a diagnostic release');
}));
test('v8 refuses mixed versions, changed artifacts and missing normalized partitions before loading',()=>fixture(async({file,revision,save,conn,catalog,root})=>{
 const original=revision.bundle_index;delete revision.bundle_index;await save();await assert.rejects(readReleaseManifest(file),/bundle.index/i);
 revision.bundle_index=original;await save();const p=await readReleaseManifest(file);
 await fs.appendFile(path.join(root,revision.rates[0].path),'x');await assert.rejects(preflightRelease(conn,p,catalog),/hash/i);
 assert.equal(await activeShipmentRelease(conn),null);
}));
test('production preparation cannot use diagnostic evidence or a partial revision selection',()=>fixture(async({manifest,save,file})=>{
 manifest.preparation_mode='production';await save();await assert.rejects(readReleaseManifest(file),/evidence|coverage|revision/i);
}));

test('the ordinary combiner Hive partition identity is verified without rewriting its Parquet',()=>fixture(async({conn,file,catalog})=>{
 const p=await readReleaseManifest(file);const report=await prepareRelease(conn,p,catalog);
 assert.equal(report.status,'prepared_diagnostic');
 assert.deepEqual((await conn.runAndReadAll(`SELECT DISTINCT revision FROM "${p.schema}".rates`)).getRowObjects(),[{revision:'synthetic_partition'}]);
},{hive:true}));

test('duplicate product states cannot multiply a release join',()=>fixture(async({conn,file,catalog,root,revision,save,descriptor})=>{
 const target=path.join(root,'duplicate-products.parquet');
 await conn.run(`COPY (SELECT * FROM read_parquet(${q(path.join(root,'products_base.parquet'))}) UNION ALL SELECT * FROM read_parquet(${q(path.join(root,'products_base.parquet'))})) TO ${q(target)} (FORMAT PARQUET)`);
 revision.products_base=[await descriptor('duplicate-products.parquet')];await save();
 const p=await readReleaseManifest(file);await assert.rejects(prepareRelease(conn,p,catalog),/Duplicate product-base/);
 assert.equal(await activeShipmentRelease(conn),null);
 const tables=(await conn.runAndReadAll("SELECT table_name FROM information_schema.tables WHERE table_name='tariff_releases'")).getRowObjects();
 assert.equal(tables.length,0);
}));

test('a correctly hashed forged membership still fails executable reconciliation',()=>fixture(async({conn,file,catalog,root,revision,save,descriptor})=>{
 await conn.run(RELEASE_MIGRATION);
 await conn.run("INSERT INTO tariff_releases(release_id,schema_name,contract_version,dataset_version,evidence_snapshot_id,manifest_sha256,status) VALUES ('prior-release',?,'sail.tariff-release/v7','prior-dataset',?,?, 'validated')",['release_'+'f'.repeat(24),'0'.repeat(64),'1'.repeat(64)]);
 await conn.run("INSERT INTO tariff_active_release(singleton,release_id) VALUES (1,'prior-release')");
 const target=path.join(root,'forged-membership.parquet');
 await conn.run(`COPY (SELECT * REPLACE('invented-class' AS class_id) FROM read_parquet(${q(path.join(root,'shipment_decision_membership.parquet'))})) TO ${q(target)} (FORMAT PARQUET)`);
 revision.shipment_decision_membership=[await descriptor('forged-membership.parquet')];await save();
 const p=await readReleaseManifest(file);await assert.rejects(prepareRelease(conn,p,catalog),/membership mismatch/i);
 assert.equal((await activeShipmentRelease(conn)).release_id,'prior-release','Failed preparation preserves the active release');
}));

test('catalog mismatch and unsupported field types fail read-only preflight',()=>fixture(async({conn,file,catalog,root,revision,save,descriptor})=>{
 let p=await readReleaseManifest(file);await assert.rejects(preflightRelease(conn,p,'unrelated-catalog'),/catalog mismatch/i);
 const target=path.join(root,'wrong-rates.parquet');
 await conn.run(`COPY (SELECT * REPLACE(CAST(statutory_base_rate AS VARCHAR) AS statutory_base_rate) FROM read_parquet(${q(path.join(root,'rates.parquet'))})) TO ${q(target)} (FORMAT PARQUET)`);
 revision.rates=[await descriptor('wrong-rates.parquet')];await save();p=await readReleaseManifest(file);
 await assert.rejects(preflightRelease(conn,p,catalog),/Missing or invalid rates fields/);
 assert.equal(await activeShipmentRelease(conn),null);
}));

test('optional partition fields and reordered columns load by name without inventing zeros',()=>fixture(async({conn,file,catalog,root,revision,save,descriptor})=>{
 const source=q(path.join(root,'rates.parquet'));
 await conn.run(`COPY (SELECT *,7.25::DOUBLE AS optional_probe FROM read_parquet(${source}) WHERE country='2010') TO ${q(path.join(root,'part-a.parquet'))} (FORMAT PARQUET)`);
 await conn.run(`COPY (SELECT country,* EXCLUDE(country),'source evidence'::VARCHAR AS optional_label FROM read_parquet(${source}) WHERE country='5700') TO ${q(path.join(root,'part-b.parquet'))} (FORMAT PARQUET)`);
 revision.rates=[await descriptor('part-a.parquet'),await descriptor('part-b.parquet')];await save();
 const p=await readReleaseManifest(file);await prepareRelease(conn,p,catalog);
 const rows=(await conn.runAndReadAll(`SELECT country,optional_probe,optional_label FROM "${p.schema}".rates ORDER BY country,hts10`)).getRowObjects();
 assert.equal(rows.length,4);
 for(const r of rows)assert.deepEqual(r,r.country==='2010'
  ?{country:'2010',optional_probe:7.25,optional_label:null}
  :{country:'5700',optional_probe:null,optional_label:'source evidence'});
}));

test('each physical partition must contain required fields before union can fill optional nulls',()=>fixture(async({conn,file,catalog,root,revision,save,descriptor})=>{
 const source=q(path.join(root,'rates.parquet'));
 await conn.run(`COPY (SELECT * FROM read_parquet(${source}) WHERE country='2010') TO ${q(path.join(root,'part-a.parquet'))} (FORMAT PARQUET)`);
 await conn.run(`COPY (SELECT * EXCLUDE(statutory_base_rate) FROM read_parquet(${source}) WHERE country='5700') TO ${q(path.join(root,'part-b.parquet'))} (FORMAT PARQUET)`);
 revision.rates=[await descriptor('part-a.parquet'),await descriptor('part-b.parquet')];await save();
 await assert.rejects(preflightRelease(conn,await readReleaseManifest(file),catalog),/Missing or invalid rates fields:.*statutory_base_rate/);
 assert.equal(await activeShipmentRelease(conn),null);
}));

test('conflicting shared optional types are rejected with the exact field and types',()=>fixture(async({conn,file,catalog,root,revision,save,descriptor})=>{
 const source=q(path.join(root,'rates.parquet'));
 await conn.run(`COPY (SELECT *,7.25::DOUBLE AS optional_probe FROM read_parquet(${source}) WHERE country='2010') TO ${q(path.join(root,'part-a.parquet'))} (FORMAT PARQUET)`);
 await conn.run(`COPY (SELECT *,'unresolved'::VARCHAR AS optional_probe FROM read_parquet(${source}) WHERE country='5700') TO ${q(path.join(root,'part-b.parquet'))} (FORMAT PARQUET)`);
 revision.rates=[await descriptor('part-a.parquet'),await descriptor('part-b.parquet')];await save();
 await assert.rejects(preflightRelease(conn,await readReleaseManifest(file),catalog),/optional_probe.*DOUBLE.*VARCHAR/);
}));
