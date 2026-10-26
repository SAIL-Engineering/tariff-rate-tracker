// Bounded R normal-build interchange test. Entirely local/in-memory. The test
// registry is a routing fixture, NOT release preparation or legal qualification.
import fs from 'node:fs/promises';
import path from 'node:path';
import crypto from 'node:crypto';
import assert from 'node:assert/strict';
import { parseArgs } from 'node:util';
import { DuckDBInstance } from '@duckdb/node-api';
import { tableFromIPC } from 'apache-arrow';
import { RELEASE_CONTRACT, SHIPMENT_CONTRACT } from '../server/shipment-store.js';
import { registerShipmentRoutes } from '../server/shipment-routes.js';
import { readShipmentWideProjection } from '../server/generated/shipmentWide.js';
import { readShipmentBundleIndex, shipmentBundles } from '../server/shipment-bundle-index.js';

const { values } = parseArgs({ options: { fixture: { type: 'string' } } });
if (!values.fixture) throw new Error('Provide the bounded R fixture directory');
const root = await fs.realpath(values.fixture);
const cases = JSON.parse(await fs.readFile(path.join(root, 'delivery_cases.json')));
const dir = path.join(root, cases.revision_dir);
const checked = await readShipmentBundleIndex(path.join(dir, 'shipment_rules.json'));
const index = checked.index;
assert.equal(index.contract_version, 'sail.shipment-bundle-index/v1');
const quote = x => `'${x.replaceAll("'", "''")}'`;
const digest = x => crypto.createHash('sha256').update(x).digest('hex');
const instance = await DuckDBInstance.create(':memory:');
const conn = await instance.connect();
const schema = 'release_' + 'a'.repeat(24);
const normalize = x => Array.isArray(x) ? x.map(normalize) : x && typeof x === 'object'
  ? Object.fromEntries(Object.keys(x).sort().filter(k => x[k] != null).map(k => [k, normalize(x[k])])) : x;
const check = (actual, expected) => {
  for (const key of ['contract_version', 'dataset_version', 'evidence_snapshot_id', 'revision', 'status',
    'missing_inputs', 'source_errors', 'applied_rules', 'suppressed_rules', 'required_facts', 'claim_options',
    'components', 'rule_decisions', 'coverage_decisions']) assert.deepEqual(normalize(actual[key]), normalize(expected[key]), key);
  assert.ok(Math.abs(actual.known_subtotal - expected.known_subtotal) < 1e-9);
  assert.equal(actual.complete_total, expected.complete_total);
};
try {
  await conn.run(`CREATE SCHEMA ${schema}`);
  await conn.run(`CREATE TABLE ${schema}.rule_bundles (valid_from TIMESTAMPTZ,valid_until TIMESTAMPTZ,bundle_json VARCHAR,bundle_sha256 VARCHAR)`);
  for await (const entry of shipmentBundles(checked)) {
    const data = entry.text;
    assert.equal(digest(data), entry.sha256);
    const bundle = entry.bundle;
    assert.equal(bundle.dataset_version, index.dataset_version);
    await conn.run(`INSERT INTO ${schema}.rule_bundles VALUES (?,?,?,?)`,
      [entry.valid_from, entry.valid_until, data, entry.sha256]);
  }
  for (const [table, filename] of Object.entries({
    rates: path.join(root, 'rates_fixture.parquet'),
    memberships: path.join(dir, 'shipment_decision_membership.parquet'),
    classes: path.join(dir, 'shipment_decision_classes.parquet'),
  })) await conn.run(`CREATE TABLE ${schema}.${table} AS SELECT * FROM read_parquet(${quote(filename)})`);
  const invalid = (await conn.runAndReadAll(`SELECT count(*) n FROM ${schema}.memberships m LEFT JOIN ${schema}.classes c
    ON m.class_id=c.class_id AND m.bundle_id=c.bundle_id AND m.dataset_version=c.dataset_version
    WHERE c.class_id IS NULL OR m.entry_valid_from::TIMESTAMPTZ>=m.entry_valid_until::TIMESTAMPTZ`)).getRowObjects()[0].n;
  assert.equal(Number(invalid), 0);
  const wide = (await conn.runAndReadAll(`SELECT * FROM ${schema}.rates`)).getRowObjects();
  assert.ok(wide.length > 0);
  for (const row of wide) {
    assert.ok(readShipmentWideProjection(row), 'Normal wide rows satisfy the shared nullable projection contract');
    assert.equal(row.statutory_total_rate, null);
    assert.equal(row.shipment_status, 'unresolved_source');
    assert.equal(row.shipment_dataset_version, index.dataset_version);
    const ids = JSON.parse(row.shipment_decision_ids_json);
    assert.ok(ids.length > 0);
    for (const id of ids) {
      const classes = (await conn.runAndReadAll(`SELECT count(*) n FROM ${schema}.classes WHERE class_id=?`, [id])).getRowObjects();
      assert.equal(Number(classes[0].n), 1);
    }
  }
  // Simulate registry lookup only to exercise the real route/serializer code.
  // Production preparation would reject this fixture's unreconciled evidence.
  await conn.run(`CREATE TABLE tariff_releases (release_id VARCHAR,schema_name VARCHAR,contract_version VARCHAR,
    evidence_snapshot_id VARCHAR,dataset_version VARCHAR,status VARCHAR)`);
  await conn.run(`INSERT INTO tariff_releases VALUES (?,?,?,?,?,'validated')`,
    ['local-test-routing-only', schema, RELEASE_CONTRACT, index.evidence_snapshot_id, index.dataset_version]);
  await conn.run("CREATE TABLE tariff_active_release AS SELECT 1 singleton,'local-test-routing-only' release_id");
  const routes = new Map();
  const app = { get: (url, ...handlers) => routes.set(`GET ${url}`, handlers.at(-1)),
    post: (url, ...handlers) => routes.set(`POST ${url}`, handlers.at(-1)) };
  registerShipmentRoutes(app, { connection: () => conn, requireAuth: (_req, _res, next) => next() });
  async function request(method, url, body = {}, query = {}) {
    let payload; let status = 200; const headers = {};
    const res = { set: (k, v) => { headers[k] = v; return res; }, type: () => res,
      status: n => { status = n; return res; }, json: v => { payload = v; return res; }, send: v => { payload = v; return res; } };
    await routes.get(`${method} ${url}`)({ method, path: url, body, query }, res, () => { payload = 'legacy'; });
    return { payload, status, headers };
  }
  for (const { expected, ...shipment } of cases.cases) {
    const json = await request('POST', '/api/shipments/resolve', shipment);
    assert.equal(json.status, 200);check(json.payload.data[0], expected);
    assert.equal(json.headers['X-Dataset-Version'], index.dataset_version);
    const batch = await request('POST', '/api/rates/batch', { contract_version: SHIPMENT_CONTRACT, shipments: [shipment, shipment] });
    assert.equal(batch.payload.data.length, 2);batch.payload.data.forEach(r => check(r, expected));
    // GET's documented contract has no arbitrary facts input. Compare that
    // no-facts calculation with the identical POST request, never inject facts.
    const noFacts = await request('POST', '/api/shipments/resolve', { ...shipment, facts: {} });
    const arrow = await request('GET', '/api/rates/arrow', {}, { ...shipment, contract_version: SHIPMENT_CONTRACT });
    const table = tableFromIPC(arrow.payload);
    const expectedArrow = noFacts.payload.data[0];
    for (const k of ['status', 'known_subtotal', 'complete_total', 'dataset_version']) assert.equal(table.getChild(k).get(0), expectedArrow[k]);
    for (const k of ['components', 'missing_inputs', 'source_errors', 'rule_decisions', 'coverage_decisions'])
      assert.deepEqual(normalize(JSON.parse(table.getChild(`${k}_json`).get(0))), normalize(expectedArrow[k]));
    assert.equal((await request('POST', '/api/shipments/resolve', { ...shipment, dataset_version: 'stale' })).status, 409);
  }
  await conn.run(`UPDATE ${schema}.rule_bundles SET bundle_json='{}'`);
  const broken = await request('POST', '/api/shipments/resolve', cases.cases[0]);
  assert.equal(broken.payload.data[0].complete_total, null);
  assert.ok(broken.payload.data[0].source_errors.includes('stored_rule_bundle_hash_mismatch'));
  console.log(JSON.stringify({ cases: cases.cases.length, status: 'passed',
    checks: ['normal Parquet relationships', 'R/TypeScript components', 'JSON', 'Arrow', 'batch', 'dataset invalidation', 'bundle tampering'],
    production_release_preparation: false, live_motherduck: false }));
} finally { conn.closeSync(); instance.closeSync(); }
