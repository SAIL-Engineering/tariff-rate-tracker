// Compressed answers (server/compress.js) and the byte-bounded answer cache (server/rates-cache.js). A product's
// rates for every country are about 39 MB of Arrow and gzip to about 1.2 MB (2026-11-23): sent raw, a browser waited
// tens of seconds and a network change cut the download; cached raw, a few dozen filled the server's memory.
import test from 'node:test';
import assert from 'node:assert/strict';
import http from 'node:http';
import zlib from 'node:zlib';
import express from 'express';
import { compressResponses, gzipBuffer, sendGzipped } from '../server/compress.js';
import { createRatesCache } from '../server/rates-cache.js';

const BIG = { rows: Array.from({ length: 400 }, (_, i) => ({ hts10: '6110202079', country: '5700', i })) };

/** One raw request: the status, headers and undecoded body bytes. */
function get(port, path, headers = {}) {
  return new Promise((resolve, reject) => {
    http.get({ host: '127.0.0.1', port, path, headers }, (res) => {
      const chunks = [];
      res.on('data', (c) => chunks.push(c));
      res.on('end', () => resolve({ status: res.statusCode, headers: res.headers, body: Buffer.concat(chunks) }));
    }).on('error', reject);
  });
}

async function withApp(fn) {
  const app = express();
  app.use(compressResponses());
  app.get('/big', (_req, res) => res.json(BIG));
  app.get('/small', (_req, res) => res.json({ ok: true }));
  app.get('/arrow', async (req, res) => {
    const raw = Buffer.alloc(50_000, 7);
    res.setHeader('Content-Type', 'application/vnd.apache.arrow.stream');
    res.setHeader('Content-Length', raw.byteLength);
    res.send(raw);
  });
  app.get('/pre', async (req, res) => {
    res.setHeader('Content-Type', 'application/vnd.apache.arrow.stream');
    return sendGzipped(req, res, await gzipBuffer(Buffer.from('arrow-bytes'.repeat(500))));
  });
  const server = app.listen(0);
  await new Promise((r) => server.once('listening', r));
  try { await fn(server.address().port); } finally { server.close(); }
}

test('a JSON answer of 1 KB or more goes gzipped to a client that accepts gzip', async () => {
  await withApp(async (port) => {
    const r = await get(port, '/big', { 'Accept-Encoding': 'gzip, deflate, br' });
    assert.equal(r.status, 200);
    assert.equal(r.headers['content-encoding'], 'gzip');
    assert.match(String(r.headers.vary), /Accept-Encoding/);
    assert.equal(Number(r.headers['content-length']), r.body.length);
    assert.deepEqual(JSON.parse(zlib.gunzipSync(r.body).toString('utf8')), BIG);
    assert.match(String(r.headers['content-type']), /application\/json/);
  });
});

test('a client that does not accept gzip gets the plain answer', async () => {
  await withApp(async (port) => {
    const r = await get(port, '/big');
    assert.equal(r.headers['content-encoding'], undefined);
    assert.deepEqual(JSON.parse(r.body.toString('utf8')), BIG);
  });
});

test('a small answer is sent as is', async () => {
  await withApp(async (port) => {
    const r = await get(port, '/small', { 'Accept-Encoding': 'gzip' });
    assert.equal(r.headers['content-encoding'], undefined);
    assert.deepEqual(JSON.parse(r.body.toString('utf8')), { ok: true });
  });
});

test('an Arrow answer goes gzipped, its length the compressed length', async () => {
  await withApp(async (port) => {
    const r = await get(port, '/arrow', { 'Accept-Encoding': 'gzip' });
    assert.equal(r.headers['content-encoding'], 'gzip');
    assert.equal(Number(r.headers['content-length']), r.body.length);
    assert.ok(r.body.length < 50_000);
    assert.deepEqual(zlib.gunzipSync(r.body), Buffer.alloc(50_000, 7));
    assert.equal(r.headers['content-type'], 'application/vnd.apache.arrow.stream');
  });
});

test('an answer kept gzipped is sent once compressed, and unzipped for a client without gzip', async () => {
  await withApp(async (port) => {
    const zipped = await get(port, '/pre', { 'Accept-Encoding': 'gzip' });
    assert.equal(zipped.headers['content-encoding'], 'gzip');
    assert.equal(zlib.gunzipSync(zipped.body).toString(), 'arrow-bytes'.repeat(500)); // not compressed twice
    const plain = await get(port, '/pre');
    assert.equal(plain.headers['content-encoding'], undefined);
    assert.equal(plain.body.toString(), 'arrow-bytes'.repeat(500));
  });
});

test('the cache keeps under its byte budget, dropping the least recently used first', () => {
  const cache = createRatesCache({ maxEntries: 100, maxBytes: 3000, ttlMs: 60_000 });
  for (const k of ['a', 'b', 'c', 'd']) cache.set(k, Buffer.alloc(700)); // 2800 bytes
  cache.get('a'); // a is now the most recent; b is the least
  cache.set('e', Buffer.alloc(700)); // 3500 would exceed 3000: b goes
  assert.equal(cache.get('b'), null);
  for (const k of ['a', 'c', 'd', 'e']) assert.ok(cache.get(k), k);
  assert.equal(cache.bytes(), 2800);
});

test('an answer larger than a quarter of the budget is not kept', () => {
  const cache = createRatesCache({ maxEntries: 100, maxBytes: 4000, ttlMs: 60_000 });
  cache.set('huge', Buffer.alloc(1001));
  assert.equal(cache.get('huge'), null);
  assert.equal(cache.bytes(), 0);
});

test('the cache still caps entries and expires them', () => {
  let now = 0;
  const cache = createRatesCache({ maxEntries: 2, maxBytes: 1e9, ttlMs: 1000, now: () => now });
  cache.set('a', { x: 1 });
  cache.set('b', { x: 2 });
  cache.set('c', { x: 3 });
  assert.equal(cache.get('a'), null);
  assert.deepEqual(cache.get('c'), { x: 3 });
  now = 2000;
  assert.equal(cache.get('c'), null);
});

test('a kept gzip entry counts its compressed size', () => {
  const cache = createRatesCache({ maxEntries: 10, maxBytes: 10_000, ttlMs: 60_000 });
  cache.set('arrow', { gz: Buffer.alloc(300), rawBytes: 39_000_000 });
  assert.equal(cache.bytes(), 300);
});

test('an entry can be kept longer than the default', () => {
  let now = 0;
  const cache = createRatesCache({ maxEntries: 10, maxBytes: 1e9, ttlMs: 1000, now: () => now });
  cache.set('short', { x: 1 });
  cache.set('long', { x: 2 }, 60_000);
  now = 5000;
  assert.equal(cache.get('short'), null);
  assert.deepEqual(cache.get('long'), { x: 2 });
});
