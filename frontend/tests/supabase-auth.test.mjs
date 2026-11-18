import test from 'node:test';
import assert from 'node:assert/strict';
import crypto from 'crypto';
import { createSupabaseVerifier, supabaseAuthUrls, verifyHs256 } from '../server/supabase-auth.js';

const SUPABASE_URL = 'https://example-project.supabase.co';
const ISSUER = `${SUPABASE_URL}/auth/v1`;
const SECRET = 'test-legacy-secret-not-real';
const NOW = 1_800_000_000_000;
const now = () => NOW;

const b64url = (buf) => Buffer.from(buf).toString('base64').replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
const seg = (obj) => b64url(JSON.stringify(obj));
const claims = (extra = {}) => ({ sub: 'user-1', iss: ISSUER, exp: NOW / 1000 + 600, role: 'authenticated', ...extra });

function signHs256(payload, secret = SECRET, header = { alg: 'HS256', typ: 'JWT' }) {
  const head = `${seg(header)}.${seg(payload)}`;
  return `${head}.${b64url(crypto.createHmac('sha256', secret).update(head).digest())}`;
}

function signAsym(payload, { alg, kid, privateKey }) {
  const head = `${seg({ alg, kid, typ: 'JWT' })}.${seg(payload)}`;
  const sig = alg === 'ES256'
    ? crypto.sign('sha256', Buffer.from(head), { key: privateKey, dsaEncoding: 'ieee-p1363' })
    : crypto.sign('sha256', Buffer.from(head), privateKey);
  return `${head}.${b64url(sig)}`;
}

function keyPair(alg, kid) {
  const { publicKey, privateKey } = alg === 'ES256'
    ? crypto.generateKeyPairSync('ec', { namedCurve: 'P-256' })
    : crypto.generateKeyPairSync('rsa', { modulusLength: 2048 });
  return { alg, kid, privateKey, jwk: { ...publicKey.export({ format: 'jwk' }), alg, kid, use: 'sig' } };
}

function jwksFetch(getKeys, calls = []) {
  return async (url) => {
    calls.push(url);
    return { ok: true, status: 200, json: async () => ({ keys: getKeys().map((k) => k.jwk) }) };
  };
}

const es = keyPair('ES256', 'es-key-1');
const rs = keyPair('RS256', 'rs-key-1');

test('the auth URLs come from SUPABASE_URL, https only', () => {
  assert.deepEqual(supabaseAuthUrls(SUPABASE_URL), { issuer: ISSUER, jwksUrl: `${ISSUER}/.well-known/jwks.json` });
  assert.equal(supabaseAuthUrls('http://example-project.supabase.co'), null);
  assert.equal(supabaseAuthUrls(''), null);
  assert.equal(supabaseAuthUrls('not a url'), null);
});

test('HS256 with the legacy secret still verifies, as before', async () => {
  const v = createSupabaseVerifier({ secret: SECRET, now });
  assert.deepEqual(await v.verify(signHs256(claims())), { ok: true, userId: 'user-1' });
  assert.equal((await v.verify(signHs256(claims(), 'other-secret'))).error, 'invalid signature');
  assert.equal((await v.verify(signHs256(claims({ exp: NOW / 1000 - 1 })))).error, 'token expired');
  assert.equal(verifyHs256(signHs256(claims()), SECRET, now).ok, true);
});

test('without SUPABASE_URL an ES256 token is refused, as today', async () => {
  const v = createSupabaseVerifier({ secret: SECRET, now });
  assert.equal(v.enforced, true);
  assert.equal(v.asymmetric, false);
  assert.equal((await v.verify(signAsym(claims(), es))).error, 'unsupported algorithm');
});

test('ES256 and RS256 tokens verify against the project JWKS', async () => {
  const v = createSupabaseVerifier({ secret: SECRET, supabaseUrl: SUPABASE_URL, fetchImpl: jwksFetch(() => [es, rs]), now });
  await v.refresh();
  assert.equal(v.keyCount(), 2);
  assert.deepEqual(await v.verify(signAsym(claims(), es)), { ok: true, userId: 'user-1' });
  assert.deepEqual(await v.verify(signAsym(claims(), rs)), { ok: true, userId: 'user-1' });
  // HS256 keeps working beside them.
  assert.equal((await v.verify(signHs256(claims()))).ok, true);
});

test('a forged, confused, foreign-issuer or expired asymmetric token is refused', async () => {
  const v = createSupabaseVerifier({ supabaseUrl: SUPABASE_URL, fetchImpl: jwksFetch(() => [es, rs]), now });
  await v.refresh();
  const attacker = keyPair('ES256', 'es-key-1'); // same kid, different key
  assert.equal((await v.verify(signAsym(claims(), attacker))).error, 'invalid signature');
  // An RS256 header naming the EC key's kid.
  assert.equal((await v.verify(signAsym(claims(), { ...rs, kid: 'es-key-1' }))).error, 'invalid signature');
  assert.equal((await v.verify(signAsym(claims({ iss: 'https://attacker.supabase.co/auth/v1' }), es))).error, 'wrong issuer');
  assert.equal((await v.verify(signAsym(claims({ exp: NOW / 1000 - 1 }), es))).error, 'token expired');
  // No secret configured: an HS256 token cannot be checked, so it is refused.
  assert.equal((await v.verify(signHs256(claims()))).error, 'unsupported algorithm');
  assert.equal((await v.verify(`${seg({ alg: 'none' })}.${seg(claims())}.`)).error, 'unsupported algorithm');
  assert.equal((await v.verify('not.a.jwt.at.all')).error, 'malformed token');
});

test('a rotated key loads on first sight, once per cooldown', async () => {
  let published = [es];
  const calls = [];
  let t = NOW;
  const v = createSupabaseVerifier({ supabaseUrl: SUPABASE_URL, fetchImpl: jwksFetch(() => published, calls), now: () => t, refreshCooldownMs: 30_000 });
  await v.refresh();
  const next = keyPair('ES256', 'es-key-2');
  t += 31_000;
  // Not yet published: one refresh, then refused.
  assert.equal((await v.verify(signAsym(claims({ exp: t / 1000 + 600 }), next))).error, 'unknown signing key');
  assert.equal(calls.length, 2);
  published = [es, next];
  // Inside the cooldown: no new fetch.
  assert.equal((await v.verify(signAsym(claims({ exp: t / 1000 + 600 }), next))).error, 'unknown signing key');
  assert.equal(calls.length, 2);
  t += 31_000;
  assert.equal((await v.verify(signAsym(claims({ exp: t / 1000 + 600 }), next))).ok, true);
  assert.equal(calls.length, 3);
});

test('a failed JWKS fetch keeps the keys already loaded', async () => {
  let fail = false;
  const errors = [];
  const fetchImpl = async () => (fail ? { ok: false, status: 503, json: async () => ({}) } : { ok: true, status: 200, json: async () => ({ keys: [es.jwk] }) });
  const v = createSupabaseVerifier({ supabaseUrl: SUPABASE_URL, fetchImpl, now, onRefreshError: (e) => errors.push(e.message) });
  await v.refresh();
  fail = true;
  await v.refresh();
  assert.equal(errors.length, 1);
  assert.equal((await v.verify(signAsym(claims(), es))).ok, true);
});

test('nothing configured means nothing enforced', () => {
  assert.equal(createSupabaseVerifier({}).enforced, false);
});

test('the Express middleware lets a verified ES256 or HS256 request through and refuses the rest with 401', async () => {
  const { default: express } = await import('express');
  const { createRequireSupabaseAuth } = await import('../server/supabase-auth.js');
  const v = createSupabaseVerifier({ secret: SECRET, supabaseUrl: SUPABASE_URL, fetchImpl: jwksFetch(() => [es]), now });
  await v.refresh();
  const app = express();
  app.post('/api/rates/batch', createRequireSupabaseAuth(v), (req, res) => res.json({ userId: req.userId }));
  const server = await new Promise((ok) => { const s = app.listen(0, '127.0.0.1', () => ok(s)); });
  const url = `http://127.0.0.1:${server.address().port}/api/rates/batch`;
  const post = async (token) => {
    const r = await fetch(url, { method: 'POST', headers: token ? { authorization: `Bearer ${token}` } : {} });
    return { status: r.status, body: await r.json() };
  };
  try {
    assert.deepEqual(await post(signAsym(claims(), es)), { status: 200, body: { userId: 'user-1' } });
    assert.deepEqual(await post(signHs256(claims())), { status: 200, body: { userId: 'user-1' } });
    assert.equal((await post(null)).status, 401);
    assert.deepEqual(await post(signAsym(claims(), keyPair('ES256', 'es-key-1'))), { status: 401, body: { error: 'Authentication failed: invalid signature.' } });
  } finally {
    server.close();
  }
});

test('the middleware passes everything through when nothing is configured', async () => {
  const { createRequireSupabaseAuth } = await import('../server/supabase-auth.js');
  let passed = false;
  await createRequireSupabaseAuth(createSupabaseVerifier({}))({ headers: {} }, {}, () => { passed = true; });
  assert.equal(passed, true);
});
