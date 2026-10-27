import fs from 'node:fs/promises';
import assert from 'node:assert/strict';
import {DuckDBInstance} from '../../../frontend/node_modules/@duckdb/node-api/lib/index.js';
import {readReleaseManifest} from '../../../frontend/server/shipment-release.js';
import {activeShipmentRelease,resolveStoredShipment} from '../../../frontend/server/shipment-store.js';
const s=JSON.parse(await fs.readFile(process.argv[2]));
assert.equal(s.resumed,true);assert.equal(s.revision_build_rerun,false);
const p=await readReleaseManifest(s.output+'/release.json');
const i=await DuckDBInstance.create(s.database,{access_mode:'READ_ONLY'}),c=await i.connect();
const q=x=>"'"+x.replaceAll("'","''")+"'";
try {
 const release=(await c.runAndReadAll('SELECT * FROM tariff_releases WHERE release_id=?',[s.preparation.release_id])).getRowObjects()[0];
 assert.equal(release.status,'prepared_diagnostic');assert.equal(await activeShipmentRelease(c),null);
 const schema='"'+s.preparation.schema+'"';
 const source=r=>{const sql='read_parquet(['+r.files.rates.map(q).join(',')+'],hive_partitioning=false,union_by_name=true)';return 'SELECT *'+(r.artifact.rates_partitioning==='hive_revision'?','+q(r.revision)+'::VARCHAR AS revision':'')+' FROM '+sql;};
 const union=p.revisions.map(source).join(' UNION ALL BY NAME ');
 const counts=(await c.runAndReadAll(`SELECT revision,count(*)::INTEGER n FROM ${schema}.rates GROUP BY revision ORDER BY revision`)).getRowObjects();
 for(const sql of [`(${union}) EXCEPT ALL SELECT * FROM ${schema}.rates`,`SELECT * FROM ${schema}.rates EXCEPT ALL (${union})`]) {
  assert.equal(Number((await c.runAndReadAll(`SELECT count(*) n FROM (${sql})`)).getRowObjects()[0].n),0);
 }
 const request={hts10:'8703230190',country:'2010',entry_at:'2025-05-03T12:00:00-04:00',facts:{customs_value:100,ieepa_ftz_entry:false,s232_auto_passenger_vehicle:true,s232_auto_manufacture_year:2020,s232_auto_usmca_eligible:false}};
 const result=await resolveStoredShipment(c,release,request);
 assert.equal(result.dataset_version,p.manifest.dataset_version);
 assert.equal(result.complete_total,null);
 const autos=result.components.filter(x=>x.authority==='section_232'&&x.action_id.includes('auto'));
 assert.ok(autos.some(x=>x.amount===25),'Published auto charge must survive the stored rule delivery');
 const wrong=await resolveStoredShipment(c,release,{...request,dataset_version:'different-dataset'});
 assert.ok(wrong.source_errors.includes('dataset_version_mismatch'));
 const report={status:'local_roundtrip_verified',database:s.database,source_commit:s.source_commit,tooling_commit:s.tooling_commit,
  dataset_version:p.manifest.dataset_version,counts,all_columns_equal_to_original_artifacts:true,original_byte_pins_reverified:true,
  active_release:null,stored_auto_result:result,stale_version_rejected:true,legal_coverage_complete:false,production_qualified:false};
 await fs.writeFile(process.argv[3],JSON.stringify(report,null,2)+'\n',{flag:'wx'});
 console.log(JSON.stringify({status:report.status,counts,auto_components:autos.map(({action_id,amount,reporting_codes})=>({action_id,amount,reporting_codes})),complete_total:result.complete_total}));
} finally {c.closeSync();i.closeSync();}
