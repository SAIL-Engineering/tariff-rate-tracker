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
//   POST /api/rates/batch { keys: [{hts10,country,date}] } — bulk rate lookup (Arrow)
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

// Column 2 Census codes (Cuba, North Korea, Belarus, Russia). Mirrors
// COLUMN2_COUNTRY_CODES in frontend/src/types/tariff.ts. For these countries,
// base-MFN synthesis uses rate_column2 instead of base_rate.
const COLUMN2_CENSUS_CODES = new Set(['2390', '4622', '4621', '5790']);

// =============================================================================
// Phase 2.5c — Phase 3 scaffolding (feature-flagged OFF by default)
// =============================================================================
//
// These three knobs exist so Phase 3 can land behind a flag without needing
// a second deployment. Until both flags are flipped on explicitly, the
// scaffolding has zero runtime effect — `gapfillFromNormalized()` returns
// `null`, the shadow logger short-circuits, and every endpoint still uses
// the Phase 1 synthesis path.
//
// See docs/adrs/001-denorm-state-pattern.md for why the normalized layers
// can cleanly answer "no row in rates" queries without any heuristic
// once Phase 3 is green.
//
// Flags:
//   USE_NORMALIZED_GAPFILL   — when 'true', route the Phase 1 synthesis
//                              fallback through gapfillFromNormalized()
//                              first, falling back to the existing
//                              synthesizeBaseMfnRow() on null. Default off.
//   SHADOW_LOG_NORMALIZED    — when '1', run BOTH the normalized path and
//                              the Phase 1 synthesis path for every
//                              gapfill, and log any diff to
//                              output/shadow-normalized.ndjson. Used in
//                              staging to prove zero-diff before flipping
//                              USE_NORMALIZED_GAPFILL in production.
//                              Has no effect when USE_NORMALIZED_GAPFILL
//                              is already 'true' (no diff to check).
const USE_NORMALIZED_GAPFILL = String(process.env.USE_NORMALIZED_GAPFILL || '').toLowerCase() === 'true';
const SHADOW_LOG_NORMALIZED = process.env.SHADOW_LOG_NORMALIZED === '1';
const NORMALIZED_DIR = path.resolve(__dirname, '..', 'output', 'normalized');
const SHADOW_LOG_PATH = path.resolve(__dirname, '..', 'output', 'shadow-normalized.ndjson');

/**
 * Stub for the Phase 3 normalized-layer gapfill path.
 *
 * When Phase 3 lands, this reads:
 *   - output/normalized/{revision}/products_base.parquet  → base_rate / Column 2 fields
 *   - output/normalized/{revision}/authority_exemptions.parquet → USMCA shares for CA/MX
 *   - output/normalized/mfn_exemption_shares.parquet       → FTA/GSP shares for non-CA/MX
 * and constructs a ProductRate row with every rate_* = 0 (there's no layer-2/3
 * content for this (product, country, revision), so no authority applies).
 *
 * Until Phase 3 wires it up this function returns `null`, signalling "no
 * normalized answer — fall through to the Phase 1 synthesis path." That
 * keeps the shadow logger inert and the feature flag a no-op.
 *
 * @param {string} hts10
 * @param {string} country
 * @param {string} revision
 * @returns {Promise<object|null>}
 */
async function gapfillFromNormalized(hts10, country, revision) {
  // Placeholder. Phase 3b implements the three parquet reads + the
  // MFN/USMCA share application. For now: fail open, letting the
  // Phase 1 synthesis path answer.
  return null;
}

/**
 * Shadow logger — compares the normalized path against the Phase 1
 * synthesis path and writes a diff record to
 * output/shadow-normalized.ndjson whenever they disagree. Called from
 * every gapfill site when SHADOW_LOG_NORMALIZED is on.
 *
 * Does not throw — logging failures are silenced so shadow comparison
 * can never affect the main response path.
 *
 * @param {object} ctx         Context for the log line (endpoint, keys)
 * @param {object|null} synthesized  Row from Phase 1 synthesis
 * @param {object|null} normalized   Row from normalized gapfill
 */
function logShadowDiff(ctx, synthesized, normalized) {
  if (!SHADOW_LOG_NORMALIZED) return;
  // A null normalized result means "no normalized answer available" —
  // during Phase 2.5c the stub always returns null, so we skip the
  // comparison entirely. Phase 3b wires a real implementation and this
  // guard stops firing. Never treat null-normalized as a diff against
  // a synthesized row, or we'd log a diff on every request.
  if (normalized == null) return;
  try {
    // Compare the fields we actually care about for duty calculation.
    // Everything else is metadata / provenance and doesn't affect the
    // user-visible duty total.
    const COMPARE_FIELDS = [
      'base_rate',
      'statutory_base_rate',
      'rate_232',
      'rate_301',
      'rate_ieepa_recip',
      'rate_ieepa_fent',
      'rate_s122',
      'rate_section_201',
      'rate_other',
      'total_additional',
      'total_rate',
    ];
    const diffs = [];
    if (synthesized == null) {
      diffs.push({ field: '__presence__', synthesized: null, normalized: 'row' });
    } else {
      for (const f of COMPARE_FIELDS) {
        const a = synthesized[f];
        const b = normalized[f];
        if (a !== b && !(a == null && b == null)) {
          diffs.push({ field: f, synthesized: a, normalized: b });
        }
      }
    }
    if (diffs.length === 0) return; // clean, nothing to log
    const line = JSON.stringify({
      ts: new Date().toISOString(),
      ctx,
      diffs,
    }) + '\n';
    fs.appendFileSync(SHADOW_LOG_PATH, line);
  } catch {
    // silent — shadow logging is best-effort observability, never a
    // reason to fail an API request
  }
}

// =============================================================================
// End Phase 2.5c scaffolding
// =============================================================================

// Phase 1 stopgap — Synthesize base-MFN-only ProductRate rows for (hts10,
// country, revision) tuples that have no row in the rates parquet. This
// exists because src/06_calculate_rates.R only seeds (hts10, country) pairs
// that attract an additional duty; non-IEEPA-listed countries (CZ, most of
// the world) have no rows in early-2025 revisions even though base MFN
// legally applies.
//
// REMOVE after Phase 2 schema normalization cutover — at that point absence
// of an authority_product_applicability row is itself the legal answer and
// this heuristic becomes unnecessary.
function buildSynthesizedRow(base, country) {
  const isCol2 = COLUMN2_CENSUS_CODES.has(String(country));
  // Use statutory_base_rate as the MFN source — it's the HTSUS Column 1
  // General rate and is genuinely per-product (unlike base_rate, which the
  // pipeline adjusts per HS2 × country via FTA/GSP preference shares). For
  // a country with no preference claim, statutory_base_rate is exactly what
  // CBP would assess, which matches broker-variance expectations.
  const mfn = isCol2
    ? (base.rate_column2 ?? base.statutory_base_rate ?? base.base_rate ?? 0)
    : (base.statutory_base_rate ?? base.base_rate ?? 0);
  return {
    ...base,
    country: String(country),
    base_rate: mfn,
    statutory_base_rate: base.statutory_base_rate ?? mfn,
    rate_232: 0, rate_301: 0, rate_ieepa_recip: 0, rate_ieepa_fent: 0,
    rate_s122: 0, rate_section_201: 0, rate_other: 0,
    statutory_rate_232: 0, statutory_rate_301: 0,
    statutory_rate_ieepa_recip: 0, statutory_rate_ieepa_fent: 0,
    statutory_rate_s122: 0, statutory_rate_section_201: 0, statutory_rate_other: 0,
    ch99_code_232: null, ch99_code_301: null, ch99_code_ieepa_recip: null,
    ch99_code_ieepa_fent: null, ch99_code_s122: null, ch99_code_s201: null,
    metal_share: 1.0, steel_share: 0, aluminum_share: 0,
    copper_share: 0, other_metal_share: 0,
    is_copper_heading: false, deriv_type: null, s232_annex: null,
    total_additional: 0, total_rate: mfn,
    usmca_eligible: false,
    // Mark every synthesized row explicitly so the frontend can show the
    // "MFN only" caption even when mixed with real rows in the history.
    __synthesized: true,
  };
}

// Returns a single synthesized row covering the revision active on `date`
// (used for the point-lookup synthesis path).
async function synthesizeBaseMfnRow(hts10, country, date) {
  if (!date || !/^\d{4}-\d{2}-\d{2}$/.test(String(date))) return null;
  if (!country || !/^\d{1,6}$/.test(String(country))) return null;
  const sql = `
    SELECT * FROM product_base_rates
    WHERE hts10 = '${hts10}'
      AND valid_from <= '${date}' AND valid_until >= '${date}'
    LIMIT 1
  `;
  const reader = await connection.runAndReadAll(sql);
  const rows = reader.getRowObjects().map(cleanRow);
  if (rows.length === 0) return null;
  return buildSynthesizedRow(rows[0], country);
}

// Fills gaps in a history-style response: for every revision where the
// (hts10, country) has no row but product_base_rates does, emit a synthetic
// base-MFN row. Returns a new array containing the original rows plus any
// synthetic fillers, sorted by effective_date.
async function fillHistoryGaps(existingRows, hts10, country) {
  if (!country || !/^\d{1,6}$/.test(String(country))) return existingRows;
  if (!hts10 || !/^\d{10}$/.test(String(hts10))) return existingRows;
  const sql = `
    SELECT * FROM product_base_rates
    WHERE hts10 = '${hts10}'
    ORDER BY valid_from ASC
  `;
  const reader = await connection.runAndReadAll(sql);
  const allBase = reader.getRowObjects().map(cleanRow);
  if (allBase.length === 0) return existingRows;
  const coveredRevisions = new Set(existingRows.map((r) => r.revision));
  const fillers = [];
  for (const base of allBase) {
    if (coveredRevisions.has(base.revision)) continue;
    fillers.push(buildSynthesizedRow(base, country));
  }
  if (fillers.length === 0) return existingRows;
  return [...existingRows, ...fillers].sort((a, b) =>
    String(a.effective_date).localeCompare(String(b.effective_date)),
  );
}

// Multi-hts10 gap-fill: groups `existingRows` by hts10 and applies
// fillHistoryGaps() per group. Any hts10 not represented in existingRows
// at all is NOT synthesized — we only gap-fill revisions of products that
// the caller's query has already surfaced. For 4-9 digit prefix queries
// this is the correct behavior: the caller is asking about products matching
// the prefix, not about every possible 10-digit code under the prefix.
// Returns a new array sorted by (hts10, effective_date).
async function fillHistoryGapsMulti(existingRows, country) {
  if (!country || !/^\d{1,6}$/.test(String(country))) return existingRows;
  const byHts = new Map();
  for (const r of existingRows) {
    if (!r.hts10 || !/^\d{10}$/.test(String(r.hts10))) continue;
    if (!byHts.has(r.hts10)) byHts.set(r.hts10, []);
    byHts.get(r.hts10).push(r);
  }
  const out = [];
  for (const [hts, rs] of byHts.entries()) {
    const filled = await fillHistoryGaps(rs, hts, country);
    out.push(...filled);
  }
  out.sort((a, b) =>
    String(a.hts10).localeCompare(String(b.hts10)) ||
    String(a.effective_date).localeCompare(String(b.effective_date)),
  );
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

  // Phase 1 stopgap view — one row per (hts10, revision) carrying the
  // per-product rate-tier fields (base MFN, Column 2, special, rate_basis,
  // specific-rate metadata). Used by synthesizeBaseMfnRow() to answer
  // "no row in rates" queries with a legally-correct base-MFN-only row.
  // ANY_VALUE is safe because these fields are per-product, not per-country.
  await connection.run(`
    CREATE VIEW product_base_rates AS
    SELECT
      hts10, revision,
      ANY_VALUE(base_rate)             AS base_rate,
      ANY_VALUE(statutory_base_rate)   AS statutory_base_rate,
      ANY_VALUE(rate_column2)          AS rate_column2,
      ANY_VALUE(rate_column2_raw)      AS rate_column2_raw,
      ANY_VALUE(rate_special)          AS rate_special,
      ANY_VALUE(rate_special_raw)      AS rate_special_raw,
      ANY_VALUE(special_programs_json) AS special_programs_json,
      ANY_VALUE(rate_basis)            AS rate_basis,
      ANY_VALUE(specific_amount)       AS specific_amount,
      ANY_VALUE(specific_rate_unit)    AS specific_rate_unit,
      ANY_VALUE(reported_unit_1)       AS reported_unit_1,
      ANY_VALUE(reported_unit_2)       AS reported_unit_2,
      ANY_VALUE(duty_basis_unit)       AS duty_basis_unit,
      ANY_VALUE(is_qty_duty_relevant)  AS is_qty_duty_relevant,
      ANY_VALUE(quantity_source)       AS quantity_source,
      ANY_VALUE(rounding_rule)         AS rounding_rule,
      ANY_VALUE(calc_status)           AS calc_status,
      ANY_VALUE(effective_date)        AS effective_date,
      MIN(valid_from)                  AS valid_from,
      MAX(valid_until)                 AS valid_until
    FROM rates
    GROUP BY hts10, revision
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

  // Warm the base-rate view so its GROUP BY is compiled once at startup.
  await connection.runAndReadAll('SELECT count(*) FROM product_base_rates');

  console.log('DuckDB catalog ready:', stats);
  return stats;
}

const app = express();
app.use(express.json({ limit: '8mb' }));

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
      if (fbRows.length > 0) {
        // Phase 1: gap-fill per distinct hts10 in the prefix result set.
        if (country) {
          fbRows = await fillHistoryGapsMulti(fbRows, String(country));
        }
        return res.json({
          data: fbRows,
          match: 'prefix',
          query: { hts10: cleanCode, country },
        });
      }
      // Phase 1 stopgap — fall through to base-MFN synthesis below
    }

    // Phase 1 stopgap: if we have real rows but missed revisions for this
    // country, fill the gaps with synthesized base-MFN rows so the
    // frontend's findRateForDate() can answer any date. Applies to both
    // exact 10-digit queries (single hts10) and short-prefix queries that
    // matched multiple 10-digit products.
    let synthesized = 0;
    if (rows.length > 0 && country) {
      const before = rows.length;
      if (cleanCode.length === 10) {
        rows = await fillHistoryGaps(rows, cleanCode, String(country));
      } else {
        rows = await fillHistoryGapsMulti(rows, String(country));
      }
      synthesized = rows.length - before;
    }

    // Phase 1 stopgap: if still zero rows and we have a country, synthesize
    // full history from product_base_rates (one row per revision that has
    // this product). For a 10-digit query, synthesize the specific hts10.
    // For a short-prefix query with zero results, look up all hts10s
    // matching the prefix in product_base_rates and synthesize each.
    if (rows.length === 0 && country) {
      if (cleanCode.length === 10) {
        rows = await fillHistoryGaps([], cleanCode, String(country));
      } else {
        // Short-prefix path: enumerate distinct hts10s under the prefix
        // in product_base_rates, synthesize each.
        const prefixSql = `
          SELECT DISTINCT hts10 FROM product_base_rates
          WHERE hts10 LIKE '${cleanCode}%'
          LIMIT 500
        `;
        const pReader = await connection.runAndReadAll(prefixSql);
        const hts10s = pReader.getRowObjects().map((r) => String(r.hts10));
        const collected = [];
        for (const h of hts10s) {
          const filled = await fillHistoryGaps([], h, String(country));
          collected.push(...filled);
        }
        collected.sort((a, b) =>
          String(a.hts10).localeCompare(String(b.hts10)) ||
          String(a.effective_date).localeCompare(String(b.effective_date)),
        );
        rows = collected;
      }
      if (rows.length > 0) {
        return res.json({
          data: rows,
          match: 'base_mfn_synthesized',
          query: { hts10: cleanCode, country },
        });
      }
      // Last resort: single-date synthesis when product_base_rates itself
      // has no revision covering the requested date (very rare).
      if (date && cleanCode.length === 10) {
        const row = await synthesizeBaseMfnRow(cleanCode, String(country), String(date));
        if (row) {
          return res.json({
            data: [row],
            match: 'base_mfn_synthesized',
            query: { hts10: cleanCode, country },
          });
        }
      }
    }

    res.json({
      data: rows,
      match: synthesized > 0 ? 'base_mfn_synthesized' : 'exact',
      query: { hts10: cleanCode, country },
    });
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
    let rows = reader.getRowObjects().map(cleanRow);

    // Phase 1 stopgap: for each requested country, fill revision gaps with
    // synthesized base-MFN rows so multi-country comparison charts have
    // complete historical coverage.
    if (countryCodes.length > 0 && cleanCode.length === 10) {
      const byCountry = new Map();
      for (const cc of countryCodes) byCountry.set(cc, []);
      for (const r of rows) {
        if (!byCountry.has(r.country)) byCountry.set(r.country, []);
        byCountry.get(r.country).push(r);
      }
      const filledAll = [];
      for (const [cc, rs] of byCountry.entries()) {
        const filled = await fillHistoryGaps(rs, cleanCode, cc);
        filledAll.push(...filled);
      }
      filledAll.sort((a, b) =>
        String(a.country).localeCompare(String(b.country)) ||
        String(a.effective_date).localeCompare(String(b.effective_date)),
      );
      // Normalize __synthesized to a boolean on every row so the Arrow
      // column schema is consistent regardless of which row is rows[0].
      for (const r of filledAll) r.__synthesized = r.__synthesized === true;
      rows = filledAll;
    }

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

// --- Batch rate lookup endpoint ---
// Accepts an array of {hts10, country, date} keys and returns all matching
// ProductRate rows whose valid_from..valid_until contains the requested date.
// Used by the Bulk Duty Analysis workflow to resolve many (hts, country, date)
// combinations in one round-trip after client-side deduplication.
//
// Response is Arrow IPC stream with an additional 'request_key' column so the
// client can join rows back to the originating request key.
app.post('/api/rates/batch', async (req, res) => {
  try {
    const body = req.body ?? {};
    const rawKeys = Array.isArray(body.keys) ? body.keys : null;
    if (!rawKeys || rawKeys.length === 0) {
      return res.status(400).json({ error: 'keys array required' });
    }
    if (rawKeys.length > 2000) {
      return res.status(400).json({
        error: `Too many keys (${rawKeys.length}); cap is 2000 per request`,
      });
    }

    // Sanitize every key to digits-only / ISO date. Reject malformed.
    const keys = [];
    const seen = new Set();
    for (const k of rawKeys) {
      if (!k || typeof k !== 'object') continue;
      const hts10 = String(k.hts10 ?? '').replace(/\./g, '');
      const country = String(k.country ?? '');
      const date = String(k.date ?? '');
      if (!/^\d{4,10}$/.test(hts10)) continue;
      if (!/^\d{1,6}$/.test(country)) continue;
      if (!/^\d{4}-\d{2}-\d{2}$/.test(date)) continue;
      const dedupe = `${hts10}|${country}|${date}`;
      if (seen.has(dedupe)) continue;
      seen.add(dedupe);
      keys.push({ hts10, country, date });
    }

    if (keys.length === 0) {
      return res.status(400).json({ error: 'no valid keys after sanitization' });
    }

    // Build the SQL. We construct a CTE of (hts10, country, date) tuples,
    // join it to rates on hts10/country, and filter by date range. For a
    // 10-digit key with no match, we fall back to the 8-digit prefix by
    // doing a second scan (union) on rows where the tuple's hts10 prefix
    // matches the rates row.
    //
    // SECURITY: every field has been regex-validated above, so interpolation
    // is safe. DuckDB does not support parameterized queries in the node
    // bindings in the same way as pg, so interpolation with sanitized
    // inputs is the standard approach used elsewhere in this file.
    const valuesClause = keys
      .map(
        (k) =>
          `('${k.hts10}', '${k.country}', DATE '${k.date}')`,
      )
      .join(',');

    const sql = `
      WITH req(req_hts10, req_country, req_date) AS (
        VALUES ${valuesClause}
      )
      SELECT req.req_hts10 AS request_hts10,
             req.req_country AS request_country,
             CAST(req.req_date AS VARCHAR) AS request_date,
             r.*
      FROM req
      JOIN rates r
        ON r.hts10 = req.req_hts10
       AND r.country = req.req_country
       AND r.valid_from <= req.req_date
       AND r.valid_until >= req.req_date
      ORDER BY req.req_hts10, req.req_country, req.req_date, r.effective_date
    `;

    const reader = await connection.runAndReadAll(sql);
    const rows = reader.getRowObjects().map(cleanRow);

    // Phase 1 stopgap: figure out which requested keys got zero rows and
    // synthesize base-MFN rows for them so the bulk calculator can compute
    // MFN + fees without "no rate found" gaps.
    const matched = new Set(
      rows.map((r) => `${r.request_hts10}|${r.request_country}|${r.request_date}`),
    );
    let syntheticsAdded = 0;
    for (const k of keys) {
      const dedupe = `${k.hts10}|${k.country}|${k.date}`;
      if (matched.has(dedupe)) continue;
      const synthesized = await synthesizeBaseMfnRow(k.hts10, k.country, k.date);
      if (!synthesized) continue;
      rows.push({
        request_hts10: k.hts10,
        request_country: k.country,
        request_date: k.date,
        ...synthesized,
      });
      syntheticsAdded += 1;
    }

    const arrow = await import('apache-arrow');

    if (rows.length === 0) {
      res.setHeader('Content-Type', 'application/vnd.apache.arrow.stream');
      res.setHeader('X-SAIL-Found', '0');
      res.setHeader('Access-Control-Expose-Headers', 'X-SAIL-Found');
      return res.send(Buffer.alloc(0));
    }

    const columnData = {};
    const keysSet = Object.keys(rows[0]);
    for (const k of keysSet) {
      const vals = rows.map((r) => r[k]);
      const sample = rows[0][k];
      if (typeof sample === 'number') {
        columnData[k] = new Float64Array(
          vals.map((v) => (v == null ? 0 : Number(v))),
        );
      } else if (typeof sample === 'boolean') {
        columnData[k] = vals.map((v) => Boolean(v));
      } else {
        columnData[k] = vals.map((v) => (v == null ? '' : String(v)));
      }
    }

    const table = arrow.tableFromArrays(columnData);
    const ipcBytes = arrow.tableToIPC(table, 'stream');

    res.setHeader('Content-Type', 'application/vnd.apache.arrow.stream');
    res.setHeader('Content-Length', ipcBytes.byteLength);
    res.setHeader('X-SAIL-Found', String(rows.length));
    res.setHeader('X-SAIL-Keys', String(keys.length));
    res.setHeader('X-SAIL-Synthesized', String(syntheticsAdded));
    res.setHeader(
      'Access-Control-Expose-Headers',
      'Content-Length, X-SAIL-Found, X-SAIL-Keys, X-SAIL-Synthesized',
    );
    res.send(Buffer.from(ipcBytes));
  } catch (err) {
    console.error('Batch rate endpoint error:', err);
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
