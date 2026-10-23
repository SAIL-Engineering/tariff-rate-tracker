/** Preserve absence and all row fields in the legacy aggregate transport. */
import {Bool, Float64, Utf8, Table, vectorFromArray, tableToIPC} from 'apache-arrow';
export function encodeRateRows(rows) {
  const columns = {};
  const keys = new Set(rows.flatMap(row => Object.keys(row)));
  for (const key of keys) {
    const values = rows.map(row => row[key] ?? null);
    const sample = values.find(value => value !== null);
    if (typeof sample === 'number') columns[key] = vectorFromArray(values, new Float64());
    else if (typeof sample === 'boolean') columns[key] = vectorFromArray(values, new Bool());
    else columns[key] = vectorFromArray(values.map(value => value === null ? null : String(value)), new Utf8());
  }
  return Buffer.from(tableToIPC(new Table(columns), 'stream'));
}
