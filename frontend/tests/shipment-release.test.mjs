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
    rates: "SELECT '1234567890'::VARCHAR hts10, 'TEST'::VARCHAR country, 'test'::VARCHAR revision, 0.05::DOUBLE statutory_base_rate, 0.25::DOUBLE statutory_rate_232, 0::DOUBLE rate_301, 0::DOUBLE statutory_rate_301, 0::DOUBLE rate_s301_maritime, 0::DOUBLE statutory_rate_s301_maritime",
    products_base: "SELECT '1234567890'::VARCHAR hts10, 'test'::VARCHAR revision, '5%'::VARCHAR duty_expression_raw, '10%'::VARCHAR rate_column2_raw",
    authority_country_rates: "SELECT 'test'::VARCHAR revision, 'synthetic'::VARCHAR authority, 'action-a'::VARCHAR AS \"program\", 'TEST'::VARCHAR country",
    authority_product_applicability: "SELECT 'test'::VARCHAR revision, 'synthetic'::VARCHAR authority, 'action-a'::VARCHAR AS \"program\", '1234567890'::VARCHAR hts10, NULL::VARCHAR hts_prefix",
    authority_product_candidates: "SELECT 'test'::VARCHAR revision, 'synthetic'::VARCHAR authority, 'a'::VARCHAR AS \"program\", '1234567890'::VARCHAR hts10, '1234567890'::VARCHAR scope_code, 'exact_hts10'::VARCHAR scope_grain, 'fixture'::VARCHAR source_path, repeat('0',64)::VARCHAR source_sha256, 'candidate_requires_legal_predicates'::VARCHAR status",
    section301_scope_decisions: "SELECT 'test'::VARCHAR revision, 'section_301'::VARCHAR authority, 'china_technology_transfer'::VARCHAR AS \"program\", '5700'::VARCHAR country_scope, '1234567890'::VARCHAR hts10, '9903.88.01'::VARCHAR ch99_code, 0.25::DOUBLE rate, NULL::VARCHAR condition_text, 'fixture'::VARCHAR source_locator, repeat('0',64)::VARCHAR source_text_sha256, repeat('0',64)::VARCHAR pdf_sha256, repeat('0',64)::VARCHAR hts_sha256, NULL::VARCHAR valid_from, NULL::VARCHAR valid_until WHERE FALSE",
    claim_effects: "SELECT ''::VARCHAR revision,''::VARCHAR claim_id,''::VARCHAR rule_id,''::VARCHAR authority,''::VARCHAR effect,''::VARCHAR target_reporting_code,''::VARCHAR hts10,''::VARCHAR country,''::VARCHAR valid_from,''::VARCHAR valid_until,''::VARCHAR source_ids_json,''::VARCHAR condition_json,''::VARCHAR source_locator,''::VARCHAR source_scope_sha256 WHERE FALSE",
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
  const manifest = { contract_version: 'sail.tariff-release/v3', dataset_version: version,
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

test('release v3 rejects old manifests and missing Section 301 evidence', () => withDatabase(async (conn, root) => {
  const {file,manifest}=await manifestFixture(conn,root);
  manifest.contract_version='sail.tariff-release/v1';
  await fs.writeFile(file,JSON.stringify(manifest));
  await assert.rejects(readReleaseManifest(file),/Unsupported release/);
  manifest.contract_version='sail.tariff-release/v3';
  delete manifest.revisions[0].section301_scope_decisions;
  await fs.writeFile(file,JSON.stringify(manifest));
  await assert.rejects(readReleaseManifest(file),/Missing section301_scope_decisions/);
  assert.equal(await activeShipmentRelease(conn),null);
}));

test('release preflight rejects unattributed Section 301 wide rates', () => withDatabase(async (conn,root)=>{
  const {file,manifest}=await manifestFixture(conn,root);
  const a=manifest.revisions[0].rates[0], original=path.join(root,a.path), changed=path.join(root,'unattributed.parquet');
  await conn.run(`COPY (SELECT * REPLACE ('5700' AS country,0.5 AS rate_301,0.5 AS statutory_rate_301) FROM read_parquet('${original}')) TO '${changed}' (FORMAT PARQUET)`);
  a.path=path.basename(changed);a.sha256=crypto.createHash('sha256').update(await fs.readFile(changed)).digest('hex');
  await fs.writeFile(file,JSON.stringify(manifest));
  const catalog=(await conn.runAndReadAll('SELECT current_database() AS name')).getRowObjects()[0].name;
  await assert.rejects(preflightRelease(conn,await readReleaseManifest(file),catalog),/Section 301 normalized\/wide/);
  assert.equal(await activeShipmentRelease(conn),null);
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

test('release preflight never treats missing Section 301 values as zero or broadens origin', () => withDatabase(async (conn,root)=>{
  const {file,manifest}=await manifestFixture(conn,root);
  const artifact=manifest.revisions[0].rates[0], original=path.join(root,artifact.path);
  const catalog=(await conn.runAndReadAll('SELECT current_database() AS name')).getRowObjects()[0].name;
  for(const [country,column,value] of [
    ['5700','rate_301','NULL::DOUBLE'],['5700','statutory_rate_301','NULL::DOUBLE'],
    ['TEST','rate_301','0.25::DOUBLE'],['TEST','statutory_rate_301','NULL::DOUBLE'],
    ['TEST','rate_s301_maritime','NULL::DOUBLE'],['TEST','statutory_rate_s301_maritime','NULL::DOUBLE'],
  ]) {
    const changed=path.join(root,`invalid-301-${country}-${column}.parquet`);
    await conn.run(`COPY (SELECT * REPLACE ('${country}' AS country,${value} AS ${column}) FROM read_parquet('${original}')) TO '${changed}' (FORMAT PARQUET)`);
    artifact.path=path.basename(changed);artifact.sha256=crypto.createHash('sha256').update(await fs.readFile(changed)).digest('hex');
    await fs.writeFile(file,JSON.stringify(manifest));
    await assert.rejects(preflightRelease(conn,await readReleaseManifest(file),catalog),/Section 301.*mismatch/);
    assert.equal(await activeShipmentRelease(conn),null);
  }
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


test('candidate provenance preflight rejects missing scope and cross-product membership before loading', () => withDatabase(async (conn, root) => {
  const { file, manifest } = await manifestFixture(conn, root);
  const catalog = (await conn.runAndReadAll('SELECT current_database() AS name')).getRowObjects()[0].name;
  const artifact = manifest.revisions[0].authority_product_candidates[0];
  const original = path.join(root, artifact.path);
  for (const [column, value] of [['scope_code', 'NULL::VARCHAR'], ['source_sha256', "'invalid'"],
    ['hts10', "'9999999999'"], ['scope_grain', "'prefix'"], ['source_path', "''"]]) {
    const changed = path.join(root, 'candidate-invalid.parquet');
    await fs.rm(changed, { force: true });
    await conn.run(`COPY (SELECT * REPLACE (${value} AS ${column}) FROM read_parquet('${original}')) TO '${changed}' (FORMAT PARQUET)`);
    artifact.path = path.basename(changed);
    artifact.sha256 = crypto.createHash('sha256').update(await fs.readFile(changed)).digest('hex');
    await fs.writeFile(file, JSON.stringify(manifest));
    await assert.rejects(preflightRelease(conn, await readReleaseManifest(file), catalog), /Invalid candidate scope/);
    assert.equal(await activeShipmentRelease(conn), null);
  }
}));

test('release v3 requires claim chronology and validates every executable effect before preparation', () => withDatabase(async (conn,root)=>{
  const {file,manifest,bundle}=await manifestFixture(conn,root);
  const artifact=manifest.revisions[0].claim_effects;
  delete manifest.revisions[0].claim_effects;
  await fs.writeFile(file,JSON.stringify(manifest));
  await assert.rejects(readReleaseManifest(file),/Missing claim_effects partition/);
  manifest.revisions[0].claim_effects=artifact;
  const source=bundle.sources[0];
  const rule={id:'test-exclusion',action_id:'test-exclusion',authority:'synthetic',kind:'duty',verification:'verified',
    role:'exclusion',claim_id:'test-claim',target_reporting_codes:['9999.00.01'],reporting_codes:['9999.00.02'],
    scope:{hts_exact:['1234567890'],countries:['TEST'],from:bundle.valid_from,until:bundle.valid_until},
    when:{claim:'test-claim'},formula:{value:0},source_ids:[source.id],legal_locator:'Synthetic test source',source_scope_sha256:'0'.repeat(64)};
  bundle.rules.push(rule);
  bundle.claim_definitions=[{id:'test-claim',label:'Synthetic claim',source_ids:[source.id],rule_ids:bundle.rules.map(r=>r.id),candidate_rule_ids:[rule.id]}];
  const rulesFile=path.join(root,manifest.revisions[0].rules.path);
  await fs.writeFile(rulesFile,JSON.stringify(bundle));
  manifest.revisions[0].rules.sha256=crypto.createHash('sha256').update(await fs.readFile(rulesFile)).digest('hex');
  const catalog=(await conn.runAndReadAll('SELECT current_database() AS name')).getRowObjects()[0].name;
  await fs.writeFile(file,JSON.stringify(manifest));
  await assert.rejects(preflightRelease(conn,await readReleaseManifest(file),catalog),/Claim effect inventory/);
  const rows=[{revision:'test',claim_id:rule.claim_id,rule_id:rule.id,authority:rule.authority,effect:'suppress',
    target_reporting_code:rule.target_reporting_codes[0],hts10:'1234567890',country:'TEST',valid_from:rule.scope.from,valid_until:rule.scope.until,
    source_ids_json:JSON.stringify(rule.source_ids),condition_json:JSON.stringify(rule.when),source_locator:rule.legal_locator,source_scope_sha256:rule.source_scope_sha256}];
  const json=path.join(root,'claims.json'),parquet=path.join(root,'claims.parquet');
  const rewrite=async value=>{
    await fs.writeFile(json,JSON.stringify(value));await fs.rm(parquet,{force:true});
    const columns=Object.fromEntries(Object.keys(rows[0]).map(k=>[k,'VARCHAR']));
    await conn.run(`COPY (SELECT * FROM read_json('${json}', columns=${JSON.stringify(columns)})) TO '${parquet}' (FORMAT PARQUET)`);
    artifact[0]={path:path.basename(parquet),sha256:crypto.createHash('sha256').update(await fs.readFile(parquet)).digest('hex')};
    await fs.writeFile(file,JSON.stringify(manifest));
    return readReleaseManifest(file);
  };
  await preflightRelease(conn,await rewrite(rows),catalog);
  for(const change of [{target_reporting_code:'9999.00.99'},{country:'other'},
    {condition_json:'{"value":true}'},{source_ids_json:'["unknown"]'},{valid_until:rule.scope.from},
    {source_scope_sha256:'1'.repeat(64)}])
    await assert.rejects(preflightRelease(conn,await rewrite([{...rows[0],...change}]),catalog),/Claim effect\/bundle/);
  await assert.rejects(preflightRelease(conn,await rewrite([rows[0],rows[0]]),catalog),/Claim effect inventory/);
  assert.equal(await activeShipmentRelease(conn),null);
}));
