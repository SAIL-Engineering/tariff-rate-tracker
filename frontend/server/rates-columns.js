/**
 * Columns a local rate partition carries that the cloud `rates` table lacks.
 *
 * An incremental push replaces revisions with INSERT ... BY NAME, which fails
 * on a column the target does not have. When the build starts emitting a new
 * column (e.g. duty_expression_raw), the cloud table needs that column before
 * the first replaced revision, or the push rolls back revision one and stops.
 *
 * ensureRatesColumns() only ever ADDs nullable columns. It never drops,
 * renames or retypes, so rows of revisions not being replaced keep their values
 * and read NULL in the new column until they are pushed again. It acts only
 * when asked (--add-columns); otherwise it stops the push before any row moves
 * and names what is missing.
 */

const COLUMN_NAME_RE = /^[a-z_][a-z0-9_]*$/;
const COLUMN_TYPE_RE = /^[A-Z][A-Z0-9_]*(\([0-9, ]+\))?(\[\])?$/;

async function describe(conn, sql) {
  const reader = await conn.runAndReadAll(`DESCRIBE ${sql}`);
  return reader.getRowObjects().map((r) => ({ name: String(r.column_name), type: String(r.column_type) }));
}

/** New columns across the given parquet globs, in first-seen order. */
export async function newRatesColumns(conn, globs) {
  const have = new Set((await describe(conn, 'rates')).map((c) => c.name));
  const found = new Map();
  for (const glob of globs) {
    const cols = await describe(
      conn,
      `SELECT * FROM read_parquet('${glob}', hive_partitioning = true, union_by_name = true)`,
    );
    for (const c of cols) {
      if (have.has(c.name)) continue;
      const seen = found.get(c.name);
      if (seen && seen.type !== c.type) {
        throw new Error(
          `column ${c.name} is ${seen.type} in one partition and ${c.type} in another; ` +
            'rebuild the partitions before pushing',
        );
      }
      if (!seen) found.set(c.name, c);
    }
  }
  return [...found.values()];
}

export async function ensureRatesColumns(conn, globs, { addColumns = false, dryRun = false, log = () => {} } = {}) {
  const missing = await newRatesColumns(conn, globs);
  if (missing.length === 0) return [];
  for (const c of missing) {
    if (!COLUMN_NAME_RE.test(c.name) || !COLUMN_TYPE_RE.test(c.type)) {
      throw new Error(`refusing to add column with unexpected name or type: ${c.name} ${c.type}`);
    }
  }
  const listed = missing.map((c) => `${c.name} ${c.type}`).join(', ');
  if (!addColumns) {
    throw new Error(
      `the partitions carry column(s) the cloud rates table lacks: ${listed}. ` +
        'Re-run with --add-columns to add them (nullable; rows of revisions not pushed read NULL), ' +
        'or do a full rebuild push. Nothing was changed.',
    );
  }
  if (dryRun) {
    log('dry_run.would_add_columns', { columns: missing });
    return missing;
  }
  for (const c of missing) {
    await conn.run(`ALTER TABLE rates ADD COLUMN ${c.name} ${c.type}`);
    log('exec.rates.add_column', { column: c.name, type: c.type });
  }
  return missing;
}
