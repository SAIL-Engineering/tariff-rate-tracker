import test from 'node:test';
import assert from 'node:assert/strict';
import { readShipmentWideProjection, SHIPMENT_STATUTORY_FIELDS } from '../server/generated/shipmentWide.js';
import { RATES_COLUMNS } from '../server/db.js';

const row = () => ({ ...Object.fromEntries(SHIPMENT_STATUTORY_FIELDS.map(k => [k, null])),
  shipment_projection_version: 'sail.shipment-wide/v1', shipment_contract_version: 'sail.shipment-result/v1',
  shipment_dataset_version: `shipment-${'a'.repeat(64)}`, shipment_evidence_snapshot_id: 'unresolved_trade_intelligence_snapshot',
  shipment_status: 'unresolved_source', shipment_quote_profile: 'unclaimed_missing_shipment_facts/v1',
  shipment_decision_ids_json: JSON.stringify(['b'.repeat(64)]), shipment_bundle_ids_json: JSON.stringify(['c'.repeat(64)]),
  shipment_missing_inputs_json: '["content_value"]', shipment_source_errors_json: '["coverage_unverified:section_232"]',
  shipment_exact_time_required: false });
test('shared projection preserves unavailable rates and never reads aggregate arithmetic', () => {
  const r = row();
  assert.deepEqual(readShipmentWideProjection({ ...r, total_rate: .75, metal_share: .5 }), readShipmentWideProjection({ ...r, total_rate: 0 }));
  assert.equal(readShipmentWideProjection(r).rates.statutory_total_rate, null);
  assert.deepEqual(readShipmentWideProjection(r).missing_inputs, ['content_value']);
});
test('old and contradictory schemas are unsupported; verified zero remains zero', () => {
  assert.equal(readShipmentWideProjection({ total_rate: .5 }), null);
  const zero = { ...row(), ...Object.fromEntries(SHIPMENT_STATUTORY_FIELDS.map(k => [k, 0])),
    shipment_status: 'complete', shipment_evidence_snapshot_id: 'd'.repeat(64), shipment_missing_inputs_json: '[]', shipment_source_errors_json: '[]' };
  assert.equal(readShipmentWideProjection(zero).rates.statutory_total_rate, 0);
  assert.equal(readShipmentWideProjection({ ...zero, statutory_total_rate: null }), null);
  assert.equal(readShipmentWideProjection({ ...row(), shipment_decision_ids_json: '"scalar"' }), null);
});
test('ordinary API projection carries every shipment contract and nullable rate field', () => {
  for (const k of Object.keys(row())) assert.ok(RATES_COLUMNS.includes(k), `Missing API field ${k}`);
});
