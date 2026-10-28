import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import {gunzipSync} from 'node:zlib';
import {evaluateShipmentBundle} from '../server/generated/shipmentRules.js';
const {bundle,cases}=JSON.parse(gunzipSync(fs.readFileSync(new URL('../../tests/fixtures/shipment/note16-column1-benchmarks.json.gz',import.meta.url))));
for(const c of cases)test('native Column1 benchmark R/TypeScript: '+c.name,()=>{
 const result=evaluateShipmentBundle(bundle,c.hts10,c.country,c.entry_at,c.facts);
 assert.deepEqual(JSON.parse(JSON.stringify(result,(_key,value)=>value===undefined?null:value)),c.expected);
 assert.deepEqual(evaluateShipmentBundle(bundle,c.hts10,c.country,c.entry_at,
  {...c.facts,column1_duty_amount:999999,modeled_metal_share:.001,modeled_assembly_credit:999999}),result);
});
