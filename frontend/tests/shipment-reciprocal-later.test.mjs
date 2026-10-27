import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import {gunzipSync} from 'node:zlib';
import crypto from 'node:crypto';
import {DuckDBInstance} from '@duckdb/node-api';
import {tableFromIPC} from 'apache-arrow';
import {evaluateShipmentBundle} from '../server/generated/shipmentRules.js';
import {registerShipmentRoutes} from '../server/shipment-routes.js';
import {RELEASE_CONTRACT,SHIPMENT_CONTRACT} from '../server/shipment-store.js';
const fixture=name=>JSON.parse(gunzipSync(fs.readFileSync(new URL('../../tests/fixtures/shipment/'+name+'.json.gz',import.meta.url))));
const later=fixture('ieepa-reciprocal-later'),transit=fixture('ieepa-reciprocal-transit-boundary'),overlap=fixture('ieepa-reciprocal-overlap');
for(const f of [later,transit,overlap])for(const c of f.cases)test('later reciprocal R/TypeScript: '+c.name,()=>{
 const r=evaluateShipmentBundle(f.bundles[c.bundle],c.hts10,c.country,c.entry_at,c.facts);
 assert.ok(Math.abs(r.known_subtotal-c.expected.known_subtotal)<1e-9);
 assert.deepEqual(r.missing_inputs,c.expected.missing_inputs);assert.deepEqual(r.source_errors,c.expected.source_errors);
 const codes=[...new Set(r.components.filter(x=>x.authority==='ieepa_reciprocal'&&x.status==='applied').flatMap(x=>x.reporting_codes))].sort();
 assert.deepEqual(codes,c.expected.codes);assert.equal(r.complete_total,null);
});

test('stored JSON/Arrow/batch preserve retroactivity, reporting obligations and ended collection',async()=>{
 // Routing fixture only: synthetic232 inventory attestations are not a
 // production release, live MotherDuck smoke test or all-authority proof.
 const i=await DuckDBInstance.create(':memory:'),c=await i.connect();
 try {
  const schema='release_'+'3'.repeat(16),first=later.bundles['2025_rev_29'];
  await c.run('CREATE TABLE tariff_releases (release_id VARCHAR,schema_name VARCHAR,contract_version VARCHAR,evidence_snapshot_id VARCHAR,dataset_version VARCHAR,status VARCHAR)');
  await c.run('CREATE TABLE tariff_active_release (singleton INTEGER,release_id VARCHAR)');
  await c.run('INSERT INTO tariff_releases VALUES (?,?,?,?,?,?)',['later-fixture',schema,RELEASE_CONTRACT,first.evidence_snapshot_id,first.dataset_version,'validated']);
  await c.run("INSERT INTO tariff_active_release VALUES (1,'later-fixture')");
  await c.run(`CREATE SCHEMA ${schema}`);
  await c.run(`CREATE TABLE ${schema}.rule_bundles (valid_from TIMESTAMPTZ,valid_until TIMESTAMPTZ,bundle_json VARCHAR,bundle_sha256 VARCHAR)`);
  for(const key of ['2025_rev_29','2026_rev_1_actual_semi','2026_rev_4_actual_semi']) {
   const b=later.bundles[key],text=JSON.stringify(b);
   await c.run(`INSERT INTO ${schema}.rule_bundles VALUES (?,?,?,?)`,[b.valid_from,b.valid_until,text,crypto.createHash('sha256').update(text).digest('hex')]);
  }
  const routes=new Map();registerShipmentRoutes({get:(u,...h)=>routes.set('GET '+u,h.at(-1)),post:(u,...h)=>routes.set('POST '+u,h.at(-1))},
   {connection:()=>c,requireAuth:(_q,_s,next)=>next()});
  async function post(path,body,query={}) {
   let payload,status=200;const headers={};
   const res={set:(k,v)=>{headers[k]=v;return res;},type:()=>res,status:n=>{status=n;return res;},json:v=>{payload=v;return res;},send:v=>{payload=v;return res;}};
   await routes.get('POST '+path)({method:'POST',path,body,query},res,()=>{});
   return {payload,status,headers};
  }
  const selected=['Korea additive predecessor before November14','Korea retroactive floor starts within source revision',
   'Actual semiconductor technical charge prioritizes Section232 reciprocal reporting',
   'Collection ending removes reciprocal headings while preserving semiconductor charge'].map(name=>later.cases.find(c=>c.name===name));
  assert.ok(selected.every(Boolean));
  const shipments=selected.map(({hts10,country,entry_at,facts})=>({hts10,country,entry_at,facts}));
  const body={contract_version:SHIPMENT_CONTRACT,shipments};
  const json=await post('/api/rates/batch',body);assert.equal(json.status,200);
  assert.equal(json.headers['X-Dataset-Version'],first.dataset_version);
  assert.deepEqual(json.payload.data.map(r=>r.known_subtotal),selected.map(r=>r.expected.known_subtotal));
  const ipc=await post('/api/rates/batch',body,{format:'arrow'});assert.equal(ipc.status,200);const table=tableFromIPC(ipc.payload);
  for(let n=0;n<shipments.length;n++) {
   const single=await post('/api/shipments/resolve',shipments[n]);assert.equal(single.status,200);
   assert.deepEqual(single.payload.data[0],json.payload.data[n]);
   for(const key of ['known_subtotal','complete_total','dataset_version','status'])assert.equal(table.getChild(key).get(n),json.payload.data[n][key]);
   assert.deepEqual(JSON.parse(table.getChild('components_json').get(n)),json.payload.data[n].components);
   assert.equal(json.payload.data[n].complete_total,null);
  }
  assert.equal((await post('/api/shipments/resolve',{...shipments[0],dataset_version:'stale'})).status,409);
 }finally{c.closeSync();i.closeSync();}
});
