// Explicit local diagnostic reader. Never creates or activates a release.
import fs from 'node:fs/promises';
import {parseArgs} from 'node:util';
import {DuckDBInstance} from '@duckdb/node-api';
import {resolveStoredShipment} from '../server/shipment-store.js';
const {values}=parseArgs({options:{database:{type:'string'},release:{type:'string'},request:{type:'string'}}});
if(!values.database||values.database!==values.database.trim()||/^md:/i.test(values.database)||!values.release||!values.request)throw new Error('Provide a local --database, --release ID and --request JSON file');
const i=await DuckDBInstance.create(values.database,{access_mode:'READ_ONLY'}),c=await i.connect();
try {
 const rows=(await c.runAndReadAll('SELECT * FROM tariff_releases WHERE release_id=?',[values.release])).getRowObjects();
 if(rows.length!==1||!['prepared_diagnostic','prepared','validated'].includes(rows[0].status)||!/^release_[a-f0-9]{24}$/.test(rows[0].schema_name))throw new Error('Prepared immutable release not found');
 const request=JSON.parse(await fs.readFile(values.request));
 console.log(JSON.stringify({mode:'explicit_local_prepared_release',production_qualified:false,result:await resolveStoredShipment(c,rows[0],request)}));
} finally {c.closeSync();i.closeSync();}
