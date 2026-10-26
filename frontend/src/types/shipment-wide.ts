// Generated from SAIL shared shipmentWide.ts. Do not edit.
// Source SHA256: 8b097f9000be44baaf518e320a2b1fe179e7a0d752e2fc3d880452d883d9ddb2
/** Ordinary-build projection contract. This adapter never reads economic rates
 * or infers liability from a missing row. Exact rules/components remain in the
 * versioned shipment bundle; decision IDs resolve to that immutable evidence. */
export const SHIPMENT_STATUTORY_FIELDS = [
  'statutory_base_rate', 'statutory_rate_232', 'statutory_rate_301',
  'statutory_rate_ieepa_recip', 'statutory_rate_ieepa_fent', 'statutory_rate_s122',
  'statutory_rate_section_201', 'statutory_rate_other', 'statutory_rate_s301fl',
  'statutory_rate_s301br', 'statutory_rate_s301_maritime', 'statutory_rate_s338',
  'statutory_total_additional', 'statutory_total_rate',
] as const;
export type ShipmentWideProjection = {
  contract_version: 'sail.shipment-wide/v1';
  dataset_version: string;
  evidence_snapshot_id: string;
  status: 'complete' | 'needs_inputs' | 'unresolved_source';
  rates: Record<typeof SHIPMENT_STATUTORY_FIELDS[number], number | null>;
  decision_ids: string[];
  bundle_ids: string[];
  missing_inputs: string[];
  source_errors: string[];
  exact_time_required: boolean;
  quote_profile: 'unclaimed_missing_shipment_facts/v1';
};

export function readShipmentWideProjection(value: unknown): ShipmentWideProjection | null {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return null;
  const row = value as Record<string, unknown>;
  if (row.shipment_projection_version !== 'sail.shipment-wide/v1'
    || row.shipment_contract_version !== 'sail.shipment-result/v1'
    || typeof row.shipment_dataset_version !== 'string' || !/^shipment-[a-f0-9]{64}$/.test(row.shipment_dataset_version)
    || typeof row.shipment_evidence_snapshot_id !== 'string'
    || row.shipment_quote_profile !== 'unclaimed_missing_shipment_facts/v1'
    || typeof row.shipment_exact_time_required !== 'boolean'
    || typeof row.shipment_status !== 'string'
    || !['complete', 'needs_inputs', 'unresolved_source'].includes(row.shipment_status)) return null;
  const evidence = row.shipment_evidence_snapshot_id;
  if (!/^[a-f0-9]{64}$/.test(evidence) && evidence !== 'unresolved_trade_intelligence_snapshot') return null;
  const array = (key: string, identifiers = false): string[] | null => {
    if (typeof row[key] !== 'string') return null;
    try {
      const xs: unknown = JSON.parse(row[key]);
      if (!Array.isArray(xs) || xs.some(x => typeof x !== 'string' || !x.length || identifiers && !/^[a-f0-9]{64}$/.test(x))
        || new Set(xs).size !== xs.length || identifiers && !xs.length) return null;
      return xs as string[];
    } catch { return null; }
  };
  const decision_ids = array('shipment_decision_ids_json', true);
  const bundle_ids = array('shipment_bundle_ids_json', true);
  const missing_inputs = array('shipment_missing_inputs_json');
  const source_errors = array('shipment_source_errors_json');
  if (!decision_ids || !bundle_ids || !missing_inputs || !source_errors) return null;
  const rates = {} as ShipmentWideProjection['rates'];
  for (const key of SHIPMENT_STATUTORY_FIELDS) {
    const amount = row[key];
    if (amount !== null && (typeof amount !== 'number' || !Number.isFinite(amount) || amount < 0)) return null;
    rates[key] = amount as number | null;
  }
  const status = row.shipment_status as ShipmentWideProjection['status'];
  if (status === 'complete' && (missing_inputs.length || source_errors.length || evidence.length !== 64
    || rates.statutory_total_rate === null || rates.statutory_total_additional === null || rates.statutory_base_rate === null)) return null;
  if (status !== 'complete' && (rates.statutory_total_rate !== null || rates.statutory_total_additional !== null)) return null;
  if (status === 'needs_inputs' && (!missing_inputs.length || source_errors.length)) return null;
  if (status === 'unresolved_source' && !source_errors.length) return null;
  return { contract_version: 'sail.shipment-wide/v1', dataset_version: row.shipment_dataset_version,
    evidence_snapshot_id: evidence, status, rates, decision_ids, bundle_ids, missing_inputs, source_errors,
    exact_time_required: row.shipment_exact_time_required, quote_profile: row.shipment_quote_profile };
}
