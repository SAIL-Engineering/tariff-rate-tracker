// =============================================================================
// Bulk Export — multi-sheet XLSX writer
// =============================================================================
// Sheets:
//   Enriched Lines — original source columns first, then SAIL-added columns
//   Entry Summary  — per-entry rollups (primary customs anchor)
//   Shipment Summary — per-shipment rollups (secondary business grouping)
//   Exceptions     — rows with any flag, one row per flag
//   Reconciliation — rows with broker-reported values, variance-sorted
//   Methodology    — fixed documentation of duty-stack rules
//   Mapping        — the column mapping used to interpret the file
//
// The Enriched Lines sheet preserves the original header order first so
// Excel users keep their muscle memory, then appends SAIL fields in
// clearly grouped sections.

import * as XLSX from 'xlsx';
import type {
  ImportJob,
  DutyResultRow,
  EntryGroup,
  ShipmentGroup,
  ColumnMapping,
} from '@/types/bulk';
import { CANONICAL_FIELDS } from './columnMapping';

// -----------------------------------------------------------------------------
// Public entry point
// -----------------------------------------------------------------------------

export function exportBulkJob(job: ImportJob): void {
  const wb = XLSX.utils.book_new();

  XLSX.utils.book_append_sheet(
    wb,
    buildEnrichedLinesSheet(job),
    'Enriched Lines',
  );
  XLSX.utils.book_append_sheet(
    wb,
    buildEntrySummarySheet(job.entries),
    'Entry Summary',
  );
  XLSX.utils.book_append_sheet(
    wb,
    buildShipmentSummarySheet(job.shipments),
    'Shipment Summary',
  );
  XLSX.utils.book_append_sheet(wb, buildExceptionsSheet(job.rows), 'Exceptions');
  XLSX.utils.book_append_sheet(
    wb,
    buildReconciliationSheet(job.rows),
    'Reconciliation',
  );
  XLSX.utils.book_append_sheet(wb, buildMethodologySheet(), 'Methodology');
  XLSX.utils.book_append_sheet(
    wb,
    buildMappingSheet(job.mapping, job.sourceColumns),
    'Mapping',
  );

  const base = job.fileName.replace(/\.[^.]+$/, '');
  const stamp = new Date().toISOString().slice(0, 10);
  XLSX.writeFile(wb, `${base}_sail_enriched_${stamp}.xlsx`);
}

// -----------------------------------------------------------------------------
// Enriched Lines — original columns first, then SAIL columns
// -----------------------------------------------------------------------------

const SAIL_CALC_COLUMNS = [
  'SAIL_controlling_date',
  'SAIL_controlling_date_field',
  'SAIL_country_of_origin',
  'SAIL_rate_revision',
  'SAIL_rate_basis',
  'SAIL_base_rate_pct',
  'SAIL_base_duty',
  'SAIL_additional_rate_pct',
  'SAIL_additional_duty',
  'SAIL_total_duty',
  'SAIL_effective_rate_pct',
  'SAIL_mpf',
  'SAIL_hmf',
  'SAIL_total_fees',
  'SAIL_landed_cost',
  'SAIL_assumptions',
];

const SAIL_STACK_COLUMNS = [
  'SAIL_mfn_rate_pct', 'SAIL_mfn_duty',
  'SAIL_s232_rate_pct', 'SAIL_s232_duty',
  'SAIL_s301_rate_pct', 'SAIL_s301_duty',
  'SAIL_ieepa_recip_rate_pct', 'SAIL_ieepa_recip_duty',
  'SAIL_ieepa_fent_rate_pct', 'SAIL_ieepa_fent_duty',
  'SAIL_s122_rate_pct', 'SAIL_s122_duty',
  'SAIL_s201_rate_pct', 'SAIL_s201_duty',
  'SAIL_other_ch99_rate_pct', 'SAIL_other_ch99_duty',
];

const SAIL_RECON_COLUMNS = [
  'SAIL_duty_variance',
  'SAIL_duty_variance_pct',
  'SAIL_mpf_variance',
  'SAIL_hmf_variance',
  'SAIL_variance_severity',
];

const SAIL_FLAG_COLUMNS = [
  'SAIL_flags',
  'SAIL_flag_severity',
  'SAIL_validation_messages',
];

function authorityColumn(authority: string): keyof typeof AUTHORITY_COLUMN_MAP | null {
  const label = authority.toLowerCase();
  if (label.includes('mfn') || label.includes('column')) return 'mfn';
  if (label.includes('232')) return 's232';
  if (label.includes('301')) return 's301';
  if (label.includes('reciprocal')) return 'ieepa_recip';
  if (label.includes('fentanyl')) return 'ieepa_fent';
  if (label.includes('122')) return 's122';
  if (label.includes('201')) return 's201';
  if (label.includes('other')) return 'other';
  return null;
}

const AUTHORITY_COLUMN_MAP = {
  mfn: ['SAIL_mfn_rate_pct', 'SAIL_mfn_duty'] as const,
  s232: ['SAIL_s232_rate_pct', 'SAIL_s232_duty'] as const,
  s301: ['SAIL_s301_rate_pct', 'SAIL_s301_duty'] as const,
  ieepa_recip: ['SAIL_ieepa_recip_rate_pct', 'SAIL_ieepa_recip_duty'] as const,
  ieepa_fent: ['SAIL_ieepa_fent_rate_pct', 'SAIL_ieepa_fent_duty'] as const,
  s122: ['SAIL_s122_rate_pct', 'SAIL_s122_duty'] as const,
  s201: ['SAIL_s201_rate_pct', 'SAIL_s201_duty'] as const,
  other: ['SAIL_other_ch99_rate_pct', 'SAIL_other_ch99_duty'] as const,
};

function buildEnrichedLinesSheet(job: ImportJob): XLSX.WorkSheet {
  // Column order: original source columns first (preserve muscle memory),
  // then SAIL sections in clearly delineated groups.
  const allColumns = [
    ...job.sourceColumns,
    ...SAIL_CALC_COLUMNS,
    ...SAIL_STACK_COLUMNS,
    ...SAIL_RECON_COLUMNS,
    ...SAIL_FLAG_COLUMNS,
  ];

  const aoa: (string | number | null)[][] = [allColumns];

  for (const row of job.rows) {
    const obj: Record<string, string | number | null> = {};
    // Original source columns — verbatim
    for (const col of job.sourceColumns) {
      obj[col] = row.source[col] ?? '';
    }
    // SAIL calculation section
    const c = row.calculated;
    if (c) {
      obj['SAIL_controlling_date'] = c.controllingDate;
      obj['SAIL_controlling_date_field'] = c.controllingDateField;
      obj['SAIL_country_of_origin'] = c.countryCodeUsed;
      obj['SAIL_rate_revision'] = c.rateRevision;
      obj['SAIL_rate_basis'] = c.rateBasis;
      obj['SAIL_base_rate_pct'] = round4(c.baseRate * 100);
      obj['SAIL_base_duty'] = round2(c.baseDuty);
      obj['SAIL_additional_rate_pct'] = round4(c.additionalRate * 100);
      obj['SAIL_additional_duty'] = round2(c.additionalDuty);
      obj['SAIL_total_duty'] = round2(c.totalDuty);
      obj['SAIL_effective_rate_pct'] = round4(c.effectiveRatePct);
      obj['SAIL_mpf'] = round2(c.mpf);
      obj['SAIL_hmf'] = round2(c.hmf);
      obj['SAIL_total_fees'] = round2(c.totalFees);
      obj['SAIL_landed_cost'] = round2(c.landedCost);
      obj['SAIL_assumptions'] = c.assumptions.join('; ');

      // Stack columns — empty where authority not applied
      for (const b of c.breakdown) {
        const key = authorityColumn(b.authority);
        if (!key) continue;
        const [rateCol, dutyCol] = AUTHORITY_COLUMN_MAP[key];
        obj[rateCol] = round4(b.rate * 100);
        obj[dutyCol] = round2(b.dutyAmount);
      }
    }
    // Reconciliation
    const v = row.variance;
    if (v) {
      obj['SAIL_duty_variance'] = v.dutyVariance != null ? round2(v.dutyVariance) : '';
      obj['SAIL_duty_variance_pct'] =
        v.dutyVariancePct != null ? round4(v.dutyVariancePct) : '';
      obj['SAIL_mpf_variance'] = v.mpfVariance != null ? round2(v.mpfVariance) : '';
      obj['SAIL_hmf_variance'] = v.hmfVariance != null ? round2(v.hmfVariance) : '';
      obj['SAIL_variance_severity'] = v.severity;
    }
    // Flags
    if (row.flags.length > 0) {
      obj['SAIL_flags'] = row.flags.map((f) => f.kind).join('; ');
      obj['SAIL_flag_severity'] = highestSeverity(row.flags);
    }
    if (row.validation.length > 0) {
      obj['SAIL_validation_messages'] = row.validation
        .map((v) => `${v.severity}:${v.code}:${v.message}`)
        .join(' | ');
    }

    aoa.push(allColumns.map((c) => obj[c] ?? ''));
  }

  return XLSX.utils.aoa_to_sheet(aoa);
}

// -----------------------------------------------------------------------------
// Entry / Shipment summaries
// -----------------------------------------------------------------------------

function buildEntrySummarySheet(entries: EntryGroup[]): XLSX.WorkSheet {
  const headers = [
    'Entry Number',
    'Kind',
    'Row Count',
    'Total Customs Value',
    'Total Calculated Duty',
    'Sum Line MPF (naive)',
    'Recomputed MPF (entry-level)',
    'Sum Line HMF (naive)',
    'Recomputed HMF (entry-level)',
    'Total Calculated Fees',
    'Total Landed Cost',
    'Effective Rate (%)',
    'Total Uploaded Duty',
    'Duty Variance',
    'Total Uploaded MPF',
    'MPF Variance',
    'Total Uploaded HMF',
    'HMF Variance',
  ];
  const aoa: (string | number | null)[][] = [headers];
  for (const e of entries) {
    aoa.push([
      e.key ?? '(unassigned)',
      e.kind,
      e.rowIds.length,
      round2(e.totalCustomsValue),
      round2(e.totalCalculatedDuty),
      round2(e.sumLineMPF),
      round2(e.recomputedMPF),
      round2(e.sumLineHMF),
      round2(e.recomputedHMF),
      round2(e.totalCalculatedFees),
      round2(e.totalLandedCost),
      round4(e.effectiveRatePct),
      e.totalUploadedDuty != null ? round2(e.totalUploadedDuty) : '',
      e.dutyVariance != null ? round2(e.dutyVariance) : '',
      e.totalUploadedMPF != null ? round2(e.totalUploadedMPF) : '',
      e.mpfVariance != null ? round2(e.mpfVariance) : '',
      e.totalUploadedHMF != null ? round2(e.totalUploadedHMF) : '',
      e.hmfVariance != null ? round2(e.hmfVariance) : '',
    ]);
  }
  return XLSX.utils.aoa_to_sheet(aoa);
}

function buildShipmentSummarySheet(shipments: ShipmentGroup[]): XLSX.WorkSheet {
  return buildEntrySummarySheet(shipments); // same shape
}

// -----------------------------------------------------------------------------
// Exceptions
// -----------------------------------------------------------------------------

function buildExceptionsSheet(rows: DutyResultRow[]): XLSX.WorkSheet {
  const headers = [
    'Source Row',
    'Entry Number',
    'HTS',
    'Country of Origin',
    'Flag Kind',
    'Severity',
    'Message',
    'Field',
  ];
  const aoa: (string | number | null)[][] = [headers];
  for (const row of rows) {
    if (row.flags.length === 0) continue;
    for (const f of row.flags) {
      aoa.push([
        row.sourceRowIndex,
        row.normalized.entryNumber ?? '',
        row.normalized.hts10 ?? '',
        row.normalized.countryOfOrigin ?? '',
        f.kind,
        f.severity,
        f.message,
        f.field ?? '',
      ]);
    }
  }
  return XLSX.utils.aoa_to_sheet(aoa);
}

// -----------------------------------------------------------------------------
// Reconciliation
// -----------------------------------------------------------------------------

function buildReconciliationSheet(rows: DutyResultRow[]): XLSX.WorkSheet {
  const headers = [
    'Source Row',
    'Entry Number',
    'HTS',
    'Country of Origin',
    'Customs Value',
    'Broker Duty',
    'SAIL Duty',
    'Duty Variance',
    'Duty Variance %',
    'Broker MPF',
    'SAIL MPF',
    'MPF Variance',
    'Broker HMF',
    'SAIL HMF',
    'HMF Variance',
    'Severity',
  ];
  const aoa: (string | number | null)[][] = [headers];
  const reconRows = rows
    .filter((r) => r.variance != null)
    .sort((a, b) => {
      const av = Math.abs(a.variance?.dutyVariance ?? 0);
      const bv = Math.abs(b.variance?.dutyVariance ?? 0);
      return bv - av;
    });
  for (const row of reconRows) {
    const v = row.variance!;
    aoa.push([
      row.sourceRowIndex,
      row.normalized.entryNumber ?? '',
      row.normalized.hts10 ?? '',
      row.normalized.countryOfOrigin ?? '',
      row.normalized.customsValue != null ? round2(row.normalized.customsValue) : '',
      v.uploadedDuty != null ? round2(v.uploadedDuty) : '',
      round2(v.calculatedDuty),
      v.dutyVariance != null ? round2(v.dutyVariance) : '',
      v.dutyVariancePct != null ? round4(v.dutyVariancePct) : '',
      v.uploadedMPF != null ? round2(v.uploadedMPF) : '',
      round2(v.calculatedMPF),
      v.mpfVariance != null ? round2(v.mpfVariance) : '',
      v.uploadedHMF != null ? round2(v.uploadedHMF) : '',
      round2(v.calculatedHMF),
      v.hmfVariance != null ? round2(v.hmfVariance) : '',
      v.severity,
    ]);
  }
  return XLSX.utils.aoa_to_sheet(aoa);
}

// -----------------------------------------------------------------------------
// Methodology
// -----------------------------------------------------------------------------

function buildMethodologySheet(): XLSX.WorkSheet {
  const rows: string[][] = [
    ['SAIL GTX Bulk Duty Analysis — Methodology'],
    [''],
    ['Rate applicability date'],
    ['Primary: entryDate.'],
    ['Fallbacks (in order): arrivalDate → importDate → shipmentDate.'],
    ['transitEvidenceDate is derived from exportDate → itDate → shipmentDate and is used ONLY for in-transit exception screening.'],
    [''],
    ['Duty stack authorities'],
    ['MFN / Column 1 General (or Column 2 / Special Preferential as applicable)'],
    ['Section 232 — national security tariffs'],
    ['Section 301 — China-specific retaliatory tariffs'],
    ['IEEPA Reciprocal — EO 14257 with optional US content carveout'],
    ['IEEPA Fentanyl — emergency tariffs on specific countries'],
    ['Section 122 — temporary balance-of-payments tariffs'],
    ['Section 201 — safeguard tariffs (solar, washers)'],
    ['Other Chapter 99 provisions'],
    [''],
    ['Mutual exclusion'],
    ['Section 232 and IEEPA reciprocal are mutually exclusive: 232 covers the metal portion, IEEPA/S122 the non-metal portion.'],
    ['Fentanyl stacks fully on China; on non-China countries it scales by non-metal share.'],
    [''],
    ['MPF / HMF'],
    ['MPF: 0.3464% of customs value, per-entry, min $33.58, max $651.50 (FY 2026).'],
    ['HMF: 0.125% of customs value, ocean freight only, no min/max.'],
    ['Entry-level totals recompute MPF/HMF from aggregated entry customs value (line-level sums overstate MPF due to the cap).'],
    [''],
    ['Rounding'],
    ['19 CFR 159.3: ad valorem → value rounded to even dollars; specific ≤$1/unit → qty < 0.5 disregarded; specific > $1/unit → exact qty to 2 decimal places.'],
    [''],
    ['In-transit candidates'],
    ['A row is flagged when transitEvidenceDate predates a punitive rate change (232/301/IEEPA/122/201) that took effect on or before the controlling date. Candidates are screening hints only — verify eligibility with the broker.'],
    [''],
    ['Variance severity thresholds'],
    ['match: |variance| < $1'],
    ['minor: $1 ≤ |variance| < $50 and < 1%'],
    ['material: $50 ≤ |variance| < $500 and < 5%'],
    ['critical: ≥ $500 or ≥ 5%'],
  ];
  return XLSX.utils.aoa_to_sheet(rows);
}

// -----------------------------------------------------------------------------
// Mapping
// -----------------------------------------------------------------------------

function buildMappingSheet(
  mapping: ColumnMapping,
  sourceColumns: string[],
): XLSX.WorkSheet {
  const rows: (string | number)[][] = [
    ['Canonical Field', 'Label', 'Group', 'Required', 'Source Column', 'Confidence', 'Manual Override'],
  ];
  for (const field of CANONICAL_FIELDS) {
    const m = mapping[field.key];
    rows.push([
      field.key,
      field.label,
      field.group,
      field.required ? 'yes' : '',
      m?.sourceColumn ?? '',
      m?.confidence != null ? round4(m.confidence) : 0,
      m?.manualOverride ? 'yes' : '',
    ]);
  }
  rows.push([]);
  rows.push(['Unmapped source columns (preserved verbatim in output)']);
  const mappedCols = new Set(
    Object.values(mapping)
      .map((m) => m?.sourceColumn)
      .filter((c): c is string => !!c),
  );
  for (const col of sourceColumns) {
    if (!mappedCols.has(col)) rows.push([col]);
  }
  return XLSX.utils.aoa_to_sheet(rows);
}

// -----------------------------------------------------------------------------
// Helpers
// -----------------------------------------------------------------------------

function round2(n: number): number {
  return Math.round(n * 100) / 100;
}

function round4(n: number): number {
  return Math.round(n * 10000) / 10000;
}

function highestSeverity(flags: { severity: 'info' | 'warning' | 'error' }[]): string {
  if (flags.some((f) => f.severity === 'error')) return 'error';
  if (flags.some((f) => f.severity === 'warning')) return 'warning';
  return 'info';
}
