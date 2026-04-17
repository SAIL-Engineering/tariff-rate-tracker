// =============================================================================
// Bulk Parser — CSV + XLSX ingestion
// =============================================================================
// Parses a File object into ParseResult { sheets }. XLSX files may contain
// multiple sheets — the UI lets the user pick the active sheet.
//
// Runs on the main thread. Files up to ~25k rows complete in under a second
// on a modest laptop; larger files should be promoted to a Web Worker in
// Phase 3 (see plan).

import * as XLSX from 'xlsx';
import type { ParseResult, ParsedSheet } from '@/types/bulk';

const MAX_ROWS_PER_SHEET = 100_000;

function isCSVFileName(name: string): boolean {
  return /\.csv$/i.test(name);
}

function isXLSXFileName(name: string): boolean {
  return /\.(xlsx|xls|xlsm)$/i.test(name);
}

/** Parse a File object into a ParseResult (one or more sheets). */
export async function parseBulkFile(file: File): Promise<ParseResult> {
  const fileType: 'csv' | 'xlsx' = isCSVFileName(file.name) ? 'csv' : 'xlsx';
  if (!isCSVFileName(file.name) && !isXLSXFileName(file.name)) {
    throw new Error(
      `Unsupported file type: ${file.name}. Upload a CSV or XLSX file.`,
    );
  }

  const buffer = await file.arrayBuffer();
  const workbook = XLSX.read(buffer, {
    type: 'array',
    cellDates: false, // we'll handle dates ourselves so excel-serial → ISO is consistent
    raw: true,
  });

  const sheets: ParsedSheet[] = [];
  for (const sheetName of workbook.SheetNames) {
    const ws = workbook.Sheets[sheetName];
    if (!ws) continue;
    const sheet = extractSheet(ws, sheetName);
    if (sheet) sheets.push(sheet);
  }

  if (sheets.length === 0) {
    throw new Error('File contains no readable sheets or is empty.');
  }

  // Prefer the first non-empty sheet as the active one.
  const activeSheetIndex = sheets.findIndex((s) => s.rowCount > 0);
  return {
    fileName: file.name,
    fileType,
    sheets,
    activeSheetIndex: activeSheetIndex >= 0 ? activeSheetIndex : 0,
  };
}

function extractSheet(
  ws: XLSX.WorkSheet,
  sheetName: string,
): ParsedSheet | null {
  // sheet_to_json with header:1 gives an array-of-arrays — safer than the
  // object form because we want to preserve the original header order.
  const aoa: unknown[][] = XLSX.utils.sheet_to_json(ws, {
    header: 1,
    defval: '',
    blankrows: false,
    raw: true,
  }) as unknown[][];

  if (!aoa || aoa.length === 0) {
    return { sheetName, headers: [], rows: [], rowCount: 0 };
  }

  // Locate the header row: first row that has at least 2 non-empty cells.
  let headerRowIdx = -1;
  for (let i = 0; i < Math.min(aoa.length, 20); i++) {
    const row = aoa[i];
    const nonEmpty = row.filter(
      (c) => c != null && String(c).trim().length > 0,
    ).length;
    if (nonEmpty >= 2) {
      headerRowIdx = i;
      break;
    }
  }
  if (headerRowIdx < 0) {
    return { sheetName, headers: [], rows: [], rowCount: 0 };
  }

  const headerRow = aoa[headerRowIdx];
  const headers: string[] = [];
  const seen = new Set<string>();
  for (let i = 0; i < headerRow.length; i++) {
    const raw = headerRow[i];
    let label = raw == null ? '' : String(raw).trim();
    if (!label) label = `Column ${i + 1}`;
    // Disambiguate duplicates
    let final = label;
    let counter = 2;
    while (seen.has(final)) {
      final = `${label} (${counter})`;
      counter++;
    }
    seen.add(final);
    headers.push(final);
  }

  const rows: Record<string, string>[] = [];
  const dataStart = headerRowIdx + 1;
  const dataEnd = Math.min(aoa.length, dataStart + MAX_ROWS_PER_SHEET);
  for (let r = dataStart; r < dataEnd; r++) {
    const row = aoa[r] ?? [];
    // Skip rows that are entirely empty
    let hasAny = false;
    const obj: Record<string, string> = {};
    for (let c = 0; c < headers.length; c++) {
      const cell = row[c];
      const str = cell == null ? '' : String(cell).trim();
      if (str !== '') hasAny = true;
      obj[headers[c]] = str;
    }
    if (hasAny) rows.push(obj);
  }

  return {
    sheetName,
    headers,
    rows,
    rowCount: rows.length,
  };
}
