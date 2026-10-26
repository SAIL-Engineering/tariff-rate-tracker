import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import crypto from 'node:crypto';
import { readShipmentBundleIndex, shipmentBundles } from '../server/shipment-bundle-index.js';

const sha = bytes => crypto.createHash('sha256').update(bytes).digest('hex');
async function fixture(fn) {
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), 'shipment-index-'));
  const index = { contract_version: 'sail.shipment-bundle-index/v1', revision: 'source-frame', dataset_version: 'synthetic-index-fixture',
    evidence_snapshot_id: 'd'.repeat(64), valid_from: '2026-09-15T04:00:00Z', valid_until: '2026-09-16T04:00:00Z', bundles: [] };
  for (const [i, from, until] of [[1,index.valid_from,'2026-09-15T04:01:00Z'],[2,'2026-09-15T04:01:00Z',index.valid_until]]) {
    const id = String(i).repeat(64); const filename = `shipment_bundle_${id}.json`;
    const bundle = { contract_version: 'sail.shipment-rules/v1', bundle_id: id, revision: index.revision,
      dataset_version: index.dataset_version, evidence_snapshot_id: index.evidence_snapshot_id, valid_from: from, valid_until: until,
      products: ['8537109130'], countries: ['1220'], rules: [], sources: [], coverage: [], coverage_requirements: ['synthetic'],
      claim_definitions: [], fact_definitions: {} };
    const bytes = JSON.stringify(bundle);await fs.writeFile(path.join(dir,filename),bytes);
    index.bundles.push({ bundle_id: id, path: filename, sha256: sha(bytes), valid_from: from, valid_until: until });
  }
  const file = path.join(dir,'shipment_rules.json');await fs.writeFile(file,JSON.stringify(index));
  try { await fn({ dir,file,index }); } finally { await fs.rm(dir,{recursive:true,force:true}); }
}
test('streamed index retains every exact-time bundle and version', () => fixture(async ({file,index}) => {
  const parsed = await readShipmentBundleIndex(file,{revision:index.revision,dataset_version:index.dataset_version,evidence_snapshot_id:index.evidence_snapshot_id});
  const bundles=[];for await(const entry of shipmentBundles(parsed))bundles.push(entry);
  assert.equal(bundles.length,2);assert.equal(bundles[1].bundle.valid_from,'2026-09-15T04:01:00Z');
  assert.equal(sha(bundles[0].text),index.bundles[0].sha256);
  assert.equal(bundles[0].bundle.dataset_version,index.dataset_version);
}));
test('gaps, overlaps, invalid dates and unsupported index schemas fail', () => fixture(async ({file,index}) => {
  for (const mutate of [
    x=>x.bundles[1].valid_from='2026-09-15T04:01:01Z',x=>x.bundles[1].valid_from=x.valid_from,
    x=>x.valid_until='2026-02-30T04:00:00Z',x=>x.contract_version='old',x=>x.bundles.push(x.bundles[0]),
  ]) { const bad=structuredClone(index);mutate(bad);await fs.writeFile(file,JSON.stringify(bad));await assert.rejects(readShipmentBundleIndex(file)); }
}));
test('hash changes, mixed versions, escaping paths and malformed roots stay unavailable', () => fixture(async ({dir,file,index}) => {
  await assert.rejects(readShipmentBundleIndex(file,{dataset_version:'stale'}),/version/i);
  const parsed=await readShipmentBundleIndex(file);
  await fs.writeFile(path.join(dir,index.bundles[0].path),'{}');
  await assert.rejects(async()=>{for await(const _entry of shipmentBundles(parsed)){}},/hash/i);
  const escaping=structuredClone(index);escaping.bundles[0].path='../outside.json';await fs.writeFile(file,JSON.stringify(escaping));
  await assert.rejects(readShipmentBundleIndex(file),/path|artifact/i);
  await fs.writeFile(file,'true');await assert.rejects(readShipmentBundleIndex(file),/index/i);
}));
test('a valid artifact hash cannot conceal mixed body versions or missing contract fields', () => fixture(async ({dir,file,index}) => {
  const entry=index.bundles[0];const filename=path.join(dir,entry.path);
  const original=JSON.parse(await fs.readFile(filename));
  for(const mutate of [x=>x.dataset_version='different',x=>x.revision='different',x=>x.bundle_id='f'.repeat(64),
    x=>delete x.coverage_requirements,x=>x.products=[],x=>x.rules=[{id:'duplicate'},{id:'duplicate'}]]) {
    const bundle=structuredClone(original);mutate(bundle);const bytes=JSON.stringify(bundle);
    await fs.writeFile(filename,bytes);const changed=structuredClone(index);changed.bundles[0].sha256=sha(bytes);
    await fs.writeFile(file,JSON.stringify(changed));const parsed=await readShipmentBundleIndex(file);
    await assert.rejects(async()=>{for await(const _entry of shipmentBundles(parsed)){}},/version|identity|identities|contract/i);
  }
}));
test('an artifact symlink cannot combine another directory into a release', () => fixture(async ({dir,file,index}) => {
  const external=await fs.mkdtemp(path.join(os.tmpdir(),'shipment-index-external-'));
  try {
    const filename=path.join(dir,index.bundles[0].path);const target=path.join(external,'payload.json');
    await fs.copyFile(filename,target);await fs.unlink(filename);await fs.symlink(target,filename);
    const parsed=await readShipmentBundleIndex(file);
    await assert.rejects(async()=>{for await(const _entry of shipmentBundles(parsed)){}},/escapes/i);
  } finally {await fs.rm(external,{recursive:true,force:true});}
}));
