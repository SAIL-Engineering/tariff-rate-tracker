// Backend runtime config.
//
// Reads environment, validates, and fails fast with actionable errors when
// MotherDuck mode lacks a token. Imported by both server.js and the sync CLI.

function normalizeTarget(raw) {
  const v = String(raw || 'local').trim().toLowerCase();
  if (v !== 'local' && v !== 'motherduck') {
    throw new Error(
      `Invalid DATABASE_TARGET="${raw}". Expected "local" or "motherduck".`,
    );
  }
  return v;
}

function parseOrigins(raw) {
  if (!raw) return [];
  return String(raw)
    .split(',')
    .map((s) => s.trim())
    .filter(Boolean);
}

export function getConfig() {
  const target = normalizeTarget(process.env.DATABASE_TARGET);
  const motherduckToken = process.env.MOTHERDUCK_TOKEN || '';
  const motherduckDb = process.env.MOTHERDUCK_DATABASE || 'duty_calculator';
  const corsAllowedOrigins = parseOrigins(process.env.CORS_ALLOWED_ORIGINS);

  if (target === 'motherduck' && !motherduckToken) {
    throw new Error(
      'DATABASE_TARGET=motherduck requires MOTHERDUCK_TOKEN. ' +
        'Set it in .env (local) or Railway env vars (deploy).',
    );
  }

  return { target, motherduckToken, motherduckDb, corsAllowedOrigins };
}
