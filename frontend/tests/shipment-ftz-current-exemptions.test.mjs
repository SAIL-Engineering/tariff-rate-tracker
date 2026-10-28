import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import {gunzipSync} from 'node:zlib';
import {evaluateShipmentBundle} from '../server/generated/shipmentRules.js';
const {bundles,cases}=JSON.parse(gunzipSync(fs.readFileSync(new URL('../../tests/fixtures/shipment/ftz-current-exemptions.json.gz',import.meta.url))));
for(const c of cases)test('FTZ exemption chronology R/TypeScript: '+c.name,()=>{
 const r=evaluateShipmentBundle(bundles[c.bundle],c.hts10,c.country,c.entry_at,c.facts);
 assert.deepEqual(JSON.parse(JSON.stringify(r,(_key,value)=>value===undefined?null:value)),c.expected);
});
