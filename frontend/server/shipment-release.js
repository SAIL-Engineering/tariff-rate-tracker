/** Versioned, additive release preparation. No active tables are replaced. */
import fs from 'node:fs/promises';
import path from 'node:path';
import crypto from 'node:crypto';
import { RELEASE_CONTRACT } from './shipment-store.js';

const digest = bytes => crypto.createHash('sha256').update(bytes).digest('hex');
const identifier = name => {
  if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(name)) throw new Error('Invalid SQL identifier');
  return `"${name}"`;
};
const literal = value => `'${String(value).replaceAll("'", "''")}'`;
export const RELEASE_MIGRATION = await fs.readFile(new URL('../migrations/001_shipment_releases.sql', import.meta.url), 'utf8');

const TABLES = {
  rates: ['hts10', 'country', 'revision', 'statutory_base_rate', 'statutory_rate_232'],
  products_base: ['hts10', 'revision', 'duty_expression_raw', 'rate_column2_raw'],
  authority_country_rates: ['revision', 'authority', 'program', 'country'],
  authority_product_applicability: ['revision', 'authority', 'program', 'hts10', 'hts_prefix'],
  authority_exemptions: ['revision', 'authority'],
  authority_product_candidates: ['revision', 'authority', 'program', 'hts10', 'scope_code', 'scope_grain', 'source_path', 'source_sha256', 'status'],
};

export async function readReleaseManifest(manifestPath) {
  const root = await fs.realpath(path.dirname(manifestPath));
  const bytes = await fs.readFile(manifestPath);
  const manifest = JSON.parse(bytes);
  if (manifest.contract_version !== RELEASE_CONTRACT || !manifest.dataset_version
    || !/^[a-f0-9]{64}$/.test(manifest.evidence_snapshot_id ?? '')
    || !Array.isArray(manifest.required_revisions) || !manifest.required_revisions.length
    || !Array.isArray(manifest.revisions)) throw new Error('Unsupported release manifest');
  const expected = [...manifest.required_revisions].sort();
  const actual = manifest.revisions.map(r => r.revision).sort();
  if (new Set(expected).size !== expected.length || new Set(actual).size !== actual.length
    || JSON.stringify(actual) !== JSON.stringify(expected)) throw new Error('Revision coverage mismatch');
  const checkedFile = async file => {
    if (!file || typeof file.path !== 'string' || !/^[a-f0-9]{64}$/.test(file.sha256 ?? ''))
      throw new Error('Every artifact requires its SHA256');
    const full = await fs.realpath(path.resolve(root, file.path));
    if (!full.startsWith(`${root}${path.sep}`)) throw new Error('Artifact escapes release directory');
    const data = await fs.readFile(full);
    if (digest(data) !== file.sha256) throw new Error(`Artifact hash mismatch: ${file.path}`);
    return { full, data };
  };
  const revisions = [];
  for (const revision of manifest.revisions) {
    const files = {};
    for (const table of Object.keys(TABLES)) {
      if (!Array.isArray(revision[table]) || !revision[table].length) throw new Error(`Missing ${table} partition`);
      files[table] = [];
      for (const file of revision[table]) files[table].push((await checkedFile(file)).full);
    }
    const rules = await checkedFile(revision.rules);
    const bundle = JSON.parse(rules.data);
    if (bundle.contract_version !== 'sail.shipment-rules/v1' || bundle.revision !== revision.revision
      || bundle.dataset_version !== manifest.dataset_version || bundle.evidence_snapshot_id !== manifest.evidence_snapshot_id)
      throw new Error('Mixed rule/evidence/dataset versions');
    if (!bundle.valid_from || !bundle.valid_until || !(Date.parse(bundle.valid_from) < Date.parse(bundle.valid_until)))
      throw new Error('Invalid rule interval');
    revisions.push({ revision: revision.revision, files, bundle, bundleHash: revision.rules.sha256 });
  }
  const ordered = [...revisions].sort((a, b) => Date.parse(a.bundle.valid_from) - Date.parse(b.bundle.valid_from));
  for (let i = 1; i < ordered.length; i++) {
    if (Date.parse(ordered[i - 1].bundle.valid_until) !== Date.parse(ordered[i].bundle.valid_from))
      throw new Error('Gap or overlap between rule intervals');
  }
  return { manifest, revisions, manifestHash: digest(bytes), releaseId: digest(bytes), schema: `release_${digest(bytes).slice(0, 24)}` };
}

/** Read-only: no DDL, no table creation, target catalog is explicitly verified. */
export async function preflightRelease(conn, prepared, expectedCatalog) {
  const catalog = (await conn.runAndReadAll('SELECT current_database() AS name')).getRowObjects()[0].name;
  if (catalog !== expectedCatalog) throw new Error(`Target catalog mismatch: expected ${expectedCatalog}`);
  const types = new Map();
  for (const revision of prepared.revisions) {
    for (const [table, files] of Object.entries(revision.files)) {
      const from = `read_parquet([${files.map(literal).join(',')}], hive_partitioning = false)`;
      const columns = (await conn.runAndReadAll(`DESCRIBE SELECT * FROM ${from}`)).getRowObjects();
      const have = new Map(columns.map(c => [c.column_name, c.column_type]));
      if (TABLES[table].some(k => !have.has(k))) throw new Error(`Missing required ${table} fields`);
      const signature = JSON.stringify([...have].sort(([a], [b]) => a.localeCompare(b)));
      if (types.has(table) && types.get(table) !== signature) throw new Error(`Inconsistent ${table} partition types`);
      types.set(table, signature);
      const invalid = (await conn.runAndReadAll(`SELECT count(*) AS n FROM ${from} WHERE revision IS DISTINCT FROM ?`, [revision.revision])).getRowObjects()[0].n;
      if (Number(invalid)) throw new Error(`Mixed revision in ${table}`);
    }
    const products = `read_parquet([${revision.files.products_base.map(literal).join(',')}], hive_partitioning=false)`;
    const rates = `read_parquet([${revision.files.rates.map(literal).join(',')}], hive_partitioning=false)`;
    const candidates = `read_parquet([${revision.files.authority_product_candidates.map(literal).join(',')}], hive_partitioning=false)`;
    const badCandidates = (await conn.runAndReadAll(`SELECT count(*) AS n FROM ${candidates} c
      LEFT JOIN ${products} p ON c.hts10=p.hts10 AND c.revision=p.revision
      WHERE p.hts10 IS NULL OR NOT regexp_full_match(coalesce(c.source_sha256,''),'[a-f0-9]{64}')
        OR coalesce(c.source_path,'')='' OR coalesce(c.status,'')<>'candidate_requires_legal_predicates'
        OR NOT regexp_full_match(coalesce(c.hts10,''),'[0-9]{10}')
        OR NOT regexp_full_match(coalesce(c.scope_code,''),'([0-9]{2}|[0-9]{4}|[0-9]{6}|[0-9]{8}|[0-9]{10})')
        OR coalesce(c.authority,'')='' OR coalesce(c."program",'')=''
        OR (c.scope_grain='prefix' AND length(c.scope_code)=10)
        OR NOT starts_with(c.hts10,c.scope_code)
        OR (c.scope_grain='exact_hts10' AND c.hts10<>c.scope_code)
        OR coalesce(c.scope_grain,'') NOT IN ('exact_hts10','prefix')`)).getRowObjects()[0].n;
    if (Number(badCandidates)) throw new Error('Invalid candidate scope/source relationship');

    const invalid = (await conn.runAndReadAll(`SELECT count(*) AS n FROM ${rates} r
      LEFT JOIN ${products} p ON r.hts10=p.hts10 AND r.revision=p.revision WHERE p.hts10 IS NULL`)).getRowObjects()[0].n;
    if (Number(invalid)) throw new Error('Rates reference missing products_base rows');
    const productRows = (await conn.runAndReadAll(`SELECT hts10, count(*) AS n FROM ${products} GROUP BY hts10`)).getRowObjects();
    if (productRows.some(r => Number(r.n) !== 1) || productRows.length !== revision.bundle.products.length
      || productRows.some(r => !revision.bundle.products.includes(r.hts10))) throw new Error('Rule/product coverage mismatch');
  }
  return { catalog, revisions: prepared.revisions.length, manifest_sha256: prepared.manifestHash };
}

export async function prepareRelease(conn, prepared, expectedCatalog) {
  const report = await preflightRelease(conn, prepared, expectedCatalog);
  await conn.run(RELEASE_MIGRATION);
  const exists = (await conn.runAndReadAll('SELECT release_id FROM main.tariff_releases WHERE release_id=? OR dataset_version=?',
    [prepared.releaseId, prepared.manifest.dataset_version])).getRowObjects();
  if (exists.length) throw new Error('Release already exists; releases are immutable');
  const schema = identifier(prepared.schema);
  // DDL may not be transactional on MotherDuck. Active pointer stays untouched
  // even if a staged table fails. A failed schema is retained for inspection.
  await conn.run('INSERT INTO main.tariff_releases (release_id,schema_name,contract_version,dataset_version,evidence_snapshot_id,manifest_sha256,status) VALUES (?,?,?,?,?,?,?)',
    [prepared.releaseId, prepared.schema, RELEASE_CONTRACT, prepared.manifest.dataset_version,
      prepared.manifest.evidence_snapshot_id, prepared.manifestHash, 'preparing']);
  try {
    await conn.run(`CREATE SCHEMA ${schema}`);
    for (const table of Object.keys(TABLES)) {
      const files = prepared.revisions.flatMap(r => r.files[table]);
      await conn.run(`CREATE TABLE ${schema}.${identifier(table)} AS SELECT * FROM read_parquet([${files.map(literal).join(',')}], hive_partitioning=false)`);
    }
    await conn.run(`CREATE TABLE ${schema}.rule_bundles (revision VARCHAR PRIMARY KEY, valid_from TIMESTAMPTZ, valid_until TIMESTAMPTZ, bundle_sha256 VARCHAR, bundle_json VARCHAR)`);
    await conn.run(`CREATE TABLE ${schema}.rule_sources (revision VARCHAR, source_id VARCHAR, source_json VARCHAR, PRIMARY KEY(revision,source_id))`);
    await conn.run(`CREATE TABLE ${schema}.executable_rules (revision VARCHAR, rule_id VARCHAR, action_id VARCHAR, authority VARCHAR, rule_json VARCHAR, PRIMARY KEY(revision,rule_id))`);
    for (const { revision, bundle } of prepared.revisions) {
      await conn.run(`INSERT INTO ${schema}.rule_bundles VALUES (?,?,?,?,?)`, [revision, bundle.valid_from, bundle.valid_until, digest(JSON.stringify(bundle)), JSON.stringify(bundle)]);
      for (const source of bundle.sources) await conn.run(`INSERT INTO ${schema}.rule_sources VALUES (?,?,?)`, [revision, source.id, JSON.stringify(source)]);
      for (const rule of bundle.rules) await conn.run(`INSERT INTO ${schema}.executable_rules VALUES (?,?,?,?,?)`, [revision, rule.id, rule.action_id, rule.authority, JSON.stringify(rule)]);
    }
    await conn.run("UPDATE main.tariff_releases SET status='prepared' WHERE release_id=?", [prepared.releaseId]);
    return { ...report, release_id: prepared.releaseId, schema: prepared.schema, status: 'prepared' };
  } catch (error) {
    await conn.run("UPDATE main.tariff_releases SET status='failed' WHERE release_id=?", [prepared.releaseId]);
    throw error;
  }
}

/** Explicit activation/rollback primitive, never called by preparation or startup.
 * A separate reviewed coverage/reconciliation gate must first mark it validated.
 */
export async function activateRelease(conn, releaseId, expectedActive) {
  await conn.run('BEGIN TRANSACTION');
  try {
    const release = (await conn.runAndReadAll('SELECT status FROM main.tariff_releases WHERE release_id=?', [releaseId])).getRowObjects();
    if (release.length !== 1 || release[0].status !== 'validated') throw new Error('Release has not passed validation');
    const active = (await conn.runAndReadAll('SELECT release_id FROM main.tariff_active_release WHERE singleton=1')).getRowObjects();
    const current = active[0]?.release_id ?? null;
    if (current !== expectedActive) throw new Error('Active release changed during review');
    await conn.run(`INSERT INTO main.tariff_active_release VALUES (1,?,?,current_timestamp)
      ON CONFLICT (singleton) DO UPDATE SET previous_release_id=excluded.previous_release_id,
      release_id=excluded.release_id, activated_at=excluded.activated_at`, [releaseId, current]);
    await conn.run('COMMIT');
  } catch (error) { await conn.run('ROLLBACK'); throw error; }
}
