// With neither SUPABASE_JWT_SECRET nor SUPABASE_URL set, nothing can be verified, so nothing is enforced: local
// development runs this server from the repository's .env, which names neither (the dev frontend here, and SAIL's
// `dev:local-duckdb`, call it with no sign-in). Production sets both, so there every data endpoint asks for one
// (data-endpoints-auth.test.mjs). The server says which it is doing when it starts.
import test from 'node:test';
import assert from 'node:assert/strict';

process.env.TARIFF_API_NO_START = '1';
// Set but empty, so a repository .env can never supply them.
process.env.SUPABASE_JWT_SECRET = '';
process.env.SUPABASE_URL = '';
delete process.env.CORS_ALLOWED_ORIGINS;
process.env.DATABASE_TARGET = 'local';

const { app } = await import('../server.js');
const server = await new Promise((ok) => { const s = app.listen(0, '127.0.0.1', () => ok(s)); });
const base = `http://127.0.0.1:${server.address().port}`;
test.after(() => server.close());

test('unconfigured (local development): a data endpoint answers without a sign-in, as before', async () => {
  const info = await fetch(`${base}/api/product-info?hts10=0101210000`);
  assert.equal(info.status, 200);
  const rates = await fetch(`${base}/api/rates`);
  assert.equal(rates.status, 400); // the handler's own input check, not a refusal
});
