import test from 'node:test';
import assert from 'node:assert/strict';
import {DuckDBInstance} from '@duckdb/node-api';
import {
  productBaseRatesBody,
  productBaseRatesViewSql,
  ratesColumnSet,
  RATES_COLUMNS,
} from '../server/db.js';

// The columns productBaseRatesBody() always aggregates, one row per revision.
const BASE = `
  SELECT * FROM (VALUES
    ('0102294000','5700','2025_rev_17', 0.0::DOUBLE, 0.0::DOUBLE, NULL::DOUBLE, NULL::VARCHAR,
     NULL::DOUBLE, NULL::VARCHAR, NULL::VARCHAR, 'specific', 0.01::DOUBLE, 'kg', 'kg', NULL::VARCHAR,
     'kg', true, 'rate_text', '19cfr159.3_specific_lte1', 'base_ad_valorem_only',
     DATE '2025-06-01', DATE '2025-06-01', DATE '2025-07-01'))
  t(hts10, country, revision, base_rate, statutory_base_rate, rate_column2, rate_column2_raw,
    rate_special, rate_special_raw, special_programs_json, rate_basis, specific_amount,
    specific_rate_unit, reported_unit_1, reported_unit_2, duty_basis_unit, is_qty_duty_relevant,
    quantity_source, rounding_rule, calc_status, effective_date, valid_from, valid_until)`;

async function withRates(withText, fn) {
  const instance = await DuckDBInstance.create();
  const conn = await instance.connect();
  try {
    await conn.run(withText
      ? `CREATE TABLE rates AS SELECT *, '1¢/kg' AS duty_expression_raw FROM (${BASE})`
      : `CREATE TABLE rates AS ${BASE}`);
    await fn(conn);
  } finally {
    conn.closeSync?.();
    instance.closeSync?.();
  }
}

test('the General rate text is a served column', () => {
  assert.ok(RATES_COLUMNS.includes('duty_expression_raw'));
});

test('product_base_rates carries the General rate text when rates has it', async () => {
  await withRates(true, async (conn) => {
    await conn.run(productBaseRatesViewSql(await ratesColumnSet(conn)));
    const rows = (await conn.runAndReadAll('SELECT * FROM product_base_rates')).getRowObjects();
    assert.equal(rows.length, 1);
    assert.equal(rows[0].duty_expression_raw, '1¢/kg');
    assert.equal(rows[0].specific_amount, 0.01);
  });
});

test('product_base_rates still builds over a rates table that predates the column', async () => {
  // An ANY_VALUE over a missing column would fail the whole rebuild, which is
  // what a --post-only run against an older cloud table would hit.
  await withRates(false, async (conn) => {
    await conn.run(productBaseRatesViewSql(await ratesColumnSet(conn)));
    const rows = (await conn.runAndReadAll('SELECT * FROM product_base_rates')).getRowObjects();
    assert.equal(rows.length, 1);
    assert.ok(!('duty_expression_raw' in rows[0]));
  });
});

test('without a column set the body names only the columns every rates table has', () => {
  assert.ok(!productBaseRatesBody("WHERE revision = 'x'").includes('duty_expression_raw'));
});
