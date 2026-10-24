/** Versioned, additive release preparation. No active tables are replaced. */
import fs from 'node:fs/promises';
import path from 'node:path';
import crypto from 'node:crypto';
import { validateProjectedIntervals } from './revision-intervals.js';
import { RELEASE_CONTRACT } from './shipment-store.js';

const digest = bytes => crypto.createHash('sha256').update(bytes).digest('hex');
const identifier = name => {
  if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(name)) throw new Error('Invalid SQL identifier');
  return `"${name}"`;
};
const literal = value => `'${String(value).replaceAll("'", "''")}'`;
export const RELEASE_MIGRATION = await fs.readFile(new URL('../migrations/001_shipment_releases.sql', import.meta.url), 'utf8');

const TABLES = {
  rates: ['hts10', 'country', 'revision', 'valid_from', 'valid_until', 'statutory_base_rate', 'statutory_rate_232', 'rate_301', 'statutory_rate_301', 'rate_s301_maritime', 'statutory_rate_s301_maritime'],
  products_base: ['hts10', 'revision', 'valid_from', 'valid_until', 'duty_expression_raw', 'rate_column2_raw'],
  authority_country_rates: ['revision', 'valid_from', 'valid_until', 'authority', 'program', 'country','reciprocal_parameter','reciprocal_ch99','country_eo_parameter','country_eo_ch99'],
  authority_product_applicability: ['revision', 'valid_from', 'valid_until', 'authority', 'program', 'hts10', 'hts_prefix'],
  authority_exemptions: ['revision', 'valid_from', 'valid_until', 'authority'],
  authority_product_candidates: ['revision', 'authority', 'program', 'hts10', 'scope_code', 'scope_grain', 'source_path', 'source_sha256', 'status'],
  claim_effects: ['revision', 'claim_id', 'rule_id', 'authority', 'effect', 'target_reporting_code', 'hts10', 'country', 'valid_from', 'valid_until', 'source_ids_json', 'condition_json', 'source_locator', 'source_scope_sha256'],
  section301_scope_decisions: ['revision', 'authority', 'program', 'country_scope', 'hts10', 'ch99_code', 'rate', 'condition_text', 'source_locator', 'source_text_sha256', 'pdf_sha256', 'hts_sha256', 'valid_from', 'valid_until'],
  ieepa_action_decisions: ['revision','authority','country','ch99_code','rate','rate_type','phase','terminated','decision','source_description','duty_expression','source_heading_sha256','hts_sha256','amendment_source_id','amendment_source_sha256','amendment_effective_from','pdf_sha256','source_note_locator','source_note_sha256','source_note','entry_valid_from','entry_valid_until','state_valid_from','state_valid_until'],
  section232_scope_decisions: ['revision','authority','hts10','scope_code','scope_grain','list_id','metal','derivative','source_locator','source_text_sha256','pdf_sha256','hts_sha256','state_valid_from','state_valid_until'],
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
  let commerceGrantPin = null;
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
    const grantRules = (bundle.rules ?? []).filter(r => r.grant_id);
    const grantPin = bundle.evidence_dependencies?.section232_grants;
    if (grantRules.length && !grantPin) throw new Error('Commerce grant rules require an evidence snapshot');
    if (grantPin) {
      if (!grantPin.snapshot_id || !/^[a-f0-9]{64}$/.test(grantPin.snapshot_sha256 ?? '')
        || !Number.isFinite(Date.parse(grantPin.as_of))
        || grantRules.some(r => r.grant_snapshot_id !== grantPin.snapshot_id)
        || !(bundle.sources ?? []).some(s => s.id === `commerce-grant-snapshot-${grantPin.snapshot_sha256}`
          && s.sha256 === grantPin.snapshot_sha256 && s.status === 'verified'))
        throw new Error('Invalid Commerce grant evidence pin');
      const identity = JSON.stringify([grantPin.snapshot_id, grantPin.snapshot_sha256, grantPin.as_of]);
      if (commerceGrantPin && commerceGrantPin !== identity) throw new Error('Mixed Commerce grant evidence snapshots');
      commerceGrantPin = identity;
    }
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
      if (table === 'claim_effects' && TABLES[table].some(k => have.get(k) !== 'VARCHAR'))
        throw new Error('Invalid claim_effects field types');
      if(table==='ieepa_action_decisions' && TABLES[table].some(k=>have.get(k)!==
        (k==='rate'?'DOUBLE':k==='terminated'?'BOOLEAN':k.startsWith('state_valid_')?'DATE':'VARCHAR'))) throw new Error('Invalid IEEPA action field types');
      if(['rates','products_base','authority_country_rates','authority_product_applicability','authority_exemptions'].includes(table)
        && ['valid_from','valid_until'].some(k=>have.get(k)!=='DATE')) throw new Error(`Invalid ${table} legal-state date types`);
      if(table==='section232_scope_decisions' && ['state_valid_from','state_valid_until'].some(k=>have.get(k)!=='DATE'))
        throw new Error('Invalid Section 232 legal-state date types');
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

    const decisions = `read_parquet([${revision.files.section301_scope_decisions.map(literal).join(',')}], hive_partitioning=false)`;
    const bad301 = (await conn.runAndReadAll(`SELECT count(*) AS n FROM ${decisions} d
      LEFT JOIN ${products} p ON d.hts10=p.hts10 AND d.revision=p.revision
      WHERE p.hts10 IS NULL OR coalesce(d.authority,'')<>'section_301'
        OR coalesce(d.country_scope,'') NOT IN ('5700','all') OR d.rate IS NULL OR NOT isfinite(d.rate) OR d.rate<0
        OR coalesce(d."program",'') NOT IN ('china_technology_transfer','maritime')
        OR (d."program"='china_technology_transfer' AND d.country_scope<>'5700')
        OR coalesce(d.source_locator,'')=''
        OR NOT regexp_full_match(coalesce(d.ch99_code,''),'9903[.](88|91|92)[.][0-9]{2}')
        OR NOT regexp_full_match(coalesce(d.source_text_sha256,''),'[a-f0-9]{64}')
        OR NOT regexp_full_match(coalesce(d.pdf_sha256,''),'[a-f0-9]{64}')
        OR NOT regexp_full_match(coalesce(d.hts_sha256,''),'[a-f0-9]{64}')`)).getRowObjects()[0].n;
    if (Number(bad301)) throw new Error('Invalid Section 301 source decision');
    const hashes = (await conn.runAndReadAll(`SELECT DISTINCT pdf_sha256,hts_sha256 FROM ${decisions}`)).getRowObjects();
    const bundleHashes = new Set(revision.bundle.sources.map(s => s.sha256));
    if(hashes.some(r => !bundleHashes.has(r.pdf_sha256) || !bundleHashes.has(r.hts_sha256)))
      throw new Error('Section 301 decisions are absent from bundle sources');
    const countryActions = `read_parquet([${revision.files.authority_country_rates.map(literal).join(',')}], hive_partitioning=false)`;
    const invalidParameters = (await conn.runAndReadAll(`SELECT count(*) AS n FROM ${countryActions}
      WHERE authority='ieepa_reciprocal' AND (reciprocal_parameter IS NULL OR country_eo_parameter IS NULL
        OR NOT isfinite(reciprocal_parameter) OR NOT isfinite(country_eo_parameter)
        OR reciprocal_parameter<0 OR country_eo_parameter<0
        OR (reciprocal_parameter>0 AND NOT regexp_full_match(coalesce(reciprocal_ch99,''),'9903[.](01|02)[.][0-9]{2}'))
        OR (country_eo_parameter>0 AND NOT regexp_full_match(coalesce(country_eo_ch99,''),'9903[.]01[.][0-9]{2}')))`)).getRowObjects()[0].n;
    if(Number(invalidParameters)) throw new Error('Incomplete IEEPA action parameters');
    const ieepa = `read_parquet([${revision.files.ieepa_action_decisions.map(literal).join(',')}], hive_partitioning=false)`;
    const invalidIEEPA = (await conn.runAndReadAll(`SELECT count(*) AS n FROM ${ieepa} d WHERE
      coalesce(d.authority,'') NOT IN ('ieepa_reciprocal','ieepa_fentanyl') OR coalesce(d.country,'')=''
      OR NOT regexp_full_match(coalesce(d.ch99_code,''),'9903[.](01|02)[.][0-9]{2}')
      OR coalesce(d.rate_type,'') NOT IN ('floor','surcharge','passthrough')
      OR (d.rate_type<>'passthrough' AND (d.rate IS NULL OR NOT isfinite(d.rate) OR d.rate<0))
      OR coalesce(d.decision,'') NOT IN ('retired_heading','ordinary_action_selected','published_candidate')
      OR d.terminated IS NULL OR (d.terminated AND d.decision<>'retired_heading')
      OR coalesce(d.source_description,'')=''
      OR (coalesce(trim(d.duty_expression),'')='' AND NOT
        coalesce(d.phase='country_exclusion' AND d.rate_type='passthrough' AND d.rate=0,FALSE))
      OR NOT regexp_full_match(coalesce(d.source_heading_sha256,''),'[a-f0-9]{64}')
      OR NOT regexp_full_match(coalesce(d.hts_sha256,''),'[a-f0-9]{64}')
      OR d.state_valid_from IS NULL OR d.state_valid_until IS NULL OR d.state_valid_from>d.state_valid_until
      OR (d.authority='ieepa_fentanyl' AND (
        NOT regexp_full_match(coalesce(d.pdf_sha256,''),'[a-f0-9]{64}')
        OR coalesce(d.source_note_locator,'')='' OR coalesce(d.source_note,'')=''
        OR sha256(d.source_note) IS DISTINCT FROM d.source_note_sha256
        OR (d.decision='ordinary_action_selected' AND d.phase<>'general')
        OR (d.entry_valid_from IS NOT NULL AND TRY_CAST(d.entry_valid_from AS TIMESTAMPTZ) IS NULL)
        OR (d.entry_valid_until IS NOT NULL AND TRY_CAST(d.entry_valid_until AS TIMESTAMPTZ) IS NULL)))
      OR (d.amendment_source_id IS NOT NULL AND (d.amendment_effective_from IS NULL
        OR NOT regexp_full_match(coalesce(d.amendment_source_sha256,''),'[a-f0-9]{64}')))`)).getRowObjects()[0].n;
    if(Number(invalidIEEPA)) throw new Error('Invalid IEEPA action decision');
    const ieepaHashes = (await conn.runAndReadAll(`SELECT DISTINCT hts_sha256,pdf_sha256,amendment_source_sha256 FROM ${ieepa}`)).getRowObjects();
    if(ieepaHashes.some(r=>!bundleHashes.has(r.hts_sha256)||(r.pdf_sha256&&!bundleHashes.has(r.pdf_sha256))||
      (r.amendment_source_sha256&&!bundleHashes.has(r.amendment_source_sha256))))
      throw new Error('IEEPA decisions are absent from bundle sources');
    const metals = `read_parquet([${revision.files.section232_scope_decisions.map(literal).join(',')}], hive_partitioning=false)`;
    const bad232 = (await conn.runAndReadAll(`SELECT count(*) AS n FROM ${metals} d
      LEFT JOIN ${products} p ON d.hts10=p.hts10 AND d.revision=p.revision
      WHERE p.hts10 IS NULL OR coalesce(d.authority,'')<>'section_232'
        OR NOT regexp_full_match(coalesce(d.scope_code,''),'([0-9]{4}|[0-9]{6}|[0-9]{8}|[0-9]{10})')
        OR d.scope_grain IS DISTINCT FROM length(d.scope_code) OR NOT starts_with(d.hts10,d.scope_code)
        OR (coalesce(d.list_id,'') NOT IN ('i','ii','iii','iv','v','vi','vii','viii','ix','x','xi')
          AND NOT regexp_full_match(coalesce(d.list_id,''),'n16_(j|q|[ls]_[A-D]|[mntu]_[1-3])|n19_([go](_castings)?|[iq]_[A-F]|[jkrs]_[1-3])'))
        OR coalesce(d.metal,'') NOT IN ('aluminum','steel','copper') OR d.derivative IS NULL
        OR (NOT starts_with(d.list_id,'n') AND d.source_locator IS DISTINCT FROM ('U.S. note 16(c)('||d.list_id||')'))
        OR (starts_with(d.list_id,'n') AND d.source_locator IS DISTINCT FROM
          ('U.S. note '||substr(d.list_id,2,2)||'('||substr(d.list_id,5,1)||')'||substr(d.list_id,6)))
        OR d.state_valid_from IS NULL OR d.state_valid_until IS NULL OR d.state_valid_from>d.state_valid_until
        OR NOT regexp_full_match(coalesce(d.source_text_sha256,''),'[a-f0-9]{64}')
        OR NOT regexp_full_match(coalesce(d.pdf_sha256,''),'[a-f0-9]{64}')
        OR NOT regexp_full_match(coalesce(d.hts_sha256,''),'[a-f0-9]{64}')`)).getRowObjects()[0].n;
    if(Number(bad232)) throw new Error('Invalid Section 232 source decision');
    const invalidMetalWindow=(await conn.runAndReadAll(`SELECT count(*) n FROM ${metals} d
      WHERE NOT EXISTS (SELECT 1 FROM ${rates} r WHERE r.revision=d.revision
        AND r.valid_from=d.state_valid_from AND r.valid_until=d.state_valid_until)`)).getRowObjects()[0].n;
    if(Number(invalidMetalWindow)) throw new Error('Section 232 decision legal state mismatch');
    const metalHashes = (await conn.runAndReadAll(`SELECT DISTINCT pdf_sha256,hts_sha256 FROM ${metals}`)).getRowObjects();
    if(metalHashes.some(r=>!bundleHashes.has(r.pdf_sha256)||!bundleHashes.has(r.hts_sha256)))
      throw new Error('Section 232 decisions are absent from bundle sources');
    const missingMetalCandidate = (await conn.runAndReadAll(`SELECT count(*) AS n FROM (
      SELECT d.hts10,d.scope_code,d.pdf_sha256,(CASE WHEN starts_with(d.list_id,'n') THEN 'legacy_metals_' ELSE 'note16_c_' END)||d.list_id AS program_key FROM ${metals} d
      EXCEPT SELECT hts10,scope_code,source_sha256,"program" FROM ${candidates} WHERE starts_with("program",'note16_c_') OR starts_with("program",'legacy_metals_')
    )`)).getRowObjects()[0].n;
    const extraMetalCandidate = (await conn.runAndReadAll(`SELECT count(*) AS n FROM (
      SELECT hts10,scope_code,source_sha256,"program" FROM ${candidates} WHERE starts_with("program",'note16_c_') OR starts_with("program",'legacy_metals_')
      EXCEPT SELECT d.hts10,d.scope_code,d.pdf_sha256,(CASE WHEN starts_with(d.list_id,'n') THEN 'legacy_metals_' ELSE 'note16_c_' END)||d.list_id AS program_key FROM ${metals} d
    )`)).getRowObjects()[0].n;
    if(Number(missingMetalCandidate)||Number(extraMetalCandidate)) throw new Error('Section 232 candidate inventory mismatch');
    const metalTotal = (await conn.runAndReadAll(`SELECT count(*) AS n FROM ${rates} r
      JOIN (SELECT DISTINCT hts10,revision,state_valid_from,state_valid_until FROM ${metals}) d
        ON r.hts10=d.hts10 AND r.revision=d.revision AND r.valid_from=d.state_valid_from AND r.valid_until=d.state_valid_until
      WHERE r.statutory_rate_232 IS NOT NULL`)).getRowObjects()[0].n;
    if(Number(metalTotal)) throw new Error('Section 232 conditional scope escaped as a statutory rate');
    // Wide tables represent daily legal states. Exact intraday boundaries
    // remain in executable rules; compare the source parameter for that day.
    const inDailyState = `AND (d.valid_from IS NULL OR CAST(substr(d.valid_from,1,10) AS DATE)<=r.valid_from)
      AND (d.valid_until IS NULL OR CAST(substr(d.valid_until,1,10) AS DATE)>r.valid_from)`;
    const mismatch301 = (await conn.runAndReadAll(`SELECT count(*) AS n FROM ${rates} r LEFT JOIN LATERAL (
      SELECT min(rate) expected,min(rate)=max(rate) consistent,
        count(DISTINCT ch99_code) headings,bool_and(condition_text IS NOT NULL) needs_inputs
      FROM ${decisions} d WHERE d.hts10=r.hts10 AND d.revision=r.revision
        AND d."program"='china_technology_transfer' ${inDailyState}
    ) d ON TRUE WHERE r.country='5700' AND (
      (d.headings=0 AND (r.rate_301 IS DISTINCT FROM 0 OR r.statutory_rate_301 IS DISTINCT FROM 0)) OR
      (d.headings>0 AND (NOT d.consistent OR d.headings<>1
        OR r.rate_301 IS NULL OR abs(r.rate_301-d.expected)>0.000000001
        OR (d.needs_inputs AND r.statutory_rate_301 IS NOT NULL)
        OR (NOT d.needs_inputs AND (r.statutory_rate_301 IS NULL OR abs(r.statutory_rate_301-d.expected)>0.000000001))))
    )`)).getRowObjects()[0].n;
    if(Number(mismatch301)) throw new Error('Section 301 normalized/wide completeness mismatch');
    const foreign301 = (await conn.runAndReadAll(`SELECT count(*) AS n FROM ${rates}
      WHERE country<>'5700' AND (rate_301 IS DISTINCT FROM 0 OR statutory_rate_301 IS DISTINCT FROM 0)`)).getRowObjects()[0].n;
    if(Number(foreign301)) throw new Error('Section 301 technology-transfer origin/completeness mismatch');
    const maritimeMismatch = (await conn.runAndReadAll(`SELECT count(*) AS n FROM ${rates} r LEFT JOIN
      (SELECT DISTINCT hts10,revision,country_scope,rate,valid_from,valid_until FROM ${decisions} WHERE "program"='maritime') d
      ON d.hts10=r.hts10 AND d.revision=r.revision AND (d.country_scope='all' OR d.country_scope=r.country) ${inDailyState}
      WHERE (d.hts10 IS NULL AND (r.rate_s301_maritime IS DISTINCT FROM 0 OR r.statutory_rate_s301_maritime IS DISTINCT FROM 0))
        OR (d.hts10 IS NOT NULL AND (r.rate_s301_maritime IS NULL OR abs(r.rate_s301_maritime-d.rate)>0.000000001
          OR r.statutory_rate_s301_maritime IS NOT NULL))`)).getRowObjects()[0].n;
    if(Number(maritimeMismatch)) throw new Error('Maritime Section 301 normalized/wide completeness mismatch');

    const claimFiles = `read_parquet([${revision.files.claim_effects.map(literal).join(',')}], hive_partitioning=false)`;
    const claimRows = (await conn.runAndReadAll(`SELECT * FROM ${claimFiles}`)).getRowObjects();
    const expectedClaims = new Map();
    const canonical = value => JSON.stringify((function sort(x) {
      return Array.isArray(x) ? x.map(sort) : x && typeof x === 'object'
        ? Object.fromEntries(Object.keys(x).sort().map(k => [k, sort(x[k])])) : x;
    })(value));
    for (const rule of revision.bundle.rules.filter(r => r.role === 'exclusion')) {
      const definition = revision.bundle.claim_definitions?.find(c => c.id === rule.claim_id);
      if (!definition?.candidate_rule_ids?.includes(rule.id) || !rule.target_reporting_codes?.length
        || !rule.scope?.hts_exact?.length || !rule.scope?.countries?.length
        || !/^[a-f0-9]{64}$/.test(rule.source_scope_sha256 ?? '')) throw new Error('Incomplete executable claim provenance');
      for (const hts10 of rule.scope.hts_exact) for (const country of rule.scope.countries)
        for (const target of rule.target_reporting_codes) {
          const key = [rule.id, hts10, country, target].join('|');
          expectedClaims.set(key, { rule, hts10, country, target });
        }
    }
    if (claimRows.length !== expectedClaims.size) throw new Error('Claim effect inventory mismatch');
    for (const row of claimRows) {
      const key = [row.rule_id, row.hts10, row.country, row.target_reporting_code].join('|');
      const expected = expectedClaims.get(key), rule = expected?.rule;
      if (!rule || row.claim_id !== rule.claim_id || row.authority !== rule.authority || row.effect !== 'suppress'
        || row.valid_from !== rule.scope.from || row.valid_until !== rule.scope.until
        || row.source_locator !== rule.legal_locator || row.source_scope_sha256 !== rule.source_scope_sha256
        || !revision.bundle.products.includes(row.hts10)
        || canonical(JSON.parse(row.source_ids_json)) !== canonical(rule.source_ids)
        || canonical(JSON.parse(row.condition_json)) !== canonical(rule.when)
        || !rule.source_ids.every(id => revision.bundle.sources.some(s => s.id === id)))
        throw new Error('Claim effect/bundle relationship mismatch');
      expectedClaims.delete(key);
    }

    const states = (await conn.runAndReadAll(`SELECT DISTINCT revision,valid_from::VARCHAR valid_from,
      valid_from::VARCHAR valid_from_max,valid_until::VARCHAR valid_until,valid_until::VARCHAR valid_until_min FROM ${rates}`)).getRowObjects();
    validateProjectedIntervals([],states,{full:true});
    const ordered = [...states].sort((a,b)=>a.valid_from.localeCompare(b.valid_from));
    const lastDay = new Date(`${ordered.at(-1).valid_until}T00:00:00Z`);
    lastDay.setUTCDate(lastDay.getUTCDate()+1);
    // Compare calendar labels for daily data; bundle timestamps additionally
    // preserve the entry-time rule boundary.
    if(ordered[0].valid_from!==revision.bundle.valid_from.slice(0,10)
      || lastDay.toISOString().slice(0,10)!==revision.bundle.valid_until.slice(0,10))
      throw new Error('Daily state/bundle interval mismatch');
    const invalid = (await conn.runAndReadAll(`SELECT count(*) AS n FROM ${rates} r
      LEFT JOIN ${products} p ON r.hts10=p.hts10 AND r.revision=p.revision
        AND r.valid_from=p.valid_from AND r.valid_until=p.valid_until WHERE p.hts10 IS NULL`)).getRowObjects()[0].n;
    if (Number(invalid)) throw new Error('Rates reference missing products_base legal states');
    for(const table of ['products_base','authority_country_rates','authority_product_applicability','authority_exemptions']) {
      const from = `read_parquet([${revision.files[table].map(literal).join(',')}], hive_partitioning=false)`;
      const invalidStates = (await conn.runAndReadAll(`SELECT count(*) n FROM ${from} m
        LEFT JOIN (SELECT DISTINCT revision,valid_from,valid_until FROM ${rates}) r
        ON m.revision=r.revision AND m.valid_from=r.valid_from AND m.valid_until=r.valid_until
        WHERE r.revision IS NULL`)).getRowObjects()[0].n;
      if(Number(invalidStates)) throw new Error(`Inconsistent ${table} legal states`);
    }
    const invalidGrid = (await conn.runAndReadAll(`SELECT count(*) n FROM (
      SELECT hts10,country,count(*) row_count,count(DISTINCT (valid_from,valid_until)) states
      FROM ${rates} GROUP BY hts10,country HAVING row_count<>${states.length} OR states<>${states.length})`)).getRowObjects()[0].n;
    if(Number(invalidGrid)) throw new Error('Incomplete or duplicate product-country legal states');
    const productRows = (await conn.runAndReadAll(`SELECT hts10,count(*) n,
      count(DISTINCT (valid_from,valid_until)) states FROM ${products} GROUP BY hts10`)).getRowObjects();
    if (productRows.some(r => Number(r.n)!==states.length || Number(r.states)!==states.length)
      || productRows.length !== revision.bundle.products.length
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
