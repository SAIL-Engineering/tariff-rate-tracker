import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import crypto from 'node:crypto';
import {DuckDBInstance} from '@duckdb/node-api';
import {tableFromIPC} from 'apache-arrow';
import {evaluateShipmentBundle} from '../server/generated/shipmentRules.js';
import {registerShipmentRoutes} from '../server/shipment-routes.js';
const {bundle,cases}=JSON.parse(await fs.readFile(new URL('../../tests/fixtures/shipment/semiconductor-composition.json',import.meta.url)));
for(const fixture of cases) test(`conditional action: ${fixture.name}`,()=>{
 const result=evaluateShipmentBundle(bundle,fixture.hts10,fixture.country,fixture.entry_at,fixture.facts);
 for(const [key,value]of Object.entries(fixture.expected)) {
  if(key==='reporting_code') {if(value)assert.ok(result.components.some(c=>c.reporting_codes.includes(value)));continue;}
  if(typeof value==='number')assert.ok(Math.abs(value-result[key])<1e-9,key);else assert.deepEqual(result[key],value,key);
 }
 assert.deepEqual(Object.keys(result.required_facts).sort(),result.missing_inputs);
 assert.ok(result.rule_decisions.every(d=>d.citations.length>0));
});
test('stored action rules survive JSON/Arrow/batch with decisions, relevant facts and hashes',async()=>{
 const db=await DuckDBInstance.create(':memory:'),c=await db.connect();
 try {
  const schema='release_'+ 'a'.repeat(24), json=JSON.stringify(bundle), sha=crypto.createHash('sha256').update(json).digest('hex');
  await c.run('CREATE TABLE tariff_active_release (singleton INTEGER,release_id VARCHAR)');
  await c.run('CREATE TABLE tariff_releases (release_id VARCHAR,schema_name VARCHAR,contract_version VARCHAR,evidence_snapshot_id VARCHAR,dataset_version VARCHAR,status VARCHAR)');
  await c.run('INSERT INTO tariff_active_release VALUES(1,?)',['test']);
  await c.run('INSERT INTO tariff_releases VALUES(?,?,?,?,?,?)',['test',schema,'sail.tariff-release/v6',bundle.evidence_snapshot_id,bundle.dataset_version,'validated']);
  await c.run(`CREATE SCHEMA ${schema}`);
  await c.run(`CREATE TABLE ${schema}.rule_bundles(valid_from TIMESTAMPTZ,valid_until TIMESTAMPTZ,bundle_json VARCHAR,bundle_sha256 VARCHAR)`);
  await c.run(`INSERT INTO ${schema}.rule_bundles VALUES(?,?,?,?)`,[bundle.valid_from,bundle.valid_until,json,sha]);
  const routes=new Map();const app={get:(url,...hs)=>routes.set(url,hs.at(-1)),post:(url,...hs)=>routes.set(url,hs.at(-1))};
  registerShipmentRoutes(app,{connection:()=>c,requireAuth:(_q,_s,n)=>n()});
  const request=async(shipments,format)=>{
   let body,status=200;const headers={};
   const res={set:(k,v)=>{headers[k]=v;return res},type:()=>res,status:n=>{status=n;return res},json:v=>{body=v;return res},send:v=>{body=v;return res}};
   await routes.get('/api/shipments/resolve')({method:'POST',path:'/api/shipments/resolve',query:{format},body:{shipments}},res);
   return {body,status,headers};
  };
  const shipments=[cases[0],cases.find(f=>f.name.startsWith('unresolved technical'))].map(f=>({hts10:f.hts10,country:f.country,entry_at:f.entry_at,facts:f.facts,dataset_version:bundle.dataset_version}));
  const response=await request(shipments);
  assert.equal(response.status,200);assert.equal(response.headers['X-Dataset-Version'],bundle.dataset_version);
  assert.equal(response.body.data[0].known_subtotal,45);assert.equal(response.body.data[0].complete_total,null);
  assert.equal(response.body.data[0].rule_decisions.find(d=>d.rule_id==='synthetic-1').outcome,'suppressed');
  assert.deepEqual(Object.keys(response.body.data[1].required_facts),['contains_logic_integrated_circuit']);
  const arrow=tableFromIPC((await request(shipments,'arrow')).body);
  assert.equal(arrow.getChild('complete_total').get(0),null);
  assert.deepEqual(JSON.parse(arrow.getChild('required_facts_json').get(1)),response.body.data[1].required_facts);
  assert.deepEqual(JSON.parse(arrow.getChild('rule_decisions_json').get(0)),JSON.parse(JSON.stringify(response.body.data[0].rule_decisions)));
  assert.deepEqual(JSON.parse(arrow.getChild('coverage_decisions_json').get(0)),response.body.data[0].coverage_decisions);
  assert.equal(response.body.data[0].coverage_decisions.find(d=>d.authority==='section_232').status,'unresolved_source');
  assert.equal((await request([{...shipments[0],dataset_version:'old'}])).status,409);
  await c.run(`UPDATE ${schema}.rule_bundles SET bundle_json = ?`,[json+' ']);
  const corrupt=(await request(shipments)).body.data[0];
  assert.equal(corrupt.complete_total,null);assert.deepEqual(corrupt.source_errors,['stored_rule_bundle_hash_mismatch']);
 } finally {c.closeSync();db.closeSync();}
});
