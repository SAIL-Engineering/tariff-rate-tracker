// Database connection factory.
//
// Branches on DATABASE_TARGET:
//   local      → in-memory DuckDB reading partitioned parquet via read_parquet()
//   motherduck → cloud MotherDuck DB; tables/views pre-baked by scripts/push-to-motherduck.mjs
//
// Both branches return { connection, stats } so server.js can keep its
// module-level `connection` variable and startup log untouched.

import { DuckDBInstance } from '@duckdb/node-api';
import path from 'path';
import { fileURLToPath } from 'url';
import { getConfig } from './config.js';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

// .../frontend/server/ → .../data/timeseries/rate_timeseries_parquet/
export const PARQUET_PATH = path.resolve(
  __dirname,
  '..',
  '..',
  'data',
  'timeseries',
  'rate_timeseries_parquet',
);

// Canonical column projection for the /api/rates response.
//
// Matches the 54 fields validated by
// frontend/src/types/rate-response.ts (or the sail-gtx-prerelease mirror).
// Explicit projection (vs `SELECT *`) lets MotherDuck skip columns that
// aren't in the ProductRate contract and shrinks the wire payload ~4–10×.
// Add new fields here AND in rate-response.ts when extending the contract.
export const RATES_COLUMNS = [
  'hts10',
  'country',
  'revision',
  'effective_date',
  'valid_from',
  'valid_until',
  'base_rate',
  'statutory_base_rate',
  'rate_232',
  'rate_301',
  'rate_ieepa_recip',
  'rate_ieepa_fent',
  'rate_s122',
  'rate_section_201',
  'rate_other',
  'statutory_rate_232',
  'statutory_rate_301',
  'statutory_rate_ieepa_recip',
  'statutory_rate_ieepa_fent',
  'statutory_rate_s122',
  'statutory_rate_section_201',
  'statutory_rate_other',
  'ch99_code_232',
  'ch99_code_301',
  'ch99_code_ieepa_recip',
  'ch99_code_ieepa_fent',
  'ch99_code_s122',
  'ch99_code_s201',
  'metal_share',
  'steel_share',
  'aluminum_share',
  'copper_share',
  'other_metal_share',
  'is_copper_heading',
  'deriv_type',
  's232_annex',
  'duty_basis_232',
  'total_additional',
  'total_rate',
  'usmca_eligible',
  'rate_special',
  'rate_special_raw',
  'special_programs_json',
  'rate_column2',
  'rate_column2_raw',
  'rate_basis',
  'specific_amount',
  'specific_rate_unit',
  'reported_unit_1',
  'reported_unit_2',
  'duty_basis_unit',
  'is_qty_duty_relevant',
  'quantity_source',
  'rounding_rule',
  'calc_status',
  'duty_provenance_json',
  'ch99_rules_json',
];

// Live binding: re-resolved at startup against the actual rates schema so
// columns added by newer pipeline builds (duty_basis_232, ch99_rules_json)
// don't break queries against pre-rebuild parquet/MotherDuck data. Until
// initDatabase() runs this is the optimistic full list.
export let RATES_PROJECTION = RATES_COLUMNS.join(', ');

async function resolveRatesProjection(connection) {
  const reader = await connection.runAndReadAll('DESCRIBE rates');
  const available = new Set(
    reader.getRowObjects().map((r) => String(r.column_name)),
  );
  const present = RATES_COLUMNS.filter((c) => available.has(c));
  const missing = RATES_COLUMNS.filter((c) => !available.has(c));
  if (missing.length > 0) {
    console.log(
      `[db] rates data predates optional columns (omitted): ${missing.join(', ')}`,
    );
  }
  RATES_PROJECTION = present.join(', ');
}

// Shared GROUP BY body for product_base_rates. The grouping key includes
// `revision`, which means a per-revision aggregate (with WHERE revision =
// '...') is mathematically identical to the global aggregate restricted to
// that revision's groups. The push script exploits that to rebuild the
// materialized cloud table revision-by-revision, bounding peak duckling
// memory to one partition.
export function productBaseRatesBody(whereClause = '') {
  return `
    SELECT
      hts10, revision,
      ANY_VALUE(base_rate)             AS base_rate,
      ANY_VALUE(statutory_base_rate)   AS statutory_base_rate,
      ANY_VALUE(rate_column2)          AS rate_column2,
      ANY_VALUE(rate_column2_raw)      AS rate_column2_raw,
      ANY_VALUE(rate_special)          AS rate_special,
      ANY_VALUE(rate_special_raw)      AS rate_special_raw,
      ANY_VALUE(special_programs_json) AS special_programs_json,
      ANY_VALUE(rate_basis)            AS rate_basis,
      ANY_VALUE(specific_amount)       AS specific_amount,
      ANY_VALUE(specific_rate_unit)    AS specific_rate_unit,
      ANY_VALUE(reported_unit_1)       AS reported_unit_1,
      ANY_VALUE(reported_unit_2)       AS reported_unit_2,
      ANY_VALUE(duty_basis_unit)       AS duty_basis_unit,
      ANY_VALUE(is_qty_duty_relevant)  AS is_qty_duty_relevant,
      ANY_VALUE(quantity_source)       AS quantity_source,
      ANY_VALUE(rounding_rule)         AS rounding_rule,
      ANY_VALUE(calc_status)           AS calc_status,
      ANY_VALUE(effective_date)        AS effective_date,
      MIN(valid_from)                  AS valid_from,
      MAX(valid_until)                 AS valid_until
    FROM rates
    ${whereClause}
    GROUP BY hts10, revision
  `;
}

// Local DuckDB: a VIEW is cheap because parquet reads are columnar and the
// local query planner prunes files aggressively. The GROUP BY compiles once.
export const PRODUCT_BASE_RATES_VIEW_SQL = `
  CREATE OR REPLACE VIEW product_base_rates AS
  ${productBaseRatesBody()}
`;

const STATS_SQL = `
  SELECT
    count(DISTINCT hts10) AS n_products,
    count(DISTINCT country) AS n_countries,
    count(DISTINCT revision) AS n_revisions,
    count(*) AS n_rows
  FROM rates
`;

// Connection-pool size. A single DuckDB/MotherDuck connection executes
// queries SERIALLY, so one slow scan (e.g. an all-country /api/rates/arrow)
// head-of-line-blocks every other in-flight request behind it. We therefore
// open a small pool of INDEPENDENT instances — each is its own MotherDuck
// session (cloud) or its own in-memory catalog (local) — and round-robin
// requests across them so independent lookups run concurrently. Override with
// DB_POOL_SIZE; 4 is a safe default for the Pulse/standard MotherDuck tiers.
const POOL_SIZE = Math.max(1, Number(process.env.DB_POOL_SIZE) || 4);

// One local in-memory member: an instance + connection with the `rates` and
// `product_base_rates` views defined. Each member has its OWN in-memory
// catalog (instances don't share catalogs), so the views are (re)created per
// member — cheap, since read_parquet is lazy and copies no data.
async function createLocalMember() {
  const instance = await DuckDBInstance.create();
  const connection = await instance.connect();

  // Legacy short-format revisions (e.g. 'rev_2') duplicate the canonical
  // year-prefixed revisions (e.g. '2025_rev_2') so we filter them out here.
  await connection.run(`
    CREATE VIEW rates AS
    SELECT * FROM read_parquet('${PARQUET_PATH}/*/*.parquet', hive_partitioning = true)
    WHERE revision LIKE '20%'
  `);
  await connection.run(PRODUCT_BASE_RATES_VIEW_SQL);
  return { instance, connection };
}

// One MotherDuck member: an independent cloud session. Multiple sessions let
// MotherDuck execute our queries concurrently instead of queueing them.
async function createMotherDuckMember(motherduckDb) {
  const instance = await DuckDBInstance.create(`md:${motherduckDb}`);
  const connection = await instance.connect();
  return { instance, connection };
}

async function initLocal() {
  // Members are independent — build them in parallel to keep startup snappy.
  const members = await Promise.all(
    Array.from({ length: POOL_SIZE }, () => createLocalMember()),
  );
  // Warm the base-rate view's GROUP BY plan ONCE (on member 0) — not per
  // member: each in-memory instance has its own catalog, but warming all of
  // them in parallel at startup contends on a full-corpus scan. The other
  // members compile their plan lazily on first use.
  const reader = await members[0].connection.runAndReadAll(STATS_SQL);
  const stats = reader.getRowObjects()[0];
  await members[0].connection.runAndReadAll('SELECT count(*) FROM product_base_rates');
  return { connections: members.map((m) => m.connection), stats };
}

async function initMotherDuck({ motherduckToken, motherduckDb }) {
  // The @duckdb/node-api driver reads the token from the motherduck_token env
  // variable; setting it on process.env is the documented pattern.
  process.env.motherduck_token = motherduckToken;

  const members = await Promise.all(
    Array.from({ length: POOL_SIZE }, () => createMotherDuckMember(motherduckDb)),
  );
  const reader = await members[0].connection.runAndReadAll(STATS_SQL);
  const stats = reader.getRowObjects()[0];
  return { connections: members.map((m) => m.connection), stats };
}

// Returns the set of country census codes that have at least one row in the
// rates table. Used by the server to short-circuit lookups for countries
// with no direct (hts10, country) coverage (most non-IEEPA-listed countries
// in early-2025 revisions) — straight to product_base_rates synthesis.
export async function loadKnownRatesCountries(connection) {
  const reader = await connection.runAndReadAll(
    'SELECT DISTINCT country FROM rates',
  );
  const set = new Set();
  for (const row of reader.getRowObjects()) {
    if (row.country != null) set.add(String(row.country));
  }
  return set;
}

export async function initDatabase() {
  const config = getConfig();
  const db =
    config.target === 'motherduck'
      ? await initMotherDuck(config)
      : await initLocal();
  // Schema is identical across pool members; resolve once off member 0.
  await resolveRatesProjection(db.connections[0]);
  return db; // { connections: DuckDBConnection[], stats }
}
