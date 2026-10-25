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

// Same source-generated rules and requests evaluated by the R reference suite.
// Section 232 inventory attestations are synthetic dependency fixtures; neither
// these tests nor the fragment claims complete all-authority legal coverage.
const {bundles,cases}=JSON.parse(gunzipSync(fs.readFileSync(new URL('../../tests/fixtures/shipment/ieepa-reciprocal-initial.json.gz',import.meta.url))));
for(const c of cases)test(`reciprocal R/TypeScript conformance: ${c.name}`,()=>{
  const r=evaluateShipmentBundle(bundles[c.bundle],c.hts10,c.country,c.entry_at,c.facts);
  assert.ok(Math.abs(r.known_subtotal-c.expected.known_subtotal)<1e-8);
  assert.deepEqual(r.missing_inputs,c.expected.missing_inputs);
  assert.deepEqual(r.source_errors,c.expected.source_errors);
  const codes=[...new Set(r.components.filter(x=>x.authority==='ieepa_reciprocal'&&x.status==='applied').flatMap(x=>x.reporting_codes))].sort();
  assert.deepEqual(codes,c.expected.codes);
  assert.equal(r.complete_total,null);
});

test('stored reciprocal rules preserve amendment, content claim and missing value through JSON/batch/Arrow',async()=>{
  const instance=await DuckDBInstance.create(':memory:');const conn=await instance.connect();
  try {
    const b=bundles.june_metal,schema='release_'+'2'.repeat(16),encoded=JSON.stringify(b);
    await conn.run('CREATE TABLE tariff_releases (release_id VARCHAR,schema_name VARCHAR,contract_version VARCHAR,evidence_snapshot_id VARCHAR,dataset_version VARCHAR,status VARCHAR)');
    await conn.run('CREATE TABLE tariff_active_release (singleton INTEGER,release_id VARCHAR)');
    await conn.run('INSERT INTO tariff_releases VALUES (?,?,?,?,?,?)',['synthetic-reciprocal-test',schema,RELEASE_CONTRACT,b.evidence_snapshot_id,b.dataset_version,'validated']);
    await conn.run("INSERT INTO tariff_active_release VALUES (1,'synthetic-reciprocal-test')");
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
    const c=cases.find(c=>c.name==='June non-metal portion owes reciprocal duty');
    const shipment={hts10:c.hts10,country:c.country,entry_at:c.entry_at,facts:c.facts};
    const single=await request('/api/shipments/resolve',shipment);
    assert.equal(single.data[0].known_subtotal,18);assert.equal(single.data[0].complete_total,null);
    const absent={...c.facts};delete absent.steel_content_value;
    const body={contract_version:SHIPMENT_CONTRACT,shipments:[
      {...shipment,entry_at:'2025-06-04T00:00:59-04:00'},shipment,{...shipment,facts:absent},
      {...shipment,facts:{...c.facts,claims:['RECIPROCAL_US_CONTENT'],reciprocal_us_content_value:40,reciprocal_us_content_in_metal_excluded_value:20}}
    ]};
    const batch=await request('/api/rates/batch',body);
    assert.deepEqual(batch.data.map(r=>r.known_subtotal),[10,18,10,16]);
    assert.ok(batch.data[2].missing_inputs.includes('steel_content_value'));
    for(const r of batch.data)assert.equal(r.complete_total,null);
    assert.ok(batch.data[3].components.some(c=>c.reporting_codes.includes('9903.01.34')));
    const arrow=tableFromIPC(await request('/api/rates/batch',body,{format:'arrow'}));
    for(let i=0;i<body.shipments.length;i++) {
      assert.equal(arrow.getChild('known_subtotal').get(i),batch.data[i].known_subtotal);
      assert.equal(arrow.getChild('complete_total').get(i),null);
      assert.deepEqual(JSON.parse(arrow.getChild('components_json').get(i)),batch.data[i].components);
      assert.deepEqual(JSON.parse(arrow.getChild('missing_inputs_json').get(i)),batch.data[i].missing_inputs);
    }
  } finally {conn.closeSync();instance.closeSync();}
});
