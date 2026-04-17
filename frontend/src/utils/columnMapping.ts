// =============================================================================
// Column Mapping — Canonical Field Registry + Fuzzy Auto-Detection
// =============================================================================
// Maps messy broker / ACE spreadsheet headers to canonical SAIL fields.
// Every source column is preserved verbatim on DutyResultRow.source; this
// registry only decides which columns *also* flow into the calculation path.
//
// Fields are organized into six groups matching how broker/ACE files are
// structured operationally:
//   identity     — entry, shipment, bill, invoice, broker refs
//   parties      — importer, consignee, supplier, bill-to
//   logistics    — carrier, vessel, ports, MOT
//   dates        — full customs-lifecycle timeline
//   classification — HTS, SPI, origin, description
//   values       — customs value, quantity, UOM
//   reconciliation — broker-reported duty/fee amounts
//
// The system is jurisdiction-agnostic: countryOfOrigin is the key that maps
// to the backend rate matrix, which already supports non-US jurisdictions.

import type {
  CanonicalFieldDef,
  CanonicalFieldKey,
  ColumnMapping,
  MappedField,
} from '@/types/bulk';

export const CANONICAL_FIELDS: CanonicalFieldDef[] = [
  // -------------------------------------------------------------------------
  // CLASSIFICATION / COMMERCIAL
  // -------------------------------------------------------------------------
  {
    key: 'hts10',
    label: 'HTS Code',
    type: 'hts',
    required: true,
    group: 'classification',
    description: '10-digit HTS classification code. Dots are optional.',
    aliases: [
      'hts', 'hts code', 'hts10', 'hts 10', 'tariff', 'tariff code',
      'tariff no', 'tariff number', 'hts part code', 'classification',
      'commodity', 'hs code', 'hts number', 'htsus', 'classification code',
    ],
  },
  {
    key: 'htsDescription',
    label: 'HTS Description',
    type: 'string',
    required: false,
    group: 'classification',
    description: 'Official HTS description text.',
    aliases: ['hts description', 'tariff description', 'classification description'],
  },
  {
    key: 'description',
    label: 'Line Description',
    type: 'string',
    required: false,
    group: 'classification',
    description: 'Line-item or part description.',
    aliases: [
      'description', 'product description', 'item description',
      'goods description', 'desc', 'bom description', 'root',
    ],
  },
  {
    key: 'spi',
    label: 'SPI',
    type: 'string',
    required: false,
    group: 'classification',
    description: 'Special Program Indicator (USMCA, GSP, etc.).',
    aliases: ['spi', 'special program', 'spi code', 'preference program'],
  },
  {
    key: 'countryOfOrigin',
    label: 'Country of Origin',
    type: 'country',
    required: false,
    group: 'classification',
    description:
      'Country where the goods originated. Maps to the backend rate matrix.',
    aliases: [
      'c/o', 'c o', 'country of origin', 'origin', 'coo',
      'origin country', 'country origin',
    ],
  },
  {
    key: 'importCountry',
    label: 'Import Country',
    type: 'country',
    required: false,
    group: 'classification',
    description:
      'Jurisdiction of import. Leave blank for US (default) or specify to use another jurisdiction.',
    aliases: [
      'import country', 'destination country', 'country import',
      'country of import',
    ],
  },
  {
    key: 'exportCountry',
    label: 'Export Country',
    type: 'country',
    required: false,
    group: 'classification',
    description: 'Country of export — may differ from country of origin.',
    aliases: ['export country', 'country of export', 'country export'],
  },
  {
    key: 'partNumber',
    label: 'Part Number',
    type: 'string',
    required: false,
    group: 'classification',
    description: 'Internal part / SKU number.',
    aliases: ['part number', 'part no', 'part #', 'sku', 'item number'],
  },
  {
    key: 'tariffCategory',
    label: 'Tariff Category',
    type: 'string',
    required: false,
    group: 'classification',
    description: 'Broker-assigned tariff category.',
    aliases: ['tariff category', 'category', 'code'],
  },

  // -------------------------------------------------------------------------
  // VALUES
  // -------------------------------------------------------------------------
  {
    key: 'customsValue',
    label: 'Customs Value',
    type: 'currency',
    required: true,
    group: 'values',
    description: 'Entered value for duty calculation.',
    aliases: [
      'entered value usd', 'entered value', 'customs value', 'declared value',
      'invoice line value', 'invoice value', 'cv', 'value', 'line value',
      'total entered value', 'dutiable value', 'pc price',
    ],
  },
  {
    key: 'quantity',
    label: 'Quantity',
    type: 'number',
    required: false,
    group: 'values',
    description:
      'Quantity of goods. Required when the HTS has a specific or compound duty.',
    aliases: [
      'quantity', 'qty', 'units', 'pieces', 'manifest qty', 'mfst qty',
    ],
  },
  {
    key: 'unitOfMeasure',
    label: 'Unit of Measure',
    type: 'string',
    required: false,
    group: 'values',
    description:
      'Statistical reporting unit. NOT the duty basis unit — for context only.',
    aliases: [
      'uom', 'unit', 'unit of measure', 'mfst unit', 'unit of quantity',
    ],
  },

  // -------------------------------------------------------------------------
  // ENTRY / SHIPMENT IDENTITY
  // -------------------------------------------------------------------------
  {
    key: 'entryNumber',
    label: 'Entry Number',
    type: 'string',
    required: false,
    priority: 'grouping',
    group: 'identity',
    description:
      'CBP entry number. Primary grouping key — controls MPF/HMF recomputation and reconciliation.',
    aliases: [
      'entry number', 'entry no', 'entry no.', 'entry #', 'entry num',
      'cbp entry', 'entry',
    ],
  },
  {
    key: 'shipmentId',
    label: 'Shipment ID',
    type: 'string',
    required: false,
    priority: 'grouping',
    group: 'identity',
    description:
      'Business shipment identifier. Secondary grouping for landed-cost rollups.',
    aliases: ['shipment id', 'shipment no', 'shipment #', 'shipment'],
  },
  {
    key: 'masterBill',
    label: 'Master Bill',
    type: 'string',
    required: false,
    group: 'identity',
    description: 'Master bill of lading.',
    aliases: ['master bill', 'mbl', 'mbl no', 'master b/l'],
  },
  {
    key: 'houseBill',
    label: 'House Bill',
    type: 'string',
    required: false,
    group: 'identity',
    description: 'House bill of lading.',
    aliases: ['house bill', 'hbl', 'hbl no', 'house b/l'],
  },
  {
    key: 'invoiceNumber',
    label: 'Invoice Number',
    type: 'string',
    required: false,
    group: 'identity',
    description: 'Commercial invoice number.',
    aliases: ['invoice no', 'invoice number', 'invoice #', 'invoice'],
  },
  {
    key: 'invoiceLineNumber',
    label: 'Invoice Line Number',
    type: 'string',
    required: false,
    group: 'identity',
    description: 'Line-item position within the invoice.',
    aliases: [
      'invoice line number', 'invoice line no', 'invoice line',
      'line number', 'line no', 'line #', 'summary line',
    ],
  },
  {
    key: 'brokerRefNumber',
    label: 'Broker Reference',
    type: 'string',
    required: false,
    group: 'identity',
    description: 'Broker-assigned reference number.',
    aliases: ['broker ref', 'broker ref no', 'broker ref. no', 'broker reference'],
  },
  {
    key: 'customerRefNumber',
    label: 'Customer Reference',
    type: 'string',
    required: false,
    group: 'identity',
    description: 'Customer-assigned reference number.',
    aliases: [
      'customer ref', 'customer ref no', 'customer ref. no',
      'customer reference', 'po number', 'purchase order',
    ],
  },
  {
    key: 'itNumber',
    label: 'I.T. Number',
    type: 'string',
    required: false,
    group: 'identity',
    description: 'In-bond (immediate transportation) number.',
    aliases: ['i.t. no', 'it no', 'it number', 'in bond no', 'in-bond no'],
  },

  // -------------------------------------------------------------------------
  // PARTIES
  // -------------------------------------------------------------------------
  {
    key: 'importer',
    label: 'Importer',
    type: 'string',
    required: false,
    group: 'parties',
    description: 'Importer of record.',
    aliases: ['importer', 'ior', 'importer of record', 'importer name'],
  },
  {
    key: 'consignee',
    label: 'Consignee',
    type: 'string',
    required: false,
    group: 'parties',
    description: 'Consignee name.',
    aliases: ['consignee', 'consignee name', 'ultimate consignee'],
  },
  {
    key: 'supplier',
    label: 'Supplier',
    type: 'string',
    required: false,
    group: 'parties',
    description: 'Supplier / shipper name.',
    aliases: ['supplier', 'shipper', 'vendor', 'manufacturer'],
  },
  {
    key: 'billToParty',
    label: 'Bill-to Party',
    type: 'string',
    required: false,
    group: 'parties',
    description: 'Party billed by the broker.',
    aliases: ['bill to', 'bill to party', 'billed to'],
  },

  // -------------------------------------------------------------------------
  // LOGISTICS / MOVEMENT
  // -------------------------------------------------------------------------
  {
    key: 'carrier',
    label: 'Carrier',
    type: 'string',
    required: false,
    group: 'logistics',
    description: 'Transportation carrier.',
    aliases: ['carrier', 'carrier name', 'carrier code'],
  },
  {
    key: 'vesselName',
    label: 'Vessel Name',
    type: 'string',
    required: false,
    group: 'logistics',
    description: 'Vessel name for ocean shipments.',
    aliases: ['vessel name', 'vessel', 'ship name'],
  },
  {
    key: 'voyageFlight',
    label: 'Voyage / Flight',
    type: 'string',
    required: false,
    group: 'logistics',
    description: 'Voyage or flight number.',
    aliases: ['voyage', 'flight', 'voyage flight', 'voyage/flight', 'flight number', 'voyage number'],
  },
  {
    key: 'entryPort',
    label: 'Entry Port',
    type: 'string',
    required: false,
    group: 'logistics',
    description: 'CBP port of entry.',
    aliases: ['entry port', 'port of entry', 'unlading port', 'port'],
  },
  {
    key: 'destination',
    label: 'Destination',
    type: 'string',
    required: false,
    group: 'logistics',
    description: 'Ultimate destination.',
    aliases: ['destination', 'location', 'destination name'],
  },
  {
    key: 'modeOfTransport',
    label: 'Mode of Transport',
    type: 'mot',
    required: false,
    group: 'logistics',
    description: 'ocean / air / land — controls HMF applicability.',
    aliases: ['mot', 'mode of transport', 'transport mode', 'mode'],
  },
  {
    key: 'portOfLading',
    label: 'Port of Lading',
    type: 'string',
    required: false,
    group: 'logistics',
    description: 'Foreign port where goods were loaded.',
    aliases: ['port of lading', 'lading port', 'loading port'],
  },
  {
    key: 'trailerNumber',
    label: 'Trailer Number',
    type: 'string',
    required: false,
    group: 'logistics',
    description: 'Trailer / container number.',
    aliases: ['trailer no', 'trailer', 'container no', 'container'],
  },

  // -------------------------------------------------------------------------
  // TIMELINE — preserve full customs-lifecycle distinctions
  // -------------------------------------------------------------------------
  {
    key: 'entryDate',
    label: 'Entry Date',
    type: 'date',
    required: false,
    group: 'dates',
    description:
      'PRIMARY duty applicability date. Drives rate lookup whenever present.',
    aliases: [
      'entry date', 'date of entry', 'entry dt', 'entered date',
      'cbp entry date', 'filing date',
    ],
  },
  {
    key: 'shipmentDate',
    label: 'Shipment Date',
    type: 'date',
    required: false,
    group: 'dates',
    description:
      'Generic business shipment date. NOT the legal in-transit trigger.',
    aliases: ['shipment date', 'ship date', 'ship dt', 'date shipped'],
  },
  {
    key: 'exportDate',
    label: 'Export Date',
    type: 'date',
    required: false,
    group: 'dates',
    description: 'Date goods left the exporting country.',
    aliases: ['export date', 'export dt', 'date of export'],
  },
  {
    key: 'importDate',
    label: 'Import Date',
    type: 'date',
    required: false,
    group: 'dates',
    description: 'Date goods entered the importing country.',
    aliases: ['import date', 'import dt'],
  },
  {
    key: 'arrivalDate',
    label: 'Arrival Date',
    type: 'date',
    required: false,
    group: 'dates',
    description: 'Date of arrival at port.',
    aliases: ['arrival date', 'arrival dt', 'date of arrival'],
  },
  {
    key: 'itDate',
    label: 'I.T. Date',
    type: 'date',
    required: false,
    group: 'dates',
    description: 'In-bond movement date.',
    aliases: ['i.t. date', 'it date', 'in-bond date', 'in bond date'],
  },
  {
    key: 'cargoReleaseDate',
    label: 'Cargo Release Date',
    type: 'date',
    required: false,
    group: 'dates',
    description: 'Date cargo was released by CBP.',
    aliases: ['cargo release date', 'release date', 'cargo release'],
  },
  {
    key: 'liquidationDate',
    label: 'Liquidation Date',
    type: 'date',
    required: false,
    group: 'dates',
    description: 'CBP liquidation date.',
    aliases: ['liquidation date', 'liq date', 'liquidation'],
  },

  // -------------------------------------------------------------------------
  // RECONCILIATION — broker-reported
  // -------------------------------------------------------------------------
  {
    key: 'uploadedDuty',
    label: 'Broker-Reported Duty',
    type: 'currency',
    required: false,
    group: 'reconciliation',
    description:
      'Duty amount from the broker / ACE file for variance analysis.',
    aliases: [
      'duty', 'total duty', 'u.s. customs duty', 'us customs duty',
      'customs duty', 'duty amount', 'duty usd', 'duty (usd)',
    ],
  },
  {
    key: 'uploadedMPF',
    label: 'Broker-Reported MPF',
    type: 'currency',
    required: false,
    group: 'reconciliation',
    description: 'MPF from the broker file (typically not prorated).',
    aliases: [
      'mpf', 'total mpf', 'mpf (not prorated)', 'mpf not prorated',
      'merchandise processing fee',
    ],
  },
  {
    key: 'uploadedHMF',
    label: 'Broker-Reported HMF',
    type: 'currency',
    required: false,
    group: 'reconciliation',
    description: 'HMF from the broker file.',
    aliases: ['hmf', 'total hmf', 'harbor maintenance fee'],
  },
  {
    key: 'uploadedFees',
    label: 'Broker-Reported Other Fees',
    type: 'currency',
    required: false,
    group: 'reconciliation',
    description: 'Other customs fees from the broker file.',
    aliases: ['other fees', 'total fees', 'fees', 'fees total'],
  },
  {
    key: 'uploadedAmountBilled',
    label: 'Broker Amount Billed',
    type: 'currency',
    required: false,
    group: 'reconciliation',
    description: 'Total amount billed by the broker.',
    aliases: ['amount billed', 'billed amount', 'total billed'],
  },
  {
    key: 'uploadedPaidStatus',
    label: 'Paid Status',
    type: 'string',
    required: false,
    group: 'reconciliation',
    description: 'Payment / settlement status.',
    aliases: ['paid status', 'payment status', 'status'],
  },
];

export const CANONICAL_FIELD_MAP: Record<CanonicalFieldKey, CanonicalFieldDef> =
  Object.fromEntries(CANONICAL_FIELDS.map((f) => [f.key, f])) as Record<
    CanonicalFieldKey,
    CanonicalFieldDef
  >;

export const FIELD_GROUP_LABELS: Record<string, string> = {
  classification: 'Classification / Commercial',
  values: 'Values',
  identity: 'Entry / Shipment Identity',
  parties: 'Parties',
  logistics: 'Logistics / Movement',
  dates: 'Timeline',
  reconciliation: 'Reconciliation',
};

// -----------------------------------------------------------------------------
// Header normalization
// -----------------------------------------------------------------------------

export function normalizeHeader(h: string): string {
  return h
    .toLowerCase()
    .replace(/[_\-./#()]/g, ' ')
    .replace(/\s+/g, ' ')
    .trim();
}

function levenshtein(a: string, b: string): number {
  if (a === b) return 0;
  if (a.length === 0) return b.length;
  if (b.length === 0) return a.length;
  const m = a.length;
  const n = b.length;
  const dp: number[] = new Array(n + 1);
  for (let j = 0; j <= n; j++) dp[j] = j;
  for (let i = 1; i <= m; i++) {
    let prev = dp[0];
    dp[0] = i;
    for (let j = 1; j <= n; j++) {
      const temp = dp[j];
      if (a.charCodeAt(i - 1) === b.charCodeAt(j - 1)) {
        dp[j] = prev;
      } else {
        dp[j] = 1 + Math.min(prev, dp[j], dp[j - 1]);
      }
      prev = temp;
    }
  }
  return dp[n];
}

function similarityRatio(a: string, b: string): number {
  if (!a || !b) return 0;
  const maxLen = Math.max(a.length, b.length);
  if (maxLen === 0) return 1;
  return 1 - levenshtein(a, b) / maxLen;
}

// -----------------------------------------------------------------------------
// Auto-detection
// -----------------------------------------------------------------------------

interface DetectionCandidate {
  sourceColumn: string;
  confidence: number;
}

function bestCandidateForField(
  field: CanonicalFieldDef,
  normalizedHeaders: { raw: string; norm: string }[],
): DetectionCandidate | null {
  let best: DetectionCandidate | null = null;

  for (const h of normalizedHeaders) {
    let conf = 0;

    // 1. Exact alias match
    for (const alias of field.aliases) {
      const normAlias = normalizeHeader(alias);
      if (h.norm === normAlias) {
        conf = Math.max(conf, 1.0);
        break;
      }
    }

    if (conf < 1.0) {
      // 2. Levenshtein ratio
      for (const alias of field.aliases) {
        const normAlias = normalizeHeader(alias);
        const ratio = similarityRatio(h.norm, normAlias);
        if (ratio >= 0.85 && ratio > conf) conf = ratio;
      }
    }

    if (conf < 0.7) {
      // 3. Substring match (only when meaningful length)
      for (const alias of field.aliases) {
        const normAlias = normalizeHeader(alias);
        if (
          (h.norm.includes(normAlias) || normAlias.includes(h.norm)) &&
          Math.min(h.norm.length, normAlias.length) >= 3
        ) {
          conf = Math.max(conf, 0.7);
          break;
        }
      }
    }

    if (conf > (best?.confidence ?? 0)) {
      best = { sourceColumn: h.raw, confidence: conf };
    }
  }

  return best && best.confidence >= 0.5 ? best : null;
}

/**
 * Auto-detect canonical field mappings from a list of source headers.
 * Greedy assignment: highest confidence wins, each column used at most once.
 */
export function autoDetectMapping(headers: string[]): ColumnMapping {
  const norm = headers.map((h) => ({ raw: h, norm: normalizeHeader(h) }));
  const mapping: ColumnMapping = {};

  const candidates: Array<{
    key: CanonicalFieldKey;
    sourceColumn: string;
    confidence: number;
  }> = [];
  for (const field of CANONICAL_FIELDS) {
    const c = bestCandidateForField(field, norm);
    if (c) {
      candidates.push({
        key: field.key,
        sourceColumn: c.sourceColumn,
        confidence: c.confidence,
      });
    }
  }

  candidates.sort((a, b) => b.confidence - a.confidence);
  const usedColumns = new Set<string>();
  for (const c of candidates) {
    if (usedColumns.has(c.sourceColumn)) continue;
    if (mapping[c.key]) continue;
    mapping[c.key] = {
      sourceColumn: c.sourceColumn,
      confidence: c.confidence,
      manualOverride: false,
    };
    usedColumns.add(c.sourceColumn);
  }

  for (const field of CANONICAL_FIELDS) {
    if (!mapping[field.key]) {
      mapping[field.key] = {
        sourceColumn: null,
        confidence: 0,
        manualOverride: false,
      };
    }
  }

  return mapping;
}

// -----------------------------------------------------------------------------
// Mapping validation
// -----------------------------------------------------------------------------

export interface MappingValidation {
  ok: boolean;
  missingRequired: CanonicalFieldKey[];
  mappedCount: number;
}

export function validateMapping(mapping: ColumnMapping): MappingValidation {
  const missingRequired: CanonicalFieldKey[] = [];
  let mappedCount = 0;
  for (const field of CANONICAL_FIELDS) {
    const entry = mapping[field.key];
    if (entry?.sourceColumn) mappedCount++;
    if (field.required && !entry?.sourceColumn) {
      missingRequired.push(field.key);
    }
  }
  return {
    ok: missingRequired.length === 0,
    missingRequired,
    mappedCount,
  };
}

export function setMapping(
  mapping: ColumnMapping,
  key: CanonicalFieldKey,
  sourceColumn: string | null,
): ColumnMapping {
  const next: ColumnMapping = { ...mapping };
  next[key] = {
    sourceColumn,
    confidence: sourceColumn ? 1.0 : 0,
    manualOverride: true,
  } as MappedField;
  return next;
}
