import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import crypto from 'node:crypto';
import {DuckDBInstance} from '@duckdb/node-api';
import {tableFromIPC} from 'apache-arrow';
import {registerShipmentRoutes} from '../server/shipment-routes.js';
import {RELEASE_CONTRACT} from '../server/shipment-store.js';
import {evaluateShipmentBundle} from '../server/generated/shipmentRules.js';
const fixture=JSON.parse(await fs.readFile(new URL('../../tests/fixtures/shipment/section301-reconstruction.json',import.meta.url)));
for(const c of fixture.cases) test(`source-derived Section 301: ${c.name}`,()=>{
  const result=evaluateShipmentBundle(fixture.bundles[c.bundle],c.hts10,c.country,c.entry_at,c.facts);
  assert.equal(result.known_subtotal,c.expected.known_subtotal);
  assert.equal(result.complete_total,null);
  assert.equal(result.status,'unresolved_source');
  assert.ok(result.rule_decisions.every(r=>r.citations.length));
});

test('source-derived Section 301 survives stored JSON/Arrow/batch serving',async()=>{
  const db=await DuckDBInstance.create(':memory:'),c=await db.connect();
  try {
    const schema='release_'+'b'.repeat(24);
    const b=fixture.bundles.current;
    await c.run('CREATE TABLE tariff_active_release(singleton INTEGER,release_id VARCHAR)');
    await c.run('CREATE TABLE tariff_releases(release_id VARCHAR,schema_name VARCHAR,contract_version VARCHAR,evidence_snapshot_id VARCHAR,dataset_version VARCHAR,status VARCHAR)');
    await c.run('INSERT INTO tariff_active_release VALUES(1,?)',['test']);
    await c.run('INSERT INTO tariff_releases VALUES(?,?,?,?,?,?)',['test',schema,RELEASE_CONTRACT,b.evidence_snapshot_id,b.dataset_version,'validated']);
    await c.run(`CREATE SCHEMA ${schema}`);
    await c.run(`CREATE TABLE ${schema}.rule_bundles(valid_from TIMESTAMPTZ,valid_until TIMESTAMPTZ,bundle_json VARCHAR,bundle_sha256 VARCHAR)`);
    for(const bundle of Object.values(fixture.bundles)) {
      const json=JSON.stringify(bundle);
      await c.run(`INSERT INTO ${schema}.rule_bundles VALUES(?,?,?,?)`,[bundle.valid_from,bundle.valid_until,json,crypto.createHash('sha256').update(json).digest('hex')]);
    }
    const routes=new Map();
    registerShipmentRoutes({get:(p,...handlers)=>routes.set(p,handlers.at(-1)),post:(p,...handlers)=>routes.set(p,handlers.at(-1))},
      {connection:()=>c,requireAuth:(_q,_s,next)=>next()});
    const cases=fixture.cases.filter(c=>['China crane cumulative investigations','Taiwan crane qualifying Chinese components or ownership','semiconductor heading rate','neighboring non-mask remains List 4A','retroactive pump code and alternative descriptions','claimed amendment boundary remains unresolved','crane contract exclusion removes both named investigations'].includes(c.name));
    const shipments=cases.map(c=>({...c,dataset_version:b.dataset_version}));
    const request=async format=>{
      let body,status=200;
      const response={set:()=>response,type:()=>response,status:n=>{status=n;return response},json:x=>{body=x;return response},send:x=>{body=x;return response}};
      await routes.get('/api/shipments/resolve')({method:'POST',path:'/api/shipments/resolve',query:{format},body:{shipments}},response);
      assert.equal(status,200);return body;
    };
    const json=await request();
    assert.deepEqual(json.data.map(r=>r.known_subtotal),cases.map(c=>c.expected.known_subtotal));
    assert.ok(json.data.every(r=>r.complete_total===null && r.status==='unresolved_source'));
    const arrow=tableFromIPC(await request('arrow'));
    for(let i=0;i<cases.length;i++) {
      assert.equal(arrow.getChild('known_subtotal').get(i),cases[i].expected.known_subtotal);
      assert.equal(arrow.getChild('complete_total').get(i),null);
      assert.deepEqual(JSON.parse(arrow.getChild('claim_options_json').get(i)),json.data[i].claim_options);
      assert.deepEqual(JSON.parse(arrow.getChild('rule_decisions_json').get(i)),JSON.parse(JSON.stringify(json.data[i].rule_decisions)));
    }
  } finally {c.closeSync();db.closeSync();}
});
