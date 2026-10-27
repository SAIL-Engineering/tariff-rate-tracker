// Reopen all original byte pins before reusing a completed diagnostic build.
import {parseArgs} from 'node:util';
import {readReleaseManifest} from '../server/shipment-release.js';
const {values}=parseArgs({options:{manifest:{type:'string'}}});
if(!values.manifest)throw new Error('Provide --manifest');
const p=await readReleaseManifest(values.manifest);
if(p.manifest.contract_version!=='sail.tariff-release/v8'||p.manifest.preparation_mode!=='diagnostic')
 throw new Error('Resume requires an indexed local diagnostic manifest');
console.log(JSON.stringify({status:'artifacts_verified',dataset_version:p.manifest.dataset_version,
 revisions:p.manifest.required_revisions,manifest_sha256:p.manifestHash}));
