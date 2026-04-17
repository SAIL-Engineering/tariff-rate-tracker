// =============================================================================
// Bulk Duty Analysis — Type Definitions
// =============================================================================
// The bulk workflow models every uploaded row with three parallel namespaces
// (source / normalized / calculated) to preserve full auditability from
// uploaded spreadsheet → normalized model → calculated result → exported file.

import type { LandedCostResult, DutyBreakdown, RateBasis, AuthorityKey } from './tariff';

// -----------------------------------------------------------------------------
// Canonical field registry
// -----------------------------------------------------------------------------

export type CanonicalFieldKey =
  // Classification / commercial
  | 'hts10'
  | 'htsDescription'
  | 'description'
  | 'spi'
  | 'countryOfOrigin'
  | 'importCountry'
  | 'exportCountry'
  | 'partNumber'
  | 'tariffCategory'
  // Values
  | 'customsValue'
  | 'quantity'
  | 'unitOfMeasure'
  // Entry / shipment identity
  | 'entryNumber'
  | 'shipmentId'
  | 'masterBill'
  | 'houseBill'
  | 'invoiceNumber'
  | 'invoiceLineNumber'
  | 'brokerRefNumber'
  | 'customerRefNumber'
  | 'itNumber'
  // Parties
  | 'importer'
  | 'consignee'
  | 'supplier'
  | 'billToParty'
  // Logistics / movement
  | 'carrier'
  | 'vesselName'
  | 'voyageFlight'
  | 'entryPort'
  | 'destination'
  | 'modeOfTransport'
  | 'portOfLading'
  | 'trailerNumber'
  // Timeline
  | 'entryDate'
  | 'shipmentDate'
  | 'exportDate'
  | 'importDate'
  | 'arrivalDate'
  | 'itDate'
  | 'cargoReleaseDate'
  | 'liquidationDate'
  // Reconciliation (broker-reported)
  | 'uploadedDuty'
  | 'uploadedMPF'
  | 'uploadedHMF'
  | 'uploadedFees'
  | 'uploadedAmountBilled'
  | 'uploadedPaidStatus';

export type CanonicalFieldType =
  | 'hts'
  | 'currency'
  | 'date'
  | 'country'
  | 'string'
  | 'number'
  | 'mot';

export type CanonicalFieldGroup =
  | 'identity'
  | 'parties'
  | 'logistics'
  | 'dates'
  | 'classification'
  | 'values'
  | 'reconciliation';

export interface CanonicalFieldDef {
  key: CanonicalFieldKey;
  label: string;
  type: CanonicalFieldType;
  required: boolean;
  group: CanonicalFieldGroup;
  aliases: string[];
  description: string;
  /**
   * Operational priority for grouping / recommendation in the mapping UI.
   * 'grouping' fields (entry number, shipment id) drive rollups and should
   * be surfaced prominently even when not strictly required.
   */
  priority?: 'required' | 'grouping' | 'optional';
}

export interface MappedField {
  /** Verbatim header name from the source file, or null if unmapped. */
  sourceColumn: string | null;
  /** 0–1 confidence from auto-detection. */
  confidence: number;
  /** True when the user manually overrode the auto-detection. */
  manualOverride: boolean;
  /** Which preset (if any) contributed this mapping. */
  presetSource?: string;
}

export type ColumnMapping = Partial<Record<CanonicalFieldKey, MappedField>>;

// -----------------------------------------------------------------------------
// Row model — three parallel namespaces
// -----------------------------------------------------------------------------

/** Verbatim original columns, keyed by source header name. Never modified. */
export type SourceFields = Record<string, string>;

/** Canonical SAIL fields after parsing + normalization. */
export interface NormalizedRow {
  // Classification / commercial
  hts10: string | null;
  htsDescription: string | null;
  description: string | null;
  spi: string | null;
  countryOfOrigin: string | null;
  /** ISO alpha-2 code for display (resolved from the source country during normalization). */
  countryOfOriginAlpha2: string | null;
  /** Resolved human-readable country name (for tooltips). */
  countryOfOriginName: string | null;
  importCountry: string | null; // jurisdiction-agnostic; null means "unspecified"
  exportCountry: string | null;
  partNumber: string | null;
  tariffCategory: string | null;

  // Values
  customsValue: number | null;
  quantity: number | null;
  unitOfMeasure: string | null;

  // Entry / shipment identity (entry is the primary customs anchor)
  entryNumber: string | null;
  shipmentId: string | null;
  masterBill: string | null;
  houseBill: string | null;
  invoiceNumber: string | null;
  invoiceLineNumber: string | null;
  brokerRefNumber: string | null;
  customerRefNumber: string | null;
  itNumber: string | null;

  // Parties
  importer: string | null;
  consignee: string | null;
  supplier: string | null;
  billToParty: string | null;

  // Logistics / movement
  carrier: string | null;
  vesselName: string | null;
  voyageFlight: string | null;
  entryPort: string | null;
  destination: string | null;
  modeOfTransport: 'ocean' | 'air' | 'land' | null;
  portOfLading: string | null;
  trailerNumber: string | null;

  // Timeline — preserve the full customs-lifecycle timeline separately.
  // entryDate is the primary duty-applicability date.
  // The other fields are kept distinct because they carry different legal meaning.
  entryDate: string | null; // YYYY-MM-DD — primary duty applicability
  shipmentDate: string | null; // generic business "ship date" — NOT a legal trigger
  exportDate: string | null; // date goods left origin
  importDate: string | null;
  arrivalDate: string | null;
  itDate: string | null; // in-bond movement date
  cargoReleaseDate: string | null;
  liquidationDate: string | null;
  /**
   * Best-available proxy for in-transit exception screening.
   * Derived (not user-mapped). Prefers, in order: exportDate → itDate →
   * shipmentDate. Never equated with the legal in-transit trigger — this is
   * screening evidence only.
   */
  transitEvidenceDate: string | null;

  // Reconciliation source values (broker / ACE)
  uploadedDuty: number | null;
  uploadedMPF: number | null;
  uploadedHMF: number | null;
  uploadedFees: number | null;
  uploadedAmountBilled: number | null;
  uploadedPaidStatus: string | null;
}

export interface CalculatedRow {
  /** Which date actually drove the rate lookup. */
  controllingDate: string;
  controllingDateField: 'entryDate' | 'shipmentDate' | 'imputed';
  /** Census country code used for the lookup. */
  countryCodeUsed: string;
  /** Full duty-stack breakdown — reused from the single-HTS engine. */
  breakdown: DutyBreakdown[];
  baseRate: number;
  baseDuty: number;
  additionalRate: number;
  additionalDuty: number;
  totalDuty: number;
  totalDutyRate: number;
  mpf: number;
  hmf: number;
  totalFees: number;
  landedCost: number;
  effectiveRatePct: number;
  rateRevision: string;
  rateBasis: RateBasis;
  assumptions: string[];
}

export type ExceptionFlagKind =
  | 'in_transit_candidate'
  | 'date_ambiguity'
  | 'missing_hts'
  | 'missing_value'
  | 'missing_date'
  | 'unsupported_country'
  | 'no_rate_found'
  | 'duplicate_row'
  | 'broker_variance'
  | 'psc_candidate'
  | 'spi_review'
  | 'composition_required'
  /** Lines inside a single shipment/entry disagree on a field expected to be uniform. */
  | 'group_inconsistency';

export type FlagSeverity = 'info' | 'warning' | 'error';

export interface ExceptionFlag {
  kind: ExceptionFlagKind;
  severity: FlagSeverity;
  message: string;
  field?: string;
}

export interface ValidationIssue {
  field: CanonicalFieldKey | 'row';
  severity: 'warning' | 'blocking';
  code: string;
  message: string;
  suggestion?: string;
}

export interface ReconciliationVariance {
  uploadedDuty: number | null;
  calculatedDuty: number;
  dutyVariance: number | null;
  dutyVariancePct: number | null;
  uploadedMPF: number | null;
  calculatedMPF: number;
  mpfVariance: number | null;
  uploadedHMF: number | null;
  calculatedHMF: number;
  hmfVariance: number | null;
  severity: 'match' | 'minor' | 'material' | 'critical' | 'no_upload';
}

export interface DutyResultRow {
  rowId: string;
  sourceRowIndex: number; // 1-based
  source: SourceFields;
  normalized: NormalizedRow;
  calculated: CalculatedRow | null;
  variance: ReconciliationVariance | null;
  flags: ExceptionFlag[];
  validation: ValidationIssue[];
  shipmentGroupId?: string;
  entryGroupId?: string;
  /** Set when this row is a Chapter 99 additional-tariff line. */
  isChapter99?: boolean;
  /** SAIL authority this Chapter 99 code maps to, when isChapter99 is true. */
  ch99Authority?: AuthorityKey | null;
  /** Stable id of the MergedLineItem this row belongs to (main + ch99 rows share this). */
  mergedLineItemId?: string;
  /** True when this row is the main (chapter 1-97) row inside its merged line item. */
  isMainLine?: boolean;
  /** Dedupe / lookup key used to fetch rates. */
  rateKey?: string;
  /** true once calculation pass ran (even if it produced flags). */
  calculated_at?: string;
}

// -----------------------------------------------------------------------------
// Merged line items — reconcile chapter 99 rows into their parent line
// -----------------------------------------------------------------------------
//
// A "merged line item" bundles a main (chapter 1-97) row together with every
// Chapter 99 row from the same source file that describes the same physical
// line. Broker files split the duty stack across multiple rows — one for
// the MFN base, and one row per applied Chapter 99 program. Merging puts
// them back together so we can compare SAIL's calculated stack against the
// broker's reported stack authority-by-authority.
//
// Merge key: entryNumber + (invoiceLineNumber || partNumber || tariffCategory).
// Rows missing a usable disambiguator become their own single-row line.

/** Per-authority comparison between SAIL's calculated stack and the broker-reported stack. */
export interface AuthorityStackEntry {
  /** Authority key, or 'base' for the chapter 1-97 MFN row. */
  key: 'base' | 'mfn' | 'rate_232' | 'rate_301' | 'rate_ieepa_recip' | 'rate_ieepa_fent' | 'rate_s122' | 'rate_section_201' | 'rate_other' | 'mpf' | 'hmf';
  label: string;
  /** SAIL rate as a fraction (0.15 = 15%). */
  sailRate: number | null;
  sailAmount: number | null;
  /** Broker-reported amount summed across all chapter 99 rows that mapped here. */
  brokerAmount: number | null;
  /** Derived broker rate = brokerAmount / lineCustomsValue. */
  brokerRate: number | null;
  variance: number | null;
  /** Rows that contributed the broker amount, if any (for drill-down / trace). */
  sourceRowIds?: string[];
  /** Chapter 99 HTS codes that appeared for this authority. */
  ch99Codes?: string[];
}

export interface MergedLineItem {
  id: string;
  mergeKey: string;
  entryGroupId: string;
  shipmentGroupId: string;
  /** All row ids contained in this merged line (main + ch99). */
  rowIds: string[];
  /** Row id of the main chapter 1-97 row, or null if only ch99 rows. */
  mainRowId: string | null;
  /** Row id of each Chapter 99 row. */
  ch99RowIds: string[];
  // Display metadata inherited from the main row (or first row if no main).
  hts10: string | null;
  description: string | null;
  partNumber: string | null;
  invoiceLineNumber: string | null;
  countryOfOrigin: string | null;
  countryOfOriginAlpha2: string | null;
  countryOfOriginName: string | null;
  controllingDate: string | null;
  customsValue: number | null;
  quantity: number | null;
  // SAIL calculation results (from main row)
  sailTotalDuty: number | null;
  sailMpf: number | null;
  sailHmf: number | null;
  sailTotalFees: number | null;
  sailEffectiveRatePct: number | null;
  sailLandedCost: number | null;
  sailStack: AuthorityStackEntry[];
  // Broker-reported totals (summed across all contained rows)
  brokerTotalDuty: number | null;
  brokerMpf: number | null;
  brokerHmf: number | null;
  brokerFees: number | null;
  brokerStack: AuthorityStackEntry[];
  // Variance at the merged-line level
  dutyVariance: number | null;
  dutyVariancePct: number | null;
  varianceSeverity: 'match' | 'minor' | 'material' | 'critical' | 'no_upload';
  /** True when the line contains any ch99 row whose authority could not be mapped. */
  hasUnmappedCh99: boolean;
  flags: ExceptionFlag[];
}

// -----------------------------------------------------------------------------
// Groups and summaries
// -----------------------------------------------------------------------------

export type GroupKind = 'entry' | 'shipment' | 'batch';

export interface GroupRollup {
  id: string;
  kind: GroupKind;
  /** Entry number / shipment id / synthetic batch key. */
  key: string | null;
  rowIds: string[];
  /** Merged line items contained in this group (ordered by invoice line). */
  lineItemIds: string[];
  totalCustomsValue: number;
  totalCalculatedDuty: number;
  /**
   * Per-line MPF/HMF summed verbatim. Distinct from `recomputedMPF` below
   * because MPF is legally a per-entry fee — summing per-line overstates it.
   */
  sumLineMPF: number;
  sumLineHMF: number;
  /** MPF/HMF recomputed on the group's aggregated customs value. */
  recomputedMPF: number;
  recomputedHMF: number;
  totalCalculatedFees: number; // recomputedMPF + recomputedHMF
  totalLandedCost: number;
  effectiveRatePct: number;
  // Broker-reported (only set when source file provided these values)
  totalUploadedDuty: number | null;
  totalUploadedMPF: number | null;
  totalUploadedHMF: number | null;
  dutyVariance: number | null;
  mpfVariance: number | null;
  hmfVariance: number | null;
}

export type EntryGroup = GroupRollup;
export type ShipmentGroup = GroupRollup;

export interface JobSummary {
  totalRows: number;
  validRows: number;
  warningRows: number;
  blockedRows: number;
  uniqueRateKeys: number;
  totalCustomsValue: number;
  totalCalculatedDuty: number;
  totalCalculatedFees: number;
  totalUploadedDuty: number | null;
  totalDutyVariance: number | null;
  flagCounts: Partial<Record<ExceptionFlagKind, number>>;
  shipmentCount: number;
  entryCount: number;
}

// -----------------------------------------------------------------------------
// Import job state machine
// -----------------------------------------------------------------------------

export type JobStage =
  | 'upload'
  | 'mapping'
  | 'validation'
  | 'processing'
  | 'review';

export type JobStatus =
  | 'idle'
  | 'parsing'
  | 'ready_to_map'
  | 'ready_to_validate'
  | 'ready_to_calculate'
  | 'calculating'
  | 'complete'
  | 'cancelled'
  | 'error';

export interface ParsedSheet {
  sheetName: string;
  headers: string[];
  rows: Record<string, string>[]; // each row keyed by header
  rowCount: number;
}

export interface ParseResult {
  fileName: string;
  fileType: 'csv' | 'xlsx';
  sheets: ParsedSheet[];
  /** Index of the sheet currently selected. */
  activeSheetIndex: number;
}

export interface ImportJob {
  id: string;
  createdAt: string;
  fileName: string;
  fileType: 'csv' | 'xlsx';
  parseResult: ParseResult | null;
  /** Verbatim source headers (from the active sheet), ordered. */
  sourceColumns: string[];
  mapping: ColumnMapping;
  rows: DutyResultRow[];
  /** Merged line items — the canonical "physical line" after ch99 reconciliation. */
  lineItems: MergedLineItem[];
  shipments: ShipmentGroup[];
  entries: EntryGroup[];
  jobSummary: JobSummary;
  stage: JobStage;
  status: JobStatus;
  errorMessage?: string;
}

// -----------------------------------------------------------------------------
// Rate batch query types (client ↔ server)
// -----------------------------------------------------------------------------

export interface RateBatchKey {
  hts10: string;
  country: string;
  date: string; // YYYY-MM-DD
}

export interface RateBatchResult {
  /** Map from `${hts10}|${country}|${date}` → matching ProductRate (or null). */
  found: number;
  missing: number;
  /** Unique keys that had no rate match — flagged on the corresponding rows. */
  missingKeys: string[];
}

// -----------------------------------------------------------------------------
// Worker message protocol
// -----------------------------------------------------------------------------

export interface CalcWorkerRequest {
  kind: 'calculate';
  rows: DutyResultRow[];
  /** Serialized rate map entries. */
  rateEntries: Array<[string, unknown]>;
  /** Default mode of transport when row doesn't specify. */
  defaultMOT: 'ocean' | 'air' | 'land';
}

export interface CalcWorkerProgress {
  kind: 'progress';
  processed: number;
  total: number;
}

export interface CalcWorkerComplete {
  kind: 'complete';
  rows: DutyResultRow[];
  shipments: ShipmentGroup[];
  entries: EntryGroup[];
  jobSummary: JobSummary;
}

export interface CalcWorkerError {
  kind: 'error';
  message: string;
}

export type CalcWorkerMessage =
  | CalcWorkerProgress
  | CalcWorkerComplete
  | CalcWorkerError;

/** Utility: build the stable rate-lookup key used for dedupe and cache. */
export function buildRateKey(hts10: string, country: string, date: string): string {
  return `${hts10}|${country}|${date}`;
}

/** Helper: does a row have a calculable normalized payload? */
export function isCalculable(row: DutyResultRow): boolean {
  const n = row.normalized;
  return (
    n.hts10 !== null &&
    n.customsValue !== null &&
    n.customsValue > 0 &&
    (n.entryDate !== null || n.shipmentDate !== null) &&
    row.validation.every((v) => v.severity !== 'blocking')
  );
}

/** Helper: empty JobSummary used as initial state. */
export function emptyJobSummary(): JobSummary {
  return {
    totalRows: 0,
    validRows: 0,
    warningRows: 0,
    blockedRows: 0,
    uniqueRateKeys: 0,
    totalCustomsValue: 0,
    totalCalculatedDuty: 0,
    totalCalculatedFees: 0,
    totalUploadedDuty: null,
    totalDutyVariance: null,
    flagCounts: {},
    shipmentCount: 0,
    entryCount: 0,
  };
}

/** Helper: re-export LandedCostResult so consumers only import from bulk types. */
export type { LandedCostResult };
