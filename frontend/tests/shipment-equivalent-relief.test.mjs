import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import {evaluateShipmentBundle} from '../server/generated/shipmentRules.js';
const cases=JSON.parse(fs.readFileSync(new URL('../../tests/fixtures/shipment/equivalent-relief.json',import.meta.url)));
for(const c of cases)test('equivalent whole-action relief R/TypeScript: '+c.name,()=>{
 const r=evaluateShipmentBundle(c.bundle,c.hts10,c.country,c.entry_at,c.facts);
 assert.deepEqual(JSON.parse(JSON.stringify(r,(_key,value)=>value===undefined?null:value)),c.expected);
});
