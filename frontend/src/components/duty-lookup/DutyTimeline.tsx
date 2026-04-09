import React, { useMemo, useState, useCallback } from 'react';
import { Card, CardContent } from '@/components/ui/card';
import { Badge } from '@/components/ui/badge';
import { TariffProgramBadge } from './TariffProgramBadge';
import {
  BarChart, Bar, XAxis, YAxis, CartesianGrid, Tooltip as ReTooltip,
  ResponsiveContainer, ReferenceLine, Cell,
} from 'recharts';
import type { ProductRate } from '@/types/tariff';
import { AUTHORITIES, MFN_COLOR, STACK_COLORS } from '@/types/tariff';
import { formatRateShort, formatDate, formatHtsCode, formatRate } from '@/utils/formatters';
import { computeRateVolatility } from '@/utils/tariffCalculator';
import { TrendingUp, X, Calendar, Layers, Shield, FileText } from 'lucide-react';
import { cn } from '@/lib/utils';

interface DutyTimelineProps {
  rates: ProductRate[];
  onSelectEntry?: (index: number | null) => void;
  selectedIndex?: number | null;
  countryName?: string;
}

function computeYCeiling(maxRate: number): number {
  const pct = maxRate * 100;
  if (pct <= 25) return Math.ceil(pct / 5) * 5 / 100;
  if (pct <= 50) return Math.ceil(pct / 10) * 10 / 100;
  if (pct <= 100) return Math.ceil(pct / 25) * 25 / 100;
  if (pct <= 200) return Math.ceil(pct / 50) * 50 / 100;
  return Math.ceil(pct / 100) * 100 / 100;
}

// Custom bar shape with rounded top corners on topmost segment
function RoundedTopBar(props: Record<string, unknown>) {
  const { x, y, width, height, fill, fillOpacity, index, dataKey, payload } = props as {
    x: number; y: number; width: number; height: number;
    fill: string; fillOpacity: number;
    index: number; dataKey: string;
    payload: Record<string, number>;
  };

  if (!height || height <= 0) return null;

  const r = Math.min(4, width / 2, height);
  const ALL_KEYS = ['base_rate', ...AUTHORITIES.map(a => a.key)];
  const currentKeyIdx = ALL_KEYS.indexOf(dataKey);
  const isTopmost = ALL_KEYS.slice(currentKeyIdx + 1).every(k => (payload?.[k] ?? 0) <= 0);

  if (!isTopmost || r <= 0) {
    return <rect x={x} y={y} width={width} height={height} fill={fill} fillOpacity={fillOpacity} />;
  }

  const path = `M${x},${y + height}
    V${y + r}
    Q${x},${y} ${x + r},${y}
    H${x + width - r}
    Q${x + width},${y} ${x + width},${y + r}
    V${y + height}Z`;

  return <path d={path} fill={fill} fillOpacity={fillOpacity} />;
}

export function DutyTimeline({ rates, onSelectEntry, selectedIndex, countryName }: DutyTimelineProps) {
  const [internalSelected, setInternalSelected] = useState<number | null>(null);
  const activeIndex = selectedIndex ?? internalSelected;
  const isLocked = activeIndex != null;

  const chartData = useMemo(() => {
    return rates.map((r, i) => ({
      index: i,
      label: formatDate(r.effective_date),
      revision: r.revision,
      base_rate: r.base_rate,
      rate_232: r.rate_232,
      rate_301: r.rate_301,
      rate_ieepa_recip: r.rate_ieepa_recip,
      rate_ieepa_fent: r.rate_ieepa_fent,
      rate_s122: r.rate_s122,
      rate_section_201: r.rate_section_201,
      rate_other: r.rate_other,
      total_rate: r.total_rate,
    }));
  }, [rates]);

  const { maxRate, minRate, volatility } = useMemo(() => {
    const totalRates = rates.map(r => r.total_rate);
    return {
      maxRate: Math.max(...totalRates, 0.01),
      minRate: Math.min(...totalRates, 0),
      volatility: computeRateVolatility(rates),
    };
  }, [rates]);

  const yCeiling = computeYCeiling(maxRate);

  const activeKeys = useMemo(() => {
    const keys = ['base_rate', ...AUTHORITIES.map(a => a.key)] as const;
    return keys.filter(k => rates.some(r => (r as unknown as Record<string, number>)[k] > 0));
  }, [rates]);

  const todayStr = new Date().toISOString().slice(0, 10);
  const todayIdx = useMemo(() => {
    for (let i = rates.length - 1; i >= 0; i--) {
      if (rates[i].effective_date <= todayStr) return i;
    }
    return -1;
  }, [rates, todayStr]);

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const handleBarClick = useCallback((e: any) => {
    const idx = e?.activeTooltipIndex as number | undefined;
    if (idx != null) {
      const newIdx = idx === activeIndex ? null : idx;
      setInternalSelected(newIdx);
      onSelectEntry?.(newIdx);
    }
  }, [activeIndex, onSelectEntry]);

  const closeDetail = useCallback(() => {
    setInternalSelected(null);
    onSelectEntry?.(null);
  }, [onSelectEntry]);

  const selectedEntry = activeIndex != null ? rates[activeIndex] : null;

  if (rates.length === 0) return null;

  return (
    <Card>
      <CardContent className="p-5">
        {/* Header */}
        <div className="flex items-center justify-between mb-1">
          <div className="flex items-center gap-2">
            <TrendingUp className="h-4 w-4 text-[#353CED]" />
            <h3 className="font-semibold text-sm text-gray-900">Rate History</h3>
          </div>
          <div className="flex items-center gap-3 text-xs">
            <span className="text-gray-400">
              Range: {formatRateShort(minRate)} → {formatRateShort(maxRate)}
            </span>
            <span className={cn(
              'font-medium',
              volatility === 'HIGH' ? 'text-red-600' : volatility === 'MODERATE' ? 'text-amber-600' : 'text-emerald-600'
            )}>
              {volatility === 'HIGH' ? 'High volatility' : volatility === 'MODERATE' ? 'Moderate volatility' : 'Stable'}
            </span>
          </div>
        </div>
        {countryName && (
          <div className="text-xs text-gray-400 mb-4">{countryName} &middot; {rates.length} revisions</div>
        )}

        {/* Chart + Detail panel flex layout */}
        <div className="flex gap-4 items-start">
          {/* Chart */}
          <div className="flex-1 min-w-0">
            <div className="h-[360px] w-full">
              <ResponsiveContainer width="100%" height="100%">
                <BarChart data={chartData} onClick={handleBarClick}>
                  <CartesianGrid horizontal={true} vertical={false} strokeOpacity={0.5} stroke="#f0f0f0" />
                  <XAxis dataKey="label" tick={{ fontSize: 10, fill: '#9ca3af' }} interval="preserveStartEnd" />
                  <YAxis
                    domain={[0, yCeiling]}
                    tickFormatter={(v: number) => `${(v * 100).toFixed(0)}%`}
                    tick={{ fontSize: 10, fill: '#9ca3af' }}
                    width={45}
                  />
                  {!isLocked && (
                    <ReTooltip
                      content={({ active, payload }) => {
                        if (!active || !payload?.length) return null;
                        const d = payload[0].payload;
                        return (
                          <div className="bg-white border border-gray-200 rounded-lg shadow-lg p-3 text-xs">
                            <div className="font-semibold text-gray-900 mb-1">{d.revision}</div>
                            <div className="text-gray-500 mb-2">{d.label}</div>
                            <div className="font-bold text-[#353CED]">Total: {formatRateShort(d.total_rate)}</div>
                          </div>
                        );
                      }}
                      cursor={{ fill: '#353CED', fillOpacity: 0.04, radius: 4 }}
                    />
                  )}
                  {todayIdx >= 0 && (
                    <ReferenceLine x={chartData[todayIdx]?.label} stroke="#353CED" strokeDasharray="4 4" strokeOpacity={0.4}
                      label={{ value: 'Today', fill: '#353CED', fontSize: 10, position: 'top' }} />
                  )}
                  {activeKeys.map(key => (
                    <Bar key={key} dataKey={key} stackId="stack"
                      fill={STACK_COLORS[key] ?? '#ccc'}
                      shape={<RoundedTopBar />}
                      className="cursor-pointer">
                      {chartData.map((_, i) => (
                        <Cell key={i} fillOpacity={isLocked && activeIndex !== i ? 0.35 : 1} />
                      ))}
                    </Bar>
                  ))}
                </BarChart>
              </ResponsiveContainer>
            </div>

            {/* Legend */}
            <div className="flex flex-wrap gap-3 mt-3 pt-3 border-t border-gray-100">
              {activeKeys.map(key => {
                const label = key === 'base_rate' ? 'MFN Base' : AUTHORITIES.find(a => a.key === key)?.shortLabel ?? key;
                return (
                  <div key={key} className="flex items-center gap-1.5">
                    <div className="w-2.5 h-2.5 rounded-sm" style={{ backgroundColor: STACK_COLORS[key] }} />
                    <span className="text-[10px] text-gray-500">{label}</span>
                  </div>
                );
              })}
            </div>

            {/* Footer */}
            <div className="flex items-center gap-4 mt-2 text-[10px] text-gray-400">
              <div className="flex items-center gap-1">
                <Calendar className="h-3 w-3" />
                {rates.length} rate periods tracked
              </div>
              <span>Click a bar to view details</span>
            </div>
          </div>

          {/* Detail panel (slides in on selection) */}
          {selectedEntry && (
            <div className="w-[320px] xl:w-[380px] flex-shrink-0 rounded-lg border border-gray-200 bg-white shadow-sm overflow-hidden animate-fade-in">
              <div className="px-4 py-3 bg-gray-50 border-b border-gray-100 flex items-center justify-between">
                <div>
                  <div className="text-xs font-semibold text-gray-900">{formatDate(selectedEntry.effective_date)}</div>
                  <div className="text-[10px] text-gray-400">{selectedEntry.revision}</div>
                </div>
                <div className="flex items-center gap-2">
                  <span className="text-lg font-bold text-[#353CED]">{formatRateShort(selectedEntry.total_rate)}</span>
                  <button onClick={closeDetail} className="text-gray-400 hover:text-gray-600 transition-colors">
                    <X className="h-4 w-4" />
                  </button>
                </div>
              </div>

              <div className="p-4 space-y-3 max-h-[400px] overflow-y-auto scrollbar-hide">
                {/* Active duty breakdown */}
                <div className="text-[10px] font-medium text-gray-400 uppercase tracking-wider flex items-center gap-1">
                  <Layers className="h-3 w-3" /> Active Duty Breakdown
                </div>

                {/* MFN */}
                {selectedEntry.base_rate > 0 && (
                  <div className="flex items-center justify-between text-xs">
                    <div className="flex items-center gap-1.5">
                      <div className="w-2.5 h-2.5 rounded-sm" style={{ backgroundColor: MFN_COLOR }} />
                      <span className="text-gray-700">MFN Base</span>
                    </div>
                    <span className="font-mono font-medium">{formatRate(selectedEntry.base_rate)}</span>
                  </div>
                )}

                {/* Authority rates */}
                {AUTHORITIES.filter(a => selectedEntry[a.key] > 0).map(a => (
                  <div key={a.key} className="flex items-center justify-between text-xs">
                    <div className="flex items-center gap-1.5">
                      <div className="w-2.5 h-2.5 rounded-sm" style={{ backgroundColor: a.color }} />
                      <span className="text-gray-700">{a.label}</span>
                    </div>
                    <span className="font-mono font-medium">{formatRate(selectedEntry[a.key])}</span>
                  </div>
                ))}

                {/* Ch.99 Trade Remedies table */}
                {AUTHORITIES.filter(a => selectedEntry[a.key] > 0 && a.ch99Prefix).length > 0 && (
                  <>
                    <div className="text-[10px] font-medium text-gray-400 uppercase tracking-wider flex items-center gap-1 mt-3">
                      <FileText className="h-3 w-3" /> Chapter 99 — Trade Remedies
                    </div>
                    <div className="rounded border border-gray-100 overflow-hidden">
                      <table className="w-full text-[10px]">
                        <thead>
                          <tr className="bg-gray-50">
                            <th className="px-2 py-1.5 text-left text-gray-500 font-medium">Program</th>
                            <th className="px-2 py-1.5 text-left text-gray-500 font-medium">Ch. 99 Code</th>
                            <th className="px-2 py-1.5 text-right text-gray-500 font-medium">Rate</th>
                          </tr>
                        </thead>
                        <tbody>
                          {AUTHORITIES.filter(a => selectedEntry[a.key] > 0 && a.ch99Prefix).map(a => (
                            <tr key={a.key} className="border-t border-gray-50">
                              <td className="px-2 py-1.5">
                                <TariffProgramBadge label={a.shortLabel} className="text-[9px] px-1.5 py-0" />
                              </td>
                              <td className="px-2 py-1.5 font-mono text-[#353CED]">{a.ch99Prefix}</td>
                              <td className="px-2 py-1.5 text-right font-mono font-medium">{formatRateShort(selectedEntry[a.key])}</td>
                            </tr>
                          ))}
                        </tbody>
                      </table>
                    </div>
                  </>
                )}

                {/* Active programs */}
                <div className="flex flex-wrap gap-1 pt-2">
                  {AUTHORITIES.filter(a => selectedEntry[a.key] > 0).map(a => (
                    <TariffProgramBadge key={a.key} label={a.label} rate={selectedEntry[a.key]} />
                  ))}
                  {selectedEntry.usmca_eligible && (
                    <Badge variant="outline" className="text-[10px] bg-emerald-50 text-emerald-700 border-emerald-200">USMCA</Badge>
                  )}
                </div>

                {/* Metadata */}
                {selectedEntry.metal_share < 1 && selectedEntry.metal_share > 0 && (
                  <div className="text-[10px] text-gray-400 flex items-center gap-1">
                    <Shield className="h-3 w-3" />
                    Metal share: {(selectedEntry.metal_share * 100).toFixed(0)}% — IEEPA/S122 scaled by non-metal portion
                  </div>
                )}
              </div>
            </div>
          )}
        </div>
      </CardContent>
    </Card>
  );
}
