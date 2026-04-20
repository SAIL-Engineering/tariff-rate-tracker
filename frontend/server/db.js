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

// product_base_rates view DDL — shared between local init and the cloud
// sync script, so both modes expose the exact same relation to route handlers.
export const PRODUCT_BASE_RATES_VIEW_SQL = `
  CREATE OR REPLACE VIEW product_base_rates AS
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
  GROUP BY hts10, revision
`;

const STATS_SQL = `
  SELECT
    count(DISTINCT hts10) AS n_products,
    count(DISTINCT country) AS n_countries,
    count(DISTINCT revision) AS n_revisions,
    count(*) AS n_rows
  FROM rates
`;

async function initLocal() {
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

  const reader = await connection.runAndReadAll(STATS_SQL);
  const stats = reader.getRowObjects()[0];

  // Warm the base-rate view so its GROUP BY is compiled once at startup.
  await connection.runAndReadAll('SELECT count(*) FROM product_base_rates');

  return { connection, stats };
}

async function initMotherDuck({ motherduckToken, motherduckDb }) {
  // The @duckdb/node-api driver reads the token from the motherduck_token env
  // variable; setting it on process.env is the documented pattern.
  process.env.motherduck_token = motherduckToken;

  const instance = await DuckDBInstance.create(`md:${motherduckDb}`);
  const connection = await instance.connect();

  const reader = await connection.runAndReadAll(STATS_SQL);
  const stats = reader.getRowObjects()[0];

  return { connection, stats };
}

export async function initDatabase() {
  const config = getConfig();
  if (config.target === 'motherduck') {
    return initMotherDuck(config);
  }
  return initLocal();
}
