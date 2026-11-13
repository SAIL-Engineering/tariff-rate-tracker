import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {DuckDBInstance} from '@duckdb/node-api';
import {ensureRatesColumns, newRatesColumns} from '../server/rates-columns.js';

// A cloud-shaped `rates` (no duty_expression_raw) and a rebuilt partition that has it.
async function withFixture(fn) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'rates-columns-'));
  const part = path.join(dir, 'revision=2025_rev_17');
  fs.mkdirSync(part);
  const instance = await DuckDBInstance.create();
  const conn = await instance.connect();
  try {
    await conn.run(`CREATE TABLE rates AS SELECT * FROM (VALUES
      ('0102294000','5700','2025_rev_17',0.075::DOUBLE),
      ('0101210000','5700','2019_basic',0.0::DOUBLE)) t(hts10,country,revision,total_additional)`);
    await conn.run(`COPY (SELECT '0102294000' hts10, '5700' country, 0.075::DOUBLE total_additional,
      '1¢/kg' duty_expression_raw) TO '${path.join(part, 'data_0.parquet')}' (FORMAT parquet)`);
    await fn(conn, [path.join(dir, 'revision=2025_rev_17', '*.parquet')]);
  } finally {
    conn.closeSync?.();
    instance.closeSync?.();
    fs.rmSync(dir, {recursive: true, force: true});
  }
}

const columnsOf = async (conn) =>
  (await conn.runAndReadAll('DESCRIBE rates')).getRowObjects().map((r) => String(r.column_name));

test('names a column the partitions carry and rates lacks', async () => {
  await withFixture(async (conn, globs) => {
    assert.deepEqual(await newRatesColumns(conn, globs), [{name: 'duty_expression_raw', type: 'VARCHAR'}]);
  });
});

test('without --add-columns the push stops before any row moves', async () => {
  await withFixture(async (conn, globs) => {
    await assert.rejects(ensureRatesColumns(conn, globs), /duty_expression_raw VARCHAR.*--add-columns.*Nothing was changed/);
    assert.ok(!(await columnsOf(conn)).includes('duty_expression_raw'));
  });
});

test('a dry run reports the column and leaves rates alone', async () => {
  await withFixture(async (conn, globs) => {
    const seen = [];
    const added = await ensureRatesColumns(conn, globs, {addColumns: true, dryRun: true, log: (e, d) => seen.push([e, d])});
    assert.equal(added.length, 1);
    assert.equal(seen[0][0], 'dry_run.would_add_columns');
    assert.ok(!(await columnsOf(conn)).includes('duty_expression_raw'));
  });
});

test('--add-columns adds it nullable, then the revision inserts by name', async () => {
  await withFixture(async (conn, globs) => {
    await ensureRatesColumns(conn, globs, {addColumns: true});
    assert.ok((await columnsOf(conn)).includes('duty_expression_raw'));
    await conn.run(`DELETE FROM rates WHERE revision = '2025_rev_17'`);
    await conn.run(`INSERT INTO rates BY NAME SELECT * FROM read_parquet('${globs[0]}', hive_partitioning = true, union_by_name = true)`);
    const rows = (await conn.runAndReadAll('SELECT revision, duty_expression_raw FROM rates ORDER BY revision')).getRowObjects();
    assert.deepEqual(rows.map((r) => [r.revision, r.duty_expression_raw]), [
      ['2019_basic', null], // a revision not pushed keeps its row and reads NULL
      ['2025_rev_17', '1¢/kg'],
    ]);
    // Idempotent: nothing left to add.
    assert.deepEqual(await ensureRatesColumns(conn, globs, {addColumns: true}), []);
  });
});
