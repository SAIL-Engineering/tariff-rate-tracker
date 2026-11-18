// Supabase access token verification for the bulk endpoints.
//
// Supabase signs user access tokens one of two ways:
//   HS256         the project's legacy shared JWT secret (SUPABASE_JWT_SECRET).
//   ES256 / RS256 an asymmetric signing key, whose public half is published at
//                 <SUPABASE_URL>/auth/v1/.well-known/jwks.json.
//
// A project that rotates to an asymmetric signing key starts issuing ES256
// tokens to every user at once, so a verifier that knows only HS256 refuses
// every signed-in request ("unsupported algorithm"). This one accepts both.
//
// Dependency-free (node:crypto). Each algorithm branch pins exactly one key type,
// so `alg: none` and HS/RS key-confusion tokens are refused. An asymmetric token
// is checked against the configured project's JWKS only, never a URL the token
// names, and its issuer must be that project's auth URL.

import crypto from 'crypto';

const ASYMMETRIC = { ES256: 'EC', RS256: 'RSA' };

function b64urlDecode(segment) {
  return Buffer.from(segment.replace(/-/g, '+').replace(/_/g, '/'), 'base64');
}

function decode(token) {
  const parts = typeof token === 'string' ? token.split('.') : [];
  if (parts.length !== 3) return null;
  try {
    return {
      parts,
      header: JSON.parse(b64urlDecode(parts[0]).toString('utf8')),
      payload: JSON.parse(b64urlDecode(parts[1]).toString('utf8')),
    };
  } catch {
    return null;
  }
}

function expired(payload, now) {
  return typeof payload.exp === 'number' && payload.exp * 1000 < now();
}

/** HS256 with the legacy shared secret: signature and expiry. */
export function verifyHs256(token, secret, now = Date.now) {
  const d = decode(token);
  if (!d) return { ok: false, error: 'malformed token' };
  if (d.header.alg !== 'HS256') return { ok: false, error: 'unsupported algorithm' };
  if (!secret) return { ok: false, error: 'unsupported algorithm' };
  const expected = crypto.createHmac('sha256', secret).update(`${d.parts[0]}.${d.parts[1]}`).digest();
  const actual = b64urlDecode(d.parts[2]);
  if (expected.length !== actual.length || !crypto.timingSafeEqual(expected, actual)) {
    return { ok: false, error: 'invalid signature' };
  }
  if (expired(d.payload, now)) return { ok: false, error: 'token expired' };
  return { ok: true, userId: d.payload.sub ?? null };
}

/**
 * The project's auth URLs from SUPABASE_URL (e.g. https://<ref>.supabase.co), or
 * null when it is unset or not an https origin.
 */
export function supabaseAuthUrls(supabaseUrl) {
  if (!supabaseUrl) return null;
  let url;
  try {
    url = new URL(supabaseUrl);
  } catch {
    return null;
  }
  if (url.protocol !== 'https:' && url.hostname !== '127.0.0.1' && url.hostname !== 'localhost') return null;
  const issuer = `${url.origin}/auth/v1`;
  return { issuer, jwksUrl: `${issuer}/.well-known/jwks.json` };
}

/**
 * A verifier for HS256 (when `secret` is set) and ES256 / RS256 (when `supabaseUrl`
 * is set). `verify(token)` is async: a token whose key id is not loaded triggers
 * one throttled JWKS refresh, so a key rotation heals itself.
 */
export function createSupabaseVerifier({
  secret = '',
  supabaseUrl = '',
  fetchImpl = globalThis.fetch,
  now = Date.now,
  refreshCooldownMs = 30_000,
  onRefreshError = () => {},
} = {}) {
  const urls = supabaseAuthUrls(supabaseUrl);
  let keys = new Map(); // kid -> { alg, key }
  let lastRefresh = 0;
  let inflight = null;

  async function refresh() {
    if (!urls) return;
    if (inflight) return inflight;
    lastRefresh = now();
    inflight = (async () => {
      try {
        const res = await fetchImpl(urls.jwksUrl, { headers: { accept: 'application/json' } });
        if (!res.ok) throw new Error(`JWKS fetch failed: HTTP ${res.status}`);
        const body = await res.json();
        const next = new Map();
        for (const jwk of Array.isArray(body?.keys) ? body.keys : []) {
          if (!jwk?.kid || !ASYMMETRIC[jwk.alg] || ASYMMETRIC[jwk.alg] !== jwk.kty) continue;
          if (jwk.use && jwk.use !== 'sig') continue;
          try {
            next.set(jwk.kid, { alg: jwk.alg, key: crypto.createPublicKey({ key: jwk, format: 'jwk' }) });
          } catch {
            // A key node cannot import is skipped; the others still load.
          }
        }
        keys = next; // A failed fetch keeps the previous keys.
      } catch (error) {
        onRefreshError(error);
      } finally {
        inflight = null;
      }
    })();
    return inflight;
  }

  async function verifyAsymmetric(d) {
    if (!urls) return { ok: false, error: 'unsupported algorithm' };
    const kid = d.header.kid;
    if (typeof kid !== 'string' || !kid) return { ok: false, error: 'unknown signing key' };
    if (!keys.has(kid) && now() - lastRefresh >= refreshCooldownMs) await refresh();
    const entry = keys.get(kid);
    if (!entry) return { ok: false, error: 'unknown signing key' };
    if (entry.alg !== d.header.alg) return { ok: false, error: 'invalid signature' };
    const data = Buffer.from(`${d.parts[0]}.${d.parts[1]}`);
    const signature = b64urlDecode(d.parts[2]);
    const valid = entry.alg === 'ES256'
      ? crypto.verify('sha256', data, { key: entry.key, dsaEncoding: 'ieee-p1363' }, signature)
      : crypto.verify('sha256', data, entry.key, signature);
    if (!valid) return { ok: false, error: 'invalid signature' };
    if (d.payload.iss !== urls.issuer) return { ok: false, error: 'wrong issuer' };
    if (expired(d.payload, now)) return { ok: false, error: 'token expired' };
    return { ok: true, userId: d.payload.sub ?? null };
  }

  return {
    /** Whether any verification is configured; unconfigured means no enforcement. */
    enforced: Boolean(secret) || Boolean(urls),
    /** Whether asymmetric tokens can be verified. */
    asymmetric: Boolean(urls),
    refresh,
    keyCount: () => keys.size,
    async verify(token) {
      const d = decode(token);
      if (!d) return { ok: false, error: 'malformed token' };
      if (d.header.alg === 'HS256') return verifyHs256(token, secret, now);
      if (ASYMMETRIC[d.header.alg]) return verifyAsymmetric(d);
      return { ok: false, error: 'unsupported algorithm' };
    },
  };
}

/**
 * Express middleware over a verifier: passes through when nothing is configured,
 * otherwise requires `Authorization: Bearer <token>` that verifies, and sets
 * req.userId.
 */
export function createRequireSupabaseAuth(verifier) {
  return async function requireSupabaseAuth(req, res, next) {
    if (!verifier.enforced) return next(); // enforcement not configured
    const auth = req.headers.authorization || '';
    const token = auth.startsWith('Bearer ') ? auth.slice(7) : null;
    if (!token) {
      return res.status(401).json({
        error:
          'Authentication required: send a Supabase access token as Authorization: Bearer <token>.',
      });
    }
    let result;
    try {
      result = await verifier.verify(token);
    } catch {
      result = { ok: false, error: 'verification failed' };
    }
    if (!result.ok) {
      return res.status(401).json({ error: `Authentication failed: ${result.error}.` });
    }
    req.userId = result.userId;
    return next();
  };
}
