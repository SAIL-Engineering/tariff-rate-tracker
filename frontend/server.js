// =============================================================================
// Tariff Rate API Server
// =============================================================================
//
// Lightweight Express server backed by DuckDB for querying the Parquet dataset.
// DuckDB ingests the partitioned Parquet files at startup and maintains an
// in-memory catalog for sub-millisecond query execution.
//
// Endpoints:
//   GET /api/rates?hts10=...&country=...        — product-level rate lookup (JSON)
//   GET /api/rates/arrow?hts10=...&country=... — rate lookup (Arrow IPC stream)
//   GET /api/products?q=...                     — HTS code search/autocomplete
//   GET /api/health                             — health check
//
// Usage:
//   node server.js
// =============================================================================

import express from 'express';
import { DuckDBInstance } from '@duckdb/node-api';
import path from 'path';
import fs from 'fs';
import { fileURLToPath } from 'url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const PARQUET_PATH = path.resolve(__dirname, '..', 'data', 'timeseries', 'rate_timeseries_parquet');
const HTS_ARCHIVES_PATH = path.resolve(__dirname, '..', 'data', 'hts_archives');
const PORT = process.env.API_PORT || 3001;

let connection;

// DuckDB DATE type comes back as { days: N } (epoch days since 1970-01-01).
// Convert to ISO date strings for JSON serialization.
const EPOCH = new Date('1970-01-01T00:00:00Z');
function duckdbDateToString(val) {
  if (val && typeof val === 'object' && 'days' in val) {
    const ms = Number(val.days) * 86400000;
    return new Date(EPOCH.getTime() + ms).toISOString().slice(0, 10);
  }
  return val;
}

function cleanRow(row) {
  const out = {};
  for (const [k, v] of Object.entries(row)) {
    if (typeof v === 'bigint') {
      out[k] = Number(v);
    } else if (v instanceof Date) {
      out[k] = v.toISOString().slice(0, 10);
    } else if (v && typeof v === 'object' && 'days' in v) {
      out[k] = duckdbDateToString(v);
    } else {
      out[k] = v;
    }
  }
  return out;
}

async function initDatabase() {
  const instance = await DuckDBInstance.create();
  connection = await instance.connect();

  // Create a view over the partitioned Parquet dataset.
  // DuckDB scans metadata once and builds an internal catalog in memory.
  // Filter out legacy short-format revisions (e.g. 'rev_2') that duplicate
  // the canonical year-prefixed revisions (e.g. '2025_rev_2').
  await connection.run(`
    CREATE VIEW rates AS
    SELECT * FROM read_parquet('${PARQUET_PATH}/*/*.parquet', hive_partitioning = true)
    WHERE revision LIKE '20%'
  `);

  // Warm the catalog — forces DuckDB to read Parquet metadata (row group stats)
  const reader = await connection.runAndReadAll(`
    SELECT
      count(DISTINCT hts10) AS n_products,
      count(DISTINCT country) AS n_countries,
      count(DISTINCT revision) AS n_revisions,
      count(*) AS n_rows
    FROM rates
  `);
  const stats = reader.getRowObjects()[0];
  console.log('DuckDB catalog ready:', stats);
  return stats;
}

const app = express();

// --- Rate lookup endpoint ---
// Returns all revision periods for an HTS code + country pair.
// Supports exact match and 8-digit prefix fallback.
app.get('/api/rates', async (req, res) => {
  try {
    const { hts10, country, revision, date } = req.query;

    if (!hts10 || String(hts10).replace(/\./g, '').length < 4) {
      return res.status(400).json({ error: 'hts10 parameter required (min 4 digits)' });
    }

    const cleanCode = String(hts10).replace(/\./g, '');

    // Build query with string interpolation (DuckDB parameterized queries
    // use $name syntax; we sanitize inputs to digits-only for safety)
    if (!/^\d{4,10}$/.test(cleanCode)) {
      return res.status(400).json({ error: 'hts10 must contain only digits (4-10)' });
    }
    if (country && !/^\d{1,6}$/.test(String(country))) {
      return res.status(400).json({ error: 'country must be a Census code (digits only)' });
    }

    let whereParts = [];

    // HTS code: exact match for 10-digit, prefix for shorter
    if (cleanCode.length === 10) {
      whereParts.push(`hts10 = '${cleanCode}'`);
    } else {
      whereParts.push(`hts10 LIKE '${cleanCode}%'`);
    }

    if (country) {
      whereParts.push(`country = '${String(country)}'`);
    }
    if (revision) {
      whereParts.push(`revision = '${String(revision)}'`);
    }
    if (date && /^\d{4}-\d{2}-\d{2}$/.test(String(date))) {
      whereParts.push(`valid_from <= '${date}' AND valid_until >= '${date}'`);
    }

    const sql = `
      SELECT *
      FROM rates
      WHERE ${whereParts.join(' AND ')}
      ORDER BY effective_date ASC
      LIMIT 10000
    `;

    const reader = await connection.runAndReadAll(sql);
    let rows = reader.getRowObjects();

    // Convert DuckDB types for JSON serialization
    rows = rows.map(cleanRow);

    // If exact 10-digit match returned nothing, try 8-digit prefix fallback
    if (rows.length === 0 && cleanCode.length === 10) {
      const prefix8 = cleanCode.substring(0, 8);
      const fallbackSql = `
        SELECT *
        FROM rates
        WHERE hts10 LIKE '${prefix8}%'
          ${country ? `AND country = '${String(country)}'` : ''}
        ORDER BY effective_date ASC
        LIMIT 10000
      `;
      const fbReader = await connection.runAndReadAll(fallbackSql);
      let fbRows = fbReader.getRowObjects().map(cleanRow);
      return res.json({ data: fbRows, match: 'prefix', query: { hts10: cleanCode, country } });
    }

    res.json({ data: rows, match: 'exact', query: { hts10: cleanCode, country } });
  } catch (err) {
    console.error('Rate lookup error:', err);
    res.status(500).json({ error: 'Internal server error', detail: err.message });
  }
});

// --- Arrow IPC streaming endpoint ---
// Returns query results as Arrow IPC stream for zero-copy deserialization.
// Ideal for large result sets (multi-country comparisons, chart data).
// Uses apache-arrow JS to serialize DuckDB rows into Arrow IPC format.
app.get('/api/rates/arrow', async (req, res) => {
  try {
    const { hts10, country, revision, date } = req.query;

    if (!hts10 || String(hts10).replace(/\./g, '').length < 4) {
      return res.status(400).json({ error: 'hts10 parameter required (min 4 digits)' });
    }

    const cleanCode = String(hts10).replace(/\./g, '');
    if (!/^\d{4,10}$/.test(cleanCode)) {
      return res.status(400).json({ error: 'hts10 must contain only digits (4-10)' });
    }

    // country can be a comma-separated list for multi-country queries
    const countryCodes = country
      ? String(country).split(',').map(c => c.trim()).filter(c => /^\d{1,6}$/.test(c))
      : [];

    let whereParts = [];
    if (cleanCode.length === 10) {
      whereParts.push(`hts10 = '${cleanCode}'`);
    } else {
      whereParts.push(`hts10 LIKE '${cleanCode}%'`);
    }
    if (countryCodes.length === 1) {
      whereParts.push(`country = '${countryCodes[0]}'`);
    } else if (countryCodes.length > 1) {
      whereParts.push(`country IN (${countryCodes.map(c => `'${c}'`).join(',')})`);
    }
    if (revision) {
      whereParts.push(`revision = '${String(revision)}'`);
    }
    if (date && /^\d{4}-\d{2}-\d{2}$/.test(String(date))) {
      whereParts.push(`valid_from <= '${date}' AND valid_until >= '${date}'`);
    }

    const sql = `
      SELECT *
      FROM rates
      WHERE ${whereParts.join(' AND ')}
      ORDER BY country, effective_date ASC
    `;

    const reader = await connection.runAndReadAll(sql);
    const rows = reader.getRowObjects().map(cleanRow);

    // Build Arrow IPC buffer using apache-arrow
    const arrow = await import('apache-arrow');

    if (rows.length === 0) {
      res.setHeader('Content-Type', 'application/vnd.apache.arrow.stream');
      res.send(Buffer.alloc(0));
      return;
    }

    // Build column arrays keyed by name — tableFromArrays infers types
    const columnData = {};
    const keys = Object.keys(rows[0]);
    for (const k of keys) {
      const vals = rows.map(r => r[k]);
      const sample = rows[0][k];
      if (typeof sample === 'number') {
        columnData[k] = new Float64Array(vals.map(v => v == null ? 0 : Number(v)));
      } else if (typeof sample === 'boolean') {
        columnData[k] = vals.map(v => Boolean(v));
      } else {
        columnData[k] = vals.map(v => v == null ? '' : String(v));
      }
    }

    const table = arrow.tableFromArrays(columnData);
    const ipcBytes = arrow.tableToIPC(table, 'stream');

    res.setHeader('Content-Type', 'application/vnd.apache.arrow.stream');
    res.setHeader('Content-Length', ipcBytes.byteLength);
    res.setHeader('Access-Control-Expose-Headers', 'Content-Length');
    res.send(Buffer.from(ipcBytes));
  } catch (err) {
    console.error('Arrow endpoint error:', err);
    if (!res.headersSent) {
      res.status(500).json({ error: 'Internal server error', detail: err.message });
    }
  }
});

// --- Product search/autocomplete endpoint ---
app.get('/api/products', async (req, res) => {
  try {
    const { q } = req.query;
    if (!q || String(q).length < 2) {
      return res.status(400).json({ error: 'q parameter required (min 2 chars)' });
    }

    const prefix = String(q).replace(/\./g, '');
    if (!/^\d{2,10}$/.test(prefix)) {
      return res.status(400).json({ error: 'q must contain only digits' });
    }

    const sql = `
      SELECT DISTINCT hts10
      FROM rates
      WHERE hts10 LIKE '${prefix}%'
      ORDER BY hts10
      LIMIT 50
    `;
    const reader = await connection.runAndReadAll(sql);
    const rows = reader.getRowObjects();
    res.json({ data: rows.map(r => r.hts10) });
  } catch (err) {
    console.error('Product search error:', err);
    res.status(500).json({ error: 'Internal server error' });
  }
});

// --- HTS product description index ---
// Loaded once at startup from the latest HTS JSON archive.
// Maps each 10-digit htsno (digits only) to its hierarchical description chain.
let htsDescriptionIndex = new Map(); // hts10 → { hts10, descriptions: [{level, htsno, description}], fullDescription }

function buildHtsDescriptionIndex() {
  // Find the latest HTS archive file
  const files = fs.readdirSync(HTS_ARCHIVES_PATH)
    .filter(f => f.startsWith('hts_') && f.endsWith('.json'))
    .sort()
    .reverse();

  if (files.length === 0) {
    console.warn('No HTS archive files found — product descriptions unavailable');
    return;
  }

  const latestFile = files[0];
  console.log(`Loading HTS descriptions from ${latestFile}...`);
  const data = JSON.parse(fs.readFileSync(path.join(HTS_ARCHIVES_PATH, latestFile), 'utf-8'));

  // Build index: for each item with a non-empty htsno, walk backwards to collect
  // ancestor descriptions at each indent level (chapter → heading → subheading → suffix)
  const LEVEL_NAMES = ['Chapter', 'Heading', 'Subheading', 'Stat. Suffix', 'Stat. Suffix', 'Stat. Suffix'];

  for (let i = 0; i < data.length; i++) {
    const item = data[i];
    const rawCode = (item.htsno || '').replace(/\./g, '');
    if (!rawCode || rawCode.length < 4) continue;

    // Collect this item's description
    const descriptions = [];
    const thisIndent = Number(item.indent) || 0;

    // Walk backwards to find ancestor at each indent level
    const seenIndents = new Set();
    for (let j = i; j >= 0; j--) {
      const ancestor = data[j];
      const aIndent = Number(ancestor.indent) || 0;

      // Only collect each indent level once (the nearest ancestor)
      if (aIndent <= thisIndent && !seenIndents.has(aIndent)) {
        seenIndents.add(aIndent);
        if (ancestor.description) {
          descriptions.unshift({
            level: LEVEL_NAMES[aIndent] || `Level ${aIndent}`,
            htsno: ancestor.htsno || '',
            description: ancestor.description.replace(/:$/, '').trim(),
          });
        }
      }

      // Stop once we've found indent 0 (chapter level)
      if (aIndent === 0) break;
    }

    // Build the full concatenated description
    const fullDescription = descriptions.map(d => d.description).join(' > ');

    htsDescriptionIndex.set(rawCode, {
      hts10: rawCode,
      descriptions,
      fullDescription,
    });
  }

  console.log(`  Indexed ${htsDescriptionIndex.size} HTS descriptions`);
}

// --- Product info endpoint ---
// Returns hierarchical description for an HTS code.
app.get('/api/product-info', (req, res) => {
  const { hts10 } = req.query;
  if (!hts10) {
    return res.status(400).json({ error: 'hts10 parameter required' });
  }

  const cleanCode = String(hts10).replace(/\./g, '');
  if (!/^\d{4,10}$/.test(cleanCode)) {
    return res.status(400).json({ error: 'hts10 must contain only digits (4-10)' });
  }

  // Exact match
  let info = htsDescriptionIndex.get(cleanCode);

  // Prefix fallback — try progressively shorter codes
  if (!info) {
    for (let len = cleanCode.length - 1; len >= 4; len--) {
      const prefix = cleanCode.substring(0, len);
      info = htsDescriptionIndex.get(prefix);
      if (info) break;
    }
  }

  if (info) {
    res.json({ data: info, match: cleanCode.length === info.hts10.length ? 'exact' : 'prefix' });
  } else {
    res.json({ data: null, match: 'none' });
  }
});

// --- Health check ---
app.get('/api/health', async (_req, res) => {
  try {
    const reader = await connection.runAndReadAll('SELECT count(*) as n FROM rates');
    const result = reader.getRowObjects()[0];
    res.json({ status: 'ok', rows: Number(result.n) });
  } catch (err) {
    res.status(500).json({ status: 'error', message: err.message });
  }
});

// --- Start ---
async function start() {
  console.log('Initializing DuckDB with Parquet dataset...');
  console.log('Parquet path:', PARQUET_PATH);
  const stats = await initDatabase();
  buildHtsDescriptionIndex();
  app.listen(PORT, () => {
    console.log(`API server listening on http://localhost:${PORT}`);
    console.log(`  ${stats.n_products} products, ${stats.n_countries} countries, ${stats.n_revisions} revisions`);
  });
}

start().catch(err => {
  console.error('Failed to start API server:', err);
  process.exit(1);
});
