import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import {gunzipSync} from 'node:zlib';
import {evaluateShipmentBundle} from '../server/generated/shipmentRules.js';
const fixtures=['section301-labor-interactions','section301-labor-auto','section301-labor-common'].map(name=>JSON.parse(gunzipSync(fs.readFileSync(new URL('../../tests/fixtures/shipment/'+name+'.json.gz',import.meta.url)))));
for(const {bundles,cases} of fixtures)for(const c of cases)test('source-named Section301/232 R/TypeScript: '+c.name,()=>{
 const r=evaluateShipmentBundle(bundles[c.bundle],c.hts10,c.country,c.entry_at,c.facts);
 // Optional decision-expression fields are R NULL versus JS undefined. Their
 // absence is not a monetary/completeness difference; compare the full result
 // after giving those explicit optional properties the same JSON spelling.
 assert.deepEqual(JSON.parse(JSON.stringify(r,(_key,value)=>value===undefined?null:value)),c.expected);
 const changed={...c.facts,modeled_aircraft_share:0,modeled_assembly_credit:0};
 assert.deepEqual(evaluateShipmentBundle(bundles[c.bundle],c.hts10,c.country,c.entry_at,changed),r);
});
