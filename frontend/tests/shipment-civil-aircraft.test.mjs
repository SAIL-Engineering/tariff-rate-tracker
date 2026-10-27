import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import crypto from 'node:crypto';
import {gunzipSync} from 'node:zlib';
import {DuckDBInstance} from '@duckdb/node-api';
import {tableFromIPC} from 'apache-arrow';
import {evaluateShipmentBundle} from '../server/generated/shipmentRules.js';
import {registerShipmentRoutes} from '../server/shipment-routes.js';
import {RELEASE_CONTRACT,SHIPMENT_CONTRACT} from '../server/shipment-store.js';
const {bundles,cases}=JSON.parse(gunzipSync(fs.readFileSync(new URL('../../tests/fixtures/shipment/section232-civil-aircraft.json.gz',import.meta.url))));
for(const c of cases)test('independent aircraft R/TypeScript: '+c.name,()=>{
 const r=evaluateShipmentBundle(bundles[c.bundle],c.hts10,c.country,c.entry_at,c.facts);
 assert.equal(r.known_subtotal,c.expected.known_subtotal);assert.equal(r.complete_total,null);
 assert.deepEqual(r.missing_inputs,c.expected.missing_inputs);assert.deepEqual(r.source_errors,c.expected.source_errors);
 const codes=[...new Set(r.components.filter(x=>x.authority==='section_232'&&x.status==='applied').flatMap(x=>x.reporting_codes))].sort();
 assert.deepEqual(codes,c.expected.codes);assert.ok(r.applied_rules.includes('controlled-301'));
});

test('stored aircraft agreements retain their Section232 role across collection ending and heading amendments',async()=>{
 // Routing fixture: controlled metal/301 actions are not production coverage.
 const i=await DuckDBInstance.create(':memory:'),c=await i.connect();
 try {
  const first=bundles['2026_rev_4'],schema='release_'+'4'.repeat(16);
  await c.run('CREATE TABLE tariff_releases (release_id VARCHAR,schema_name VARCHAR,contract_version VARCHAR,evidence_snapshot_id VARCHAR,dataset_version VARCHAR,status VARCHAR)');
  await c.run('CREATE TABLE tariff_active_release (singleton INTEGER,release_id VARCHAR)');
  await c.run('INSERT INTO tariff_releases VALUES (?,?,?,?,?,?)',['aircraft-fixture',schema,RELEASE_CONTRACT,first.evidence_snapshot_id,first.dataset_version,'validated']);
  await c.run("INSERT INTO tariff_active_release VALUES (1,'aircraft-fixture')");
  await c.run(`CREATE SCHEMA ${schema}`);
  await c.run(`CREATE TABLE ${schema}.rule_bundles (valid_from TIMESTAMPTZ,valid_until TIMESTAMPTZ,bundle_json VARCHAR,bundle_sha256 VARCHAR)`);
  for(const b of Object.values(bundles)) {
   const text=JSON.stringify(b);
   await c.run(`INSERT INTO ${schema}.rule_bundles VALUES (?,?,?,?)`,[b.valid_from,b.valid_until,text,crypto.createHash('sha256').update(text).digest('hex')]);
  }
  const routes=new Map();registerShipmentRoutes({get:(u,...h)=>routes.set('GET '+u,h.at(-1)),post:(u,...h)=>routes.set('POST '+u,h.at(-1))},
   {connection:()=>c,requireAuth:(_q,_s,next)=>next()});
  async function post(path,body,query={}) {
   let payload,status=200;const headers={};const res={set:(k,v)=>{headers[k]=v;return res;},type:()=>res,status:n=>{status=n;return res;},json:v=>{payload=v;return res;},send:v=>{payload=v;return res;}};
   await routes.get('POST '+path)({method:'POST',path,body,query},res,()=>{});return {payload,status,headers};
  }
  const shipments=cases.map(({hts10,country,entry_at,facts})=>({hts10,country,entry_at,facts}));
  const body={contract_version:SHIPMENT_CONTRACT,shipments};
  const json=await post('/api/rates/batch',body);assert.equal(json.status,200);
  const arrow=await post('/api/rates/batch',body,{format:'arrow'});assert.equal(arrow.status,200);const table=tableFromIPC(arrow.payload);
  for(let n=0;n<cases.length;n++) {
   assert.equal(json.payload.data[n].known_subtotal,cases[n].expected.known_subtotal);
   assert.equal(table.getChild('known_subtotal').get(n),cases[n].expected.known_subtotal);
   assert.deepEqual(JSON.parse(table.getChild('components_json').get(n)),json.payload.data[n].components);
   assert.equal(json.payload.data[n].complete_total,null);
  }
  const example=shipments[cases.findIndex(x=>x.name==='4280 Section232 agreement survives IEEPA collection ending')];
  const single=await post('/api/shipments/resolve',example);assert.equal(single.status,200);
  const relief=single.payload.data[0].components.filter(x=>x.authority==='section_232'&&x.reporting_codes.includes('9903.02.76')&&x.status==='applied');
  assert.equal(relief.length,1);assert.equal(relief[0].amount,0);
  assert.equal((await post('/api/shipments/resolve',{...example,dataset_version:'older-dataset'})).status,409);
 }finally{c.closeSync();i.closeSync();}
});
