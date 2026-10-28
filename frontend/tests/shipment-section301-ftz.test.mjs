import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import {gunzipSync} from 'node:zlib';
import {evaluateShipmentBundle} from '../server/generated/shipmentRules.js';
const {bundle,cases}=JSON.parse(gunzipSync(fs.readFileSync(new URL('../../tests/fixtures/shipment/section301-ftz.json.gz',import.meta.url))));
for(const c of cases)test('Section301 FTZ R/TypeScript: '+c.name,()=>{
 const r=evaluateShipmentBundle(bundle,c.hts10,c.country,c.entry_at,c.facts);
 assert.deepEqual(JSON.parse(JSON.stringify(r,(_key,value)=>value===undefined?null:value)),c.expected);
 assert.deepEqual(evaluateShipmentBundle(bundle,c.hts10,c.country,c.entry_at,
  {...c.facts,modeled_fta_share:1,assembly_credit:1e9,column1_duty_amount:1e9}),r);
});
