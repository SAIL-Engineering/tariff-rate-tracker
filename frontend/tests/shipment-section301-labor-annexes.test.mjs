import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import {gunzipSync} from 'node:zlib';
import {evaluateShipmentBundle} from '../server/generated/shipmentRules.js';
const {bundle,cases}=JSON.parse(gunzipSync(fs.readFileSync(new URL('../../tests/fixtures/shipment/section301-labor-annexes.json.gz',import.meta.url))));
for(const c of cases)test('original forced-labor product annex R/TypeScript: '+c.name,()=>{
 const result=evaluateShipmentBundle(bundle,c.hts10,c.country,c.entry_at,c.facts);
 assert.deepEqual(JSON.parse(JSON.stringify(result,(_key,value)=>value===undefined?null:value)),c.expected);
 assert.deepEqual(evaluateShipmentBundle(bundle,c.hts10,c.country,c.entry_at,{...c.facts,modeled_metal_share:.01,assembly_credit:1e9}),result);
});
