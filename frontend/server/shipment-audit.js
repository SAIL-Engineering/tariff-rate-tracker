/** Read-only live-data audit queries. Diagnostics are not legal approval. */
export const AUDIT_CONTRACT = 'sail.shipment-data-audit/v1';
const id = value => {
  if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(value)) throw new Error('Invalid catalog identifier');
  return `"${value}"`;
};
export function auditQueries(catalog, cases, { from = '2025-01-01', through = '2026-10-22' } = {}) {
  if (![from, through].every(x => /^\d{4}-\d{2}-\d{2}$/.test(x)) || from > through)
    throw new Error('Invalid audit date window');
  if (!Array.isArray(cases) || !cases.length || cases.length > 500 || cases.some(c =>
    !/^[0-9]{10}$/.test(c.hts10) || !/^[0-9]{4}$/.test(c.country) || typeof c.id !== 'string'))
    throw new Error('Audit cases require exact HTS10 and Census origin codes');
  if (new Set(cases.map(c => c.id)).size !== cases.length) throw new Error('Duplicate audit case ID');
  const table = `${id(catalog)}.main.rates`;
  const window = `valid_from <= CAST(? AS DATE) AND valid_until >= CAST(? AS DATE)`;
  const params = [through, from];
  // Values are bound, including all case identities. No arbitrary SQL input.
  const pairs = [...new Map(cases.map(c => [`${c.hts10}|${c.country}`, c])).values()];
  return {
    schema: { sql: `SELECT table_schema, table_name, column_name, data_type FROM information_schema.columns
      WHERE table_catalog = ? ORDER BY table_schema,table_name,ordinal_position`, params: [catalog] },
    revisions: { sql: `SELECT revision, min(valid_from)::VARCHAR valid_from, max(valid_from)::VARCHAR valid_from_max,
      min(valid_until)::VARCHAR valid_until_min, max(valid_until)::VARCHAR valid_until,
      count(*)::DOUBLE row_count, count(DISTINCT hts10)::DOUBLE products, count(DISTINCT country)::DOUBLE origins
      FROM ${table} WHERE ${window} GROUP BY revision,valid_from,valid_until ORDER BY min(valid_from),revision`, params },
    cases: { sql: `SELECT to_json(r)::VARCHAR row_json FROM ${table} r
      WHERE ${window} AND (hts10,country) IN (${pairs.map(() => '(?,?)').join(',')})
      ORDER BY hts10,country,valid_from,revision LIMIT 10001`, params: [...params, ...pairs.flatMap(c => [c.hts10,c.country])] },
    sweep: { sql: `SELECT revision, substr(hts10,1,2) chapter, country,
      count(*)::DOUBLE row_count,
      count(*) FILTER (WHERE valid_from > valid_until)::DOUBLE invalid_intervals,
      count(*) FILTER (WHERE statutory_base_rate IS NULL)::DOUBLE missing_statutory_base,
      count(*) FILTER (WHERE statutory_total_rate IS NULL)::DOUBLE missing_statutory_total,
      count(*) FILTER (WHERE rate_232 > 0 AND ch99_code_232 IS NULL)::DOUBLE section232_without_heading,
      count(*) FILTER (WHERE abs(rate_232 - (rate_232_auto + rate_232_steel + rate_232_aluminum + rate_232_copper + rate_232_other)) > 1e-9)::DOUBLE section232_action_sum_mismatch,
      count(*) FILTER (WHERE abs(statutory_rate_232 - (statutory_rate_232_auto + statutory_rate_232_steel + statutory_rate_232_aluminum + statutory_rate_232_copper + statutory_rate_232_other)) > 1e-9)::DOUBLE statutory232_action_sum_mismatch,
      count(*) FILTER (WHERE statutory_rate_232_other > 0)::DOUBLE statutory232_unidentified_action,
      count(*) FILTER (WHERE statutory_rate_s122 > 0 AND statutory_rate_s122 < 0.1 - 1e-9)::DOUBLE fractional_statutory122_review,
      count(*) FILTER (WHERE rate_basis IN ('specific','compound') AND statutory_total_rate IS NOT NULL)::DOUBLE quantity_duty_presented_as_rate,
      count(*) FILTER (WHERE rate_adcvd = 0 AND adcvd_candidates_json IS NOT NULL AND adcvd_candidates_json NOT IN ('[]','null',''))::DOUBLE zero_adcvd_with_candidates,
      count(*) FILTER (WHERE statutory_total_rate < 0 OR statutory_rate_232 < 0)::DOUBLE negative_duty
      FROM ${table} WHERE ${window} GROUP BY revision,chapter,country ORDER BY revision,chapter,country`, params },
  };
}

export function revisionIssues(rows) {
  const problems = [];
  for (const r of rows) {
    if (r.valid_from !== r.valid_from_max || r.valid_until !== r.valid_until_min)
      problems.push({ kind: 'inconsistent_revision_interval', revision: r.revision });
    if (r.valid_from > r.valid_until) problems.push({ kind: 'empty_revision_interval', revision: r.revision });
  }
  const ordered = [...rows].sort((a,b) => a.valid_from.localeCompare(b.valid_from) || a.revision.localeCompare(b.revision));
  for (let i=0; i<ordered.length; i++) for (let j=i+1; j<ordered.length; j++) {
    const a=ordered[i], b=ordered[j];
    if (b.valid_from > a.valid_until) break;
    problems.push({ kind: 'overlapping_revision_intervals', revisions: [a.revision,b.revision],
      from: b.valid_from, through: a.valid_until < b.valid_until ? a.valid_until : b.valid_until });
  }
  for (let i=1; i<ordered.length; i++) {
    const a=ordered[i-1], b=ordered[i];
    const next = new Date(`${a.valid_until}T00:00:00Z`); next.setUTCDate(next.getUTCDate()+1);
    if (next.toISOString().slice(0,10) < b.valid_from)
      problems.push({ kind: 'gap_between_revision_intervals', revisions: [a.revision,b.revision] });
  }
  return problems;
}

export function compareAuditCases(cases, rows, verifiedSourceIds = new Set()) {
  return cases.map(c => {
    const matches = rows.filter(r => r.hts10 === c.hts10 && r.country === c.country
      && (!c.entry_date || r.valid_from <= c.entry_date && r.valid_until >= c.entry_date));
    return { case_id: c.id, hts10: c.hts10, country: c.country, entry_date: c.entry_date ?? null,
      matched_revisions: matches.map(r => r.revision),
      lookup_status: !matches.length ? 'missing_row' : c.entry_date && matches.length > 1 ? 'ambiguous_interval' : 'rows_found',
      // Expectations are independent evidence, never inferred from live values.
      checks: matches.flatMap(r => (c.expectations ?? []).map(e => {
        const actual = r[e.field];
        const verified = e.verification === 'primary_source_verified' && e.source_ids?.length > 0
          && e.source_ids.every(id => verifiedSourceIds.has(id));
        return { revision: r.revision, field: e.field, actual: actual ?? null, expected: e.value,
          source_ids: e.source_ids ?? [], status: !verified ? 'unverified_expectation' : !Object.hasOwn(r,e.field) ? 'missing_field'
            : e.value === null ? actual === null ? 'match' : 'mismatch' : actual == null ? 'missing_field'
            : typeof e.value === 'number' ? typeof actual === 'number' && Math.abs(actual-e.value) < 1e-9 ? 'match' : 'mismatch'
            : actual === e.value ? 'match' : 'mismatch' };
      })),
      legal_stack_status: 'not_certified_by_component_checks' };
  });
}
