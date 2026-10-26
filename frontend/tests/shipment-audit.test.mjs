import test from 'node:test';
import assert from 'node:assert/strict';
import { DuckDBInstance } from '@duckdb/node-api';
import { auditQueries, revisionIssues, compareAuditCases } from '../server/shipment-audit.js';
const cases = [{id:'case',hts10:'1234567890',country:'1220',entry_date:'2026-10-09',
  expectations:[{field:'statutory_rate_232',value:0.25,verification:'primary_source_verified',source_ids:['test-source']}]}];
test('a sourced conditional null is distinct from a missing column or a numeric rate',()=>{
  const conditional=structuredClone(cases);conditional[0].expectations[0].value=null;
  const row={...cases[0],revision:'r1',valid_from:'2026-09-15',valid_until:'2026-12-31'};
  const rows=[row,{...row,statutory_rate_232:null},{...row,statutory_rate_232:0},{...row,statutory_rate_232:.25}];
  assert.deepEqual(compareAuditCases(conditional,rows,new Set(['test-source']))[0].checks.map(c=>c.status),
    ['missing_field','match','mismatch','mismatch']);
});
test('audit uses bound values and rejects identifier, origin and product injection', () => {
  assert.throws(() => auditQueries('db; DROP TABLE rates',cases));
  assert.throws(() => auditQueries('db',[{...cases[0],hts10:'12345678'}]));
  assert.throws(() => auditQueries('db',[{...cases[0],country:"1220' OR TRUE"}]));
  assert.throws(() => auditQueries('db',[cases[0],cases[0]]));
  const qs=auditQueries('db',cases);
  assert.ok(Object.values(qs).every(q => q.sql.trim().startsWith('SELECT')));
  assert.ok(!qs.cases.sql.includes(cases[0].hts10));
  assert.deepEqual(qs.cases.params.slice(-2),['1234567890','1220']);
});
test('overlap includes all overlapping revisions, not only consecutive pairs', () => {
  const rows=[['r19','2026-09-15'],['r20','2026-09-29'],['r21','2026-10-09']].map(([revision,from]) =>
    ({revision,valid_from:from,valid_from_max:from,valid_until:'2026-12-31',valid_until_min:'2026-12-31'}));
  assert.equal(revisionIssues(rows).filter(r=>r.kind==='overlapping_revision_intervals').length,3);
  rows[0].valid_until=rows[0].valid_until_min='2026-09-28';
  rows[1].valid_until=rows[1].valid_until_min='2026-10-08';
  assert.deepEqual(revisionIssues(rows),[]);
});
test('missing rows, ambiguous windows and missing values never pass as zero', () => {
  assert.equal(compareAuditCases(cases,[])[0].lookup_status,'missing_row');
  const row={...cases[0],revision:'r1',valid_from:'2026-09-15',valid_until:'2026-12-31'};
  const result=compareAuditCases(cases,[row,{...row,revision:'r2',statutory_rate_232:0.25}],new Set(['test-source']))[0];
  assert.equal(result.lookup_status,'ambiguous_interval');
  assert.equal(result.checks[0].status,'missing_field');
  assert.equal(result.checks[1].status,'match');
  assert.equal(result.legal_stack_status,'not_certified_by_component_checks');
  const unverified=structuredClone(cases);delete unverified[0].expectations[0].verification;
  assert.equal(compareAuditCases(unverified,[row])[0].checks[0].status,'unverified_expectation');
});
test('read-only query shapes execute in DuckDB and preserve exact adjacent HTS10 scope', async () => {
  const db=await DuckDBInstance.create(':memory:');const c=await db.connect();
  try {
    const sql=auditQueries('memory',cases);
    const numeric=[...sql.sweep.sql.matchAll(/\b(?:statutory_[a-z0-9_]+|rate_[a-z0-9_]+)\b/g)].map(m=>m[0]);
    const cols=[...new Set(numeric)].filter(s=>s!=='rate_basis');
    await c.run(`CREATE TABLE rates (hts10 VARCHAR,country VARCHAR,revision VARCHAR,valid_from DATE,valid_until DATE,
      ch99_code_232 VARCHAR,rate_basis VARCHAR,adcvd_candidates_json VARCHAR,${cols.map(s=>s+' DOUBLE').join(',')})`);
    await c.run(`INSERT INTO rates (hts10,country,revision,valid_from,valid_until,statutory_rate_232)
      VALUES ('1234567890','1220','r1','2026-01-01','2026-12-31',0.25),
             ('1234567891','1220','r1','2026-01-01','2026-12-31',0.5)`);
    await c.run('BEGIN TRANSACTION READ ONLY');
    const actual=(await c.runAndReadAll(sql.cases.sql,sql.cases.params)).getRowObjects();
    assert.equal(actual.length,1);assert.equal(JSON.parse(actual[0].row_json).hts10,'1234567890');
    assert.equal((await c.runAndReadAll(sql.revisions.sql,sql.revisions.params)).getRowObjects()[0].row_count,2);
    assert.equal((await c.runAndReadAll(sql.sweep.sql,sql.sweep.params)).getRowObjects().length,1);
    await c.run('ROLLBACK');
  } finally { c.closeSync();db.closeSync(); }
});


test('unregistered source flags cannot masquerade as primary evidence', () => {
  const row={...cases[0],revision:'r1',valid_from:'2026-01-01',valid_until:'2026-12-31',statutory_rate_232:0.25};
  assert.equal(compareAuditCases(cases,[row])[0].checks[0].status,'unverified_expectation');
});

test('reviewed evidence must retain its source bytes and hash', async () => {
  const fs=await import('node:fs/promises'); const path=await import('node:path');
  const os=await import('node:os'); const crypto=await import('node:crypto');
  const {verifyAuditEvidence}=await import('../server/shipment-audit-evidence.js');
  const root=await fs.mkdtemp(path.join(os.tmpdir(),'audit-source-'));
  try {
    await fs.writeFile(path.join(root,'source.txt'),'test fixture');
    const source={id:'test-source',path:'source.txt',url:'https://example.test/source',locator:'clause',
      sha256:crypto.createHash('sha256').update('test fixture').digest('hex'),verification:'primary_source_verified'};
    const spec={sources:[source],cases};
    assert.deepEqual([...await verifyAuditEvidence(spec,root)],['test-source']);
    await assert.rejects(verifyAuditEvidence({...spec,sources:[]},root),/no verified evidence/);
    await fs.writeFile(path.join(root,'source.txt'),'changed');
    await assert.rejects(verifyAuditEvidence(spec,root),/hash mismatch/);
  } finally {await fs.rm(root,{recursive:true});}
});
