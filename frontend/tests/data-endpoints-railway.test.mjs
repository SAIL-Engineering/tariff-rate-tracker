// On Railway the data endpoints never answer without a sign-in (WJR 2026-11-23). With neither SUPABASE_JWT_SECRET nor
// SUPABASE_URL set there, nothing could be verified, so every data request is refused with 503 in words that read as a
// service fault (not the person's sign-in), and /api/health (still open, still with its own fields) says 'refusing',
// so a smoke check that asserts 'enforced' catches it. With either variable set, sign-in is enforced as everywhere.
// Off Railway, unconfigured stays open for local development (data-endpoints-unconfigured.test.mjs).
import test from 'node:test';
import assert from 'node:assert/strict';
import crypto from 'crypto';

const SECRET = 'test-legacy-secret-not-real';
const b64url = (buf) => Buffer.from(buf).toString('base64').replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
const seg = (obj) => b64url(JSON.stringify(obj));
function signHs256(payload) {
  const head = `${seg({ alg: 'HS256', typ: 'JWT' })}.${seg(payload)}`;
  return `${head}.${b64url(crypto.createHmac('sha256', SECRET).update(head).digest())}`;
}
const TOKEN = signHs256({ sub: 'user-1', role: 'authenticated', exp: Math.floor(Date.now() / 1000) + 600 });

const DATA = [
  ['GET', '/api/rates'], ['GET', '/api/rates/arrow'], ['POST', '/api/rates/batch'], ['GET', '/api/products'],
  ['GET', '/api/rankings'], ['GET', '/api/product-info?hts10=0101210000'], ['GET', '/api/shipment-dataset'],
  ['POST', '/api/shipments/resolve'],
];
const UNCONFIGURED = "Rates are unavailable: the service's sign-in is not configured.";

process.env.TARIFF_API_NO_START = '1';
process.env.DATABASE_TARGET = 'local';
delete process.env.CORS_ALLOWED_ORIGINS;

/** The real app under one configuration: a fresh copy of server.js (its own URL) read with these variables. */
async function serve(tag, { railway, secret = '', url = '' }) {
  process.env.RAILWAY_ENVIRONMENT = railway ?? '';
  process.env.RAILWAY_ENVIRONMENT_NAME = '';
  process.env.SUPABASE_JWT_SECRET = secret;
  process.env.SUPABASE_URL = url;
  const { app } = await import(`../server.js?${tag}`);
  const server = await new Promise((ok) => { const s = app.listen(0, '127.0.0.1', () => ok(s)); });
  test.after(() => server.close());
  const base = `http://127.0.0.1:${server.address().port}`;
  return async (method, path, token) => {
    const res = await fetch(`${base}${path}`, {
      method,
      headers: { ...(token ? { authorization: `Bearer ${token}` } : {}), ...(method === 'POST' ? { 'content-type': 'application/json' } : {}) },
      body: method === 'POST' ? '{}' : undefined,
    });
    return { status: res.status, json: await res.json().catch(() => null) };
  };
}

const refusing = await serve('railway-unconfigured', { railway: 'production' });
const withSecret = await serve('railway-secret', { railway: 'production', secret: SECRET });
// An unreachable project address: the key-set fetch fails locally and is only logged.
const withUrl = await serve('railway-url', { railway: 'production', url: 'http://127.0.0.1:9' });

test('on Railway with neither variable set, every data request is refused as a service fault, token or not', async () => {
  for (const [method, path] of DATA) {
    for (const token of [null, TOKEN]) {
      const r = await refusing(method, path, token);
      assert.equal(r.status, 503, `${method} ${path}`);
      assert.equal(r.json.error, UNCONFIGURED);
    }
  }
  assert.equal((await refusing('GET', '/api/not-a-route')).status, 503);
});

test('on Railway with neither variable set, /api/health stays open, keeps its fields and says refusing', async () => {
  const r = await refusing('GET', '/api/health');
  assert.notEqual(r.status, 503);
  assert.ok('status' in r.json);
  assert.equal(r.json.auth, 'refusing');
});

test('on Railway with either variable set, sign-in is enforced as now', async () => {
  for (const [method, path] of DATA) {
    assert.equal((await withSecret(method, path)).status, 401, `${method} ${path} (secret)`);
    assert.equal((await withUrl(method, path)).status, 401, `${method} ${path} (url)`);
    assert.notEqual((await withSecret(method, path, TOKEN)).status, 401, `${method} ${path} (signed in)`);
  }
  assert.equal((await withSecret('GET', '/api/health')).json.auth, 'enforced');
  assert.equal((await withUrl('GET', '/api/health')).json.auth, 'enforced');
});
