import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import crypto from 'node:crypto';
import {evaluateShipmentBundle} from '../server/generated/shipmentRules.js';
import {DuckDBInstance} from '@duckdb/node-api';
import {tableFromIPC} from 'apache-arrow';
import {registerShipmentRoutes} from '../server/shipment-routes.js';
import {SHIPMENT_CONTRACT,RELEASE_CONTRACT} from '../server/shipment-store.js';
const {bundles,cases}=JSON.parse(await fs.readFile(new URL('../../tests/fixtures/shipment/ieepa-emergency.json',import.meta.url)));
for(const c of cases)test(`IEEPA emergency R/TypeScript: ${c.name}`,()=>{
 const r=evaluateShipmentBundle(bundles[c.bundle],c.hts10,c.country,c.entry_at,c.facts);
 assert.equal(r.known_subtotal,c.expected.known_subtotal);
 assert.deepEqual(r.missing_inputs,c.expected.missing_inputs);
 assert.deepEqual(r.source_errors,c.expected.source_errors);
 assert.deepEqual([...new Set(r.components.filter(x=>x.authority==='ieepa_fentanyl'&&x.status==='applied').flatMap(x=>x.reporting_codes))].sort(),c.expected.codes);
 assert.equal(r.complete_total,null);
});

test('IEEPA rules and incomplete facts survive local DuckDB, JSON, batch and Arrow',async()=>{
 const instance=await DuckDBInstance.create(':memory:');const conn=await instance.connect();
 try{
  const b=bundles.november,schema='release_'+'2'.repeat(16),encoded=JSON.stringify(b);
  await conn.run('CREATE TABLE tariff_releases (release_id VARCHAR,schema_name VARCHAR,contract_version VARCHAR,evidence_snapshot_id VARCHAR,dataset_version VARCHAR,status VARCHAR)');
  await conn.run('CREATE TABLE tariff_active_release (singleton INTEGER,release_id VARCHAR)');
  await conn.run('INSERT INTO tariff_releases VALUES (?,?,?,?,?,?)',['synthetic-ieepa',schema,RELEASE_CONTRACT,b.evidence_snapshot_id,b.dataset_version,'validated']);
  await conn.run("INSERT INTO tariff_active_release VALUES (1,'synthetic-ieepa')");
  await conn.run(`CREATE SCHEMA ${schema}`);
  await conn.run(`CREATE TABLE ${schema}.rule_bundles (valid_from TIMESTAMPTZ,valid_until TIMESTAMPTZ,bundle_json VARCHAR,bundle_sha256 VARCHAR)`);
  await conn.run(`INSERT INTO ${schema}.rule_bundles VALUES (?,?,?,?)`,[b.valid_from,b.valid_until,encoded,crypto.createHash('sha256').update(encoded).digest('hex')]);
  const routes=new Map();registerShipmentRoutes({get:(u,...h)=>routes.set(u,h.at(-1)),post:(u,...h)=>routes.set(u,h.at(-1))},{connection:()=>conn,requireAuth:(_q,_s,next)=>next()});
  async function request(url,body,query={}){
   let payload,status=200;const headers={};const res={set:(k,v)=>{headers[k]=v;return res;},type:()=>res,status:n=>{status=n;return res;},json:v=>{payload=v;return res;},send:v=>{payload=v;return res;}};
   await routes.get(url)({method:'POST',path:url,body,query},res,()=>{});
   assert.equal(status,200);assert.equal(headers['X-Dataset-Version'],b.dataset_version);return payload;
  }
  const selected=cases.filter(c=>c.bundle==='november'&&['November exact replacement instant','repair valuation in covered origin','FTZ does not inherit entry-date rate'].includes(c.name));
  assert.equal(selected.length,3);
  const shipments=selected.map(({hts10,country,entry_at,facts})=>({hts10,country,entry_at,facts}));
  const single=await request('/api/shipments/resolve',shipments[0]);assert.equal(single.data[0].known_subtotal,10);
  const body={contract_version:SHIPMENT_CONTRACT,shipments};const batch=await request('/api/rates/batch',body);
  const arrow=tableFromIPC(await request('/api/rates/batch',body,{format:'arrow'}));
  for(let i=0;i<selected.length;i++){
   assert.equal(batch.data[i].known_subtotal,selected[i].expected.known_subtotal);
   assert.equal(batch.data[i].complete_total,null);
   assert.deepEqual(JSON.parse(arrow.getChild('components_json').get(i)),batch.data[i].components);
   assert.deepEqual(JSON.parse(arrow.getChild('source_errors_json').get(i)),batch.data[i].source_errors);
  }
 }finally{conn.closeSync();instance.closeSync();}
});
