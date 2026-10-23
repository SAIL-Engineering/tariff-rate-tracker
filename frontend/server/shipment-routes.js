import { tableToIPC, Float64, Utf8, vectorFromArray, Table } from 'apache-arrow';
import { activeShipmentRelease, resolveStoredShipment, SHIPMENT_CONTRACT } from './shipment-store.js';

/** Additive contract; old aggregate consumers opt in explicitly during rollout. */
export function registerShipmentRoutes(app, { connection, requireAuth }) {
  app.get('/api/shipment-dataset', async (_req, res) => {
    try {
      const release = await activeShipmentRelease(connection());
      res.set('Cache-Control', 'no-store');
      res.status(release ? 200 : 503).json({ contract_version: SHIPMENT_CONTRACT,
        dataset_version: release?.dataset_version ?? null,
        evidence_snapshot_id: release?.evidence_snapshot_id ?? null,
        status: release ? 'available' : 'unsupported_contract' });
    } catch { res.status(503).json({ error: 'Shipment dataset unavailable' }); }
  });
  const handle = async (req, res, next) => {
    if (req.path.startsWith('/api/rates') && req.body?.contract_version !== SHIPMENT_CONTRACT
      && req.query.contract_version !== SHIPMENT_CONTRACT) return next();
    const batch = Array.isArray(req.body?.shipments);
    const requests = batch ? req.body.shipments : [req.method === 'GET' ? {
      hts10: req.query.hts10, country: req.query.country, entry_at: req.query.entry_at,
      dataset_version: req.query.dataset_version,
    } : req.body];
    if (!requests.length || requests.length > 2000 || requests.some(r => !r || !/^\d{10}$/.test(r.hts10)
      || typeof r.country !== 'string' || typeof r.entry_at !== 'string'
      || r.facts != null && (typeof r.facts !== 'object' || Array.isArray(r.facts))))
      return res.status(400).json({ error: 'Expected 1–2000 exact HTS10 shipments with origin and entry timestamp' });
    try {
      const conn = connection();
      const release = await activeShipmentRelease(conn);
      if (release && requests.some(r => r.dataset_version && r.dataset_version !== release.dataset_version))
        return res.status(409).json({ error: 'dataset_version_mismatch', dataset_version: release.dataset_version });
      const data = [];
      for (const request of requests) data.push({ hts10: request.hts10, country: request.country,
        entry_at: request.entry_at, ...await resolveStoredShipment(conn, release, request) });
      res.set('Cache-Control', 'no-store');
      res.set('X-Shipment-Contract', SHIPMENT_CONTRACT);
      if (release) res.set('X-Dataset-Version', release.dataset_version);
      if (req.path.endsWith('/arrow') || req.query.format === 'arrow') {
        // Stable Arrow schema, including all-null complete_total on unsupported datasets.
        const strings = ['hts10', 'country', 'entry_at', 'contract_version', 'dataset_version', 'revision', 'evidence_snapshot_id', 'status'];
        const columns = Object.fromEntries(strings.map(k => [k, vectorFromArray(data.map(r => r[k]), new Utf8())]));
        for (const k of ['known_subtotal', 'complete_total']) columns[k] = vectorFromArray(data.map(r => r[k]), new Float64());
        for (const k of ['components', 'rule_decisions', 'coverage_decisions', 'applied_rules', 'suppressed_rules', 'missing_inputs', 'required_facts', 'source_errors'])
          columns[`${k}_json`] = vectorFromArray(data.map(r => JSON.stringify(r[k])), new Utf8());
        return res.type('application/vnd.apache.arrow.stream').send(Buffer.from(tableToIPC(new Table(columns), 'stream')));
      }
      return res.json({ contract_version: SHIPMENT_CONTRACT, dataset_version: release?.dataset_version ?? null, data });
    } catch (error) {
      console.error('Shipment resolution failed:', error.message);
      return res.status(503).json({ error: 'Shipment data unavailable' });
    }
  };
  app.post('/api/shipments/resolve', requireAuth, handle);
  app.get('/api/rates', handle);
  app.get('/api/rates/arrow', handle);
  app.post('/api/rates/batch', requireAuth, handle);
}
