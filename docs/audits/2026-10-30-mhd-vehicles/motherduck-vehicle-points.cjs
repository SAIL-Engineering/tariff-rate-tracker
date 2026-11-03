// Read-only comparison with the catalog configured for the tariff API.
const fs=require('node:fs'),path=require('node:path');
const {pathToFileURL}=require('node:url');
const {values}=require('node:util').parseArgs({options:{output:{type:'string'}}});
if(!values.output)throw new Error('Provide a new --output path');
const root=path.resolve(__dirname,'../../..');
const req=require('node:module').createRequire(path.join(root,'frontend/package.json'));
req('dotenv').config({path:path.join(root,'.env'),quiet:true});
if(!process.env.MOTHERDUCK_TOKEN)throw new Error('Configured MotherDuck token is unavailable');
process.env.motherduck_token=process.env.MOTHERDUCK_TOKEN;
(async()=>{
 const {getMotherDuckDatabase}=await import(pathToFileURL(path.join(root,'frontend/server/config.js')));
 const catalog=getMotherDuckDatabase();
 const {DuckDBInstance}=req('@duckdb/node-api');
 const instance=await DuckDBInstance.create('md:'+catalog,{access_mode:'READ_ONLY'}),connection=await instance.connect();
 try {
  if((await connection.runAndReadAll('SELECT current_database() AS catalog_name')).getRowObjects()[0].catalog_name!==catalog)throw new Error('Wrong configured catalog');
  await connection.run('BEGIN TRANSACTION READ ONLY');
  const schema=(await connection.runAndReadAll('DESCRIBE rates')).getRowObjects();
  const available=new Set(schema.map(r=>r.column_name));
  for(const key of ['hts10','country','revision','valid_from','valid_until'])if(!available.has(key))throw new Error('Missing rate identity column '+key);
  const desired=['rate_232','statutory_rate_232','total_rate','statutory_total_rate','copper_share','is_copper_heading',
   'shipment_contract_version','shipment_dataset_version','shipment_status','shipment_decision_ids_json'];
  const columns=desired.filter(k=>available.has(k));
  const entries=[['2025-11-01','8705900080'],['2025-11-01','8702103100'],['2025-11-01','8706000300'],
   ['2026-04-05','8705900080'],['2026-04-05','8702103100'],['2026-04-05','8706000300']];
  const origins=['1220','2010','5700'];
  const sql=`WITH entries(day,hts10) AS (VALUES ${entries.map(()=>'(CAST(? AS DATE),?)').join(',')}),
   origins(country) AS (VALUES ${origins.map(()=>'(?)').join(',')})
   SELECT e.day::VARCHAR entry_day,e.hts10,o.country,r.revision,r.valid_from::VARCHAR valid_from,r.valid_until::VARCHAR valid_until,
   ${columns.map(k=>'r.'+k).join(',')} FROM entries e CROSS JOIN origins o LEFT JOIN rates r
   ON r.hts10=e.hts10 AND CAST(r.country AS VARCHAR)=o.country AND r.valid_from<=e.day AND r.valid_until>=e.day
   ORDER BY e.day,e.hts10,o.country,r.revision`;
  const params=[...entries.flat(),...origins];
  const rows=(await connection.runAndReadAll(sql,params)).getRowObjects();
  await connection.run('ROLLBACK');
  fs.writeFileSync(path.resolve(values.output),JSON.stringify({catalog,access_mode:'READ_ONLY',sql,params,columns,
   missing_shipment_columns:desired.filter(k=>k.startsWith('shipment_')&&!available.has(k)),
   qualification:'Stored rate parameters, not validated shipment totals. Point calculations require actual vehicle/part identity, manufacture year, approved content and claim facts. Bus and vehicle actions are different; these are stored candidate observations, not validated complete totals. Daily rows cannot represent the first-minute transition.',rows},null,2)+'\n',{flag:'wx'});
  console.log(JSON.stringify({catalog,rows:rows.length,missingShipmentColumns:desired.filter(k=>k.startsWith('shipment_')&&!available.has(k))}));
 } finally {connection.closeSync();instance.closeSync();}
})().catch(e=>{console.error(e.message);process.exitCode=1;});
