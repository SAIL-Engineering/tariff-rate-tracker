import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
import { DuckDBInstance } from '@duckdb/node-api';
import { tableFromIPC } from 'apache-arrow';
import { readReleaseManifest, preflightRelease, prepareRelease, activateRelease } from '../server/shipment-release.js';
import { activeShipmentRelease, resolveStoredShipment, SHIPMENT_CONTRACT } from '../server/shipment-store.js';
import { registerShipmentRoutes } from '../server/shipment-routes.js';
import { evaluateShipmentBundle } from '../server/generated/shipmentRules.js';
import { getMotherDuckDatabase } from '../server/config.js';
import { initShipmentReleaseDatabase } from '../server/db.js';

const fixtures = JSON.parse(await fs.readFile(new URL('../../tests/fixtures/shipment/conformance.json', import.meta.url)));
for (const fixture of fixtures) test(`R/TS/API runtime: ${fixture.name}`, () => {
  const result = evaluateShipmentBundle(fixture.bundle, fixture.hts10, fixture.country, fixture.entry_at, fixture.facts);
  for (const [key, expected] of Object.entries(fixture.expected)) {
    if (typeof expected === 'number') assert.ok(Math.abs(result[key] - expected) < 1e-9, key);
    else assert.deepEqual(result[key], expected, key);
  }
});

async function withDatabase(fn) {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), 'duty-release-test-'));
  const instance = await DuckDBInstance.create(':memory:');
  const conn = await instance.connect();
  try { await fn(conn, root); }
  finally { conn.closeSync(); instance.closeSync(); await fs.rm(root, { recursive: true }); }
}
async function manifestFixture(conn, root, version = 'test-v1') {
  const bundle = structuredClone(fixtures[0].bundle);
  bundle.dataset_version = version; bundle.evidence_snapshot_id = '0'.repeat(64);
  const revision = { revision: 'test' };
  const statements = {
    rates: "SELECT '1234567890'::VARCHAR hts10, 'TEST'::VARCHAR country, 'test'::VARCHAR revision, 0.05::DOUBLE statutory_base_rate, 0.25::DOUBLE statutory_rate_232",
    products_base: "SELECT '1234567890'::VARCHAR hts10, 'test'::VARCHAR revision, '5%'::VARCHAR duty_expression_raw, '10%'::VARCHAR rate_column2_raw",
    authority_country_rates: "SELECT 'test'::VARCHAR revision, 'synthetic'::VARCHAR authority, 'action-a'::VARCHAR AS \"program\", 'TEST'::VARCHAR country",
    authority_product_applicability: "SELECT 'test'::VARCHAR revision, 'synthetic'::VARCHAR authority, 'action-a'::VARCHAR AS \"program\", '1234567890'::VARCHAR hts10, NULL::VARCHAR hts_prefix",
    authority_exemptions: "SELECT 'test'::VARCHAR revision, 'synthetic'::VARCHAR authority",
  };
  const hashFile = async name => ({ path: name, sha256: crypto.createHash('sha256').update(await fs.readFile(path.join(root, name))).digest('hex') });
  for (const [name, sql] of Object.entries(statements)) {
    const filename = `${version}-${name}.parquet`;
    await conn.run(`COPY (${sql}) TO '${path.join(root, filename)}' (FORMAT PARQUET)`);
    revision[name] = [await hashFile(filename)];
  }
  const rules = `${version}-rules.json`;
  await fs.writeFile(path.join(root, rules), JSON.stringify(bundle));
  revision.rules = await hashFile(rules);
  const manifest = { contract_version: 'sail.tariff-release/v1', dataset_version: version,
    evidence_snapshot_id: bundle.evidence_snapshot_id, required_revisions: ['test'], revisions: [revision] };
  const file = path.join(root, `${version}-manifest.json`);
  await fs.writeFile(file, JSON.stringify(manifest));
  return { file, manifest, bundle };
}

test('local Parquet release prepares atomically, validates target and preserves active rollback', () => withDatabase(async (conn, root) => {
  const { file } = await manifestFixture(conn, root);
  const prepared = await readReleaseManifest(file);
  const catalog = (await conn.runAndReadAll('SELECT current_database() AS name')).getRowObjects()[0].name;
  await assert.rejects(preflightRelease(conn, prepared, 'wrong_catalog'), /Target catalog/);
  await preflightRelease(conn, prepared, catalog);
  assert.equal(await activeShipmentRelease(conn), null);
  const report = await prepareRelease(conn, prepared, catalog);
  assert.equal(report.status, 'prepared');
  assert.equal(await activeShipmentRelease(conn), null);
  await assert.rejects(activateRelease(conn, prepared.releaseId, null), /not passed validation/);
  // Test-only simulation of the separately reviewed coverage/reconciliation gate.
  await conn.run("UPDATE tariff_releases SET status='validated' WHERE release_id=?", [prepared.releaseId]);
  await activateRelease(conn, prepared.releaseId, null);
  const release = await activeShipmentRelease(conn);
  const result = await resolveStoredShipment(conn, release, { ...fixtures[0], facts: { customs_value: 100 } });
  assert.equal(result.complete_total, 15);
  assert.equal(result.dataset_version, 'test-v1');
  const second = await readReleaseManifest((await manifestFixture(conn, root, 'test-v2')).file);
  await prepareRelease(conn, second, catalog);
  assert.equal((await activeShipmentRelease(conn)).release_id, prepared.releaseId);
  await conn.run("UPDATE tariff_releases SET status='validated' WHERE release_id=?", [second.releaseId]);
  await assert.rejects(activateRelease(conn, second.releaseId, null), /changed during review/);
  await activateRelease(conn, second.releaseId, prepared.releaseId);
  assert.equal((await activeShipmentRelease(conn)).dataset_version, 'test-v2');
  await activateRelease(conn, prepared.releaseId, second.releaseId);
  assert.equal((await activeShipmentRelease(conn)).dataset_version, 'test-v1');
  await assert.rejects(prepareRelease(conn, prepared, catalog), /immutable/);
}));

test('changed artifacts and missing revisions cannot prepare a release', () => withDatabase(async (conn, root) => {
  const { file, manifest } = await manifestFixture(conn, root);
  manifest.required_revisions.push('missing');
  await fs.writeFile(file, JSON.stringify(manifest));
  await assert.rejects(readReleaseManifest(file), /coverage mismatch/);
  manifest.required_revisions.pop();
  await fs.writeFile(file, JSON.stringify(manifest));
  await fs.appendFile(path.join(root, manifest.revisions[0].rules.path), ' ');
  await assert.rejects(readReleaseManifest(file), /hash mismatch/);
  assert.equal(await activeShipmentRelease(conn), null);
}));

test('JSON, Arrow and batch keep missing contracts incomplete', () => withDatabase(async conn => {
  const routes = new Map();
  const app = { get: (url, ...handlers) => routes.set(`GET ${url}`, handlers.at(-1)),
    post: (url, ...handlers) => routes.set(`POST ${url}`, handlers.at(-1)) };
  registerShipmentRoutes(app, { connection: () => conn, requireAuth: (_req, _res, next) => next() });
  async function request(method, url, body = {}, query = {}) {
    let payload; let status = 200; const headers = {};
    const res = { set: (k, v) => { headers[k] = v; return res; }, type: () => res,
      status: n => { status = n; return res; }, json: value => { payload = value; return res; },
      send: value => { payload = value; return res; } };
    await routes.get(`${method} ${url}`)({ method, path: url, body, query }, res, () => { payload = 'legacy'; });
    return { payload, status, headers };
  }
  const shipment = { hts10: '1234567890', country: 'TEST', entry_at: fixtures[0].entry_at };
  const json = await request('POST', '/api/shipments/resolve', shipment);
  assert.equal(json.payload.data[0].status, 'unresolved_source');
  assert.equal(json.payload.data[0].complete_total, null);
  const batch = await request('POST', '/api/rates/batch', { contract_version: SHIPMENT_CONTRACT, shipments: [shipment, shipment] });
  assert.equal(batch.payload.data.length, 2);
  const arrow = await request('GET', '/api/rates/arrow', {}, { ...shipment, contract_version: SHIPMENT_CONTRACT });
  const table = tableFromIPC(arrow.payload);
  assert.equal(table.getChild('complete_total').get(0), null);
  assert.equal(table.getChild('complete_total').type.toString(), 'Float64');
  assert.equal(table.getChild('status').get(0), 'unresolved_source');
  assert.deepEqual(JSON.parse(table.getChild('components_json').get(0)), []);
  assert.equal((await request('GET', '/api/rates')).payload, 'legacy');
  assert.equal((await request('POST', '/api/shipments/resolve', { ...shipment, hts10: '12345678' })).status, 400);
}));

test('database name uses one validated configuration', () => {
  assert.equal(getMotherDuckDatabase('custom_catalog'), 'custom_catalog');
  assert.throws(() => getMotherDuckDatabase('bad;DROP TABLE rates'), /identifier/);
});


test('API pool reopens an immutable database release read-only without local rule files', async () => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), 'duty-release-serving-'));
  const database = path.join(root, 'release.duckdb');
  let writer = await DuckDBInstance.create(database);
  let conn = await writer.connect();
  let db;
  try {
    const prepared = await readReleaseManifest((await manifestFixture(conn, root)).file);
    const catalog = (await conn.runAndReadAll('SELECT current_database() AS name')).getRowObjects()[0].name;
    await prepareRelease(conn, prepared, catalog);
    // Test fixture only: legal coverage validation remains a separate release gate.
    await conn.run("UPDATE tariff_releases SET status='validated' WHERE release_id=?", [prepared.releaseId]);
    await activateRelease(conn, prepared.releaseId, null);
    conn.closeSync(); conn = null; writer.closeSync(); writer = null;
    // Serving must use stored tables and rules, not interchange files.
    for (const name of await fs.readdir(root)) {
      if (name.endsWith('.json') || name.endsWith('.parquet')) await fs.unlink(path.join(root, name));
    }
    const before = crypto.createHash('sha256').update(await fs.readFile(database)).digest('hex');
    db = await initShipmentReleaseDatabase(database);
    assert.equal(Number(db.stats.n_rows), 1);
    for (const reader of db.connections) {
      const release = await activeShipmentRelease(reader);
      const result = await resolveStoredShipment(reader, release, { ...fixtures[0], facts: { customs_value: 100 } });
      assert.equal(result.complete_total, 15);
      assert.equal(result.dataset_version, 'test-v1');
      assert.equal(Number((await reader.runAndReadAll('SELECT count(*) AS n FROM product_base_rates')).getRowObjects()[0].n), 1);
      await assert.rejects(reader.run("UPDATE main.tariff_releases SET status='failed'"), /read.only/i);
    }
    db.close(); db = null;
    assert.equal(crypto.createHash('sha256').update(await fs.readFile(database)).digest('hex'), before);
  } finally {
    db?.close(); conn?.closeSync(); writer?.closeSync();
    await fs.rm(root, { recursive: true });
  }
});

test('API pool rejects a local database without a validated active release', async () => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), 'duty-release-empty-'));
  const database = path.join(root, 'empty.duckdb');
  const writer = await DuckDBInstance.create(database);
  writer.closeSync();
  try {
    await assert.rejects(initShipmentReleaseDatabase(database), /No validated active shipment release/);
    await assert.rejects(initShipmentReleaseDatabase('md:production'), /local database file/);
  } finally { await fs.rm(root, { recursive: true }); }
});
