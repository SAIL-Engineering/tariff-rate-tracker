// =============================================================================
// Bulk Calculator — entry-centric rollups + reconciliation + exception flags
// =============================================================================
// Wraps the existing calculateLandedCost engine (tariffCalculator.ts) and
// applies it across all rows in an ImportJob. Builds entry-level and
// shipment-level rollups, re-computes MPF/HMF at the entry level (since
// those are per-entry legal fees, not per-line), and flags rows for
// in-transit review when the transitEvidenceDate predates a rate change
// that took effect on or before entryDate.
//
// The calculation runs on the main thread for MVP; promoting to a Web Worker
// is a Phase 2 task (see plan).

import type { ProductRate, AuthorityKey, DutyBreakdown } from '@/types/tariff';
import type {
  DutyResultRow,
  EntryGroup,
  ShipmentGroup,
  JobSummary,
  NormalizedRow,
  CalculatedRow,
  ReconciliationVariance,
  ExceptionFlag,
  ExceptionFlagKind,
  MergedLineItem,
  AuthorityStackEntry,
} from '@/types/bulk';
import { ch99ToAuthority, authorityLabel } from './chapter99';
import { buildRateKey, emptyJobSummary, isCalculable } from '@/types/bulk';
import {
  calculateLandedCost,
  calculateMPF,
  calculateHMF,
  findRateForDate,
} from './tariffCalculator';

// -----------------------------------------------------------------------------
// Rate key map
// -----------------------------------------------------------------------------
// Each row resolves to a (hts10, country, date) key and the first ProductRate
// whose valid_from..valid_until spans that date.

export type RateMap = Map<string, ProductRate[]>;

/**
 * Determine the controlling date for duty applicability.
 * entryDate is preferred; fall back through arrivalDate → importDate →
 * shipmentDate. The controllingDateField is stamped on the result so the
 * export can show which date drove the lookup.
 */
export function selectControllingDate(
  n: NormalizedRow,
): { date: string; field: CalculatedRow['controllingDateField'] } | null {
  if (n.entryDate) return { date: n.entryDate, field: 'entryDate' };
  if (n.arrivalDate) return { date: n.arrivalDate, field: 'imputed' };
  if (n.importDate) return { date: n.importDate, field: 'imputed' };
  if (n.shipmentDate) return { date: n.shipmentDate, field: 'shipmentDate' };
  return null;
}

/** Build the stable rate-lookup key for a row (or null if uncomputable). */
export function rateKeyForRow(row: DutyResultRow): string | null {
  const n = row.normalized;
  if (!n.hts10) return null;
  const dateSel = selectControllingDate(n);
  if (!dateSel) return null;
  const country = n.countryOfOrigin ?? '';
  if (!country) return null;
  return buildRateKey(n.hts10, country, dateSel.date);
}

/**
 * Collect the unique rate keys across all calculable rows.
 * Used by useBulkRateLookup to dedupe before fetching.
 */
export function collectRateKeys(rows: DutyResultRow[]): {
  keys: Array<{ key: string; hts10: string; country: string; date: string }>;
  rowsWithoutKey: DutyResultRow[];
} {
  const seen = new Set<string>();
  const keys: Array<{ key: string; hts10: string; country: string; date: string }> = [];
  const rowsWithoutKey: DutyResultRow[] = [];

  for (const row of rows) {
    // Chapter 99 rows are authority break-outs with no entry in the rate
    // matrix. Skip their rate lookup entirely — they contribute broker-
    // reported evidence to their merged line item instead.
    if (row.isChapter99) continue;
    if (!isCalculable(row)) continue;
    const n = row.normalized;
    if (!n.hts10 || !n.countryOfOrigin) {
      rowsWithoutKey.push(row);
      continue;
    }
    const dateSel = selectControllingDate(n);
    if (!dateSel) {
      rowsWithoutKey.push(row);
      continue;
    }
    const key = buildRateKey(n.hts10, n.countryOfOrigin, dateSel.date);
    row.rateKey = key;
    if (!seen.has(key)) {
      seen.add(key);
      keys.push({
        key,
        hts10: n.hts10,
        country: n.countryOfOrigin,
        date: dateSel.date,
      });
    }
  }
  return { keys, rowsWithoutKey };
}

// -----------------------------------------------------------------------------
// Per-row calculation
// -----------------------------------------------------------------------------

function calculateOne(
  row: DutyResultRow,
  rateMap: RateMap,
  defaultMOT: 'ocean' | 'air' | 'land',
): DutyResultRow {
  const n = row.normalized;
  const newFlags: ExceptionFlag[] = [...row.flags];

  // Chapter 99 rows aren't calculated independently — they contribute
  // broker-reported amounts to their merged line item during the merge pass.
  if (row.isChapter99) {
    return { ...row, flags: newFlags };
  }

  if (!isCalculable(row)) {
    return { ...row, flags: newFlags };
  }

  const dateSel = selectControllingDate(n);
  if (!dateSel || !n.hts10 || !n.countryOfOrigin || n.customsValue == null) {
    return { ...row, flags: newFlags };
  }

  const key = buildRateKey(n.hts10, n.countryOfOrigin, dateSel.date);
  const ratesForKey = rateMap.get(key);
  if (!ratesForKey || ratesForKey.length === 0) {
    newFlags.push({
      kind: 'no_rate_found',
      severity: 'error',
      message: `No rate found for HTS ${n.hts10}, country ${n.countryOfOrigin}, date ${dateSel.date}.`,
    });
    return { ...row, flags: newFlags, rateKey: key };
  }

  const rate = findRateForDate(ratesForKey, dateSel.date) ?? ratesForKey[0];
  const mot = n.modeOfTransport ?? defaultMOT;
  const includeHMF = mot === 'ocean';

  const result = calculateLandedCost(rate, n.customsValue, {
    includeHMF,
    quantity: n.quantity ?? undefined,
    countryCode: n.countryOfOrigin,
  });

  const assumptions: string[] = [];
  if (dateSel.field !== 'entryDate') {
    assumptions.push(
      `Entry date missing — used ${dateSel.field} (${dateSel.date}) for rate lookup.`,
    );
  }
  if (!n.modeOfTransport) {
    assumptions.push(`Mode of transport not provided — defaulted to ${defaultMOT}.`);
  }

  const calculated: CalculatedRow = {
    controllingDate: dateSel.date,
    controllingDateField: dateSel.field,
    countryCodeUsed: n.countryOfOrigin,
    breakdown: result.breakdown,
    baseRate: result.baseRate,
    baseDuty: result.baseDuty,
    additionalRate: result.additionalRate,
    additionalDuty: result.additionalDuty,
    totalDuty: result.totalDuty,
    totalDutyRate: result.totalDutyRate,
    mpf: result.mpf,
    hmf: result.hmf,
    totalFees: result.totalFees,
    landedCost: result.landedCost,
    effectiveRatePct: result.totalDutyRate * 100,
    rateRevision: rate.revision,
    rateBasis: result.rateBasis,
    assumptions,
  };

  // -- In-transit candidate screening --
  // If transitEvidenceDate predates a rate that took effect on or before
  // the controlling date, the shipment *may* qualify for in-transit relief.
  // We flag — never assert — candidacy.
  if (n.transitEvidenceDate && n.entryDate) {
    const evidence = n.transitEvidenceDate;
    // Look for any rate in ratesForKey whose valid_from is between evidence
    // and controlling date, AND which carries a non-zero punitive authority.
    for (const r of ratesForKey) {
      if (r.valid_from > evidence && r.valid_from <= dateSel.date) {
        const hasPunitive =
          r.rate_232 > 0 ||
          r.rate_301 > 0 ||
          r.rate_ieepa_recip > 0 ||
          r.rate_ieepa_fent > 0 ||
          r.rate_s122 > 0 ||
          r.rate_section_201 > 0;
        if (hasPunitive) {
          newFlags.push({
            kind: 'in_transit_candidate',
            severity: 'info',
            message: `Transit evidence date ${evidence} predates rate change on ${r.valid_from} — verify in-transit eligibility with broker.`,
          });
          break;
        }
      }
    }
  }

  // -- Reconciliation variance (line level) --
  const variance = computeLineVariance(n, calculated);
  if (variance && variance.severity !== 'match' && variance.severity !== 'no_upload') {
    newFlags.push({
      kind: 'broker_variance',
      severity: variance.severity === 'critical' ? 'error' : 'warning',
      message: `Duty variance vs broker: ${
        variance.dutyVariance != null
          ? (variance.dutyVariance >= 0 ? '+' : '') + variance.dutyVariance.toFixed(2)
          : 'n/a'
      } (${variance.severity})`,
    });
    if (variance.dutyVariance != null && variance.dutyVariance > 0) {
      newFlags.push({
        kind: 'psc_candidate',
        severity: 'warning',
        message:
          'SAIL-calculated duty exceeds broker-reported duty — potential underpayment / PSC candidate.',
      });
    }
  }

  return {
    ...row,
    calculated,
    variance,
    flags: newFlags,
    rateKey: key,
    calculated_at: new Date().toISOString(),
  };
}

function computeLineVariance(
  n: NormalizedRow,
  c: CalculatedRow,
): ReconciliationVariance | null {
  if (
    n.uploadedDuty == null &&
    n.uploadedMPF == null &&
    n.uploadedHMF == null
  ) {
    return null;
  }

  const dutyVariance =
    n.uploadedDuty != null ? c.totalDuty - n.uploadedDuty : null;
  const dutyVariancePct =
    dutyVariance != null && n.uploadedDuty && n.uploadedDuty > 0
      ? (dutyVariance / n.uploadedDuty) * 100
      : null;

  const mpfVariance = n.uploadedMPF != null ? c.mpf - n.uploadedMPF : null;
  const hmfVariance = n.uploadedHMF != null ? c.hmf - n.uploadedHMF : null;

  const absDuty = Math.abs(dutyVariance ?? 0);
  const absPct = Math.abs(dutyVariancePct ?? 0);
  let severity: ReconciliationVariance['severity'] = 'match';
  if (dutyVariance == null) severity = 'no_upload';
  else if (absDuty < 1) severity = 'match';
  else if (absDuty < 50 && absPct < 1) severity = 'minor';
  else if (absDuty < 500 && absPct < 5) severity = 'material';
  else severity = 'critical';

  return {
    uploadedDuty: n.uploadedDuty,
    calculatedDuty: c.totalDuty,
    dutyVariance,
    dutyVariancePct,
    uploadedMPF: n.uploadedMPF,
    calculatedMPF: c.mpf,
    mpfVariance,
    uploadedHMF: n.uploadedHMF,
    calculatedHMF: c.hmf,
    hmfVariance,
    severity,
  };
}

// =============================================================================
// Merged line items — reconcile chapter 99 rows into their parent line
// =============================================================================
// A "merged line item" bundles rows from a broker file that describe the
// same physical line. Broker files split each line's duty stack across
// multiple rows: one main chapter 1-97 row for the MFN base, plus one
// Chapter 99 row per applied authority (232 / 301 / IEEPA / ...). This
// function re-assembles the pieces so we can compare SAIL vs broker at
// the authority level.

let mergedLineIdCounter = 0;
function nextMergedLineId(): string {
  mergedLineIdCounter++;
  return `ml_${mergedLineIdCounter}`;
}

/**
 * Build the stable merge key for a row. Rows that resolve to the same key
 * are considered parts of the same physical line. Returns null when no
 * usable disambiguator exists — those rows become their own single-row line.
 */
function mergeKeyFor(n: NormalizedRow): string | null {
  if (!n.entryNumber) return null;
  const disambig =
    n.invoiceLineNumber || n.partNumber || n.tariffCategory || null;
  if (!disambig) return null;
  return `${n.entryNumber}::${disambig}`;
}

const AUTHORITY_KEYS: AuthorityKey[] = [
  'rate_232',
  'rate_301',
  'rate_ieepa_recip',
  'rate_ieepa_fent',
  'rate_s122',
  'rate_section_201',
  'rate_other',
];

function ch99CodeFromRow(row: DutyResultRow): string | null {
  return row.normalized.hts10;
}

/**
 * Assemble AuthorityStackEntry[] for the SAIL side from a calculated
 * CalculatedRow. The breakdown from calculateLandedCost already contains
 * one entry per applied authority.
 */
function sailStackFromCalculated(
  c: CalculatedRow,
  customsValue: number,
): AuthorityStackEntry[] {
  const stack: AuthorityStackEntry[] = [];

  // Base (MFN) row from the breakdown — first entry is always the base tier.
  const baseBreakdown = c.breakdown.find(
    (b) =>
      b.authority === 'MFN Base Rate' ||
      b.authority === 'Special Preferential Rate' ||
      b.authority === 'Column 2 Rate',
  );
  stack.push({
    key: 'base',
    label: baseBreakdown?.authority ?? 'MFN Base Rate',
    sailRate: baseBreakdown?.rate ?? c.baseRate,
    sailAmount: baseBreakdown?.dutyAmount ?? c.baseDuty,
    brokerRate: null,
    brokerAmount: null,
    variance: null,
  });

  // Authority rows — match on color/ch99Code or key lookup.
  for (const key of AUTHORITY_KEYS) {
    const label = authorityLabel(key);
    const b = c.breakdown.find((x) => x.authority === label);
    if (!b) continue;
    stack.push({
      key,
      label,
      sailRate: b.rate,
      sailAmount: b.dutyAmount,
      brokerRate: null,
      brokerAmount: null,
      variance: null,
    });
  }

  // MPF / HMF as their own rows so users see them alongside duty.
  stack.push({
    key: 'mpf',
    label: 'MPF',
    sailRate: customsValue > 0 ? c.mpf / customsValue : null,
    sailAmount: c.mpf,
    brokerRate: null,
    brokerAmount: null,
    variance: null,
  });
  stack.push({
    key: 'hmf',
    label: 'HMF',
    sailRate: customsValue > 0 ? c.hmf / customsValue : null,
    sailAmount: c.hmf,
    brokerRate: null,
    brokerAmount: null,
    variance: null,
  });

  return stack;
}

/**
 * Fold broker-reported values from all rows belonging to a merged line
 * into per-authority entries. Main row contributes MFN base duty + MPF +
 * HMF (when present); chapter 99 rows contribute to their mapped authority.
 */
function foldBrokerStack(
  mainRow: DutyResultRow | null,
  ch99Rows: DutyResultRow[],
  customsValue: number,
): {
  stack: AuthorityStackEntry[];
  totalDuty: number | null;
  totalMpf: number | null;
  totalHmf: number | null;
  hasUnmapped: boolean;
} {
  const stack: AuthorityStackEntry[] = [];
  let hasUnmapped = false;
  let totalDuty = 0;
  let hasAnyDuty = false;

  // Base (MFN) — from the main row's uploadedDuty
  if (mainRow && mainRow.normalized.uploadedDuty != null) {
    const amt = mainRow.normalized.uploadedDuty;
    stack.push({
      key: 'base',
      label: 'MFN Base Rate',
      sailRate: null,
      sailAmount: null,
      brokerAmount: amt,
      brokerRate: customsValue > 0 ? amt / customsValue : null,
      variance: null,
      sourceRowIds: [mainRow.rowId],
    });
    totalDuty += amt;
    hasAnyDuty = true;
  }

  // Group ch99 rows by mapped authority
  const byAuthority = new Map<
    AuthorityKey,
    { amount: number; rowIds: string[]; codes: string[] }
  >();
  for (const r of ch99Rows) {
    const authority = r.ch99Authority ?? null;
    if (!authority) {
      hasUnmapped = true;
      continue;
    }
    const amt = r.normalized.uploadedDuty ?? 0;
    const bucket = byAuthority.get(authority) ?? {
      amount: 0,
      rowIds: [],
      codes: [],
    };
    bucket.amount += amt;
    bucket.rowIds.push(r.rowId);
    const code = ch99CodeFromRow(r);
    if (code) bucket.codes.push(code);
    byAuthority.set(authority, bucket);
    totalDuty += amt;
    hasAnyDuty = true;
  }

  for (const key of AUTHORITY_KEYS) {
    const b = byAuthority.get(key);
    if (!b) continue;
    stack.push({
      key,
      label: authorityLabel(key),
      sailRate: null,
      sailAmount: null,
      brokerAmount: b.amount,
      brokerRate: customsValue > 0 ? b.amount / customsValue : null,
      variance: null,
      sourceRowIds: b.rowIds,
      ch99Codes: b.codes,
    });
  }

  // MPF / HMF — broker reports these on the main row, typically. If not
  // present on the main row, fall back to summing across contained rows.
  let brokerMpf: number | null = null;
  let brokerHmf: number | null = null;
  const contained = [mainRow, ...ch99Rows].filter((r): r is DutyResultRow => !!r);
  for (const r of contained) {
    if (r.normalized.uploadedMPF != null) {
      brokerMpf = (brokerMpf ?? 0) + r.normalized.uploadedMPF;
    }
    if (r.normalized.uploadedHMF != null) {
      brokerHmf = (brokerHmf ?? 0) + r.normalized.uploadedHMF;
    }
  }

  if (brokerMpf != null) {
    stack.push({
      key: 'mpf',
      label: 'MPF',
      sailRate: null,
      sailAmount: null,
      brokerAmount: brokerMpf,
      brokerRate: customsValue > 0 ? brokerMpf / customsValue : null,
      variance: null,
    });
  }
  if (brokerHmf != null) {
    stack.push({
      key: 'hmf',
      label: 'HMF',
      sailRate: null,
      sailAmount: null,
      brokerAmount: brokerHmf,
      brokerRate: customsValue > 0 ? brokerHmf / customsValue : null,
      variance: null,
    });
  }

  return {
    stack,
    totalDuty: hasAnyDuty ? totalDuty : null,
    totalMpf: brokerMpf,
    totalHmf: brokerHmf,
    hasUnmapped,
  };
}

/**
 * Merge SAIL and broker stacks by authority key. Returns a single stack
 * where each row has both sides populated (when available) plus variance.
 */
function combineStacks(
  sail: AuthorityStackEntry[],
  broker: AuthorityStackEntry[],
): AuthorityStackEntry[] {
  const byKey = new Map<string, AuthorityStackEntry>();
  for (const s of sail) byKey.set(s.key, { ...s });
  for (const b of broker) {
    const existing = byKey.get(b.key);
    if (existing) {
      existing.brokerAmount = b.brokerAmount;
      existing.brokerRate = b.brokerRate;
      existing.sourceRowIds = b.sourceRowIds;
      existing.ch99Codes = b.ch99Codes;
    } else {
      byKey.set(b.key, { ...b });
    }
  }
  // Preserve a stable order: base → authorities → mpf → hmf
  const order: Array<AuthorityStackEntry['key']> = [
    'base',
    'rate_232',
    'rate_301',
    'rate_ieepa_recip',
    'rate_ieepa_fent',
    'rate_s122',
    'rate_section_201',
    'rate_other',
    'mpf',
    'hmf',
  ];
  const ordered: AuthorityStackEntry[] = [];
  for (const k of order) {
    const e = byKey.get(k);
    if (e) {
      e.variance =
        e.sailAmount != null && e.brokerAmount != null
          ? e.sailAmount - e.brokerAmount
          : null;
      ordered.push(e);
    }
  }
  return ordered;
}

function severityFromVariance(
  calcDuty: number | null,
  brokerDuty: number | null,
): MergedLineItem['varianceSeverity'] {
  if (brokerDuty == null || calcDuty == null) return 'no_upload';
  const v = calcDuty - brokerDuty;
  const abs = Math.abs(v);
  const pct = brokerDuty > 0 ? Math.abs(v / brokerDuty) * 100 : 0;
  if (abs < 1) return 'match';
  if (abs < 50 && pct < 1) return 'minor';
  if (abs < 500 && pct < 5) return 'material';
  return 'critical';
}

/**
 * Assemble MergedLineItem[] from the calculated rows.
 * Populates every row's `mergedLineItemId`.
 */
function buildMergedLineItems(rows: DutyResultRow[]): MergedLineItem[] {
  // Group rows by merge key
  const buckets = new Map<string, DutyResultRow[]>();
  const unmergedRows: DutyResultRow[] = [];
  for (const row of rows) {
    const key = mergeKeyFor(row.normalized);
    if (!key) {
      unmergedRows.push(row);
      continue;
    }
    const b = buckets.get(key) ?? [];
    b.push(row);
    buckets.set(key, b);
  }

  const items: MergedLineItem[] = [];

  function buildOne(mergeKey: string, bucket: DutyResultRow[]): MergedLineItem {
    // Pick main row: first non-chapter-99 row with a successful SAIL calc,
    // falling back to first non-chapter-99 row, falling back to first row.
    const mainRow =
      bucket.find((r) => !r.isChapter99 && r.calculated != null) ??
      bucket.find((r) => !r.isChapter99) ??
      bucket[0];
    const ch99 = bucket.filter((r) => r.isChapter99);

    // Mark rows
    const id = nextMergedLineId();
    for (const r of bucket) {
      r.mergedLineItemId = id;
      r.isMainLine = r === mainRow && !r.isChapter99;
    }

    const n = mainRow.normalized;
    const customsValue = n.customsValue ?? 0;

    // SAIL stack from main row's calculation
    const sailStackArr = mainRow.calculated
      ? sailStackFromCalculated(mainRow.calculated, customsValue)
      : [];

    // Broker stack folded from all rows
    const brokerFold = foldBrokerStack(
      !mainRow.isChapter99 ? mainRow : null,
      ch99,
      customsValue,
    );

    const combined = combineStacks(sailStackArr, brokerFold.stack);

    const sailTotalDuty = mainRow.calculated?.totalDuty ?? null;
    const brokerTotalDuty = brokerFold.totalDuty;
    const dutyVariance =
      sailTotalDuty != null && brokerTotalDuty != null
        ? sailTotalDuty - brokerTotalDuty
        : null;
    const dutyVariancePct =
      dutyVariance != null && brokerTotalDuty && brokerTotalDuty > 0
        ? (dutyVariance / brokerTotalDuty) * 100
        : null;

    return {
      id,
      mergeKey,
      entryGroupId: mainRow.entryGroupId ?? '',
      shipmentGroupId: mainRow.shipmentGroupId ?? '',
      rowIds: bucket.map((r) => r.rowId),
      mainRowId: !mainRow.isChapter99 ? mainRow.rowId : null,
      ch99RowIds: ch99.map((r) => r.rowId),
      hts10: n.hts10,
      description: n.description ?? n.htsDescription ?? null,
      partNumber: n.partNumber,
      invoiceLineNumber: n.invoiceLineNumber,
      countryOfOrigin: n.countryOfOrigin,
      countryOfOriginAlpha2: n.countryOfOriginAlpha2,
      countryOfOriginName: n.countryOfOriginName,
      controllingDate:
        mainRow.calculated?.controllingDate ?? n.entryDate ?? null,
      customsValue: n.customsValue,
      quantity: n.quantity,
      sailTotalDuty,
      sailMpf: mainRow.calculated?.mpf ?? null,
      sailHmf: mainRow.calculated?.hmf ?? null,
      sailTotalFees: mainRow.calculated?.totalFees ?? null,
      sailEffectiveRatePct: mainRow.calculated?.effectiveRatePct ?? null,
      sailLandedCost: mainRow.calculated?.landedCost ?? null,
      sailStack: sailStackArr,
      brokerTotalDuty,
      brokerMpf: brokerFold.totalMpf,
      brokerHmf: brokerFold.totalHmf,
      brokerFees:
        brokerFold.totalMpf != null || brokerFold.totalHmf != null
          ? (brokerFold.totalMpf ?? 0) + (brokerFold.totalHmf ?? 0)
          : null,
      brokerStack: brokerFold.stack,
      dutyVariance,
      dutyVariancePct,
      varianceSeverity: severityFromVariance(sailTotalDuty, brokerTotalDuty),
      hasUnmappedCh99: brokerFold.hasUnmapped,
      flags: bucket.flatMap((r) => r.flags),
      // Store the combined stack as the SAIL stack (since it also carries
      // the broker side on each entry). Consumers use `stack` for display.
    };
  }

  for (const [key, bucket] of buckets) {
    const item = buildOne(key, bucket);
    // Overwrite sailStack with the combined stack for display — every entry
    // now carries both SAIL and broker values + variance.
    item.sailStack = combineStacks(item.sailStack, item.brokerStack);
    items.push(item);
  }

  // Unmerged rows → one merged line each (they still deserve a record).
  for (const row of unmergedRows) {
    const mergeKey = `single::${row.rowId}`;
    const item = buildOne(mergeKey, [row]);
    item.sailStack = combineStacks(item.sailStack, item.brokerStack);
    items.push(item);
  }

  return items;
}

// -----------------------------------------------------------------------------
// Entry / shipment grouping
// -----------------------------------------------------------------------------
//
// Grouping is two-pass:
//   Pass A — assign every row a stable entryGroupId and shipmentGroupId
//            based on its normalized fields. Creates the group containers.
//   Pass B — aggregate customs values, compute entry-level MPF/HMF from the
//            aggregate (not from line sums), then attach broker-reported
//            totals and compute variance.
//
// The legal rule: MPF and HMF are per-entry fees with a floor and cap. Summing
// per-line MPF overstates what CBP actually assesses. The group's
// `recomputedMPF/HMF` is the correct figure; `sumLineMPF/HMF` is preserved so
// the UI can show users the gap.

let groupIdCounter = 0;
function nextGroupId(kind: string): string {
  groupIdCounter++;
  return `${kind}_${groupIdCounter}`;
}

function emptyGroup(
  kind: EntryGroup['kind'],
  key: string | null,
): EntryGroup {
  return {
    id: nextGroupId(kind),
    kind,
    key,
    rowIds: [],
    lineItemIds: [],
    totalCustomsValue: 0,
    totalCalculatedDuty: 0,
    sumLineMPF: 0,
    sumLineHMF: 0,
    recomputedMPF: 0,
    recomputedHMF: 0,
    totalCalculatedFees: 0,
    totalLandedCost: 0,
    effectiveRatePct: 0,
    totalUploadedDuty: null,
    totalUploadedMPF: null,
    totalUploadedHMF: null,
    dutyVariance: null,
    mpfVariance: null,
    hmfVariance: null,
  };
}

/**
 * Derive the entry grouping key for a row. Prefers entryNumber; falls back to
 * shipmentId / master bill / house bill so a row without an entry number still
 * rolls up into something meaningful.
 */
function entryKeyForRow(n: DutyResultRow['normalized']): { key: string; hasRealEntry: boolean } {
  if (n.entryNumber) return { key: `entry:${n.entryNumber}`, hasRealEntry: true };
  if (n.shipmentId) return { key: `ship:${n.shipmentId}`, hasRealEntry: false };
  if (n.masterBill) return { key: `mbl:${n.masterBill}`, hasRealEntry: false };
  if (n.houseBill) return { key: `hbl:${n.houseBill}`, hasRealEntry: false };
  return { key: '__unassigned__', hasRealEntry: false };
}

function shipmentKeyForRow(n: DutyResultRow['normalized']): string {
  if (n.shipmentId) return `ship:${n.shipmentId}`;
  if (n.masterBill) return `mbl:${n.masterBill}`;
  if (n.houseBill) return `hbl:${n.houseBill}`;
  if (n.entryNumber) return `entry:${n.entryNumber}`;
  return '__unassigned__';
}

function buildGroups(
  rows: DutyResultRow[],
  lineItems: MergedLineItem[],
): {
  entries: EntryGroup[];
  shipments: ShipmentGroup[];
} {
  // -- Pass A: assign groupIds --
  const entryMap = new Map<string, EntryGroup>();
  const shipmentMap = new Map<string, ShipmentGroup>();

  for (const row of rows) {
    const n = row.normalized;

    const { key: eKey, hasRealEntry } = entryKeyForRow(n);
    let entryGroup = entryMap.get(eKey);
    if (!entryGroup) {
      entryGroup = emptyGroup(
        hasRealEntry ? 'entry' : 'batch',
        hasRealEntry ? n.entryNumber : null,
      );
      entryMap.set(eKey, entryGroup);
    }
    row.entryGroupId = entryGroup.id;

    const sKey = shipmentKeyForRow(n);
    let shipmentGroup = shipmentMap.get(sKey);
    if (!shipmentGroup) {
      const hasRealShipment =
        !!(n.shipmentId || n.masterBill || n.houseBill);
      shipmentGroup = emptyGroup(
        hasRealShipment ? 'shipment' : 'batch',
        n.shipmentId ?? n.masterBill ?? n.houseBill ?? null,
      );
      shipmentMap.set(sKey, shipmentGroup);
    }
    row.shipmentGroupId = shipmentGroup.id;
  }

  // -- Pass B: aggregate and compute entry-level fees from the aggregate --
  // Per-entry ocean detection: if ANY line in the entry was ocean, HMF applies
  // to the aggregated entry value.
  const entryHasOcean = new Map<string, boolean>();
  const shipmentHasOcean = new Map<string, boolean>();
  for (const row of rows) {
    if (row.normalized.modeOfTransport !== 'ocean') continue;
    if (row.entryGroupId) entryHasOcean.set(row.entryGroupId, true);
    if (row.shipmentGroupId) shipmentHasOcean.set(row.shipmentGroupId, true);
  }

  // Index groups by id for O(1) lookup during rollup.
  const entryById = new Map<string, EntryGroup>();
  for (const g of entryMap.values()) entryById.set(g.id, g);
  const shipmentById = new Map<string, ShipmentGroup>();
  for (const g of shipmentMap.values()) shipmentById.set(g.id, g);

  // Accumulate line-level contributions.
  for (const row of rows) {
    const n = row.normalized;
    const c = row.calculated;

    const entryGroup = row.entryGroupId ? entryById.get(row.entryGroupId) : undefined;
    const shipmentGroup = row.shipmentGroupId
      ? shipmentById.get(row.shipmentGroupId)
      : undefined;

    for (const g of [entryGroup, shipmentGroup]) {
      if (!g) continue;
      g.rowIds.push(row.rowId);
      if (n.customsValue != null) g.totalCustomsValue += n.customsValue;
      if (c) {
        g.totalCalculatedDuty += c.totalDuty;
        g.sumLineMPF += c.mpf;
        g.sumLineHMF += c.hmf;
        g.totalLandedCost += c.landedCost;
      }
      if (n.uploadedDuty != null) {
        g.totalUploadedDuty = (g.totalUploadedDuty ?? 0) + n.uploadedDuty;
      }
      if (n.uploadedMPF != null) {
        g.totalUploadedMPF = (g.totalUploadedMPF ?? 0) + n.uploadedMPF;
      }
      if (n.uploadedHMF != null) {
        g.totalUploadedHMF = (g.totalUploadedHMF ?? 0) + n.uploadedHMF;
      }
    }
  }

  // Finalize: recompute MPF/HMF from the aggregated entry value, compute
  // variance vs broker totals.
  for (const g of entryById.values()) {
    finalizeGroup(g, entryHasOcean.get(g.id) ?? false);
  }
  for (const g of shipmentById.values()) {
    finalizeGroup(g, shipmentHasOcean.get(g.id) ?? false);
  }

  // -- Pass C: attach merged line item ids to their parent groups. --
  // Every row in a merged line has the same entryGroupId, so we can read it
  // from the first row in the line item.
  const rowById = new Map<string, DutyResultRow>();
  for (const r of rows) rowById.set(r.rowId, r);
  for (const li of lineItems) {
    const firstRow = li.rowIds.map((id) => rowById.get(id)).find((r) => !!r);
    if (!firstRow) continue;
    li.entryGroupId = firstRow.entryGroupId ?? '';
    li.shipmentGroupId = firstRow.shipmentGroupId ?? '';
    const eg = firstRow.entryGroupId
      ? entryById.get(firstRow.entryGroupId)
      : undefined;
    if (eg) eg.lineItemIds.push(li.id);
    const sg = firstRow.shipmentGroupId
      ? shipmentById.get(firstRow.shipmentGroupId)
      : undefined;
    if (sg) sg.lineItemIds.push(li.id);
  }

  return {
    entries: Array.from(entryById.values()),
    shipments: Array.from(shipmentById.values()),
  };
}

function finalizeGroup(g: EntryGroup, hasOcean: boolean): void {
  // MPF cap logic only applies to groups that represent a real customs entry.
  // For shipment / batch groups (where multiple entries may be aggregated),
  // recomputing from the aggregate would under-count because each CBP entry
  // gets its own min/max. In MVP we still recompute, but surface the gap so
  // users understand what they're looking at.
  g.recomputedMPF = calculateMPF(g.totalCustomsValue);
  g.recomputedHMF = hasOcean ? calculateHMF(g.totalCustomsValue) : 0;
  g.totalCalculatedFees = g.recomputedMPF + g.recomputedHMF;
  g.effectiveRatePct =
    g.totalCustomsValue > 0
      ? (g.totalCalculatedDuty / g.totalCustomsValue) * 100
      : 0;
  if (g.totalUploadedDuty != null) {
    g.dutyVariance = g.totalCalculatedDuty - g.totalUploadedDuty;
  }
  if (g.totalUploadedMPF != null) {
    g.mpfVariance = g.recomputedMPF - g.totalUploadedMPF;
  }
  if (g.totalUploadedHMF != null) {
    g.hmfVariance = g.recomputedHMF - g.totalUploadedHMF;
  }
}

// -----------------------------------------------------------------------------
// Cross-row consistency validation
// -----------------------------------------------------------------------------
// Real CBP entries are uniform on certain fields: all lines in one entry
// should share the same entryDate and (usually) the same countryOfOrigin.
// When they don't, flag every row in the group so reviewers can investigate.

function applyGroupConsistencyFlags(
  rows: DutyResultRow[],
  groups: EntryGroup[],
): void {
  const rowById = new Map<string, DutyResultRow>();
  for (const r of rows) rowById.set(r.rowId, r);

  for (const group of groups) {
    if (group.kind !== 'entry' || group.rowIds.length < 2) continue;

    const dates = new Set<string>();
    const origins = new Set<string>();
    for (const rid of group.rowIds) {
      const r = rowById.get(rid);
      if (!r) continue;
      if (r.normalized.entryDate) dates.add(r.normalized.entryDate);
      if (r.normalized.countryOfOrigin) origins.add(r.normalized.countryOfOrigin);
    }

    const mismatches: string[] = [];
    if (dates.size > 1) {
      mismatches.push(`entryDate (${Array.from(dates).join(', ')})`);
    }
    if (origins.size > 1) {
      mismatches.push(`countryOfOrigin (${Array.from(origins).join(', ')})`);
    }
    if (mismatches.length === 0) continue;

    const message = `Entry ${group.key ?? '(unassigned)'} has mixed ${mismatches.join(
      ' and ',
    )}. Verify that lines belong to the same customs entry.`;
    for (const rid of group.rowIds) {
      const r = rowById.get(rid);
      if (!r) continue;
      // Don't double-flag if already present
      if (r.flags.some((f) => f.kind === 'group_inconsistency')) continue;
      r.flags = [
        ...r.flags,
        {
          kind: 'group_inconsistency',
          severity: 'warning',
          message,
        },
      ];
    }
  }
}

// -----------------------------------------------------------------------------
// Public entry point
// -----------------------------------------------------------------------------

export interface CalculateBulkOptions {
  rateMap: RateMap;
  defaultMOT?: 'ocean' | 'air' | 'land';
  onProgress?: (processed: number, total: number) => void;
}

export interface BulkCalculationResult {
  rows: DutyResultRow[];
  lineItems: MergedLineItem[];
  entries: EntryGroup[];
  shipments: ShipmentGroup[];
  jobSummary: JobSummary;
}

export function calculateBulk(
  rows: DutyResultRow[],
  options: CalculateBulkOptions,
): BulkCalculationResult {
  const { rateMap, defaultMOT = 'ocean', onProgress } = options;

  const calculated: DutyResultRow[] = [];
  for (let i = 0; i < rows.length; i++) {
    calculated.push(calculateOne(rows[i], rateMap, defaultMOT));
    if (onProgress && (i % 100 === 0 || i === rows.length - 1)) {
      onProgress(i + 1, rows.length);
    }
  }

  // Build merged line items BEFORE grouping so entry groups can reference
  // them by id (merged line grouping assigns mergedLineItemId onto each row).
  const lineItems = buildMergedLineItems(calculated);
  const { entries, shipments } = buildGroups(calculated, lineItems);
  applyGroupConsistencyFlags(calculated, entries);

  // Job summary
  const summary = emptyJobSummary();
  summary.totalRows = calculated.length;
  summary.shipmentCount = shipments.length;
  summary.entryCount = entries.length;
  summary.uniqueRateKeys = new Set(
    calculated.map((r) => r.rateKey).filter(Boolean) as string[],
  ).size;

  let totalUploadedDuty = 0;
  let hasUploadedDuty = false;
  const flagCounts: Partial<Record<ExceptionFlagKind, number>> = {};

  for (const row of calculated) {
    const blocking = row.validation.some((v) => v.severity === 'blocking');
    if (blocking) summary.blockedRows++;
    else if (row.validation.length > 0 || row.flags.some((f) => f.severity === 'warning')) {
      summary.warningRows++;
    } else {
      summary.validRows++;
    }

    for (const f of row.flags) {
      flagCounts[f.kind] = (flagCounts[f.kind] ?? 0) + 1;
    }

    if (row.normalized.customsValue != null) {
      summary.totalCustomsValue += row.normalized.customsValue;
    }
    if (row.calculated) {
      summary.totalCalculatedDuty += row.calculated.totalDuty;
      summary.totalCalculatedFees += row.calculated.totalFees;
    }
    if (row.normalized.uploadedDuty != null) {
      totalUploadedDuty += row.normalized.uploadedDuty;
      hasUploadedDuty = true;
    }
  }

  summary.totalUploadedDuty = hasUploadedDuty ? totalUploadedDuty : null;
  summary.totalDutyVariance = hasUploadedDuty
    ? summary.totalCalculatedDuty - totalUploadedDuty
    : null;
  summary.flagCounts = flagCounts;

  return { rows: calculated, lineItems, entries, shipments, jobSummary: summary };
}
