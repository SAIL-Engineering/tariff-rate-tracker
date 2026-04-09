import { DuckDBInstance } from '@duckdb/node-api';
import path from 'path';
import { fileURLToPath } from 'url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const PARQUET_PATH = path.resolve(__dirname, '..', 'data', 'timeseries', 'rate_timeseries_parquet');

let connection;

async function initDatabase() {
  const instance = await DuckDBInstance.create();
  connection = await instance.connect();
  await connection.run(`
    CREATE VIEW rates AS
    SELECT * FROM read_parquet('${PARQUET_PATH}/*/*.parquet', hive_partitioning = true)
  `);
}

async function testQuery() {
  const cleanCode = '2924297100';
  const countryCodes = ['4271', '2470'];
  
  let whereParts = [];
  whereParts.push(`hts10 = '${cleanCode}'`);
  whereParts.push(`country IN ('${countryCodes.join("','")}')`);
  
  const sql = `
    SELECT *
    FROM rates
    WHERE ${whereParts.join(' AND ')}
    ORDER BY country, effective_date ASC
  `;
  
  console.log('SQL Query:');
  console.log(sql);
  console.log('\n');
  
  const reader = await connection.runAndReadAll(sql);
  const rows = reader.getRowObjects();
  
  console.log(`Results: ${rows.length} rows`);
  for (const row of rows) {
    console.log(`  Country ${String(row.country)}, Revision ${String(row.revision)}: total_rate=${Number(row.total_rate)}`);
  }
}

await initDatabase();
await testQuery();
process.exit(0);
