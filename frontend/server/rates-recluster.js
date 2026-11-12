/**
 * Re-sort the cloud `rates` table by (hts10, country), one revision at a time.
 *
 * Builds `rates_new` revision by revision with ORDER BY hts10, country, checks
 * that it holds exactly the rows `rates` holds, then swaps it into place. A
 * global single-statement sort of the whole panel fails on MotherDuck (~35 min
 * in), which is why it is done per revision; see push-to-motherduck.mjs.
 *
 * With `resume`, a `rates_new` left by a run that died part-way is kept: a
 * revision whose row count already equals its count in `rates` is skipped, one
 * holding some but not all of its rows is deleted and copied again, and the
 * rest are copied. Each copy is a single INSERT, so a dropped connection leaves
 * a revision either fully copied or not at all; the partial case is handled
 * anyway, because a lost acknowledgement can leave the client unsure which.
 *
 * Resume compares row counts, not contents, so it is only valid against the
 * same `rates` the interrupted run was copying. A `rates_new` holding a
 * revision `rates` lacks, or with different columns, is refused.
 */

const REVISION_RE = /^[a-zA-Z0-9_]+$/;

async function tableExists(conn, name) {
  const reader = await conn.runAndReadAll(
    `SELECT 1 FROM information_schema.tables
     WHERE table_catalog = current_database() AND table_schema = current_schema()
       AND table_name = '${name}'`,
  );
  return reader.getRowObjects().length > 0;
}

async function columns(conn, table) {
  const reader = await conn.runAndReadAll(`DESCRIBE ${table}`);
  return reader.getRowObjects().map((r) => `${r.column_name} ${r.column_type}`);
}

async function countsByRevision(conn, table) {
  const reader = await conn.runAndReadAll(
    `SELECT revision, count(*) AS n FROM ${table} GROUP BY revision ORDER BY revision`,
  );
  return new Map(reader.getRowObjects().map((r) => [String(r.revision), Number(r.n)]));
}

export async function reclusterRatesByPartition(conn, { resume = false, log = () => {} } = {}) {
  log('exec.rates.cluster.start', { resume });

  // Revisions and their row counts from the current rates table (not the
  // parquet directory, so --post-only works even if the R pipeline has
  // regenerated local files since the upload). Same order as before, so a
  // resumed run's indexes match the interrupted run's log.
  const source = await countsByRevision(conn, 'rates');
  const revisions = [...source.keys()];
  for (const rev of revisions) {
    if (!REVISION_RE.test(rev)) {
      throw new Error(`unexpected revision name in rates: ${JSON.stringify(rev)}`);
    }
  }
  log('exec.rates.cluster.partitions', { count: revisions.length });

  let present = new Map();
  if (resume && (await tableExists(conn, 'rates_new'))) {
    const [want, have] = [await columns(conn, 'rates'), await columns(conn, 'rates_new')];
    if (want.join('\n') !== have.join('\n')) {
      throw new Error(
        'rates_new does not have the columns rates has, so it was not built from this rates table. ' +
          'Re-run --post-only without --resume.',
      );
    }
    present = await countsByRevision(conn, 'rates_new');
    const foreign = [...present.keys()].filter((r) => !source.has(r));
    if (foreign.length) {
      throw new Error(
        `rates_new holds revisions rates does not (${foreign.join(', ')}), so it is from a different load. ` +
          'Re-run --post-only without --resume.',
      );
    }
    log('exec.rates.cluster.resume', { revisions_present: present.size });
  } else {
    if (resume) log('exec.rates.cluster.resume', { revisions_present: 0, rates_new: 'absent' });
    // CREATE TABLE AS with LIMIT 0 produces an empty table with the same schema.
    await conn.run('DROP TABLE IF EXISTS rates_new');
    await conn.run('CREATE TABLE rates_new AS SELECT * FROM rates LIMIT 0');
  }

  for (let i = 0; i < revisions.length; i++) {
    const rev = revisions[i];
    const want = source.get(rev);
    const have = present.get(rev) ?? 0;
    if (have === want) {
      log('exec.rates.cluster.partition.skip', { revision: rev, index: i + 1, of: revisions.length, rows: have });
      continue;
    }
    if (have > 0) {
      log('exec.rates.cluster.partition.partial', { revision: rev, rows_present: have, rows_expected: want });
      await conn.run(`DELETE FROM rates_new WHERE revision = '${rev}'`);
    }
    const t0 = Date.now();
    await conn.run(`
      INSERT INTO rates_new
      SELECT * FROM rates
      WHERE revision = '${rev}'
      ORDER BY hts10, country
    `);
    log('exec.rates.cluster.partition.done', {
      revision: rev,
      index: i + 1,
      of: revisions.length,
      elapsed_ms: Date.now() - t0,
    });
  }

  // Never swap in a table that lacks rows: rates is what the API serves.
  const copied = await countsByRevision(conn, 'rates_new');
  const wrong = revisions.filter((r) => copied.get(r) !== source.get(r));
  if (wrong.length || copied.size !== source.size) {
    throw new Error(
      `rates_new does not match rates for ${wrong.join(', ') || 'its revision set'}; rates left in place. ` +
        'Re-run with --post-only --resume.',
    );
  }

  // Swap: drop the unsorted table and rename the sorted one in its place.
  // MotherDuck does not wrap DDL in a single transaction, but the window
  // between DROP and RENAME is short and only affects live /api/rates
  // queries during that sub-second gap.
  await conn.run('DROP TABLE rates');
  await conn.run('ALTER TABLE rates_new RENAME TO rates');
  log('exec.rates.cluster.done');
}
