import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import {evaluateShipmentBundle} from '../server/generated/shipmentRules.js';

const cases=JSON.parse(fs.readFileSync(new URL('../../tests/fixtures/shipment/diagnostic-ordering.json',import.meta.url)));
const normalize=x=>Array.isArray(x)?x.map(normalize):x&&typeof x==='object'
  ?Object.fromEntries(Object.keys(x).sort().filter(k=>x[k]!=null).map(k=>[k,normalize(x[k])])):x;
for(const c of cases)test(`R/TypeScript nested diagnostics keep unique lexical order: ${c.name}`,()=>{
  const r=evaluateShipmentBundle(c.bundle,c.hts10,c.country,c.entry_at,c.facts);
  assert.deepEqual(normalize(r),normalize(c.expected));
  assert.equal(r.complete_total,null);
});
