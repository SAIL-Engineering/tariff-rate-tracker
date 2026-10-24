import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import {evaluateShipmentBundle} from '../server/generated/shipmentRules.js';
const {bundles,cases}=JSON.parse(await fs.readFile(new URL('../../tests/fixtures/shipment/commerce-grants.json',import.meta.url)));
for(const c of cases) test(`Commerce grant R/TypeScript conformance: ${c.name}`,()=>{
 const r=evaluateShipmentBundle(bundles[c.bundle],c.hts10,c.country,c.entry_at,c.facts);
 assert.ok(Math.abs(r.known_subtotal-c.expected.known_subtotal)<1e-9);
 assert.deepEqual([...new Set(r.components.filter(x=>x.status==='applied').flatMap(x=>x.reporting_codes))].sort(),c.expected.applied_codes);
 assert.deepEqual(r.missing_inputs,c.expected.missing_inputs);
 if(c.expected.source_error)assert.ok(r.source_errors.some(e=>e.includes(c.expected.source_error)));
 assert.equal(r.complete_total,null);assert.equal(r.status,'unresolved_source');
});
