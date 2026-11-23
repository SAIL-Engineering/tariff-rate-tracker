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
