import test from 'node:test';
import assert from 'node:assert/strict';
import {tableFromIPC} from 'apache-arrow';
import {encodeRateRows} from '../server/rate-arrow.js';
test('Arrow preserves numeric zero separately from unknown and absent fields', () => {
  const rows=[{hts10:'1234567890',statutory_rate_232:null,eligible:null},
    {hts10:'1234567891',statutory_rate_232:0,eligible:false,source:'evidence'},
    {hts10:'1234567892',statutory_rate_232:0.25,eligible:true}];
  const table=tableFromIPC(encodeRateRows(rows));
  assert.equal(table.getChild('statutory_rate_232').type.toString(),'Float64');
  assert.deepEqual([...table.getChild('statutory_rate_232')],[null,0,0.25]);
  assert.deepEqual([...table.getChild('eligible')],[null,false,true]);
  assert.deepEqual([...table.getChild('source')],[null,'evidence',null]);
});
test('all-null fields stay null after IPC and do not depend on row order', () => {
  const rows=[{hts10:'1234567890',statutory_rate_s122:null},
    {hts10:'1234567891',statutory_rate_s122:null}];
  for (const ordered of [rows,[...rows].reverse()]) {
    const table=tableFromIPC(encodeRateRows(ordered));
    assert.deepEqual([...table.getChild('statutory_rate_s122')],[null,null]);
  }
});
