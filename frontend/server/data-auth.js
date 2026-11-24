// Every data endpoint answers only a signed-in request (WJR 2026-11-23).
//
// Mounted once, ahead of every route and the body parser, so no endpoint can be
// added open by mistake and a request without a sign-in is refused before its
// body is read. Only the paths in OPEN_PATHS answer without one: /api/health,
// Railway's deploy check, which cannot sign in and shows only a row count.
//
// A CORS preflight (OPTIONS) never carries the token; the cors middleware ahead
// of this answers it, and one that reaches here is let through to Express's own
// OPTIONS reply, which holds no data.

export const OPEN_PATHS = Object.freeze(['/api/health']);

/** Middleware over `requireAuth` (createRequireSupabaseAuth) for every path but OPEN_PATHS. */
export function createRequireSignInForData(requireAuth, { openPaths = OPEN_PATHS } = {}) {
  const open = new Set(openPaths);
  return function requireSignInForData(req, res, next) {
    if (req.method === 'OPTIONS') return next();
    if ((req.method === 'GET' || req.method === 'HEAD') && open.has(req.path)) return next();
    return requireAuth(req, res, next);
  };
}

// On Railway nothing may answer without a sign-in (WJR 2026-11-23). With neither
// SUPABASE_JWT_SECRET nor SUPABASE_URL set there, nothing can be verified, so
// every data request is refused as a service fault (503), never served open.
// Off Railway, unconfigured stays open for local development.
export const UNCONFIGURED_WORDS = "Rates are unavailable: the service's sign-in is not configured.";

/** True on a Railway deployment (Railway sets these on every service). */
export function onRailway(env = process.env) {
  return Boolean(env.RAILWAY_ENVIRONMENT || env.RAILWAY_ENVIRONMENT_NAME);
}

/**
 * The sign-in mode /api/health reports: 'enforced' (a variable is set), 'refusing' (on Railway with neither set:
 * every data request answers 503) or 'open' (off Railway with neither set: local development).
 */
export function signInMode(verifier, env = process.env) {
  if (verifier.enforced) return 'enforced';
  return onRailway(env) ? 'refusing' : 'open';
}

/** The check every data route uses in 'refusing' mode. */
export function refuseUnconfigured(_req, res) {
  res.status(503).json({ error: UNCONFIGURED_WORDS });
}
