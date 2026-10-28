import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import {gunzipSync} from 'node:zlib';
import {evaluateShipmentBundle} from '../server/generated/shipmentRules.js';
const {bundles,cases}=JSON.parse(gunzipSync(fs.readFileSync(new URL('../../tests/fixtures/shipment/section301-labor-valuation.json.gz',import.meta.url))));
for(const c of cases)test('original note52 valuation R/TypeScript: '+c.name,()=>{
 const r=evaluateShipmentBundle(bundles[c.bundle],c.hts10,c.country,c.entry_at,c.facts);
 assert.deepEqual(JSON.parse(JSON.stringify(r,(_key,value)=>value===undefined?null:value)),c.expected);
 assert.deepEqual(evaluateShipmentBundle(bundles[c.bundle],c.hts10,c.country,c.entry_at,{...c.facts,modeled_fta_share:1,assembly_credit:1e9}),r);
});
