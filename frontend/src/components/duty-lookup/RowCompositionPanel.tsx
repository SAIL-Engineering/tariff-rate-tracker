import React, { useState, useMemo } from 'react';
import { Input } from '@/components/ui/input';
import { Button } from '@/components/ui/button';
import { applyMetalContentOverride, computeNetAuthorityAmounts } from '@/utils/tariffCalculator';
import type { ProductRate, CompositionOverrides, DeclaredMetalContent } from '@/types/tariff';
import { formatRate } from '@/utils/formatters';
import { Scale, Percent, RotateCcw, AlertTriangle } from 'lucide-react';
import { cn } from '@/lib/utils';

interface RowCompositionPanelProps {
  rate: ProductRate;
  countryCode: string;
  composition: CompositionOverrides | undefined;
  onChange: (next: CompositionOverrides | undefined) => void;
}

type InputMode = 'percent' | 'weight';
type MetalKey = 'aluminum' | 'steel' | 'copper' | 'other';

const METALS: { key: MetalKey; label: string }[] = [
  { key: 'aluminum', label: 'Aluminum' },
  { key: 'steel',    label: 'Steel' },
  { key: 'copper',   label: 'Copper' },
  { key: 'other',    label: 'Other' },
];

/**
 * Per-row "Declared metal content" panel for the multi-line duty calculator.
 *
 * Lets the user override the BEA-derived per-type metal shares on a row by
 * declaring actual content (% or grams). The calculator engine reads from
 * row.composition.declaredMetalContent and applies it to the rate before
 * stacking math runs, so the displayed Section 232 rate updates live.
 *
 * Renders nothing when the row's rate has no Section 232 component (no point
 * declaring metal content where S232 doesn't apply).
 */
export function RowCompositionPanel({
  rate, countryCode, composition, onChange,
}: RowCompositionPanelProps) {
  const [mode, setMode] = useState<InputMode>('percent');

  // No point if S232 isn't active for this row
  if (rate.rate_232 <= 0) return null;

  const declared = composition?.declaredMetalContent;

  const updateMetal = (key: MetalKey, field: 'percent' | 'grams', value: number | undefined) => {
    const nextDeclared: DeclaredMetalContent = { ...declared };
    const existing = nextDeclared[key] ?? {};
    nextDeclared[key] = { ...existing, [field]: value };
    onChange({ ...(composition ?? {}), declaredMetalContent: nextDeclared });
  };

  const updateTotalWeight = (value: number | undefined) => {
    onChange({
      ...(composition ?? {}),
      declaredMetalContent: { ...(declared ?? {}), totalWeightGrams: value },
    });
  };

  const reset = () => {
    if (!composition) return;
    const { declaredMetalContent, ...rest } = composition;
    onChange(Object.keys(rest).length > 0 ? rest : undefined);
  };

  // Effective rate after applying the declared override — for live preview.
  const effectiveRate = useMemo(
    () => applyMetalContentOverride(rate, declared),
    [rate, declared],
  );
  const netBefore = useMemo(() => computeNetAuthorityAmounts(rate, countryCode), [rate, countryCode]);
  const netAfter  = useMemo(() => computeNetAuthorityAmounts(effectiveRate, countryCode), [effectiveRate, countryCode]);

  // Per-metal effective % (for display)
  const effectivePcts: Record<MetalKey, number> = {
    aluminum: effectiveRate.aluminum_share,
    steel:    effectiveRate.steel_share,
    copper:   effectiveRate.copper_share,
    other:    effectiveRate.other_metal_share,
  };

  const totalDeclared = effectiveRate.metal_share;
  const declaredSum = (declared?.aluminum?.percent ?? 0) + (declared?.steel?.percent ?? 0)
                    + (declared?.copper?.percent ?? 0) + (declared?.other?.percent ?? 0);
  const overOneHundred = mode === 'percent' && declaredSum > 1.000001;

  const hasAnyDeclared = !!declared && (
    !!declared.aluminum || !!declared.steel || !!declared.copper || !!declared.other
    || declared.totalWeightGrams != null
  );

  return (
    <div className="rounded-lg border border-gray-200 bg-white p-3 space-y-3">
      <div className="flex items-start justify-between gap-3">
        <div>
          <div className="text-[12px] font-semibold text-gray-900 flex items-center gap-1.5">
            <Scale className="h-3.5 w-3.5 text-gray-500" />
            Declared metal content (optional)
          </div>
          <div className="text-[10.5px] text-gray-500 mt-0.5 leading-snug">
            Default scales by BEA-derived per-type shares. Declare actual content to override —
            the displayed Section 232 rate recomputes live.
          </div>
        </div>
        {hasAnyDeclared && (
          <Button variant="outline" size="sm" onClick={reset} className="h-7 text-[10.5px] px-2">
            <RotateCcw className="h-3 w-3 mr-1" />
            Reset
          </Button>
        )}
      </div>

      <div className="flex items-center gap-2 text-[10.5px]">
        <span className="text-gray-500">Input:</span>
        <button
          type="button"
          className={cn(
            'inline-flex items-center gap-1 px-2 py-1 rounded border transition-colors',
            mode === 'percent'
              ? 'bg-[#353CED]/10 border-[#353CED]/30 text-[#353CED] font-semibold'
              : 'bg-white border-gray-200 text-gray-600 hover:border-gray-300',
          )}
          onClick={() => setMode('percent')}
        >
          <Percent className="h-3 w-3" />
          Percent
        </button>
        <button
          type="button"
          className={cn(
            'inline-flex items-center gap-1 px-2 py-1 rounded border transition-colors',
            mode === 'weight'
              ? 'bg-[#353CED]/10 border-[#353CED]/30 text-[#353CED] font-semibold'
              : 'bg-white border-gray-200 text-gray-600 hover:border-gray-300',
          )}
          onClick={() => setMode('weight')}
        >
          <Scale className="h-3 w-3" />
          Weight (g)
        </button>
      </div>

      {mode === 'weight' && (
        <div className="flex items-center gap-2">
          <label className="text-[10.5px] text-gray-500 whitespace-nowrap">Total product weight (g):</label>
          <Input
            type="number"
            min={0}
            step={0.01}
            value={declared?.totalWeightGrams ?? ''}
            onChange={(e) => {
              const v = e.target.value === '' ? undefined : Number(e.target.value);
              updateTotalWeight(Number.isFinite(v as number) ? v : undefined);
            }}
            className="h-8 text-[11px] max-w-[140px]"
          />
        </div>
      )}

      <div className="grid grid-cols-1 sm:grid-cols-2 gap-2">
        {METALS.map(({ key, label }) => {
          const decl = declared?.[key];
          const fieldValue =
            mode === 'percent'
              ? decl?.percent != null ? decl.percent * 100 : ''
              : decl?.grams ?? '';
          const effPct = effectivePcts[key] * 100;
          const isOverridden = decl?.[mode === 'percent' ? 'percent' : 'grams'] != null;
          return (
            <div key={key} className="flex items-center gap-2">
              <label className="text-[11px] text-gray-700 w-16 shrink-0">{label}</label>
              <Input
                type="number"
                min={0}
                step={mode === 'percent' ? 0.01 : 0.001}
                placeholder={`BEA: ${effPct.toFixed(3)}%`}
                value={fieldValue}
                onChange={(e) => {
                  const raw = e.target.value;
                  if (raw === '') {
                    updateMetal(key, mode === 'percent' ? 'percent' : 'grams', undefined);
                    return;
                  }
                  const n = Number(raw);
                  if (!Number.isFinite(n)) return;
                  const v = mode === 'percent' ? Math.max(0, n) / 100 : Math.max(0, n);
                  updateMetal(key, mode === 'percent' ? 'percent' : 'grams', v);
                }}
                className="h-8 text-[11px]"
              />
              <span className="text-[10px] text-gray-400 w-10 shrink-0 text-right">
                {mode === 'percent' ? '%' : 'g'}
              </span>
              <span
                className={cn(
                  'text-[10px] w-14 shrink-0 tabular-nums',
                  isOverridden ? 'text-[#353CED] font-semibold' : 'text-gray-400',
                )}
                title={isOverridden ? 'Effective % after override' : 'BEA fallback'}
              >
                {effPct.toFixed(3)}%
              </span>
            </div>
          );
        })}
      </div>

      {overOneHundred && (
        <div className="flex items-start gap-1.5 rounded bg-amber-50 border border-amber-200 px-2 py-1 text-[10.5px] text-amber-800">
          <AlertTriangle className="h-3.5 w-3.5 mt-0.5 shrink-0" />
          <span>
            Declared shares sum to {(declaredSum * 100).toFixed(1)}% — total metal capped at 100% for stacking math.
          </span>
        </div>
      )}

      <div className="flex items-center justify-between rounded bg-gray-50 px-2 py-1.5 text-[11px]">
        <span className="text-gray-600">Total metal: <span className="font-semibold text-gray-900 tabular-nums">{(totalDeclared * 100).toFixed(2)}%</span></span>
        <span className="text-gray-600">
          Effective S232:{' '}
          <span className="font-semibold text-gray-900 tabular-nums">{formatRate(netAfter.rate_232)}</span>
          {Math.abs(netAfter.rate_232 - netBefore.rate_232) > 0.00001 && (
            <span className="text-gray-400 ml-1">(was {formatRate(netBefore.rate_232)})</span>
          )}
        </span>
      </div>
    </div>
  );
}
