import test from 'node:test';
import assert from 'node:assert/strict';
import {DuckDBInstance} from '@duckdb/node-api';
import {reclusterRatesByPartition} from '../server/rates-recluster.js';

// Three revisions, rows deliberately out of (hts10, country) order.
const SEED = `CREATE TABLE rates AS SELECT * FROM (VALUES
  ('r1','0201','CN',1.0),('r1','0101','MX',2.0),('r1','0101','CA',3.0),
  ('r2','0302','CN',4.0),('r2','0301','CN',5.0),
  ('r3','0402','JP',6.0),('r3','0401','JP',7.0)) t(revision,hts10,country,rate)`;

async function withDb(fn) {
  const db = await DuckDBInstance.create(':memory:');
  const c = await db.connect();
  try { await c.run(SEED); await fn(c); } finally { c.closeSync(); db.closeSync(); }
}
const rows = async (c, t) =>
  (await c.runAndReadAll(`SELECT revision,hts10,country,rate FROM ${t} ORDER BY ALL`)).getRowObjects();
const exists = async (c, t) =>
  (await c.runAndReadAll(`SELECT 1 FROM information_schema.tables WHERE table_name='${t}'`)).getRowObjects().length > 0;
const capture = () => { const events = []; return {events, log: (event, extra = {}) => events.push({event, ...extra})}; };

test('resume keeps finished revisions, recopies a partial one and copies the rest', async () => {
  await withDb(async (c) => {
    const before = await rows(c, 'rates');
    // An interrupted run: r1 fully copied, r2 holding one of its two rows.
    await c.run('CREATE TABLE rates_new AS SELECT * FROM rates LIMIT 0');
    await c.run(`INSERT INTO rates_new SELECT * FROM rates WHERE revision='r1' ORDER BY hts10,country`);
    await c.run(`INSERT INTO rates_new SELECT * FROM rates WHERE revision='r2' AND hts10='0301'`);
    const {events, log} = capture();
    await reclusterRatesByPartition(c, {resume: true, log});
    assert.deepEqual(await rows(c, 'rates'), before);
    assert.equal(await exists(c, 'rates_new'), false);
    const by = (e) => events.filter((x) => x.event === e).map((x) => x.revision);
    assert.deepEqual(by('exec.rates.cluster.partition.skip'), ['r1']);
    assert.deepEqual(by('exec.rates.cluster.partition.partial'), ['r2']);
    assert.deepEqual(by('exec.rates.cluster.partition.done'), ['r2', 'r3']);
    // Each revision now sits in (hts10, country) order.
    const r3 = (await c.runAndReadAll(`SELECT hts10 FROM rates WHERE revision='r3'`)).getRowObjects();
    assert.deepEqual(r3.map((r) => r.hts10), ['0401', '0402']);
  });
});

test('without resume a leftover rates_new is discarded and rebuilt', async () => {
  await withDb(async (c) => {
    const before = await rows(c, 'rates');
    await c.run('CREATE TABLE rates_new AS SELECT * FROM rates WHERE revision = \'r1\'');
    const {events, log} = capture();
    await reclusterRatesByPartition(c, {log});
    assert.deepEqual(await rows(c, 'rates'), before);
    assert.equal(events.filter((e) => e.event === 'exec.rates.cluster.partition.done').length, 3);
  });
});

test('resume with no rates_new starts from scratch', async () => {
  await withDb(async (c) => {
    const before = await rows(c, 'rates');
    const {events, log} = capture();
    await reclusterRatesByPartition(c, {resume: true, log});
    assert.deepEqual(await rows(c, 'rates'), before);
    assert.equal(events.find((e) => e.event === 'exec.rates.cluster.resume').rates_new, 'absent');
  });
});

test('resume refuses a rates_new from a different load and leaves rates alone', async () => {
  await withDb(async (c) => {
    const before = await rows(c, 'rates');
    await c.run(`CREATE TABLE rates_new AS SELECT 'r9' revision,'0101' hts10,'CN' country,1.0 rate`);
    await assert.rejects(reclusterRatesByPartition(c, {resume: true}), /different load/);
    await c.run('DROP TABLE rates_new');
    await c.run(`CREATE TABLE rates_new AS SELECT revision,hts10,country FROM rates LIMIT 0`);
    await assert.rejects(reclusterRatesByPartition(c, {resume: true}), /columns/);
    assert.deepEqual(await rows(c, 'rates'), before);
  });
});

test('an incomplete rates_new is never swapped in', async () => {
  await withDb(async (c) => {
    const before = await rows(c, 'rates');
    // A connection that silently loses r3's copy.
    const lossy = {
      run: (sql) => (/INSERT INTO rates_new/.test(sql) && /'r3'/.test(sql) ? Promise.resolve() : c.run(sql)),
      runAndReadAll: (sql) => c.runAndReadAll(sql),
    };
    await assert.rejects(reclusterRatesByPartition(lossy), /does not match rates for r3; rates left in place/);
    assert.deepEqual(await rows(c, 'rates'), before);
    assert.equal(await exists(c, 'rates_new'), true);
  });
});
