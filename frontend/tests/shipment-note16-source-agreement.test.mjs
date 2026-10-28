import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import {gunzipSync} from 'node:zlib';
import {evaluateShipmentBundle} from '../server/generated/shipmentRules.js';
const {bundles,cases}=JSON.parse(gunzipSync(fs.readFileSync(new URL('../../tests/fixtures/shipment/note16-source-agreement.json.gz',import.meta.url))));
for(const c of cases)test('original-source agreement R/TypeScript: '+c.name,()=>{
 const result=evaluateShipmentBundle(bundles[c.bundle],c.hts10,c.country,c.entry_at,c.facts);
 assert.deepEqual(JSON.parse(JSON.stringify(result,(_key,value)=>value===undefined?null:value)),c.expected);
 assert.deepEqual(evaluateShipmentBundle(bundles[c.bundle],c.hts10,c.country,c.entry_at,
  {...c.facts,modeled_metal_share:.001,modeled_assembly_credit:999999}),result);
});
