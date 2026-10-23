import crypto from 'node:crypto';
import { evaluateShipmentBundle, unavailableShipment } from './generated/shipmentRules.js';

export const SHIPMENT_CONTRACT = 'sail.shipment-result/v1';
export const RELEASE_CONTRACT = 'sail.tariff-release/v6';

/** Captured once per request/batch; every read uses this immutable schema. */
export async function activeShipmentRelease(conn) {
  try {
    const reader = await conn.runAndReadAll(`
      SELECT r.release_id, r.schema_name, r.contract_version, r.evidence_snapshot_id,
             r.dataset_version, r.status
      FROM main.tariff_active_release a JOIN main.tariff_releases r USING (release_id)
      WHERE a.singleton = 1
    `);
    const rows = reader.getRowObjects();
    if (rows.length !== 1) return null;
    const row = rows[0];
    if (row.contract_version !== RELEASE_CONTRACT || row.status !== 'validated'
      || !/^release_[a-f0-9]{16,64}$/.test(row.schema_name)) return null;
    return row;
  } catch (error) {
    // Only a genuinely absent release contract is an unsupported schema.
    if (/does not exist|not found/i.test(error.message)) return null;
    throw error;
  }
}

export async function resolveStoredShipment(conn, release, request) {
  if (!release) return unavailableShipment('unsupported_or_incomplete_contract');
  if (request.dataset_version && request.dataset_version !== release.dataset_version)
    return unavailableShipment('dataset_version_mismatch', release);
  const at = request.entry_at;
  if (typeof at !== 'string' || !/T.*(?:Z|[+-]\d\d:\d\d)$/.test(at) || !Number.isFinite(Date.parse(at)))
    return unavailableShipment('invalid_shipment_identity_or_entry_timestamp', release);
  const reader = await conn.runAndReadAll(`
    SELECT bundle_json, bundle_sha256 FROM "${release.schema_name}".rule_bundles
    WHERE valid_from <= CAST(? AS TIMESTAMPTZ) AND valid_until > CAST(? AS TIMESTAMPTZ)
  `, [at, at]);
  const rows = reader.getRowObjects();
  if (rows.length !== 1) return unavailableShipment(rows.length ? 'overlapping_rule_intervals' : 'missing_rule_interval', release);
  if (!/^[a-f0-9]{64}$/.test(rows[0].bundle_sha256 ?? '')
    || crypto.createHash('sha256').update(rows[0].bundle_json).digest('hex') !== rows[0].bundle_sha256)
    return unavailableShipment('stored_rule_bundle_hash_mismatch', release);
  let bundle;
  try { bundle = JSON.parse(rows[0].bundle_json); }
  catch { return unavailableShipment('invalid_shipment_rule_bundle', release); }
  if (bundle.dataset_version !== release.dataset_version || bundle.evidence_snapshot_id !== release.evidence_snapshot_id)
    return unavailableShipment('mixed_dataset_versions', release);
  return evaluateShipmentBundle(bundle, request.hts10, request.country, at, request.facts ?? {});
}
