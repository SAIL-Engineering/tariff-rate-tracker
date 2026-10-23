import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import {DuckDBInstance} from '@duckdb/node-api';
import {validateProjectedIntervals,preflightPartitionIntervals} from '../server/revision-intervals.js';
const row=(revision,from,until)=>({revision,valid_from:from,valid_from_max:from,valid_until:until,valid_until_min:until});
test('latest-only replacement cannot leave the previous revision open-ended',()=>{
 const old=[row('r19','2026-09-15','2026-12-31'),row('r20','2026-09-29','2026-12-31')];
 assert.throws(()=>validateProjectedIntervals(old,[row('r21','2026-10-09','2026-12-31')]),/preflight failed/);
 const corrected=[row('r19','2026-09-15','2026-09-28'),row('r20','2026-09-29','2026-10-08'),row('r21','2026-10-09','2026-12-31')];
 assert.deepEqual(validateProjectedIntervals(old,corrected),corrected);
 assert.throws(()=>validateProjectedIntervals([], [{...corrected[0],valid_until_min:'2026-09-27'}],{full:true}),/inconsistent/);
});
test('preflight reads parquet and target without changing either',async()=>{
 const dir=await fs.mkdtemp(path.join(os.tmpdir(),'duty-intervals-'));
 const db=await DuckDBInstance.create(':memory:');const c=await db.connect();
 try {
  await c.run(`CREATE TABLE rates AS SELECT 'r1' revision, DATE '2026-01-01' valid_from, DATE '2026-12-31' valid_until`);
  const file=path.join(dir,'new.parquet');
  await c.run(`COPY (SELECT 'r2' revision,DATE '2026-10-09' valid_from,DATE '2026-12-31' valid_until) TO '${file}' (FORMAT PARQUET)`);
  await assert.rejects(preflightPartitionIntervals(c,['r2'],()=>file),/overlapping/);
  assert.equal((await c.runAndReadAll('SELECT count(*)::DOUBLE n FROM rates')).getRowObjects()[0].n,1);
  await assert.rejects(preflightPartitionIntervals(c,['wrong'],()=>file),/Mixed or missing/);
  assert.equal((await preflightPartitionIntervals(c,['r2'],()=>file,{full:true})).length,1);
 }finally{c.closeSync();db.closeSync();await fs.rm(dir,{recursive:true});}
});
