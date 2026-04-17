// =============================================================================
// Bulk Validator + Normalizer
// =============================================================================
// Tier-1 validation: converts raw parsed rows into DutyResultRow objects with
// source preserved verbatim, canonical fields normalized, and validation
// issues surfaced. Blocking issues quarantine the row from calculation;
// warnings do not.
//
// The date model distinguishes the legal duty-applicability date (entryDate)
// from a derived transitEvidenceDate used only for in-transit exception
// screening. Both are preserved independently — the system never equates them.

import type {
  ColumnMapping,
  DutyResultRow,
  NormalizedRow,
  ValidationIssue,
  CanonicalFieldKey,
  ExceptionFlag,
} from '@/types/bulk';
import { isChapter99, ch99ToAuthority } from './chapter99';

// -----------------------------------------------------------------------------
// Primitive parsers
// -----------------------------------------------------------------------------

/** Parse a value from various spreadsheet formats into a positive number (or null). */
export function parseCurrency(raw: string): number | null {
  if (!raw) return null;
  // Strip currency symbols, commas, spaces, parens (accounting negatives)
  const s = raw.replace(/[\$£€¥,\s]/g, '').replace(/^\((.*)\)$/, '-$1');
  if (!s) return null;
  const n = Number(s);
  return Number.isFinite(n) ? n : null;
}

export function parseNumber(raw: string): number | null {
  if (!raw) return null;
  const s = raw.replace(/[,\s]/g, '');
  const n = Number(s);
  return Number.isFinite(n) ? n : null;
}

/**
 * Parse a date from common spreadsheet formats.
 * Supports ISO (YYYY-MM-DD), US (MM/DD/YYYY), EU (DD/MM/YYYY — only if first
 * component clearly >12), named months, and Excel serial numbers.
 * Returns a YYYY-MM-DD string or null.
 */
export function parseDate(raw: string): string | null {
  if (!raw) return null;
  const s = String(raw).trim();
  if (!s) return null;

  // ISO: 2024-04-15 or 2024/04/15
  const iso = /^(\d{4})[-/](\d{1,2})[-/](\d{1,2})$/.exec(s);
  if (iso) {
    const y = Number(iso[1]);
    const m = Number(iso[2]);
    const d = Number(iso[3]);
    return formatYMD(y, m, d);
  }

  // Excel serial (number, pre-1900 offset handled by 25569)
  // Excel serial 1 = 1900-01-01 (with the 1900 leap-year bug). We use the
  // standard offset for serials >= 60 which covers all modern dates.
  if (/^\d+(\.\d+)?$/.test(s)) {
    const n = Number(s);
    if (n > 25000 && n < 80000) {
      const ms = Math.round((n - 25569) * 86400 * 1000);
      const d = new Date(ms);
      if (!isNaN(d.getTime())) {
        return d.toISOString().slice(0, 10);
      }
    }
  }

  // MM/DD/YYYY or M/D/YY — US style, the most common in broker files
  const us = /^(\d{1,2})[/-](\d{1,2})[/-](\d{2,4})$/.exec(s);
  if (us) {
    let m = Number(us[1]);
    let d = Number(us[2]);
    let y = Number(us[3]);
    if (y < 100) y += y < 50 ? 2000 : 1900;
    // If first component > 12, it must be EU (DD/MM/YYYY)
    if (m > 12 && d <= 12) {
      const tmp = m;
      m = d;
      d = tmp;
    }
    return formatYMD(y, m, d);
  }

  // Fallback: let Date try
  const fallback = new Date(s);
  if (!isNaN(fallback.getTime())) {
    return fallback.toISOString().slice(0, 10);
  }

  return null;
}

function formatYMD(y: number, m: number, d: number): string | null {
  if (!Number.isFinite(y) || !Number.isFinite(m) || !Number.isFinite(d)) return null;
  if (m < 1 || m > 12 || d < 1 || d > 31) return null;
  const mm = String(m).padStart(2, '0');
  const dd = String(d).padStart(2, '0');
  return `${y}-${mm}-${dd}`;
}

/**
 * Strip dots/spaces from an HTS code and return the digits.
 * Returns null for clearly non-HTS inputs.
 */
export function parseHts(raw: string): string | null {
  if (!raw) return null;
  const digits = raw.replace(/[^\d]/g, '');
  if (digits.length < 4 || digits.length > 10) return null;
  return digits;
}

export function parseMOT(raw: string): 'ocean' | 'air' | 'land' | null {
  if (!raw) return null;
  const s = raw.toLowerCase().trim();
  if (!s) return null;
  if (/ocean|vessel|sea|ship|maritime/.test(s)) return 'ocean';
  if (/air|flight|plane/.test(s)) return 'air';
  if (/truck|rail|road|land|border/.test(s)) return 'land';
  // Numeric MOT codes from CBP 7501: 10/11 = vessel, 40/41 = air, 20/21 = rail, 30 = truck
  if (/^1[01]$/.test(s)) return 'ocean';
  if (/^4[01]$/.test(s)) return 'air';
  if (/^(2[01]|30)$/.test(s)) return 'land';
  return null;
}

// -----------------------------------------------------------------------------
// Country resolution — jurisdiction-agnostic
// -----------------------------------------------------------------------------
// The backend rate matrix is keyed by Census country codes. We accept ISO2,
// ISO3, Census codes, or country names and resolve via a provided lookup map.

export interface ResolvedCountry {
  census: string;
  alpha2: string | null;
  alpha3: string | null;
  name: string;
}

export interface CountryResolver {
  /** Resolve any representation (Census / ISO2 / ISO3 / name) to a Census code. */
  toCensus(input: string): string | null;
  /** Return the full metadata record for any input, or null. */
  resolve(input: string): ResolvedCountry | null;
  /** Look up a ResolvedCountry by Census code. */
  byCensus(census: string): ResolvedCountry | null;
}

export function buildCountryResolver(
  countries: Array<{
    code: string;
    name: string;
    alpha2: string | null;
    alpha3: string | null;
  }>,
): CountryResolver {
  const byCensusMap = new Map<string, ResolvedCountry>();
  const byAlpha2 = new Map<string, ResolvedCountry>();
  const byAlpha3 = new Map<string, ResolvedCountry>();
  const byName = new Map<string, ResolvedCountry>();

  for (const c of countries) {
    const r: ResolvedCountry = {
      census: c.code,
      alpha2: c.alpha2,
      alpha3: c.alpha3,
      name: c.name,
    };
    byCensusMap.set(c.code, r);
    if (c.alpha2) byAlpha2.set(c.alpha2.toUpperCase(), r);
    if (c.alpha3) byAlpha3.set(c.alpha3.toUpperCase(), r);
    byName.set(c.name.toLowerCase(), r);
  }

  function resolve(input: string): ResolvedCountry | null {
    if (!input) return null;
    const s = input.trim();
    if (!s) return null;
    if (/^\d{1,6}$/.test(s)) {
      return byCensusMap.get(s) ?? null;
    }
    const upper = s.toUpperCase();
    if (s.length === 2 && byAlpha2.has(upper)) return byAlpha2.get(upper)!;
    if (s.length === 3 && byAlpha3.has(upper)) return byAlpha3.get(upper)!;
    const lower = s.toLowerCase();
    if (byName.has(lower)) return byName.get(lower)!;
    return null;
  }

  return {
    toCensus(input: string): string | null {
      return resolve(input)?.census ?? null;
    },
    resolve,
    byCensus(census: string): ResolvedCountry | null {
      return byCensusMap.get(census) ?? null;
    },
  };
}

// -----------------------------------------------------------------------------
// Normalization + validation
// -----------------------------------------------------------------------------

function emptyNormalized(): NormalizedRow {
  return {
    hts10: null,
    htsDescription: null,
    description: null,
    spi: null,
    countryOfOrigin: null,
    countryOfOriginAlpha2: null,
    countryOfOriginName: null,
    importCountry: null,
    exportCountry: null,
    partNumber: null,
    tariffCategory: null,
    customsValue: null,
    quantity: null,
    unitOfMeasure: null,
    entryNumber: null,
    shipmentId: null,
    masterBill: null,
    houseBill: null,
    invoiceNumber: null,
    invoiceLineNumber: null,
    brokerRefNumber: null,
    customerRefNumber: null,
    itNumber: null,
    importer: null,
    consignee: null,
    supplier: null,
    billToParty: null,
    carrier: null,
    vesselName: null,
    voyageFlight: null,
    entryPort: null,
    destination: null,
    modeOfTransport: null,
    portOfLading: null,
    trailerNumber: null,
    entryDate: null,
    shipmentDate: null,
    exportDate: null,
    importDate: null,
    arrivalDate: null,
    itDate: null,
    cargoReleaseDate: null,
    liquidationDate: null,
    transitEvidenceDate: null,
    uploadedDuty: null,
    uploadedMPF: null,
    uploadedHMF: null,
    uploadedFees: null,
    uploadedAmountBilled: null,
    uploadedPaidStatus: null,
  };
}

function readMapped(
  source: Record<string, string>,
  mapping: ColumnMapping,
  key: CanonicalFieldKey,
): string {
  const m = mapping[key];
  if (!m || !m.sourceColumn) return '';
  return source[m.sourceColumn] ?? '';
}

export interface NormalizeOptions {
  resolver: CountryResolver;
  /** Default import country when none is mapped. Null = no assumption. */
  defaultImportCountry?: string | null;
}

export function normalizeRow(
  source: Record<string, string>,
  mapping: ColumnMapping,
  opts: NormalizeOptions,
): { normalized: NormalizedRow; validation: ValidationIssue[]; flags: ExceptionFlag[] } {
  const n = emptyNormalized();
  const validation: ValidationIssue[] = [];
  const flags: ExceptionFlag[] = [];
  const resolver = opts.resolver;

  // -- Classification --
  n.hts10 = parseHts(readMapped(source, mapping, 'hts10'));
  n.htsDescription = readMapped(source, mapping, 'htsDescription') || null;
  n.description = readMapped(source, mapping, 'description') || null;
  n.spi = readMapped(source, mapping, 'spi') || null;
  n.partNumber = readMapped(source, mapping, 'partNumber') || null;
  n.tariffCategory = readMapped(source, mapping, 'tariffCategory') || null;

  const rawCoo = readMapped(source, mapping, 'countryOfOrigin');
  if (rawCoo) {
    const resolved = resolver.resolve(rawCoo);
    if (resolved) {
      n.countryOfOrigin = resolved.census;
      n.countryOfOriginAlpha2 = resolved.alpha2;
      n.countryOfOriginName = resolved.name;
    } else {
      n.countryOfOrigin = rawCoo;
      // Still try to interpret the raw value as an alpha2 so the UI has
      // something user-friendly to display even when the Census lookup
      // failed (e.g., broker used a non-standard code).
      if (/^[A-Za-z]{2}$/.test(rawCoo.trim())) {
        n.countryOfOriginAlpha2 = rawCoo.trim().toUpperCase();
      }
      validation.push({
        field: 'countryOfOrigin',
        severity: 'warning',
        code: 'country_unresolved',
        message: `Country of origin "${rawCoo}" could not be resolved to a Census code.`,
      });
      flags.push({
        kind: 'unsupported_country',
        severity: 'warning',
        message: `Unresolved country of origin: "${rawCoo}"`,
        field: 'countryOfOrigin',
      });
    }
  }

  const rawImportCountry = readMapped(source, mapping, 'importCountry');
  n.importCountry = rawImportCountry
    ? resolver.toCensus(rawImportCountry) ?? rawImportCountry
    : opts.defaultImportCountry ?? null;

  const rawExportCountry = readMapped(source, mapping, 'exportCountry');
  n.exportCountry = rawExportCountry
    ? resolver.toCensus(rawExportCountry) ?? rawExportCountry
    : null;

  // -- Values --
  n.customsValue = parseCurrency(readMapped(source, mapping, 'customsValue'));
  n.quantity = parseNumber(readMapped(source, mapping, 'quantity'));
  n.unitOfMeasure = readMapped(source, mapping, 'unitOfMeasure') || null;

  // -- Identity --
  n.entryNumber = readMapped(source, mapping, 'entryNumber') || null;
  n.shipmentId = readMapped(source, mapping, 'shipmentId') || null;
  n.masterBill = readMapped(source, mapping, 'masterBill') || null;
  n.houseBill = readMapped(source, mapping, 'houseBill') || null;
  n.invoiceNumber = readMapped(source, mapping, 'invoiceNumber') || null;
  n.invoiceLineNumber = readMapped(source, mapping, 'invoiceLineNumber') || null;
  n.brokerRefNumber = readMapped(source, mapping, 'brokerRefNumber') || null;
  n.customerRefNumber = readMapped(source, mapping, 'customerRefNumber') || null;
  n.itNumber = readMapped(source, mapping, 'itNumber') || null;

  // -- Parties --
  n.importer = readMapped(source, mapping, 'importer') || null;
  n.consignee = readMapped(source, mapping, 'consignee') || null;
  n.supplier = readMapped(source, mapping, 'supplier') || null;
  n.billToParty = readMapped(source, mapping, 'billToParty') || null;

  // -- Logistics --
  n.carrier = readMapped(source, mapping, 'carrier') || null;
  n.vesselName = readMapped(source, mapping, 'vesselName') || null;
  n.voyageFlight = readMapped(source, mapping, 'voyageFlight') || null;
  n.entryPort = readMapped(source, mapping, 'entryPort') || null;
  n.destination = readMapped(source, mapping, 'destination') || null;
  n.modeOfTransport = parseMOT(readMapped(source, mapping, 'modeOfTransport'));
  n.portOfLading = readMapped(source, mapping, 'portOfLading') || null;
  n.trailerNumber = readMapped(source, mapping, 'trailerNumber') || null;

  // -- Timeline --
  n.entryDate = parseDate(readMapped(source, mapping, 'entryDate'));
  n.shipmentDate = parseDate(readMapped(source, mapping, 'shipmentDate'));
  n.exportDate = parseDate(readMapped(source, mapping, 'exportDate'));
  n.importDate = parseDate(readMapped(source, mapping, 'importDate'));
  n.arrivalDate = parseDate(readMapped(source, mapping, 'arrivalDate'));
  n.itDate = parseDate(readMapped(source, mapping, 'itDate'));
  n.cargoReleaseDate = parseDate(readMapped(source, mapping, 'cargoReleaseDate'));
  n.liquidationDate = parseDate(readMapped(source, mapping, 'liquidationDate'));

  // transitEvidenceDate: best-available proxy for in-transit screening.
  // Prefers exportDate (goods physically left origin) → itDate (in-bond
  // movement) → shipmentDate (generic business ship date). Never equated
  // with the legal in-transit trigger.
  n.transitEvidenceDate = n.exportDate ?? n.itDate ?? n.shipmentDate ?? null;

  // -- Reconciliation --
  n.uploadedDuty = parseCurrency(readMapped(source, mapping, 'uploadedDuty'));
  n.uploadedMPF = parseCurrency(readMapped(source, mapping, 'uploadedMPF'));
  n.uploadedHMF = parseCurrency(readMapped(source, mapping, 'uploadedHMF'));
  n.uploadedFees = parseCurrency(readMapped(source, mapping, 'uploadedFees'));
  n.uploadedAmountBilled = parseCurrency(
    readMapped(source, mapping, 'uploadedAmountBilled'),
  );
  n.uploadedPaidStatus = readMapped(source, mapping, 'uploadedPaidStatus') || null;

  // -- Chapter 99 detection --
  // Chapter 99 rows are broker-reported authority break-outs (e.g. one row
  // per Section 232 / 301 / IEEPA contribution). They do NOT have rows in
  // the rate matrix and should NOT trigger the missing-value or
  // rate-lookup rules.
  const ch99 = isChapter99(n.hts10);

  // -- Validation rules --
  if (!n.hts10) {
    validation.push({
      field: 'hts10',
      severity: 'blocking',
      code: 'missing_hts',
      message: 'HTS code missing or invalid.',
      suggestion: 'Ensure the HTS column is mapped and contains 4–10 digits.',
    });
    flags.push({
      kind: 'missing_hts',
      severity: 'error',
      message: 'Missing HTS code',
      field: 'hts10',
    });
  }

  // Chapter 99 rows may legitimately carry zero customs value because the
  // duty amount sits on the row, not a separately-entered value.
  if (!ch99 && (n.customsValue == null || n.customsValue <= 0)) {
    validation.push({
      field: 'customsValue',
      severity: 'blocking',
      code: 'missing_value',
      message: 'Customs value missing or non-positive.',
    });
    flags.push({
      kind: 'missing_value',
      severity: 'error',
      message: 'Missing or non-positive customs value',
      field: 'customsValue',
    });
  }

  // A duty-applicability date is required for non-chapter-99 rows.
  // Chapter 99 rows inherit their merged line item's date and don't need
  // their own rate lookup.
  if (!ch99 && !n.entryDate) {
    if (n.arrivalDate || n.importDate || n.shipmentDate) {
      validation.push({
        field: 'entryDate',
        severity: 'warning',
        code: 'missing_entry_date',
        message:
          'Entry date missing. Falling back to arrival / import / shipment date.',
      });
      flags.push({
        kind: 'date_ambiguity',
        severity: 'warning',
        message: 'Entry date missing — using fallback date for rate lookup.',
        field: 'entryDate',
      });
    } else {
      validation.push({
        field: 'entryDate',
        severity: 'blocking',
        code: 'missing_date',
        message: 'No date available for duty rate lookup.',
      });
      flags.push({
        kind: 'missing_date',
        severity: 'error',
        message: 'No usable date for rate lookup',
        field: 'entryDate',
      });
    }
  }

  // Date ambiguity: if shipmentDate and entryDate are >180 days apart, flag.
  if (n.shipmentDate && n.entryDate) {
    const ship = new Date(n.shipmentDate).getTime();
    const entry = new Date(n.entryDate).getTime();
    const diffDays = Math.abs(entry - ship) / (1000 * 60 * 60 * 24);
    if (diffDays > 180) {
      flags.push({
        kind: 'date_ambiguity',
        severity: 'info',
        message: `Shipment date and entry date are ${Math.round(diffDays)} days apart — verify.`,
      });
    }
  }

  return { normalized: n, validation, flags };
}

// -----------------------------------------------------------------------------
// Build DutyResultRow list from a parsed sheet
// -----------------------------------------------------------------------------

let rowIdCounter = 0;
function nextRowId(): string {
  rowIdCounter++;
  return `row_${Date.now().toString(36)}_${rowIdCounter}`;
}

export function buildRows(
  sourceRows: Record<string, string>[],
  mapping: ColumnMapping,
  opts: NormalizeOptions,
): DutyResultRow[] {
  const rows: DutyResultRow[] = [];
  for (let i = 0; i < sourceRows.length; i++) {
    const source = sourceRows[i];
    const { normalized, validation, flags } = normalizeRow(source, mapping, opts);
    const ch99 = isChapter99(normalized.hts10);
    rows.push({
      rowId: nextRowId(),
      sourceRowIndex: i + 1,
      source,
      normalized,
      calculated: null,
      variance: null,
      flags,
      validation,
      isChapter99: ch99,
      ch99Authority: ch99 ? ch99ToAuthority(normalized.hts10) : null,
    });
  }
  return rows;
}
