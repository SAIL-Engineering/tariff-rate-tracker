// Assemble local artifact references only. No DB, deployment or active pointer.
import fs from 'node:fs/promises';
import path from 'node:path';
import crypto from 'node:crypto';
import {parseArgs} from 'node:util';
import {INDEX_RELEASE_COLUMNS} from '../server/shipment-index-release.js';
import {readShipmentBundleIndex} from '../server/shipment-bundle-index.js';
import {shipmentFileHash} from '../server/shipment-release-files.js';
const {values}=parseArgs({options:{normalized:{type:'string'},rates:{type:'string'},revisions:{type:'string'},output:{type:'string'},mode:{type:'string',default:'diagnostic'},evidence:{type:'string'}}});
if(!values.normalized||!values.rates||!values.revisions||!values.output||!['diagnostic','production'].includes(values.mode))throw new Error('Provide --normalized, --rates, --revisions, --output and a valid --mode');
const base=await fs.realpath(path.dirname(values.output)),output=path.resolve(values.output);
try{await fs.access(output);throw new Error('Manifest already exists; use a new output filename');}catch(error){if(error.code!=='ENOENT')throw error;}
const sha=x=>crypto.createHash('sha256').update(x).digest('hex');
const descriptor=async filename=>{
 const full=await fs.realpath(filename);if(!full.startsWith(base+path.sep))throw new Error('Artifact is outside manifest root: '+filename);
 return {path:path.relative(base,full),sha256:await shipmentFileHash(full)};
};
const requested=values.revisions.split(',');if(new Set(requested).size!==requested.length||requested.some(r=>!/^202[56]_(basic|rev_\d+)$/.test(r)))throw new Error('Identified, unique revision IDs required');
let dataset,evidence;const revisions=[];
for(const revision of requested) {
 const dir=path.resolve(values.normalized,revision),checked=await readShipmentBundleIndex(path.join(dir,'shipment_rules.json'));
 if(checked.index.revision!==revision||dataset&&checked.index.dataset_version!==dataset||evidence&&checked.index.evidence_snapshot_id!==evidence)throw new Error('Mixed build/evidence versions; do not combine partially refreshed artifacts');
 dataset=checked.index.dataset_version;evidence=checked.index.evidence_snapshot_id;
 const r={revision,bundle_index:await descriptor(checked.filename),rates_partitioning:'hive_revision'};
 const folder=path.resolve(values.rates,'revision='+revision);
 const files=(await fs.readdir(folder)).filter(f=>f.endsWith('.parquet')).sort();if(!files.length)throw new Error('Missing rate partition: '+revision);
 r.rates=await Promise.all(files.map(f=>descriptor(path.join(folder,f))));
 for(const table of Object.keys(INDEX_RELEASE_COLUMNS).filter(t=>t!=='rates'))r[table]=[await descriptor(path.join(dir,table+'.parquet'))];
 revisions.push(r);
}
const manifest={contract_version:'sail.tariff-release/v8',preparation_mode:values.mode,dataset_version:dataset,evidence_snapshot_id:evidence,
 required_revisions:requested,revisions,tooling_sha256:{}};
for(const f of ['../server/shipment-index-release.js','../server/shipment-release-files.js','../migrations/002_shipment_bundle_indexes.sql','../../scripts/lib/shipment_partition_validation.R'])manifest.tooling_sha256[f]=sha(await fs.readFile(new URL(f,import.meta.url)));
if(values.evidence)manifest.evidence_manifest=await descriptor(path.resolve(values.evidence));
await fs.writeFile(output,JSON.stringify(manifest,null,2)+'\n',{flag:'wx'});
console.log(JSON.stringify({manifest:output,mode:values.mode,revisions:revisions.length,dataset_version:dataset,production_qualified:false}));
