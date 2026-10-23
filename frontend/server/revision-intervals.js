/** Guard date-addressed lookups before any partition is replaced. */
import { revisionIssues } from './shipment-audit.js';
export function validateProjectedIntervals(existing, replacements, {full=false}={}) {
  if (!replacements.length) throw new Error('No replacement revision intervals');
  const selected=new Set(replacements.map(r=>r.revision));
  if (selected.size !== replacements.length) throw new Error('Duplicate replacement revision intervals');
  const projected=[...(full ? [] : existing.filter(r=>!selected.has(r.revision))),...replacements];
  if (projected.some(r=>![r.valid_from,r.valid_from_max,r.valid_until,r.valid_until_min].every(v=>
    typeof v==='string' && /^\d{4}-\d{2}-\d{2}$/.test(v)))) throw new Error('Missing revision interval');
  const issues=revisionIssues(projected);
  if (issues.length) throw new Error(`Revision interval preflight failed; rebuild and include every changed neighboring partition: ${JSON.stringify(issues)}`);
  return projected;
}
const literal=s=>`'${String(s).replaceAll("'","''")}'`;
const selection=`revision, min(valid_from)::VARCHAR valid_from, max(valid_from)::VARCHAR valid_from_max,
 min(valid_until)::VARCHAR valid_until_min, max(valid_until)::VARCHAR valid_until`;
export async function preflightPartitionIntervals(conn, revisions, globForRevision, {full=false}={}) {
  const current=full ? [] : (await conn.runAndReadAll(`SELECT ${selection} FROM rates GROUP BY revision`)).getRowObjects();
  const replacement=[];
  for (const revision of revisions) {
    if (!/^[a-zA-Z0-9_]+$/.test(revision)) throw new Error('Invalid revision identifier');
    const rows=(await conn.runAndReadAll(`SELECT ${selection} FROM read_parquet(${literal(globForRevision(revision))},
      hive_partitioning=true,union_by_name=true) GROUP BY revision`)).getRowObjects();
    if (rows.length!==1 || rows[0].revision!==revision) throw new Error(`Mixed or missing partition: ${revision}`);
    replacement.push(rows[0]);
  }
  return validateProjectedIntervals(current,replacement,{full});
}
