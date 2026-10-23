import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import {evaluateShipmentBundle} from '../server/generated/shipmentRules.js';
const {bundles,cases}=JSON.parse(await fs.readFile(new URL('../../tests/fixtures/shipment/legacy-metals.json',import.meta.url)));
for(const c of cases) test(`historical metal R/TypeScript conformance: ${c.name}`,()=>{
 const result=evaluateShipmentBundle(bundles[c.bundle],c.hts10,c.country,c.entry_at,c.facts);
 assert.ok(Math.abs(result.known_subtotal-c.expected.known_subtotal)<1e-9);
 assert.deepEqual([...new Set(result.components.filter(x=>x.status==='applied').flatMap(x=>x.reporting_codes))].sort(),c.expected.applied_codes);
 assert.deepEqual(result.missing_inputs,c.expected.missing_inputs);
 assert.equal(result.complete_total,null);
 assert.equal(result.status,'unresolved_source');
 assert.ok(result.rule_decisions.every(d=>d.citations.length));
});
