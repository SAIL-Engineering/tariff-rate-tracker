// =============================================================================
// LineDetailDrawer — rate history + duty stack breakdown for a merged line
// =============================================================================
// When the user clicks a line item in the bulk review grid, this drawer
// slides over from the right and shows:
//   1. Line context (HTS, origin, controlling date, customs value, duty)
//   2. Per-authority variance against broker-reported values (if present)
//   3. Full rate-period history for the HTS + origin via RateComparisonTable
//   4. Duty-stack breakdown for the applicable period via DutyStackBreakdown
//   5. Flags and calculation assumptions
//
// Reuses the exact components the Rate Lookup tab uses so behavior, visual
// treatment, and revision logic stay consistent across the app.

import React, { useEffect, useMemo, useState } from 'react';
import {
  X,
  FileText,
  Calendar,
  Globe,
  Package,
  Loader2,
  AlertCircle,
  TrendingUp,
  TrendingDown,
  Minus,
  Info,
  Layers,
} from 'lucide-react';
import { Button } from '@/components/ui/button';
import type { ProductRate } from '@/types/tariff';
import type {
  DutyResultRow,
  MergedLineItem,
  AuthorityStackEntry,
} from '@/types/bulk';
import { fetchRatesArrow } from '@/hooks/useTariffData';
import { findRateForDate } from '@/utils/tariffCalculator';
import {
  formatCurrency,
  formatDate,
  formatHtsCode,
  formatRateShort,
} from '@/utils/formatters';
import { RateComparisonTable } from '../RateComparisonTable';
import { DutyStackBreakdown } from '../DutyStackBreakdown';
import { cn } from '@/lib/utils';

interface Props {
  lineItem: MergedLineItem | null;
  rows: DutyResultRow[];
  onClose: () => void;
}

const AUTHORITY_COLOR: Record<string, string> = {
  base: '#008dff',
  rate_232: '#ff7c43',
  rate_301: '#59a89c',
  rate_ieepa_recip: '#665191',
  rate_ieepa_fent: '#d45087',
  rate_s122: '#f95d6a',
  rate_section_201: '#a05195',
  rate_other: '#ffa600',
  mpf: '#94a3b8',
  hmf: '#94a3b8',
};

export function LineDetailDrawer({ lineItem, rows, onClose }: Props) {
  const [rates, setRates] = useState<ProductRate[]>([]);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);

  // Resolve the contained source rows for the drawer's source-rows strip.
  const containedRows = useMemo(() => {
    if (!lineItem) return [];
    const byId = new Map(rows.map((r) => [r.rowId, r]));
    return lineItem.rowIds
      .map((id) => byId.get(id))
      .filter((r): r is DutyResultRow => !!r);
  }, [lineItem, rows]);

  // Fetch full rate history for this line item's HTS + country.
  useEffect(() => {
    if (!lineItem) {
      setRates([]);
      setError(null);
      return;
    }
    const { hts10, countryOfOrigin } = lineItem;
    if (!hts10 || !countryOfOrigin) {
      setError('Line is missing HTS or country of origin.');
      return;
    }
    let cancelled = false;
    setLoading(true);
    setError(null);
    setRates([]);

    fetchRatesArrow(hts10, [countryOfOrigin])
      .then((result) => {
        if (cancelled) return;
        const sorted = [...result].sort((a, b) =>
          a.effective_date.localeCompare(b.effective_date),
        );
        setRates(sorted);
      })
      .catch((err) => {
        if (cancelled) return;
        setError(
          err instanceof Error ? err.message : 'Failed to load rate history.',
        );
      })
      .finally(() => {
        if (!cancelled) setLoading(false);
      });

    return () => {
      cancelled = true;
    };
  }, [lineItem]);

  // Period that matches the line's controlling date
  const applicableRate = useMemo(() => {
    if (!lineItem?.controllingDate || rates.length === 0) return null;
    return findRateForDate(rates, lineItem.controllingDate);
  }, [rates, lineItem]);

  const selectedIndex = useMemo(() => {
    if (!applicableRate) return null;
    const i = rates.findIndex(
      (r) =>
        r.revision === applicableRate.revision &&
        r.valid_from === applicableRate.valid_from,
    );
    return i >= 0 ? i : null;
  }, [rates, applicableRate]);

  const [inspectedIndex, setInspectedIndex] = useState<number | null>(null);
  useEffect(() => {
    setInspectedIndex(null);
  }, [lineItem]);

  const inspectedRate =
    inspectedIndex != null ? rates[inspectedIndex] ?? null : applicableRate;

  if (!lineItem) return null;

  const customsValue = lineItem.customsValue ?? 0;

  return (
    <>
      {/* Backdrop */}
      <div
        className="fixed inset-0 bg-slate-900/25 backdrop-blur-[2px] z-40 animate-fade-in"
        onClick={onClose}
      />
      {/* Drawer */}
      <div className="fixed top-0 right-0 bottom-0 w-[780px] max-w-[95vw] bg-[#FAFAF8] shadow-[−24px_0_56px_-16px_rgba(15,23,42,0.28)] z-50 flex flex-col animate-slide-in-right">
        {/* Header */}
        <div className="relative overflow-hidden border-b border-gray-100 bg-white">
          {/* Subtle accent gradient in the top-right corner */}
          <div className="absolute top-0 right-0 w-48 h-full bg-gradient-to-l from-[#353CED]/[0.04] to-transparent pointer-events-none" />
          <div className="relative flex items-center gap-3 px-5 py-4">
            <div className="w-10 h-10 rounded-xl bg-gradient-to-br from-[#353CED]/10 to-[#353CED]/5 flex items-center justify-center flex-shrink-0 ring-1 ring-[#353CED]/10">
              <FileText className="h-4 w-4 text-[#353CED]" strokeWidth={2} />
            </div>
            <div className="flex-1 min-w-0">
              <div className="flex items-baseline gap-2 flex-wrap">
                <h3 className="font-semibold text-sm text-gray-900 tracking-[-0.01em]">
                  Line Item
                </h3>
                {lineItem.hts10 && (
                  <span className="font-mono text-[13px] text-[#353CED] tracking-tight font-semibold">
                    {formatHtsCode(lineItem.hts10)}
                  </span>
                )}
                {lineItem.partNumber && (
                  <span className="text-[11px] text-gray-400">
                    · Part{' '}
                    <span className="text-gray-600 font-mono">
                      {lineItem.partNumber}
                    </span>
                  </span>
                )}
                {lineItem.invoiceLineNumber && (
                  <span className="text-[11px] text-gray-400">
                    · Line{' '}
                    <span className="text-gray-600 font-mono">
                      {lineItem.invoiceLineNumber}
                    </span>
                  </span>
                )}
                {lineItem.ch99RowIds.length > 0 && (
                  <span className="inline-flex items-center gap-1 px-1.5 py-0.5 rounded-md bg-[#353CED]/10 text-[9px] font-semibold text-[#353CED] uppercase tracking-wider ring-1 ring-[#353CED]/15">
                    <Layers className="h-2.5 w-2.5" strokeWidth={2.5} />
                    +{lineItem.ch99RowIds.length} Ch.99
                  </span>
                )}
              </div>
              <div
                className="text-[11px] text-gray-500 truncate mt-0.5"
                title={lineItem.description ?? ''}
              >
                {lineItem.description || <span className="text-gray-300">—</span>}
              </div>
            </div>
            <Button
              variant="ghost"
              size="icon"
              onClick={onClose}
              className="h-8 w-8"
              aria-label="Close drawer"
            >
              <X className="h-4 w-4" strokeWidth={2} />
            </Button>
          </div>
        </div>

        {/* Scroll container */}
        <div className="flex-1 overflow-auto p-5 space-y-4">
          {/* Context tiles */}
          <div className="grid grid-cols-4 gap-2">
            <ContextTile
              icon={<Calendar className="h-3 w-3 text-[#353CED]" />}
              label="Controlling Date"
              value={
                lineItem.controllingDate
                  ? formatDate(lineItem.controllingDate)
                  : '—'
              }
            />
            <ContextTile
              icon={<Globe className="h-3 w-3 text-[#353CED]" />}
              label="Origin"
              value={
                lineItem.countryOfOriginAlpha2 ??
                lineItem.countryOfOrigin ??
                '—'
              }
              sub={lineItem.countryOfOriginName ?? undefined}
            />
            <ContextTile
              icon={<Package className="h-3 w-3 text-[#353CED]" />}
              label="Customs Value"
              value={
                lineItem.customsValue != null
                  ? formatCurrency(lineItem.customsValue)
                  : '—'
              }
              mono
            />
            <ContextTile
              icon={<Package className="h-3 w-3 text-red-500" />}
              label="SAIL Duty"
              value={
                lineItem.sailTotalDuty != null
                  ? formatCurrency(lineItem.sailTotalDuty)
                  : '—'
              }
              mono
              tone="red"
            />
          </div>

          {/* Variance summary strip */}
          {lineItem.varianceSeverity !== 'no_upload' && (
            <div
              className={cn(
                'rounded-xl border px-4 py-3 flex items-center gap-4 text-[11px]',
                lineItem.varianceSeverity === 'critical'
                  ? 'bg-red-50/60 border-red-100'
                  : lineItem.varianceSeverity === 'material'
                  ? 'bg-amber-50/60 border-amber-100'
                  : lineItem.varianceSeverity === 'minor'
                  ? 'bg-yellow-50/60 border-yellow-100'
                  : 'bg-emerald-50/40 border-emerald-100',
              )}
            >
              <span className="text-[10px] font-semibold text-gray-500 uppercase tracking-wider">
                SAIL vs Broker
              </span>
              <VarianceItem
                label="Duty"
                calc={lineItem.sailTotalDuty ?? 0}
                broker={lineItem.brokerTotalDuty}
                variance={lineItem.dutyVariance}
              />
              <VarianceItem
                label="MPF"
                calc={lineItem.sailMpf ?? 0}
                broker={lineItem.brokerMpf}
                variance={
                  lineItem.sailMpf != null && lineItem.brokerMpf != null
                    ? lineItem.sailMpf - lineItem.brokerMpf
                    : null
                }
              />
              <VarianceItem
                label="HMF"
                calc={lineItem.sailHmf ?? 0}
                broker={lineItem.brokerHmf}
                variance={
                  lineItem.sailHmf != null && lineItem.brokerHmf != null
                    ? lineItem.sailHmf - lineItem.brokerHmf
                    : null
                }
              />
            </div>
          )}

          {/* Authority stack — SAIL vs Broker table */}
          {lineItem.sailStack.length > 0 && (
            <div className="rounded-xl border border-gray-200/80 overflow-hidden shadow-[0_1px_2px_rgba(15,23,42,0.03)]">
              <div className="bg-gradient-to-b from-gray-50 to-gray-50/60 px-3.5 py-2.5 border-b border-gray-100">
                <div className="text-[10px] font-semibold text-gray-500 uppercase tracking-[0.08em]">
                  Duty Stack — SAIL vs Broker
                </div>
              </div>
              {/* Column header */}
              <div className="grid grid-cols-[1.4fr_90px_100px_90px_100px_100px] gap-2 px-3.5 py-1.5 bg-gray-50/40 border-b border-gray-100/80 text-[9px] font-semibold text-gray-400 uppercase tracking-[0.08em]">
                <span>Authority</span>
                <span className="text-right">SAIL Rate</span>
                <span className="text-right">SAIL Duty</span>
                <span className="text-right">Broker Rate</span>
                <span className="text-right">Broker Duty</span>
                <span className="text-right">Variance</span>
              </div>
              <div className="divide-y divide-gray-50 bg-white">
                {lineItem.sailStack.map((s) => (
                  <AuthorityRow
                    key={s.key}
                    entry={s}
                    customsValue={customsValue}
                  />
                ))}
              </div>
            </div>
          )}

          {/* Contained source rows — trace back to the original spreadsheet */}
          <div className="rounded-xl border border-gray-200/80 overflow-hidden shadow-[0_1px_2px_rgba(15,23,42,0.03)]">
            <div className="bg-gradient-to-b from-gray-50 to-gray-50/60 px-3.5 py-2.5 flex items-center justify-between border-b border-gray-100">
              <span className="text-[10px] font-semibold text-gray-500 uppercase tracking-[0.08em]">
                Source Rows
              </span>
              <span className="text-[10px] font-mono tabular-nums text-gray-400">
                {containedRows.length}
              </span>
            </div>
            <div className="divide-y divide-gray-50 bg-white">
              {containedRows.map((r) => (
                <div
                  key={r.rowId}
                  className="grid grid-cols-[52px_64px_108px_1fr_108px] gap-2 px-3.5 py-2 text-[11px] items-center"
                >
                  <span className="font-mono tabular-nums text-gray-400">
                    #{r.sourceRowIndex}
                  </span>
                  {r.isChapter99 ? (
                    <span className="inline-flex items-center gap-1 px-1.5 py-0.5 rounded-md bg-[#353CED]/8 text-[9px] font-semibold text-[#353CED] uppercase tracking-wider ring-1 ring-[#353CED]/15 justify-center">
                      <Layers className="h-2 w-2" strokeWidth={2.5} />
                      Ch.99
                    </span>
                  ) : (
                    <span className="inline-flex items-center px-1.5 py-0.5 rounded-md bg-emerald-50 text-[9px] font-semibold text-emerald-700 uppercase tracking-wider ring-1 ring-emerald-100 justify-center">
                      Main
                    </span>
                  )}
                  <span className="font-mono text-gray-700">
                    {r.normalized.hts10
                      ? formatHtsCode(r.normalized.hts10)
                      : '—'}
                  </span>
                  <span
                    className="text-gray-500 truncate"
                    title={r.normalized.description ?? ''}
                  >
                    {r.normalized.description ?? '—'}
                  </span>
                  <span className="font-mono tabular-nums text-right text-gray-700">
                    {r.normalized.uploadedDuty != null
                      ? formatCurrency(r.normalized.uploadedDuty)
                      : '—'}
                  </span>
                </div>
              ))}
            </div>
          </div>

          {/* Flags */}
          {lineItem.flags.length > 0 && (
            <div className="rounded-xl border border-gray-200/80 overflow-hidden">
              <div className="bg-gray-50/80 px-3 py-2 text-[10px] font-semibold text-gray-500 uppercase tracking-wider border-b border-gray-100">
                Flags
              </div>
              <div className="divide-y divide-gray-50">
                {dedupeFlags(lineItem.flags).map((f, i) => (
                  <div
                    key={i}
                    className="px-3 py-2 flex items-start gap-2 text-[11px]"
                  >
                    <AlertCircle
                      className={cn(
                        'h-3 w-3 flex-shrink-0 mt-0.5',
                        f.severity === 'error'
                          ? 'text-red-500'
                          : f.severity === 'warning'
                          ? 'text-amber-500'
                          : 'text-blue-500',
                      )}
                    />
                    <div>
                      <div className="text-gray-700">
                        <span className="font-medium">
                          {f.kind.replace(/_/g, ' ')}
                        </span>
                        {f.field && (
                          <span className="text-gray-400 ml-1">({f.field})</span>
                        )}
                      </div>
                      <div className="text-gray-500">{f.message}</div>
                    </div>
                  </div>
                ))}
              </div>
            </div>
          )}

          {/* Rate history */}
          <div>
            <div className="flex items-center gap-1.5 mb-2">
              <span className="text-[11px] font-medium text-gray-500 uppercase tracking-wider">
                Rate History
              </span>
              <div className="group relative">
                <Info className="h-3 w-3 text-gray-400 cursor-help" />
                <div className="absolute bottom-full left-1/2 -translate-x-1/2 mb-2 px-3 py-2 bg-gray-900 text-white text-[10px] rounded-lg w-60 opacity-0 group-hover:opacity-100 transition-opacity pointer-events-none z-50">
                  The period matching this line's controlling date is
                  pre-selected. Click another period to see its duty stack.
                </div>
              </div>
              {inspectedIndex != null && (
                <button
                  type="button"
                  onClick={() => setInspectedIndex(null)}
                  className="ml-auto text-[10px] text-[#353CED] hover:underline"
                >
                  Reset to controlling period
                </button>
              )}
            </div>
            {loading ? (
              <div className="flex items-center justify-center h-40 text-gray-300 text-xs gap-2">
                <Loader2 className="h-4 w-4 animate-spin" />
                Loading rate history…
              </div>
            ) : error ? (
              <div className="flex items-start gap-2 px-4 py-3 rounded-xl bg-red-50 border border-red-200 text-xs text-red-800">
                <AlertCircle className="h-4 w-4 flex-shrink-0 mt-0.5" />
                <span>{error}</span>
              </div>
            ) : rates.length === 0 ? (
              <div className="flex items-center justify-center h-24 text-gray-300 text-xs">
                No rate history available.
              </div>
            ) : (
              <RateComparisonTable
                entries={rates}
                onSelectEntry={(i) =>
                  setInspectedIndex((prev) => (prev === i ? null : i))
                }
                selectedIndex={inspectedIndex ?? selectedIndex}
              />
            )}
          </div>

          {/* Duty stack breakdown for the inspected period */}
          {inspectedRate && (
            <div>
              <div className="text-[11px] font-medium text-gray-500 uppercase tracking-wider mb-2">
                Controlling Period Duty Stack
              </div>
              <DutyStackBreakdown
                rate={inspectedRate}
                countryName={
                  lineItem.countryOfOriginName ??
                  lineItem.countryOfOrigin ??
                  ''
                }
                label={
                  inspectedIndex != null
                    ? `Period: ${inspectedRate.revision}`
                    : 'Controlling Period'
                }
              />
            </div>
          )}
        </div>
      </div>
    </>
  );
}

// -----------------------------------------------------------------------------
// Context tile
// -----------------------------------------------------------------------------

function ContextTile({
  icon,
  label,
  value,
  sub,
  mono,
  tone,
}: {
  icon: React.ReactNode;
  label: string;
  value: string;
  sub?: string;
  mono?: boolean;
  tone?: 'red';
}) {
  return (
    <div className="rounded-xl border border-gray-100 bg-white px-3.5 py-3 shadow-[0_1px_2px_rgba(15,23,42,0.03)]">
      <div className="flex items-center gap-1.5 mb-1.5">
        <div className="w-4 h-4 rounded-md bg-[#353CED]/6 flex items-center justify-center flex-shrink-0">
          {icon}
        </div>
        <span className="text-[9px] font-semibold text-gray-500 uppercase tracking-[0.08em]">
          {label}
        </span>
      </div>
      <div
        className={cn(
          'text-[14px] tabular-nums leading-none',
          mono && 'font-mono',
          tone === 'red'
            ? 'text-red-600 font-semibold'
            : 'text-gray-900 font-semibold',
        )}
      >
        {value}
      </div>
      {sub && (
        <div className="text-[9px] text-gray-400 truncate mt-1">{sub}</div>
      )}
    </div>
  );
}

function VarianceItem({
  label,
  calc,
  broker,
  variance,
}: {
  label: string;
  calc: number;
  broker: number | null;
  variance: number | null;
}) {
  return (
    <div className="flex flex-col">
      <span className="text-[9px] uppercase tracking-wider text-gray-500">
        {label}
      </span>
      <div className="flex items-center gap-1.5">
        <span className="font-mono text-gray-600">
          {broker != null ? formatCurrency(broker) : '—'}
        </span>
        {variance != null && (
          <>
            {Math.abs(variance) < 0.01 ? (
              <Minus className="h-3 w-3 text-gray-400" />
            ) : variance > 0 ? (
              <TrendingUp className="h-3 w-3 text-red-500" />
            ) : (
              <TrendingDown className="h-3 w-3 text-emerald-500" />
            )}
            <span
              className={cn(
                'font-mono font-semibold',
                Math.abs(variance) < 1
                  ? 'text-emerald-600'
                  : Math.abs(variance) < 50
                  ? 'text-yellow-700'
                  : Math.abs(variance) < 500
                  ? 'text-amber-600'
                  : 'text-red-600',
              )}
            >
              {formatCurrency(variance)}
            </span>
          </>
        )}
      </div>
      <span className="text-[9px] text-gray-400">
        SAIL: <span className="font-mono">{formatCurrency(calc)}</span>
      </span>
    </div>
  );
}

// -----------------------------------------------------------------------------
// Authority row — one line of the per-authority SAIL vs Broker stack
// -----------------------------------------------------------------------------

function AuthorityRow({
  entry,
  customsValue,
}: {
  entry: AuthorityStackEntry;
  customsValue: number;
}) {
  const variance = entry.variance;
  const dotColor = AUTHORITY_COLOR[entry.key] ?? '#94a3b8';
  return (
    <div className="grid grid-cols-[1.4fr_100px_100px_100px_100px_100px] gap-2 px-3 py-1.5 items-center text-[11px]">
      <div className="flex items-center gap-2 min-w-0">
        <span
          className="w-1.5 h-1.5 rounded-full flex-shrink-0"
          style={{ backgroundColor: dotColor }}
        />
        <span className="text-gray-700 truncate">{entry.label}</span>
        {entry.ch99Codes && entry.ch99Codes.length > 0 && (
          <span
            className="font-mono text-[9px] text-[#353CED] truncate"
            title={entry.ch99Codes.join(', ')}
          >
            ({entry.ch99Codes.map(formatHtsCode).slice(0, 2).join(', ')}
            {entry.ch99Codes.length > 2 ? '…' : ''})
          </span>
        )}
      </div>
      <div className="font-mono text-right text-gray-500 text-[10px]">
        {entry.sailRate != null ? formatRateShort(entry.sailRate) : '—'}
      </div>
      <div className="font-mono text-right text-red-500">
        {entry.sailAmount != null ? formatCurrency(entry.sailAmount) : '—'}
      </div>
      <div className="font-mono text-right text-gray-500 text-[10px]">
        {entry.brokerRate != null ? formatRateShort(entry.brokerRate) : '—'}
      </div>
      <div className="font-mono text-right text-gray-700">
        {entry.brokerAmount != null ? formatCurrency(entry.brokerAmount) : '—'}
      </div>
      <div className="font-mono text-right">
        {variance != null ? (
          <span
            className={cn(
              Math.abs(variance) < 1
                ? 'text-emerald-600'
                : Math.abs(variance) < 50
                ? 'text-yellow-700'
                : Math.abs(variance) < 500
                ? 'text-amber-600'
                : 'text-red-600 font-semibold',
            )}
          >
            {formatCurrency(variance)}
          </span>
        ) : (
          <span className="text-gray-300">—</span>
        )}
      </div>
    </div>
  );
}

// -----------------------------------------------------------------------------
// Helpers
// -----------------------------------------------------------------------------

function dedupeFlags(flags: MergedLineItem['flags']) {
  const seen = new Map<string, MergedLineItem['flags'][number]>();
  for (const f of flags) {
    const key = `${f.kind}::${f.message}`;
    if (!seen.has(key)) seen.set(key, f);
  }
  return Array.from(seen.values());
}
