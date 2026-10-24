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
    authority_country_rates: "SELECT 'test'::VARCHAR revision, 'synthetic'::VARCHAR authority, 'action-a'::VARCHAR AS \"program\", 'TEST'::VARCHAR country,NULL::DOUBLE reciprocal_parameter,NULL::DOUBLE country_eo_parameter,NULL::VARCHAR reciprocal_ch99,NULL::VARCHAR country_eo_ch99",
    authority_product_applicability: "SELECT 'test'::VARCHAR revision, 'synthetic'::VARCHAR authority, 'action-a'::VARCHAR AS \"program\", '1234567890'::VARCHAR hts10, NULL::VARCHAR hts_prefix",
    authority_product_candidates: "SELECT 'test'::VARCHAR revision, 'synthetic'::VARCHAR authority, 'a'::VARCHAR AS \"program\", '1234567890'::VARCHAR hts10, '1234567890'::VARCHAR scope_code, 'exact_hts10'::VARCHAR scope_grain, 'fixture'::VARCHAR source_path, repeat('0',64)::VARCHAR source_sha256, 'candidate_requires_legal_predicates'::VARCHAR status",
    ieepa_action_decisions: "SELECT ''::VARCHAR revision,''::VARCHAR authority,''::VARCHAR country,''::VARCHAR ch99_code,0::DOUBLE rate,''::VARCHAR rate_type,''::VARCHAR phase,FALSE::BOOLEAN terminated,''::VARCHAR decision,''::VARCHAR source_description,''::VARCHAR duty_expression,''::VARCHAR source_heading_sha256,''::VARCHAR hts_sha256,NULL::VARCHAR amendment_source_id,NULL::VARCHAR amendment_source_sha256,NULL::VARCHAR amendment_effective_from,NULL::VARCHAR pdf_sha256,NULL::VARCHAR source_note_locator,NULL::VARCHAR source_note_sha256,NULL::VARCHAR source_note,NULL::VARCHAR entry_valid_from,NULL::VARCHAR entry_valid_until,NULL::DATE state_valid_from,NULL::DATE state_valid_until WHERE FALSE",
    section232_scope_decisions: "SELECT ''::VARCHAR revision,''::VARCHAR authority,''::VARCHAR hts10,''::VARCHAR scope_code,0::INTEGER scope_grain,''::VARCHAR list_id,''::VARCHAR metal,FALSE::BOOLEAN derivative,''::VARCHAR source_locator,''::VARCHAR source_text_sha256,''::VARCHAR pdf_sha256,''::VARCHAR hts_sha256,NULL::DATE state_valid_from,NULL::DATE state_valid_until WHERE FALSE",
    section301_scope_decisions: "SELECT 'test'::VARCHAR revision, 'section_301'::VARCHAR authority, 'china_technology_transfer'::VARCHAR AS \"program\", '5700'::VARCHAR country_scope, '1234567890'::VARCHAR hts10, '9903.88.01'::VARCHAR ch99_code, 0.25::DOUBLE rate, NULL::VARCHAR condition_text, 'fixture'::VARCHAR source_locator, repeat('0',64)::VARCHAR source_text_sha256, repeat('0',64)::VARCHAR pdf_sha256, repeat('0',64)::VARCHAR hts_sha256, NULL::VARCHAR valid_from, NULL::VARCHAR valid_until WHERE FALSE",
    claim_effects: "SELECT ''::VARCHAR revision,''::VARCHAR claim_id,''::VARCHAR rule_id,''::VARCHAR authority,''::VARCHAR effect,''::VARCHAR target_reporting_code,''::VARCHAR hts10,''::VARCHAR country,''::VARCHAR valid_from,''::VARCHAR valid_until,''::VARCHAR source_ids_json,''::VARCHAR condition_json,''::VARCHAR source_locator,''::VARCHAR source_scope_sha256 WHERE FALSE",
    authority_exemptions: "SELECT 'test'::VARCHAR revision, 'synthetic'::VARCHAR authority",
  };
  const hashFile = async name => ({ path: name, sha256: crypto.createHash('sha256').update(await fs.readFile(path.join(root, name))).digest('hex') });
  for (const [name, sql] of Object.entries(statements)) {
    const filename = `${version}-${name}.parquet`;
    const projected = ['rates','products_base','authority_country_rates','authority_product_applicability','authority_exemptions'].includes(name)
      ? `SELECT *, DATE '2026-01-01' valid_from, DATE '2026-12-31' valid_until FROM (${sql})` : sql;
    await conn.run(`COPY (${projected}) TO '${path.join(root, filename)}' (FORMAT PARQUET)`);
    revision[name] = [await hashFile(filename)];
  }
  const rules = `${version}-rules.json`;
  await fs.writeFile(path.join(root, rules), JSON.stringify(bundle));
  revision.rules = await hashFile(rules);
  const manifest = { contract_version: 'sail.tariff-release/v6', dataset_version: version,
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

test('release v6 rejects old manifests and missing Section 301 evidence', () => withDatabase(async (conn, root) => {
  const {file,manifest}=await manifestFixture(conn,root);
  for(const version of ['v1','v5']) {
    manifest.contract_version=`sail.tariff-release/${version}`;
    await fs.writeFile(file,JSON.stringify(manifest));
    await assert.rejects(readReleaseManifest(file),/Unsupported release/);
  }
  manifest.contract_version='sail.tariff-release/v6';
  delete manifest.revisions[0].section301_scope_decisions;
  await fs.writeFile(file,JSON.stringify(manifest));
  await assert.rejects(readReleaseManifest(file),/Missing section301_scope_decisions/);
  assert.equal(await activeShipmentRelease(conn),null);
}));

test('release rejects unpinned or partially refreshed Commerce grant evidence', () => withDatabase(async (conn,root)=>{
  const {file,manifest,bundle}=await manifestFixture(conn,root);
  const save=async(b,r)=>{
    const bytes=JSON.stringify(b);
    await fs.writeFile(path.join(root,r.rules.path),bytes);
    r.rules.sha256=crypto.createHash('sha256').update(bytes).digest('hex');
    await fs.writeFile(file,JSON.stringify(manifest));
  };
  const revision=manifest.revisions[0];
  bundle.rules[0].grant_id='synthetic';bundle.rules[0].grant_snapshot_id='test-grant-snapshot';
  await save(bundle,revision);
  await assert.rejects(readReleaseManifest(file),/require an evidence snapshot/);
  bundle.evidence_dependencies={section232_grants:{snapshot_id:'test-grant-snapshot',snapshot_sha256:'a'.repeat(64),as_of:'2026-10-22T00:00:00Z'}};
  await save(bundle,revision);
  await assert.rejects(readReleaseManifest(file),/Invalid Commerce grant evidence pin/);
  bundle.sources.push({id:`commerce-grant-snapshot-${'a'.repeat(64)}`,sha256:'a'.repeat(64),status:'verified',url:'urn:sha256:test',citation:'Synthetic pin'});
  await save(bundle,revision);
  const read=await readReleaseManifest(file);
  assert.equal(read.revisions[0].bundle.evidence_dependencies.section232_grants.snapshot_sha256,'a'.repeat(64));
  const second=structuredClone(bundle), r2=structuredClone(revision);
  second.revision='test2';second.valid_from=bundle.valid_until;second.valid_until='2028-01-01T05:01:00Z';
  second.evidence_dependencies.section232_grants.snapshot_sha256='b'.repeat(64);
  second.sources.at(-1).id=`commerce-grant-snapshot-${'b'.repeat(64)}`;second.sources.at(-1).sha256='b'.repeat(64);
  r2.revision='test2';r2.rules.path='test2-rules.json';
  manifest.required_revisions.push('test2');manifest.revisions.push(r2);
  await save(second,r2);
  await assert.rejects(readReleaseManifest(file),/Mixed Commerce grant evidence snapshots/);
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

test('release v6 retains all note 16 memberships and rejects incomplete inventories or numeric conditional rates', () => withDatabase(async (conn,root)=>{
  const {file,manifest}=await manifestFixture(conn,root);
  const revision=manifest.revisions[0];
  const replace=async(name,sql,suffix)=>{
    const target=path.join(root,`${name}-${suffix}.parquet`);
    await conn.run(`COPY (${sql}) TO '${target}' (FORMAT PARQUET)`);
    revision[name]=[{path:path.basename(target),sha256:crypto.createHash('sha256').update(await fs.readFile(target)).digest('hex')}];
    await fs.writeFile(file,JSON.stringify(manifest));
  };
  const empty=revision.section232_scope_decisions;
  delete revision.section232_scope_decisions;
  await fs.writeFile(file,JSON.stringify(manifest));
  await assert.rejects(readReleaseManifest(file),/Missing section232_scope_decisions/);
  revision.section232_scope_decisions=empty;
  const catalog=(await conn.runAndReadAll('SELECT current_database() AS name')).getRowObjects()[0].name;
  await replace('section232_scope_decisions',`SELECT 'test' revision,'section_232' authority,'1234567890' hts10,
    '12345678' scope_code,8::INTEGER scope_grain,v.list_id,v.metal,TRUE derivative,
    'U.S. note 16(c)('||v.list_id||')' source_locator,repeat('0',64) source_text_sha256,repeat('0',64) pdf_sha256,repeat('0',64) hts_sha256,DATE '2026-01-01' state_valid_from,DATE '2026-12-31' state_valid_until
    FROM (VALUES ('vi','aluminum'),('vii','steel')) v(list_id,metal)`,'two-metals');
  await assert.rejects(preflightRelease(conn,await readReleaseManifest(file),catalog),/candidate inventory/);
  await replace('authority_product_candidates',`SELECT 'test' revision,'section_232' authority,
    'note16_c_'||v.list_id AS "program",'1234567890' hts10,'12345678' scope_code,'prefix' scope_grain,
    'fixture' source_path,repeat('0',64) source_sha256,'candidate_requires_legal_predicates' status
    FROM (VALUES ('vi'),('vii')) v(list_id)`,'two-metals');
  await assert.rejects(preflightRelease(conn,await readReleaseManifest(file),catalog),/conditional scope escaped/);
  const oldRates=path.join(root,revision.rates[0].path);
  await replace('rates',`SELECT * REPLACE (NULL::DOUBLE AS statutory_rate_232) FROM read_parquet('${oldRates}')`,'unresolved');
  await preflightRelease(conn,await readReleaseManifest(file),catalog);
  const prepared=await readReleaseManifest(file);
  await prepareRelease(conn,prepared,catalog);
  assert.equal(Number((await conn.runAndReadAll(`SELECT count(*) n FROM "${prepared.schema}".section232_scope_decisions`)).getRowObjects()[0].n),2);
  const originalMetals=path.join(root,revision.section232_scope_decisions[0].path);
  await replace('section232_scope_decisions',`SELECT * REPLACE ('n16_m_1' AS list_id,'steel' AS metal,
    'U.S. note 16(m)_1' AS source_locator) FROM read_parquet('${originalMetals}') LIMIT 1`,'legacy');
  await replace('authority_product_candidates',`SELECT 'test' revision,'section_232' authority,
    'legacy_metals_n16_m_1' AS "program",'1234567890' hts10,'12345678' scope_code,'prefix' scope_grain,
    'fixture' source_path,repeat('0',64) source_sha256,'candidate_requires_legal_predicates' status`,'legacy');
  await preflightRelease(conn,await readReleaseManifest(file),catalog);
  const legacyMetals=path.join(root,revision.section232_scope_decisions[0].path);
  await replace('section232_scope_decisions',`SELECT * REPLACE (DATE '2026-01-02' AS state_valid_from)
    FROM read_parquet('${legacyMetals}')`,'bad-state');
  await assert.rejects(preflightRelease(conn,await readReleaseManifest(file),catalog),/legal state mismatch/);

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

test('release v6 requires claim chronology and validates every executable effect before preparation', () => withDatabase(async (conn,root)=>{
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

test('release v6 persists IEEPA note provenance and legal-state intervals',()=>withDatabase(async(conn,root)=>{
  const {file,manifest}=await manifestFixture(conn,root);
  const catalog=(await conn.runAndReadAll('SELECT current_database() AS name')).getRowObjects()[0].name;
  const table='ieepa_action_decisions',artifact=manifest.revisions[0][table];
  delete manifest.revisions[0][table];await fs.writeFile(file,JSON.stringify(manifest));
  await assert.rejects(readReleaseManifest(file),/Missing ieepa_action_decisions/);
  manifest.revisions[0][table]=artifact;
  const row={revision:'test',authority:'ieepa_reciprocal',country:'TEST',ch99_code:'9903.02.73',rate:.15,
    rate_type:'floor',phase:'phase2_aug7',terminated:false,decision:'ordinary_action_selected',
    source_description:'Synthetic action evidence',duty_expression:'15%',source_heading_sha256:'0'.repeat(64),
    hts_sha256:'0'.repeat(64),amendment_source_id:'fixture',amendment_source_sha256:'0'.repeat(64),
    amendment_effective_from:'2025-08-07T00:01:00-04:00',pdf_sha256:null,source_note_locator:null,
    source_note_sha256:null,source_note:null,entry_valid_from:null,entry_valid_until:null,
    state_valid_from:'2025-08-07',state_valid_until:'2025-08-31'};
  const rewrite=async value=>{
    const json=path.join(root,'ieepa.json'),parquet=path.join(root,'ieepa.parquet');
    await fs.writeFile(json,JSON.stringify([value]));await fs.rm(parquet,{force:true});
    const columns=Object.fromEntries(Object.keys(row).map(k=>[k,k==='rate'?'DOUBLE':k==='terminated'?'BOOLEAN':k.startsWith('state_valid_')?'DATE':'VARCHAR']));
    await conn.run(`COPY (SELECT * FROM read_json('${json}',columns=${JSON.stringify(columns)})) TO '${parquet}' (FORMAT PARQUET)`);
    artifact[0]={path:path.basename(parquet),sha256:crypto.createHash('sha256').update(await fs.readFile(parquet)).digest('hex')};
    await fs.writeFile(file,JSON.stringify(manifest));return readReleaseManifest(file);
  };
  for(const change of [{hts_sha256:'1'.repeat(64)},{amendment_source_sha256:'1'.repeat(64)},
    {rate:null},{terminated:true},{amendment_effective_from:null},{source_description:''},{duty_expression:''}])
    await assert.rejects(preflightRelease(conn,await rewrite({...row,...change}),catalog),/IEEPA/);
  // A published exclusion may have a blank duty cell. Its explicit zero
  // decision and source description/hash distinguish it from a missing rate.
  const exclusion={...row,ch99_code:'9903.01.29',rate:0,rate_type:'passthrough',phase:'country_exclusion',duty_expression:''};
  await preflightRelease(conn,await rewrite(exclusion),catalog);
  await assert.rejects(preflightRelease(conn,await rewrite({...exclusion,rate:null}),catalog),/IEEPA/);
  const note='Synthetic complete note, with independently retained heading and entry window';
  const emergency={...row,authority:'ieepa_fentanyl',ch99_code:'9903.01.10',rate:.35,rate_type:'surcharge',
    phase:'general',pdf_sha256:'0'.repeat(64),source_note_locator:'U.S. note 2(j)',source_note:note,
    source_note_sha256:crypto.createHash('sha256').update(note).digest('hex'),entry_valid_from:'2025-08-01T00:01:00-04:00'};
  await preflightRelease(conn,await rewrite(emergency),catalog);
  for(const change of [{source_note:note+' altered'},{pdf_sha256:null},{source_note_locator:null},
    {phase:'conditional_replacement'},{entry_valid_from:'unknown'},{state_valid_until:'2025-08-01'}])
    await assert.rejects(preflightRelease(conn,await rewrite({...emergency,...change}),catalog),/IEEPA/);
  const prepared=await rewrite(row);await preflightRelease(conn,prepared,catalog);
  await prepareRelease(conn,prepared,catalog);
  const stored=(await conn.runAndReadAll(`SELECT * FROM "${prepared.schema}".${table}`)).getRowObjects();
  assert.equal(stored.length,1);assert.equal(stored[0].rate,.15);
  assert.equal(stored[0].amendment_effective_from,row.amendment_effective_from);
  assert.equal(await activeShipmentRelease(conn),null);
}));

test('release compares Section 301 at each legal state and rejects missing or overlapping state grids',()=>withDatabase(async(conn,root)=>{
  const {file,manifest}=await manifestFixture(conn,root);
  const rev=manifest.revisions[0];
  const replace=async(name,sql,suffix)=>{
    const target=path.join(root,`${name}-${suffix}.parquet`);
    await conn.run(`COPY (${sql}) TO '${target}' (FORMAT PARQUET)`);
    rev[name]=[{path:path.basename(target),sha256:crypto.createHash('sha256').update(await fs.readFile(target)).digest('hex')}];
    await fs.writeFile(file,JSON.stringify(manifest));
  };
  const originalRates=path.join(root,rev.rates[0].path), originalProducts=path.join(root,rev.products_base[0].path);
  const states="(VALUES (DATE '2026-01-01',DATE '2026-06-30',0.25),(DATE '2026-07-01',DATE '2026-12-31',0.50)) s(start_day,end_day,rate)";
  await replace('rates',`SELECT r.* REPLACE ('5700' AS country,s.start_day AS valid_from,s.end_day AS valid_until,
    s.rate::DOUBLE AS rate_301,s.rate::DOUBLE AS statutory_rate_301) FROM read_parquet('${originalRates}') r CROSS JOIN ${states}`,'states');
  const fullRates=path.join(root,rev.rates[0].path);
  await replace('products_base',`SELECT p.* REPLACE (s.start_day AS valid_from,s.end_day AS valid_until)
    FROM read_parquet('${originalProducts}') p CROSS JOIN ${states}`,'states');
  for(const table of ['authority_country_rates','authority_product_applicability','authority_exemptions']) {
    const original=path.join(root,rev[table][0].path);
    await replace(table,`SELECT m.* REPLACE (s.start_day AS valid_from,s.end_day AS valid_until)
      FROM read_parquet('${original}') m CROSS JOIN ${states}`,'states');
  }
  await replace('section301_scope_decisions',`SELECT 'test' revision,'section_301' authority,'china_technology_transfer' AS "program",
    '5700' country_scope,'1234567890' hts10,'9903.88.01' ch99_code,s.rate::DOUBLE rate,NULL::VARCHAR condition_text,
    'fixture' source_locator,repeat('0',64) source_text_sha256,repeat('0',64) pdf_sha256,repeat('0',64) hts_sha256,
    s.start_day::VARCHAR||'T00:01:00-05:00' valid_from,(s.end_day+1)::VARCHAR||'T00:01:00-05:00' valid_until FROM ${states}`,'states');
  const catalog=(await conn.runAndReadAll('SELECT current_database() AS name')).getRowObjects()[0].name;
  await preflightRelease(conn,await readReleaseManifest(file),catalog);
  // Holding the old parameter through the later state cannot pass provenance checks.
  await replace('rates',`SELECT * REPLACE (0.25::DOUBLE AS rate_301,0.25::DOUBLE AS statutory_rate_301) FROM read_parquet('${fullRates}')`,'stale');
  await assert.rejects(preflightRelease(conn,await readReleaseManifest(file),catalog),/Section 301 normalized\/wide/);
  // An extra origin in just one state is a partial grid even when its rates are zero.
  await replace('rates',`SELECT * FROM read_parquet('${fullRates}') UNION ALL
    SELECT * REPLACE ('OTHER' AS country,0::DOUBLE AS rate_301,0::DOUBLE AS statutory_rate_301)
    FROM read_parquet('${fullRates}') WHERE valid_from=DATE '2026-01-01'`,'missing-origin');
  await assert.rejects(preflightRelease(conn,await readReleaseManifest(file),catalog),/product-country legal states/);
  await replace('rates',`SELECT * FROM read_parquet('${fullRates}') UNION ALL SELECT * FROM read_parquet('${fullRates}') WHERE valid_from=DATE '2026-01-01'`,'duplicate');
  await assert.rejects(preflightRelease(conn,await readReleaseManifest(file),catalog),/product-country legal states/);
  assert.equal(await activeShipmentRelease(conn),null);
}));
