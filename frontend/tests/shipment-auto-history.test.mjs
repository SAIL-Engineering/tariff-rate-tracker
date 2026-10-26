import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import {gunzipSync} from 'node:zlib';
import {evaluateShipmentBundle} from '../server/generated/shipmentRules.js';

// Independent R calculations against retained original annexes. These cases
// establish the listed automobile component, not complete authority coverage.
for(const file of ['auto-history.json.gz','auto-interactions.json.gz','auto-metals.json.gz']) {
  const {bundles,cases}=JSON.parse(gunzipSync(fs.readFileSync(new URL('../../tests/fixtures/shipment/'+file,import.meta.url))));
  for(const c of cases)test(`automobile R/TypeScript: ${c.name}`,()=>{
    const r=evaluateShipmentBundle(bundles[c.bundle],c.hts10,c.country,c.entry_at,c.facts);
    for(const key of ['known_subtotal','status','complete_total','missing_inputs','source_errors','suppressed_rules'])
      assert.deepEqual(r[key],c.expected[key]);
    const codes=[...new Set(r.components.filter(x=>x.authority==='section_232'&&x.status==='applied').flatMap(x=>x.reporting_codes))].sort();
    assert.deepEqual(codes,c.expected.codes);
  });
}
