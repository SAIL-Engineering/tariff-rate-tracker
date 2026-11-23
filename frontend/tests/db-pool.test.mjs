// The guarded connection pool (server/db-pool.js): a query that does not answer within its deadline fails fast, its
// session is interrupted and replaced, and the process asks to be restarted when sessions cannot be replaced.
import test from 'node:test';
import assert from 'node:assert/strict';
import { createGuardedPool, QueryTimeoutError } from '../server/db-pool.js';

/** A fake DuckDB connection: answers with `rows` after `ms`, or never when `ms` is Infinity. */
function fakeConn(name, ms = 0) {
  return {
    name,
    interrupted: 0,
    calls: 0,
    interrupt() { this.interrupted++; },
    runAndReadAll(sql) {
      this.calls++;
      if (ms === Infinity) return new Promise(() => {});
      return new Promise((resolve) => setTimeout(() => resolve({ name, sql }), ms));
    },
  };
}

function quietLog() { return { warn() {}, error() {} }; }

test('a query that answers in time passes through', async () => {
  const a = fakeConn('a');
  const pool = createGuardedPool({ connections: [a], openConnection: async () => fakeConn('fresh'), timeoutMs: 50, log: quietLog(), onFatal: () => assert.fail('no fatal') });
  const out = await pool.pick().runAndReadAll('SELECT 1');
  assert.deepEqual(out, { name: 'a', sql: 'SELECT 1' });
  assert.equal(a.interrupted, 0);
});

test('a hung query fails with QueryTimeoutError, is interrupted, and its session is replaced', async () => {
  const stuck = fakeConn('stuck', Infinity);
  const fresh = fakeConn('fresh');
  const pool = createGuardedPool({ connections: [stuck], openConnection: async () => fresh, timeoutMs: 30, log: quietLog(), onFatal: () => assert.fail('no fatal') });
  await assert.rejects(pool.pick().runAndReadAll('SELECT * FROM rates'), (err) => err instanceof QueryTimeoutError && err.status === 503);
  assert.equal(stuck.interrupted, 1);
  await pool.settled();
  const out = await pool.pick().runAndReadAll('SELECT 2');
  assert.equal(out.name, 'fresh');
});

test('queries go round the pool and skip a session that is being replaced', async () => {
  const a = fakeConn('a', Infinity);
  const b = fakeConn('b');
  let release;
  const pool = createGuardedPool({
    connections: [a, b],
    openConnection: () => new Promise((resolve) => { release = () => resolve(fakeConn('a2')); }),
    timeoutMs: 20, log: quietLog(), onFatal: () => assert.fail('no fatal'),
  });
  await assert.rejects(pool.pick().runAndReadAll('q1'), QueryTimeoutError); // a: stuck, replacing
  assert.equal((await pool.pick().runAndReadAll('q2')).name, 'b');
  assert.equal((await pool.pick().runAndReadAll('q3')).name, 'b'); // a is still being replaced
  release();
  await pool.settled();
  const names = [(await pool.pick().runAndReadAll('q4')).name, (await pool.pick().runAndReadAll('q5')).name].sort();
  assert.deepEqual(names, ['a2', 'b']);
});

test('a session that cannot be reopened asks for a restart', async () => {
  const stuck = fakeConn('stuck', Infinity);
  const fatal = [];
  const pool = createGuardedPool({ connections: [stuck], openConnection: async () => { throw new Error('token rejected'); }, timeoutMs: 20, log: quietLog(), onFatal: (why) => fatal.push(why) });
  await assert.rejects(pool.pick().runAndReadAll('q'), QueryTimeoutError);
  await pool.settled();
  assert.equal(fatal.length, 1);
  assert.match(fatal[0], /token rejected/);
});

test('opening a new session that itself hangs asks for a restart', async () => {
  const stuck = fakeConn('stuck', Infinity);
  const fatal = [];
  const pool = createGuardedPool({ connections: [stuck], openConnection: () => new Promise(() => {}), timeoutMs: 20, log: quietLog(), onFatal: (why) => fatal.push(why) });
  await assert.rejects(pool.pick().runAndReadAll('q'), QueryTimeoutError);
  await pool.settled();
  assert.equal(fatal.length, 1);
});

test('too many replacements within the window ask for a restart', async () => {
  const fatal = [];
  const pool = createGuardedPool({
    connections: [fakeConn('s0', Infinity)],
    openConnection: async () => fakeConn('again', Infinity),
    timeoutMs: 10, maxReplacements: 2, replacementWindowMs: 60_000, log: quietLog(), onFatal: (why) => fatal.push(why),
  });
  for (let i = 0; i < 3; i++) {
    await assert.rejects(pool.pick().runAndReadAll(`q${i}`), QueryTimeoutError);
    await pool.settled();
  }
  assert.equal(fatal.length, 1);
  assert.match(fatal[0], /3 stuck database sessions/);
});

test('without a way to open sessions, a stuck one asks for a restart', async () => {
  const fatal = [];
  const pool = createGuardedPool({ connections: [fakeConn('s', Infinity)], openConnection: null, timeoutMs: 10, log: quietLog(), onFatal: (why) => fatal.push(why) });
  await assert.rejects(pool.pick().runAndReadAll('q'), QueryTimeoutError);
  await pool.settled();
  assert.equal(fatal.length, 1);
});

test('run() is under the same deadline as runAndReadAll()', async () => {
  const stuck = { interrupted: 0, interrupt() { this.interrupted++; }, run: () => new Promise(() => {}), runAndReadAll: async () => 'never' };
  const fresh = { run: async (sql) => `ran ${sql}`, runAndReadAll: async () => 'fresh' };
  const pool = createGuardedPool({ connections: [stuck], openConnection: async () => fresh, timeoutMs: 20, log: quietLog(), onFatal: () => assert.fail('no fatal') });
  await assert.rejects(pool.pick().run('CREATE TEMP TABLE t AS SELECT 1'), QueryTimeoutError);
  assert.equal(stuck.interrupted, 1);
  await pool.settled();
  assert.equal(await pool.pick().run('SELECT 1'), 'ran SELECT 1');
});

test('a query error that is not a timeout passes through and keeps the session', async () => {
  const bad = { interrupted: 0, interrupt() { this.interrupted++; }, runAndReadAll: async () => { throw new Error('Binder Error'); } };
  const pool = createGuardedPool({ connections: [bad], openConnection: async () => assert.fail('no replacement'), timeoutMs: 50, log: quietLog(), onFatal: () => assert.fail('no fatal') });
  await assert.rejects(pool.pick().runAndReadAll('q'), /Binder Error/);
  assert.equal(bad.interrupted, 0);
});

test('an abandoned query that fails later raises no unhandled rejection', async () => {
  let rejectLate;
  const late = { interrupt() {}, runAndReadAll: () => new Promise((_, reject) => { rejectLate = reject; }) };
  const pool = createGuardedPool({ connections: [late], openConnection: async () => fakeConn('fresh'), timeoutMs: 10, log: quietLog(), onFatal: () => assert.fail('no fatal') });
  const unhandled = [];
  const onUnhandled = (e) => unhandled.push(e);
  process.on('unhandledRejection', onUnhandled);
  await assert.rejects(pool.pick().runAndReadAll('q'), QueryTimeoutError);
  rejectLate(new Error('INTERRUPT Error'));
  await new Promise((r) => setTimeout(r, 20));
  process.off('unhandledRejection', onUnhandled);
  assert.deepEqual(unhandled, []);
});
