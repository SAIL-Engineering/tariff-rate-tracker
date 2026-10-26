import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import {gunzipSync} from 'node:zlib';
import {evaluateShipmentBundle} from '../server/generated/shipmentRules.js';
import crypto from 'node:crypto';
import {DuckDBInstance} from '@duckdb/node-api';
import {tableFromIPC} from 'apache-arrow';
import {registerShipmentRoutes} from '../server/shipment-routes.js';
import {SHIPMENT_CONTRACT, RELEASE_CONTRACT} from '../server/shipment-store.js';

// Original-annex rules and requests emitted by the independent R reference.
// Other-program amounts are synthetic relation probes, not legal rate oracles.
const {bundles,cases}=JSON.parse(gunzipSync(fs.readFileSync(new URL('../../tests/fixtures/shipment/semiconductor-history.json.gz',import.meta.url))));
for(const c of cases)test(`semiconductor history R/TypeScript: ${c.name}`,()=>{
  const result=evaluateShipmentBundle(bundles[c.bundle],c.hts10,c.country,c.entry_at,c.facts);
  assert.ok(Math.abs(result.known_subtotal-c.expected.known_subtotal)<1e-8);
  for(const key of ['status','complete_total','missing_inputs','source_errors','suppressed_rules'])
    assert.deepEqual(result[key],c.expected[key]);
  const codes=[...new Set(result.components.filter(x=>x.authority==='section_232'&&x.status==='applied').flatMap(x=>x.reporting_codes))].sort();
  assert.deepEqual(codes,c.expected.codes);
});

test('stored semiconductor chronology, claims and unresolved histories survive JSON/batch/Arrow',async()=>{
  const instance=await DuckDBInstance.create(':memory:');const conn=await instance.connect();
  try {
    const b=bundles.history,schema='release_'+'3'.repeat(16),encoded=JSON.stringify(b);
    await conn.run('CREATE TABLE tariff_releases (release_id VARCHAR,schema_name VARCHAR,contract_version VARCHAR,evidence_snapshot_id VARCHAR,dataset_version VARCHAR,status VARCHAR)');
    await conn.run('CREATE TABLE tariff_active_release (singleton INTEGER,release_id VARCHAR)');
    await conn.run('INSERT INTO tariff_releases VALUES (?,?,?,?,?,?)',['synthetic-semiconductor-history',schema,RELEASE_CONTRACT,b.evidence_snapshot_id,b.dataset_version,'validated']);
    await conn.run("INSERT INTO tariff_active_release VALUES (1,'synthetic-semiconductor-history')");
    await conn.run(`CREATE SCHEMA ${schema}`);
    await conn.run(`CREATE TABLE ${schema}.rule_bundles (valid_from TIMESTAMPTZ,valid_until TIMESTAMPTZ,bundle_json VARCHAR,bundle_sha256 VARCHAR)`);
    await conn.run(`INSERT INTO ${schema}.rule_bundles VALUES (?,?,?,?)`,[b.valid_from,b.valid_until,encoded,crypto.createHash('sha256').update(encoded).digest('hex')]);
    const routes=new Map();
    registerShipmentRoutes({get:(u,...h)=>routes.set('GET '+u,h.at(-1)),post:(u,...h)=>routes.set('POST '+u,h.at(-1))},
      {connection:()=>conn,requireAuth:(_q,_s,next)=>next()});
    async function request(url,body,query={}) {
      let payload,status=200;const headers={};
      // Emulate Express's JSON wire serialization, including absent optional
      // fields. Comparing a pre-serialization undefined to Arrow JSON is wrong.
      const res={set:(k,v)=>{headers[k]=v;return res;},type:()=>res,status:n=>{status=n;return res;},json:v=>{payload=JSON.parse(JSON.stringify(v));return res;},send:v=>{payload=v;return res;}};
      await routes.get('POST '+url)({method:'POST',path:url,body,query},res,()=>{});
      assert.equal(status,200);assert.equal(headers['X-Dataset-Version'],b.dataset_version);return payload;
    }
    const selected=cases.filter(c=>!c.name.includes('cutoff'));
    const body={contract_version:SHIPMENT_CONTRACT,shipments:selected.map(c=>({hts10:c.hts10,country:c.country,entry_at:c.entry_at,facts:c.facts}))};
    const single=await request('/api/shipments/resolve',body.shipments[0]);
    assert.equal(single.data[0].known_subtotal,selected[0].expected.known_subtotal);
    const batch=await request('/api/rates/batch',body);
    const arrow=tableFromIPC(await request('/api/rates/batch',body,{format:'arrow'}));
    for(let i=0;i<selected.length;i++) {
      assert.equal(batch.data[i].known_subtotal,selected[i].expected.known_subtotal);
      assert.equal(batch.data[i].complete_total,null);
      assert.equal(arrow.getChild('known_subtotal').get(i),batch.data[i].known_subtotal);
      assert.equal(arrow.getChild('complete_total').get(i),null);
      for(const key of ['components','rule_decisions','missing_inputs','source_errors','suppressed_rules'])
        assert.deepEqual(JSON.parse(arrow.getChild(key+'_json').get(i)),batch.data[i][key]);
    }
  } finally {conn.closeSync();instance.closeSync();}
});
