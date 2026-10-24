import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import {evaluateShipmentBundle} from '../server/generated/shipmentRules.js';
const {bundles,cases}=JSON.parse(await fs.readFile(new URL('../../tests/fixtures/shipment/section122.json',import.meta.url)));
for(const c of cases)test(`Section 122 R/TypeScript: ${c.name}`,()=>{
 const r=evaluateShipmentBundle(bundles[c.bundle],c.hts10,c.country,c.entry_at,c.facts);
 assert.ok(Math.abs(r.known_subtotal-c.expected.known_subtotal)<1e-9,`${r.known_subtotal}`);
 assert.deepEqual(r.missing_inputs,c.expected.missing_inputs);
 assert.deepEqual(r.source_errors,c.expected.source_errors);
 assert.deepEqual([...new Set(r.components.filter(x=>x.authority==='section_122'&&x.status==='applied').flatMap(x=>x.reporting_codes))].sort(),c.expected.s122_codes);
 assert.equal(r.complete_total,null);
});

import crypto from 'node:crypto';
import { DuckDBInstance } from '@duckdb/node-api';
import { tableFromIPC } from 'apache-arrow';
import { registerShipmentRoutes } from '../server/shipment-routes.js';
import { SHIPMENT_CONTRACT, RELEASE_CONTRACT } from '../server/shipment-store.js';

test('stored Section 122 bundle preserves portions and incompleteness through JSON, batch and Arrow', async()=>{
 const instance=await DuckDBInstance.create(':memory:');const conn=await instance.connect();
 try {
  const b=bundles.covered, schema='release_'+ '1'.repeat(16), encoded=JSON.stringify(b);
  await conn.run('CREATE TABLE tariff_releases (release_id VARCHAR,schema_name VARCHAR,contract_version VARCHAR,evidence_snapshot_id VARCHAR,dataset_version VARCHAR,status VARCHAR)');
  await conn.run('CREATE TABLE tariff_active_release (singleton INTEGER,release_id VARCHAR)');
  await conn.run('INSERT INTO tariff_releases VALUES (?,?,?,?,?,?)',['synthetic-test',schema,RELEASE_CONTRACT,b.evidence_snapshot_id,b.dataset_version,'validated']);
  await conn.run("INSERT INTO tariff_active_release VALUES (1,'synthetic-test')");
  await conn.run(`CREATE SCHEMA ${schema}`);
  await conn.run(`CREATE TABLE ${schema}.rule_bundles (valid_from TIMESTAMPTZ,valid_until TIMESTAMPTZ,bundle_json VARCHAR,bundle_sha256 VARCHAR)`);
  await conn.run(`INSERT INTO ${schema}.rule_bundles VALUES (?,?,?,?)`,[b.valid_from,b.valid_until,encoded,crypto.createHash('sha256').update(encoded).digest('hex')]);
  const routes=new Map();
  registerShipmentRoutes({get:(u,...h)=>routes.set('GET '+u,h.at(-1)),post:(u,...h)=>routes.set('POST '+u,h.at(-1))},
   {connection:()=>conn,requireAuth:(_q,_s,next)=>next()});
  async function request(url,body,query={}) {
   let payload,status=200;const headers={};
   const res={set:(k,v)=>{headers[k]=v;return res;},type:()=>res,status:n=>{status=n;return res;},json:v=>{payload=v;return res;},send:v=>{payload=v;return res;}};
   await routes.get('POST '+url)({method:'POST',path:url,body,query},res,()=>{});
   assert.equal(status,200);assert.equal(headers['X-Dataset-Version'],b.dataset_version);return payload;
  }
  const c=cases[0], shipment={hts10:c.hts10,country:c.country,entry_at:c.entry_at,facts:c.facts};
  const json=await request('/api/shipments/resolve',shipment);
  assert.equal(json.data[0].known_subtotal,18);assert.equal(json.data[0].complete_total,null);
  assert.deepEqual(json.data[0].components.filter(x=>x.authority==='section_122'&&x.status==='applied').map(x=>x.amount).sort(),[0,8]);
  const chapter98=await request('/api/shipments/resolve',{...shipment,facts:{...shipment.facts,
   claims:['CHAPTER_98'],s122_chapter98_claimed:true,chapter98_properly_claimed_and_cbp_agreed:true,
   chapter98_provision:'98020040',chapter98_repairs_alterations_processing_value:30}});
  assert.equal(chapter98.data[0].known_subtotal,0);
  assert.equal(chapter98.data[0].complete_total,null);
  assert.ok(chapter98.data[0].source_errors.some(e=>e.includes('claim_not_priced:CHAPTER_98')));
  const body={contract_version:SHIPMENT_CONTRACT,shipments:[shipment,{...shipment,facts:{}}]};
  const batch=await request('/api/rates/batch',body);
  assert.equal(batch.data[1].known_subtotal,0);assert.ok(batch.data[1].missing_inputs.length);
  const arrow=tableFromIPC(await request('/api/rates/batch',body,{format:'arrow'}));
  assert.equal(arrow.getChild('known_subtotal').get(0),18);assert.equal(arrow.getChild('complete_total').get(0),null);
  assert.deepEqual(JSON.parse(arrow.getChild('components_json').get(0)),batch.data[0].components);
  assert.deepEqual(JSON.parse(arrow.getChild('missing_inputs_json').get(1)),batch.data[1].missing_inputs);
 } finally {conn.closeSync();instance.closeSync();}
});
