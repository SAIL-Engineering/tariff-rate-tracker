// Every data endpoint answers only a signed-in request (WJR 2026-11-23). The rates were served to anyone who asked;
// only POST /api/rates/batch and /api/shipments/resolve checked a Supabase sign-in. Now every endpoint but
// /api/health (Railway's deploy check, which cannot sign in, and which shows only a row count) refuses a request
// without a verified Supabase access token with 401, and answers a signed-in one as before.
//
// This drives the real app (server.js) without a database: a refused request never reaches a handler, and a signed-in
// one reaches it and gets the handler's own answer (its input check, or its "unavailable" when there is no database).
import test from 'node:test';
import assert from 'node:assert/strict';
import crypto from 'crypto';
import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';

const SECRET = 'test-legacy-secret-not-real';
const ORIGIN = 'https://sailgtx.ai';

process.env.TARIFF_API_NO_START = '1';
process.env.SUPABASE_JWT_SECRET = SECRET;
process.env.SUPABASE_URL = ''; // set, so a repository .env can never supply one
process.env.CORS_ALLOWED_ORIGINS = ORIGIN;
process.env.RAILWAY_ENVIRONMENT = '';
process.env.RAILWAY_ENVIRONMENT_NAME = '';
process.env.DATABASE_TARGET = 'local';

const here = path.dirname(fileURLToPath(import.meta.url));
const { app } = await import('../server.js');

const b64url = (buf) => Buffer.from(buf).toString('base64').replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
const seg = (obj) => b64url(JSON.stringify(obj));
function signHs256(payload, secret = SECRET) {
  const head = `${seg({ alg: 'HS256', typ: 'JWT' })}.${seg(payload)}`;
  return `${head}.${b64url(crypto.createHmac('sha256', secret).update(head).digest())}`;
}
const now = () => Math.floor(Date.now() / 1000);
const TOKEN = signHs256({ sub: 'user-1', role: 'authenticated', exp: now() + 600 });

let base;
const server = await new Promise((ok) => { const s = app.listen(0, '127.0.0.1', () => ok(s)); });
base = `http://127.0.0.1:${server.address().port}`;
test.after(() => server.close());

async function call(method, url, { token = null, body, headers = {} } = {}) {
  const res = await fetch(`${base}${url}`, {
    method,
    headers: {
      ...(token ? { authorization: `Bearer ${token}` } : {}),
      ...(body !== undefined ? { 'content-type': 'application/json' } : {}),
      ...headers,
    },
    body: body !== undefined ? JSON.stringify(body) : undefined,
  });
  const text = await res.text();
  let json = null;
  try { json = JSON.parse(text); } catch { /* not JSON */ }
  return { status: res.status, json, headers: res.headers };
}

// Each data endpoint, called the way a client calls it, with the answer its handler gives a signed-in request when
// there is no database behind it: its own input check (400), its "unavailable" (503), or its empty answer (200).
const DATA_ENDPOINTS = [
  { method: 'GET', path: '/api/rates', url: '/api/rates', signedIn: 400 },
  { method: 'GET', path: '/api/rates/arrow', url: '/api/rates/arrow', signedIn: 400 },
  { method: 'POST', path: '/api/rates/batch', url: '/api/rates/batch', body: {}, signedIn: 400 },
  { method: 'GET', path: '/api/products', url: '/api/products', signedIn: 400 },
  { method: 'GET', path: '/api/rankings', url: '/api/rankings', signedIn: 400 },
  { method: 'GET', path: '/api/product-info', url: '/api/product-info?hts10=0101210000', signedIn: 200 },
  { method: 'GET', path: '/api/shipment-dataset', url: '/api/shipment-dataset', signedIn: 503 },
  { method: 'POST', path: '/api/shipments/resolve', url: '/api/shipments/resolve', body: {}, signedIn: 400 },
];

test('the list above is every route the server registers, besides /api/health', () => {
  const sources = [path.join(here, '..', 'server.js'), ...fs.readdirSync(path.join(here, '..', 'server'))
    .filter((f) => f.endsWith('.js')).map((f) => path.join(here, '..', 'server', f))];
  const registered = new Set();
  for (const file of sources) {
    for (const m of fs.readFileSync(file, 'utf8').matchAll(/\bapp\.(get|post|put|patch|delete|all)\(\s*'([^']+)'/g)) {
      registered.add(`${m[1].toUpperCase()} ${m[2]}`);
    }
  }
  const listed = new Set([...DATA_ENDPOINTS.map((e) => `${e.method} ${e.path}`), 'GET /api/health']);
  assert.deepEqual([...registered].sort(), [...listed].sort());
});

test('each data route names the sign-in check on its own definition line, as well as the gate ahead of them all', () => {
  const sources = [path.join(here, '..', 'server.js'), path.join(here, '..', 'server', 'shipment-routes.js')];
  const unchecked = [];
  for (const file of sources) {
    for (const m of fs.readFileSync(file, 'utf8').matchAll(/\bapp\.(get|post|put|patch|delete|all)\(\s*'([^']+)'(.*)$/gm)) {
      if (m[2] === '/api/health') continue;
      if (!/^\s*,\s*(requireSupabaseAuth|requireAuth)\s*,/.test(m[3])) unchecked.push(`${path.basename(file)}: ${m[1].toUpperCase()} ${m[2]}`);
    }
  }
  assert.deepEqual(unchecked, []);
});

for (const e of DATA_ENDPOINTS) {
  test(`${e.method} ${e.path}: 401 without a sign-in`, async () => {
    const r = await call(e.method, e.url, { body: e.body });
    assert.equal(r.status, 401);
    assert.match(r.json.error, /^Authentication required/);
  });

  test(`${e.method} ${e.path}: 401 with a token the server cannot verify`, async () => {
    const forged = signHs256({ sub: 'user-1', exp: now() + 600 }, 'some-other-secret');
    const expired = signHs256({ sub: 'user-1', exp: now() - 60 });
    assert.equal((await call(e.method, e.url, { token: forged, body: e.body })).status, 401);
    assert.equal((await call(e.method, e.url, { token: expired, body: e.body })).status, 401);
    assert.equal((await call(e.method, e.url, { token: 'not-a-jwt', body: e.body })).status, 401);
  });

  test(`${e.method} ${e.path}: a signed-in request reaches the handler, as before`, async () => {
    const r = await call(e.method, e.url, { token: TOKEN, body: e.body });
    assert.equal(r.status, e.signedIn, JSON.stringify(r.json));
  });
}

test('the project\'s public API key is not a sign-in', async () => {
  const anonKey = signHs256({ iss: 'supabase', ref: 'example-project', role: 'anon', exp: now() + 3e8 });
  assert.equal((await call('GET', '/api/rates/arrow?hts10=0101210000', { token: anonKey })).status, 401);
  assert.equal((await call('POST', '/api/rates/batch', { token: anonKey, body: {} })).status, 401);
});

test('a refused request is answered before its body is read', async () => {
  const res = await fetch(`${base}/api/rates/batch`, {
    method: 'POST', headers: { 'content-type': 'application/json' }, body: '{not json',
  });
  assert.equal(res.status, 401);
});

test('any other path asks for a sign-in too, so a new route is never open by default', async () => {
  assert.equal((await call('GET', '/api/not-a-route')).status, 401);
  assert.equal((await call('GET', '/API/RATES?hts10=0101210000')).status, 401);
});

test('/api/health stays open (Railway\'s deploy check cannot sign in) and says sign-in is enforced', async () => {
  const r = await call('GET', '/api/health');
  assert.notEqual(r.status, 401);
  assert.equal(r.json.auth, 'enforced');
  assert.ok('status' in r.json);
});

test('the site\'s browser calls work: the preflight passes without a token, and a 401 carries the CORS headers', async () => {
  const pre = await fetch(`${base}/api/rates?hts10=0101210000`, {
    method: 'OPTIONS',
    headers: { origin: ORIGIN, 'access-control-request-method': 'GET', 'access-control-request-headers': 'authorization' },
  });
  assert.equal(pre.status, 204);
  assert.match(pre.headers.get('access-control-allow-headers') ?? '', /authorization/i);
  assert.equal(pre.headers.get('access-control-allow-origin'), ORIGIN);
  const refused = await call('GET', '/api/rates?hts10=0101210000', { headers: { origin: ORIGIN } });
  assert.equal(refused.status, 401);
  assert.equal(refused.headers.get('access-control-allow-origin'), ORIGIN);
});
