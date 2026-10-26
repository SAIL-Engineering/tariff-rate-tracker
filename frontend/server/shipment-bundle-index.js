/** Stream validated ordinary-build bundles. No scope, rate or date inference. */
import fs from 'node:fs/promises';
import path from 'node:path';
import crypto from 'node:crypto';
import { shipmentTimestamp } from './generated/shipmentRules.js';

const object = x => x !== null && typeof x === 'object' && !Array.isArray(x);
const text = x => typeof x === 'string' && x.length > 0;
const digest = x => crypto.createHash('sha256').update(x).digest('hex');
const strings = (xs, nonempty = false) => Array.isArray(xs) && (!nonempty || xs.length > 0)
  && xs.every(text) && new Set(xs).size === xs.length;
const sameVersions = (value, expected) => {
  for (const key of ['revision', 'dataset_version', 'evidence_snapshot_id'])
    if (!text(value[key]) || expected[key] !== undefined && value[key] !== expected[key])
      throw new Error(`Shipment index/bundle version mismatch: ${key}`);
};

export async function readShipmentBundleIndex(filename, expected = {}) {
  const full = await fs.realpath(filename);
  const bytes = await fs.readFile(full);
  let index;
  try { index = JSON.parse(bytes); } catch { throw new Error('Invalid shipment bundle index JSON'); }
  if (!object(index) || index.contract_version !== 'sail.shipment-bundle-index/v1'
    || !Array.isArray(index.bundles) || !index.bundles.length) throw new Error('Unsupported shipment bundle index');
  sameVersions(index, expected);
  const start = shipmentTimestamp(index.valid_from), end = shipmentTimestamp(index.valid_until);
  if (!Number.isFinite(start) || !Number.isFinite(end) || start >= end) throw new Error('Invalid shipment index interval');
  const ids = new Set();
  let cursor = start;
  for (const entry of index.bundles) {
    if (!object(entry) || !/^[a-f0-9]{64}$/.test(entry.bundle_id ?? '')
      || entry.path !== `shipment_bundle_${entry.bundle_id}.json`
      || !/^[a-f0-9]{64}$/.test(entry.sha256 ?? '')) throw new Error('Invalid shipment bundle artifact path/identity');
    if (ids.has(entry.bundle_id)) throw new Error('Duplicate shipment bundle identity');
    ids.add(entry.bundle_id);
    const from = shipmentTimestamp(entry.valid_from), until = shipmentTimestamp(entry.valid_until);
    if (!Number.isFinite(from) || !Number.isFinite(until) || from !== cursor || until <= from)
      throw new Error('Shipment bundle index has a gap, overlap or invalid interval');
    cursor = until;
  }
  if (cursor !== end) throw new Error('Shipment bundle index does not cover its declared interval');
  return { index, root: path.dirname(full), filename: full, sha256: digest(bytes) };
}

/** Consumers can validate/store a full release without retaining every parsed
 * product/rule graph in V8 memory at once. Every yielded artifact is byte-pinned. */
export async function* shipmentBundles(checked) {
  for (const entry of checked.index.bundles) {
    const full = await fs.realpath(path.join(checked.root, entry.path));
    if (!full.startsWith(`${checked.root}${path.sep}`)) throw new Error('Shipment bundle artifact escapes index directory');
    const bytes = await fs.readFile(full);
    if (digest(bytes) !== entry.sha256) throw new Error('Shipment bundle artifact hash mismatch');
    let bundle;
    try { bundle = JSON.parse(bytes); } catch { throw new Error('Invalid shipment bundle artifact JSON'); }
    if (!object(bundle) || bundle.contract_version !== 'sail.shipment-rules/v1'
      || bundle.bundle_id !== entry.bundle_id || bundle.valid_from !== entry.valid_from || bundle.valid_until !== entry.valid_until)
      throw new Error('Shipment bundle/index identity or interval mismatch');
    sameVersions(bundle, checked.index);
    if (!strings(bundle.products, true) || bundle.products.some(p => !/^\d{10}$/.test(p))
      || !strings(bundle.countries, true) || !strings(bundle.coverage_requirements, true)
      || !Array.isArray(bundle.rules) || !Array.isArray(bundle.sources) || !Array.isArray(bundle.coverage)
      || !Array.isArray(bundle.claim_definitions)
      || !object(bundle.fact_definitions) && !(Array.isArray(bundle.fact_definitions) && !bundle.fact_definitions.length))
      throw new Error('Unsupported or incomplete shipment bundle contract');
    for (const key of ['rules', 'sources']) {
      const ids = bundle[key].map(x => object(x) ? x.id : null);
      if (ids.some(x => !text(x)) || new Set(ids).size !== ids.length) throw new Error(`Noncanonical shipment ${key} identities`);
    }
    yield { ...entry, full, text: bytes.toString('utf8'), bundle };
  }
}
