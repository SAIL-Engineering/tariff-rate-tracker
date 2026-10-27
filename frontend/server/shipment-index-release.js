/** Additive indexed release staging. Preparation never validates or activates law. */
import fs from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import crypto from 'node:crypto';
import {execFile} from 'node:child_process';
import {promisify} from 'node:util';
import {fileURLToPath} from 'node:url';
import {NORMALIZED_RELEASE_COLUMNS,RELEASE_MIGRATION} from './shipment-release.js';
import {readShipmentBundleIndex,shipmentBundles} from './shipment-bundle-index.js';
import {SHIPMENT_STATUTORY_FIELDS} from './generated/shipmentWide.js';
import {shipmentFileHash} from './shipment-release-files.js';
const exec=promisify(execFile),root=fileURLToPath(new URL('../../',import.meta.url));
const sha=x=>crypto.createHash('sha256').update(x).digest('hex');
const q=x=>`'${String(x).replaceAll("'","''")}'`;
const id=x=>{if(!/^[A-Za-z_][A-Za-z0-9_]*$/.test(x))throw new Error('Invalid release identifier');return `"${x}"`;};
import {INDEX_RELEASE_CONTRACT} from './shipment-store.js';
export const INDEX_RELEASE_COLUMNS={...NORMALIZED_RELEASE_COLUMNS,
 rates:[...new Set([...NORMALIZED_RELEASE_COLUMNS.rates,...SHIPMENT_STATUTORY_FIELDS,
  'shipment_projection_version','shipment_contract_version','shipment_dataset_version','shipment_evidence_snapshot_id',
  'shipment_status','shipment_quote_profile','shipment_decision_ids_json','shipment_bundle_ids_json',
  'shipment_missing_inputs_json','shipment_source_errors_json','shipment_exact_time_required'])],
 chapter99_provisions:['revision','reporting_code','native_record_sha256','pdf_sha256','hts_sha256','rule_links_json','status'],
 chapter99_notes:['revision','note_id','source_text','source_text_sha256'],
 shipment_decision_classes:['revision','dataset_version','evidence_snapshot_id','bundle_id','class_id','status','known_subtotal','complete_total','profile_json','decision_json','rate_projection_json','projection_missing_inputs_json'],
 shipment_decision_membership:['revision','hts10','country','dataset_version','bundle_id','class_id','entry_valid_from','entry_valid_until'],
};
const migration=await fs.readFile(new URL('../migrations/002_shipment_bundle_indexes.sql',import.meta.url),'utf8');
async function artifact(base,file,readBytes=false) {
 if(!file||typeof file.path!=='string'||!/^[a-f0-9]{64}$/.test(file.sha256??''))throw new Error('Every artifact requires its path and SHA256');
 const full=await fs.realpath(path.resolve(base,file.path));
 if(!full.startsWith(base+path.sep))throw new Error('Artifact escapes release directory');
 const bytes=readBytes?await fs.readFile(full):null;
 if((readBytes?sha(bytes):await shipmentFileHash(full))!==file.sha256)throw new Error('Artifact hash mismatch: '+file.path);
 return {full,bytes};
}
async function productionEvidence(base,m) {
 if(!m.evidence_manifest)throw new Error('Production release requires a verified evidence manifest');
 const a=await artifact(base,m.evidence_manifest);
 const script="import sys,json;sys.path.insert(0,sys.argv[1]);from shipment_build_context import read_evidence_pin;from pathlib import Path;print(json.dumps(read_evidence_pin(Path(sys.argv[2]))))";
 const p=JSON.parse((await exec('python3',['-c',script,path.join(root,'src'),a.full],{maxBuffer:4e6})).stdout);
 if(p.snapshot_id!==m.evidence_snapshot_id)throw new Error('Mixed evidence snapshot identities');
 const required=JSON.parse((await exec('python3',['-c',"import csv,json,sys;print(json.dumps([r['revision'] for r in csv.DictReader(open(sys.argv[1])) if r['revision'].startswith(('2025_','2026_'))]))",path.join(root,'config/revision_dates.csv')])).stdout);
 if(JSON.stringify([...required].sort())!==JSON.stringify([...m.required_revisions].sort()))throw new Error('Production revision coverage differs from identified audit calendar');
 return p;
}
export async function readIndexReleaseManifest(filename) {
 const base=await fs.realpath(path.dirname(filename)),bytes=await fs.readFile(filename),m=JSON.parse(bytes);
 if(m.contract_version!==INDEX_RELEASE_CONTRACT||!['diagnostic','production'].includes(m.preparation_mode)
  ||!/^shipment-[a-f0-9]{64}$/.test(m.dataset_version??'')||!(/^[a-f0-9]{64}$/.test(m.evidence_snapshot_id??'')||m.preparation_mode==='diagnostic'&&m.evidence_snapshot_id==='unresolved_trade_intelligence_snapshot')
  ||!Array.isArray(m.required_revisions)||!m.required_revisions.length||!Array.isArray(m.revisions))throw new Error('Unsupported indexed release manifest');
 const expected=[...m.required_revisions].sort(),actual=m.revisions.map(r=>r.revision).sort();
 if(new Set(expected).size!==expected.length||new Set(actual).size!==actual.length||JSON.stringify(expected)!==JSON.stringify(actual))throw new Error('Revision coverage mismatch');
 const evidence=m.preparation_mode==='production'?await productionEvidence(base,m):null;
 const revisions=[];let grantIdentity=null;
 for(const r of m.revisions) {
  const files={};
  for(const table of Object.keys(INDEX_RELEASE_COLUMNS)) {
   if(!Array.isArray(r[table])||!r[table].length||new Set(r[table].map(f=>f.path)).size!==r[table].length)throw new Error(`Missing or duplicate ${table} partitions`);
   files[table]=[];for(const f of r[table])files[table].push((await artifact(base,f)).full);
  }
  if(!r.bundle_index)throw new Error('Missing bundle index');
  if(!['physical_revision','hive_revision'].includes(r.rates_partitioning??'physical_revision'))throw new Error('Unsupported rates revision storage');
  if(r.rates_partitioning==='hive_revision'&&files.rates.some(f=>path.basename(path.dirname(f))!=='revision='+r.revision))throw new Error('Invalid Hive revision path');
  const a=await artifact(base,r.bundle_index),checked=await readShipmentBundleIndex(a.full,{revision:r.revision,dataset_version:m.dataset_version,evidence_snapshot_id:m.evidence_snapshot_id});
  for await(const {bundle} of shipmentBundles(checked)) {
   if(evidence&&(bundle.evidence_dependencies?.evidence_snapshot?.snapshot_id!==evidence.snapshot_id||bundle.evidence_dependencies?.evidence_snapshot?.manifest_sha256!==evidence.manifest_sha256))throw new Error('Bundle evidence export pin differs from release');
   const grants=bundle.rules.filter(r=>r.grant_id),pin=bundle.evidence_dependencies?.section232_grants;
   if(grants.length&&!pin)throw new Error('Commerce grant rules require an evidence snapshot');
   if(pin) {
    if(!pin.snapshot_id||!/^[a-f0-9]{64}$/.test(pin.snapshot_sha256??'')||!Number.isFinite(Date.parse(pin.as_of))||grants.some(r=>r.grant_snapshot_id!==pin.snapshot_id)
     ||!bundle.sources.some(s=>s.id===`commerce-grant-snapshot-${pin.snapshot_sha256}`&&s.sha256===pin.snapshot_sha256&&s.status==='verified'))throw new Error('Invalid Commerce grant evidence pin');
    const key=JSON.stringify([pin.snapshot_id,pin.snapshot_sha256,pin.as_of]);
    if(grantIdentity&&grantIdentity!==key)throw new Error('Mixed Commerce grant snapshots');grantIdentity=key;
   }
  }
  revisions.push({revision:r.revision,files,checked,artifact:r});
 }
 const ordered=[...revisions].sort((a,b)=>Date.parse(a.checked.index.valid_from)-Date.parse(b.checked.index.valid_from));
 for(let i=1;i<ordered.length;i++)if(Date.parse(ordered[i-1].checked.index.valid_until)>Date.parse(ordered[i].checked.index.valid_from)
  ||m.preparation_mode==='production'&&Date.parse(ordered[i-1].checked.index.valid_until)!==Date.parse(ordered[i].checked.index.valid_from))throw new Error('Release rule intervals overlap or have an unqualified gap');
 return {manifest:m,manifestPath:await fs.realpath(filename),root:base,revisions,evidence,manifestHash:sha(bytes),releaseId:sha(bytes),schema:'release_'+sha(bytes).slice(0,24)};
}
const parquet=files=>`read_parquet([${files.map(q).join(',')}],hive_partitioning=false,union_by_name=true)`;
const rateSource=r=>r.artifact.rates_partitioning==='hive_revision'?`(SELECT *,${q(r.revision)}::VARCHAR AS revision FROM ${parquet(r.files.rates)})`:parquet(r.files.rates);
function columnType(table,key) {
 if(key==='shipment_exact_time_required'||key==='terminated'||key==='derivative')return 'BOOLEAN';
 if(table==='rates'&&(SHIPMENT_STATUTORY_FIELDS.includes(key)||['rate_301','rate_s301_maritime'].includes(key))||['rate','known_subtotal','complete_total'].includes(key)||key.endsWith('_parameter'))return 'DOUBLE';
 if(key==='scope_grain'&&['section232_scope_decisions','ieepa_reciprocal_scope_decisions'].includes(table))return 'INTEGER';
 if(key.startsWith('state_valid_')||['valid_from','valid_until'].includes(key)&&['rates','products_base','authority_country_rates','authority_product_applicability','authority_exemptions'].includes(table))return 'DATE';
 return 'VARCHAR';
}
export async function preflightIndexRelease(conn,p,catalog) {
 const current=(await conn.runAndReadAll('SELECT current_database() AS name')).getRowObjects()[0].name;
 if(current!==catalog)throw new Error('Target catalog mismatch');
 // Reopen every pin. Files changed after manifest discovery cannot be loaded.
 if(sha(await fs.readFile(p.manifestPath))!==p.manifestHash)throw new Error('Release manifest hash changed after discovery');
 await readIndexReleaseManifest(p.manifestPath);
 const signatures=new Map(),reports=[],schemas=[];
 const progress=p.onProgress??(()=>{});
 const totalFiles=p.revisions.reduce((n,r)=>n+Object.values(r.files).reduce((n,files)=>n+files.length,0),0);
 let checkedFiles=0,checkedRevisions=0;
 for(const r of p.revisions) {
  for(const [table,files] of Object.entries(r.files)) {
   for(const f of r.artifact[table])await artifact(p.root,f);
   // Check physical schemas before union_by_name can supply NULL for absent
   // optional fields. A required shipment field must exist in every file.
   for(const file of files) {
    const cols=(await conn.runAndReadAll(`DESCRIBE SELECT * FROM ${parquet([file])}`)).getRowObjects();
    const types=new Map(cols.map(c=>[c.column_name,c.column_type]));
    if(table==='rates'&&r.artifact.rates_partitioning==='hive_revision') {
     if(types.has('revision'))throw new Error('Hive revision identity conflicts with physical column');
     types.set('revision','VARCHAR');
    }
    const invalid=INDEX_RELEASE_COLUMNS[table].filter(k=>types.get(k)!==columnType(table,k));
    if(invalid.length)throw new Error(`Missing or invalid ${table} fields: ${invalid.map(k=>k+' expected '+columnType(table,k)+' found '+(types.get(k)??'missing')).join(', ')} (${r.revision}: ${path.relative(p.root,file)})`);
    const shared=signatures.get(table)??new Map();
    for(const [key,type] of types) {
     if(shared.has(key)&&shared.get(key)!==type)throw new Error(`Inconsistent ${table} partition types: ${key} expected ${shared.get(key)} found ${type} (${r.revision}: ${path.relative(p.root,file)})`);
     shared.set(key,type);
    }
    signatures.set(table,shared);
    schemas.push({revision:r.revision,table,file:path.relative(p.root,file),columns:[...types.keys()]});
    progress({phase:'Schema',completed:++checkedFiles,total:totalFiles,detail:r.revision+' / '+table});
   }
   const from=table==='rates'?rateSource(r):parquet(files);
   const bad=(await conn.runAndReadAll(`SELECT count(*) n FROM ${from} WHERE revision IS DISTINCT FROM ?`,[r.revision])).getRowObjects()[0].n;
   if(Number(bad))throw new Error('Mixed revision in '+table);
  }
  const sources=new Set();
  for await(const e of shipmentBundles(r.checked))for(const s of e.bundle.sources)sources.add(s.sha256);
  for(const table of ['section301_scope_decisions','section232_scope_decisions','ieepa_reciprocal_scope_decisions','chapter99_provisions']) {
   const rows=(await conn.runAndReadAll(`SELECT DISTINCT pdf_sha256,hts_sha256 FROM ${parquet(r.files[table])}`)).getRowObjects();
   if(rows.some(row=>!sources.has(row.pdf_sha256)||!sources.has(row.hts_sha256)))throw new Error('Normalized source absent from executable bundle: '+table);
  }
  const notes=(await conn.runAndReadAll(`SELECT count(*) n FROM ${parquet(r.files.chapter99_notes)} WHERE source_text_sha256 IS DISTINCT FROM sha256(source_text)`)).getRowObjects()[0].n;
  if(Number(notes))throw new Error('Chapter99 note text/hash mismatch');
  const products=parquet(r.files.products_base),rates=rateSource(r);
  const duplicateProducts=(await conn.runAndReadAll(`SELECT count(*) n FROM (SELECT hts10,revision,valid_from,valid_until FROM ${products} GROUP BY ALL HAVING count(*)<>1)`)).getRowObjects()[0].n;
  if(Number(duplicateProducts))throw new Error('Duplicate product-base legal states');
  const absent=(await conn.runAndReadAll(`SELECT count(*) n FROM ${rates} r LEFT JOIN ${products} p ON r.hts10=p.hts10 AND r.revision=p.revision AND r.valid_from=p.valid_from AND r.valid_until=p.valid_until WHERE p.hts10 IS NULL`)).getRowObjects()[0].n;
  if(Number(absent))throw new Error('Missing product-base legal states');
  const tmp=await fs.mkdtemp(path.join(os.tmpdir(),'shipment-preflight-'));
  try {
   progress({phase:'Shipment reconciliation',completed:checkedRevisions,total:p.revisions.length,detail:r.revision+': checking every emitted cell'});
   const request=path.join(tmp,'request.json'),output=path.join(tmp,'verification.json');
   await fs.writeFile(request,JSON.stringify({normalized_dir:r.checked.root,rates:r.files.rates,classes:r.files.shipment_decision_classes,memberships:r.files.shipment_decision_membership,require_full_source_inventory:p.manifest.preparation_mode==='production',
    rates_partition_revision:r.artifact.rates_partitioning==='hive_revision'?r.revision:undefined}));
   try{await exec('Rscript',['scripts/validate_shipment_partition.R','--request='+request,'--output='+output],{cwd:root,maxBuffer:4e6});}
   catch(error){throw new Error('Shipment partition reconciliation failed: '+(error.stderr??error.message).slice(-2500));}
   reports.push(JSON.parse(await fs.readFile(output)));
   progress({phase:'Shipment reconciliation',completed:++checkedRevisions,total:p.revisions.length,detail:r.revision+' verified'});
  } finally {await fs.rm(tmp,{recursive:true,force:true});}
 }
 const optional_schema=schemas.map(s=>({...s,absent_optional_columns:[...signatures.get(s.table).keys()].filter(k=>!s.columns.includes(k))}))
  .filter(s=>s.absent_optional_columns.length||s.columns.some(k=>/\.(x|y)$/.test(k)));
 return {catalog:current,revisions:p.revisions.length,manifest_sha256:p.manifestHash,shipment_verification:reports,
  optional_schema,legal_coverage_complete:false};
}
async function insert(conn,table,rows) {
 for(let i=0;i<rows.length;i+=100){const chunk=rows.slice(i,i+100);await conn.run(`INSERT INTO ${table} VALUES ${chunk.map(r=>'('+r.map(()=>'?').join(',')+')').join(',')}`,chunk.flat());}
}
export async function prepareIndexRelease(conn,p,catalog) {
 const report=await preflightIndexRelease(conn,p,catalog);
 const progress=p.onProgress??(()=>{});
 await conn.run(RELEASE_MIGRATION);
 if((await conn.runAndReadAll('SELECT release_id FROM tariff_releases WHERE release_id=? OR dataset_version=?',[p.releaseId,p.manifest.dataset_version])).getRowObjects().length)throw new Error('Release already exists; releases are immutable');
 const schema=id(p.schema);
 await conn.run('INSERT INTO tariff_releases(release_id,schema_name,contract_version,dataset_version,evidence_snapshot_id,manifest_sha256,status) VALUES (?,?,?,?,?,?,?)',
  [p.releaseId,p.schema,INDEX_RELEASE_CONTRACT,p.manifest.dataset_version,p.manifest.evidence_snapshot_id,p.manifestHash,'preparing']);
 try {
  await conn.run('CREATE SCHEMA '+schema);await conn.run(migration.replaceAll('__RELEASE_SCHEMA__',schema));
  await conn.run(`INSERT INTO ${schema}.release_metadata VALUES (1,?,?,?,?,?)`,[p.manifest.preparation_mode,p.manifestHash,p.manifest.dataset_version,p.manifest.evidence_snapshot_id,JSON.stringify(report)]);
  const tables=Object.keys(INDEX_RELEASE_COLUMNS);let loadedTables=0;
  for(const table of tables) {
   const files=p.revisions.flatMap(r=>r.files[table]);
   const query=table==='rates'?p.revisions.map(r=>'SELECT * FROM '+rateSource(r)).join(' UNION ALL BY NAME '):'SELECT * FROM '+parquet(files);
   await conn.run(`CREATE TABLE ${schema}.${id(table)} AS ${query}`);
   for(const r of p.revisions)for(const f of r.artifact[table])await artifact(p.root,f);
   progress({phase:'Local tables',completed:++loadedTables,total:tables.length,detail:table});
  }
  for(const r of p.revisions) {
   let loadedBundles=0;
   const a=await artifact(p.root,r.artifact.bundle_index,true);
   await conn.run(`INSERT INTO ${schema}.rule_bundle_indexes VALUES (?,?,?)`,[r.revision,sha(a.bytes),a.bytes.toString()]);
   for await(const e of shipmentBundles(r.checked)) {
    const b=e.bundle,bid=e.bundle_id;
    await conn.run(`INSERT INTO ${schema}.rule_bundles VALUES (?,?,?,?,?,?)`,[bid,r.revision,e.valid_from,e.valid_until,e.sha256,e.text]);
    await insert(conn,`${schema}.rule_sources`,b.sources.map(s=>[bid,s.id,JSON.stringify(s)]));
    await insert(conn,`${schema}.executable_rules`,b.rules.map(rule=>[bid,rule.id,rule.action_id,rule.authority,JSON.stringify(rule)]));
    await insert(conn,`${schema}.rule_coverage`,b.coverage.map((c,i)=>[bid,i,c.authority,JSON.stringify(c)]));
    await insert(conn,`${schema}.executable_claims`,b.claim_definitions.map(c=>[bid,c.id,JSON.stringify(c)]));
    progress({phase:'Rule bundles',detail:r.revision+': '+(++loadedBundles)+' loaded'});
   }
  }
  const status=p.manifest.preparation_mode==='diagnostic'?'prepared_diagnostic':'prepared';
  await conn.run('UPDATE tariff_releases SET status=? WHERE release_id=?',[status,p.releaseId]);
  return {...report,release_id:p.releaseId,schema:p.schema,status};
 } catch(error){await conn.run("UPDATE tariff_releases SET status='failed' WHERE release_id=?",[p.releaseId]);throw error;}
}
