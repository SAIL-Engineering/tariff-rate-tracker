import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import {gunzipSync} from 'node:zlib';
import {evaluateShipmentBundle} from '../server/generated/shipmentRules.js';
const {bundle,extra_bundles,cases}=JSON.parse(gunzipSync(fs.readFileSync(new URL('../../tests/fixtures/shipment/mhd-content.json.gz',import.meta.url))));
for(const c of cases)test('Approved MHD content/base R/TypeScript: '+c.name,()=>{
 const r=evaluateShipmentBundle(c.bundle?extra_bundles[c.bundle]:bundle,c.hts10,c.country,c.entry_at,c.facts);
 assert.deepEqual(JSON.parse(JSON.stringify(r,(_key,value)=>value===undefined?null:value)),c.expected);
});
