import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import {evaluateShipmentBundle} from '../server/generated/shipmentRules.js';
const {bundle,cases}=JSON.parse(await fs.readFile(new URL('../../tests/fixtures/shipment/note16-composition.json',import.meta.url)));
for(const fixture of cases) test(`note 16 R/TypeScript conformance: ${fixture.name}`,()=>{
 const result=evaluateShipmentBundle(bundle,fixture.hts10,fixture.country,fixture.entry_at,fixture.facts);
 const expected=fixture.expected;
 assert.ok(Math.abs(result.known_subtotal-expected.known_subtotal)<1e-9);
 assert.deepEqual([...new Set(result.components.filter(c=>c.status==='applied').flatMap(c=>c.reporting_codes))].sort(),expected.applied_codes);
 assert.deepEqual(result.missing_inputs,expected.missing_inputs);
 assert.equal(result.complete_total,null);
 assert.equal(result.status,'unresolved_source'); // Fragment is not all-authority coverage.
 if(expected.source_error)assert.ok(result.source_errors.some(s=>s.includes(expected.source_error)));
 assert.ok(!result.source_errors.some(s=>s.includes('inconsistent_metal_weight_fractions')||s.includes('inconsistent_us_content_value')));
 if(expected.reporting)assert.ok(result.components.some(c=>c.reporting_codes.includes(expected.reporting)));
 assert.ok(result.rule_decisions.every(d=>d.citations.length));
});
