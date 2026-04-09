import React, { useMemo, useState } from 'react';
import { Card, CardContent } from '@/components/ui/card';
import { Badge } from '@/components/ui/badge';
import { CountryAutocomplete } from './CountryAutocomplete';
import {
  AreaChart, Area, Line, XAxis, YAxis, CartesianGrid, Tooltip as ReTooltip,
  ResponsiveContainer, ReferenceLine, Legend,
} from 'recharts';
import type { DailyOverall, DailyByAuthority, DailyByCountrySummary, RevisionEntry, Country } from '@/types/tariff';
import { AUTHORITIES, MFN_COLOR } from '@/types/tariff';
import { formatRateShort, formatDate } from '@/utils/formatters';
import { BarChart3, TrendingUp, Calendar, X, Globe } from 'lucide-react';

/** Maps each AUTHORITIES entry to the corresponding field in DailyByAuthority */
const AUTHORITY_DAILY_KEY: Record<string, keyof DailyByAuthority> = {
  rate_232: 'mean_232',
  rate_301: 'mean_301',
  rate_ieepa_recip: 'mean_ieepa',
  rate_ieepa_fent: 'mean_fentanyl',
  rate_s122: 'mean_s122',
  rate_section_201: 'mean_section_201',
  rate_other: 'mean_other',
};

/** Stacked area layers — bottom-up render order */
const STACK_LAYERS = [
  { key: 'stack_base', label: 'MFN Base', color: MFN_COLOR, description: 'Most-Favored-Nation base duty rate from the Harmonized Tariff Schedule, before any additional tariffs.' },
  ...AUTHORITIES.map(a => ({
    key: `stack_${a.key.replace('rate_', '')}`,
    label: a.shortLabel,
    color: a.color,
    description: a.description,
  })),
];
import { cn } from '@/lib/utils';

interface OverallDashboardProps {
  dailyOverall: DailyOverall[];
  dailyByAuthority: DailyByAuthority[];
  dailyByCountry: DailyByCountrySummary[];
  revisions: RevisionEntry[];
  countries: Country[];
  insertAfterKpis?: React.ReactNode;
}

const COUNTRY_COLORS = [
  '#EF4444', '#3B82F6', '#22C55E', '#F59E0B', '#8B5CF6',
  '#EC4899', '#06B6D4', '#F97316', '#14B8A6', '#6366F1',
];

export function OverallDashboard({
  dailyOverall, dailyByAuthority, dailyByCountry, revisions, countries, insertAfterKpis,
}: OverallDashboardProps) {
  const [metric, setMetric] = useState<'all_pairs' | 'exposed'>('all_pairs');
  const [overlayCountries, setOverlayCountries] = useState<Country[]>([]);
  const [addingCountry, setAddingCountry] = useState<Country | null>(null);
  const [disabledSeries, setDisabledSeries] = useState<Set<string>>(new Set());

  const toggleSeries = (key: string) => {
    setDisabledSeries(prev => {
      const next = new Set(prev);
      next.has(key) ? next.delete(key) : next.add(key);
      return next;
    });
  };

  // Build country revision lookup (sorted arrays for interval-based date matching)
  const countryRevisions = useMemo(() => {
    const map = new Map<string, { date: string; row: DailyByCountrySummary }[]>();
    for (const row of dailyByCountry) {
      const key = String(row.country); // coerce to string — JSON may deliver number
      if (!map.has(key)) map.set(key, []);
      map.get(key)!.push({ date: row.date, row });
    }
    for (const entries of map.values()) {
      entries.sort((a, b) => a.date.localeCompare(b.date));
    }
    return map;
  }, [dailyByCountry]);

  const chartData = useMemo(() => {
    const byAuthorityMap = new Map(dailyByAuthority.map(d => [d.date, d]));
    // Sample every 3rd day
    return dailyOverall.filter((_, i) => i % 3 === 0).map(d => {
      const auth = byAuthorityMap.get(d.date);
      const total = metric === 'all_pairs' ? d.mean_total_all_pairs : d.mean_total_exposed;
      const additional = metric === 'all_pairs' ? d.mean_additional_all_pairs : d.mean_additional_exposed;
      const baseMean = total - additional;

      // Authority means in daily_by_authority are divided by n_pairs (tariffed pairs only).
      // In "all_pairs" mode the totals are divided by n_all_pairs, so we correct:
      const correction = (metric === 'all_pairs' && d.n_all_pairs > 0)
        ? d.n_pairs / d.n_all_pairs
        : 1;

      // Compute corrected authority values
      const authValues: Record<string, number> = {};
      let rawSum = 0;
      for (const a of AUTHORITIES) {
        const dailyKey = AUTHORITY_DAILY_KEY[a.key];
        const raw = ((auth?.[dailyKey] as number) ?? 0) * correction;
        const stackKey = `stack_${a.key.replace('rate_', '')}`;
        authValues[stackKey] = raw;
        rawSum += raw;
      }

      // Normalize so authority stack sums exactly to `additional` (fix floating-point drift)
      if (rawSum > 0 && additional > 0) {
        const normFactor = additional / rawSum;
        for (const k of Object.keys(authValues)) {
          authValues[k] *= normFactor;
        }
      }

      const row: Record<string, number | string> = {
        date: d.date,
        label: new Date(d.date + 'T00:00:00').toLocaleDateString('en-US', { month: 'short', year: 'numeric' }),
        labelShort: new Date(d.date + 'T00:00:00').toLocaleDateString('en-US', { month: 'short', day: 'numeric', year: 'numeric' }),
        us_mean: total,
        stack_base: Math.max(0, baseMean),
        ...authValues,
        revision: d.revision,
      };

      // Add country-level rates (binary search for latest revision at or before this date)
      for (const country of overlayCountries) {
        const entries = countryRevisions.get(country.code);
        if (entries) {
          let lo = 0, hi = entries.length - 1, best = -1;
          while (lo <= hi) {
            const mid = (lo + hi) >> 1;
            if (entries[mid].date <= d.date) { best = mid; lo = mid + 1; }
            else { hi = mid - 1; }
          }
          if (best >= 0) {
            const entry = entries[best].row;
            row[`country_${country.code}`] = metric === 'all_pairs'
              ? entry.mean_total_all_pairs
              : entry.mean_additional_all_pairs;
          }
        }
      }
      return row;
    });
  }, [dailyOverall, dailyByAuthority, metric, overlayCountries, countryRevisions]);

  const keyRevisions = useMemo(
    () => [...revisions]
      .filter(r => r.policyEvent && r.policyEvent.length > 5)
      .sort((a, b) => {
        const aDate = a.policyEffectiveDate ?? a.effectiveDate ?? '';
        const bDate = b.policyEffectiveDate ?? b.effectiveDate ?? '';
        return bDate.localeCompare(aDate) || b.revision.localeCompare(a.revision);
      }),
    [revisions]
  );

  const latestData = dailyOverall[dailyOverall.length - 1];

  if (dailyOverall.length === 0) return null;

  const neuInset = 'inset 2px 2px 5px rgba(0,0,0,0.07), inset -2px -2px 5px rgba(255,255,255,0.9)';

  // Build legend items — stacked layers + country overlays
  const legendItems: Array<{ key: string; label: string; color: string; description?: string }> = [
    ...STACK_LAYERS.map(l => ({ key: l.key, label: l.label, color: l.color, description: l.description })),
    ...overlayCountries.map((c, i) => ({
      key: `country_${c.code}`,
      label: c.name,
      color: COUNTRY_COLORS[i % COUNTRY_COLORS.length],
    })),
  ];

  return (
    <div className="space-y-5">
      {/* KPI row */}
      <div className="grid grid-cols-2 md:grid-cols-4 gap-4">
        {[
          { label: 'Avg Total Rate', value: formatRateShort(latestData?.mean_total_all_pairs ?? 0), icon: TrendingUp, sublabel: 'Latest revision' },
          { label: 'Avg Additional', value: formatRateShort(latestData?.mean_additional_all_pairs ?? 0), icon: BarChart3, sublabel: 'Above MFN base' },
          { label: 'Products Tracked', value: latestData?.n_products?.toLocaleString() ?? '—', icon: BarChart3, sublabel: 'HTS-10 codes' },
          { label: 'Countries', value: latestData?.n_countries?.toString() ?? '—', icon: Globe, sublabel: 'Trading partners' },
        ].map(({ label, value, icon: Icon, sublabel }) => (
          <Card key={label} className="hover:-translate-y-0">
            <CardContent className="p-4">
              <div className="flex items-center gap-2 mb-1">
                <Icon className="h-3.5 w-3.5 text-[#353CED]" />
                <span className="text-[10px] font-medium text-gray-400 uppercase tracking-wider">{label}</span>
              </div>
              <div className="text-xl font-bold text-gray-900">{value}</div>
              <div className="text-[10px] text-gray-400 mt-0.5">{sublabel}</div>
            </CardContent>
          </Card>
        ))}
      </div>

      {insertAfterKpis}

      {/* Main chart */}
      <Card>
        <CardContent className="p-5">
          <div className="flex items-center justify-between mb-2">
            <div>
              <h3 className="font-semibold text-sm text-gray-900">U.S. Mean Tariff Rate (2025–2026)</h3>
              <p className="text-[10px] text-gray-400 mt-0.5">Authority decomposition with optional per-country overlays</p>
            </div>
            <div className="text-right">
              <div className="inline-flex items-center h-8 rounded-lg p-0.5"
                style={{ boxShadow: neuInset, background: '#FAFAF8' }}>
                {(['all_pairs', 'exposed'] as const).map(m => (
                  <button key={m} type="button" onClick={() => setMetric(m)}
                    className={`px-3 py-1 rounded-md text-[10px] font-medium transition-all ${
                      metric === m ? 'bg-white text-[#353CED] shadow-sm' : 'text-gray-500 hover:text-gray-700'
                    }`}>
                    {m === 'all_pairs' ? 'All Products' : 'Tariffed Only'}
                  </button>
                ))}
              </div>
              <p className="text-[10px] text-gray-400 mt-1 max-w-xs ml-auto">
                {metric === 'all_pairs'
                  ? 'Averages across all ~18K HTS-country pairs, including zero-tariff products.'
                  : 'Averages only HTS-country pairs with at least one additional tariff applied.'}
              </p>
            </div>
          </div>

          {/* Country overlay controls */}
          <div className="flex items-center gap-2 mb-4 flex-wrap">
            <span className="text-[10px] text-gray-400">Country overlays:</span>
            {overlayCountries.map((c, i) => (
              <Badge key={c.code} variant="outline" className="text-[10px] pl-1.5 pr-1 py-0.5 gap-1 border-gray-200">
                <div className="w-2 h-2 rounded-full" style={{ backgroundColor: COUNTRY_COLORS[i % COUNTRY_COLORS.length] }} />
                {c.name}
                <button onClick={() => setOverlayCountries(prev => prev.filter(cc => cc.code !== c.code))}
                  className="text-gray-400 hover:text-red-500">
                  <X className="h-2.5 w-2.5" />
                </button>
              </Badge>
            ))}
            <div className="w-56">
              <CountryAutocomplete countries={countries} value={addingCountry} onChange={setAddingCountry}
                onAutoAdd={(c) => {
                  if (!overlayCountries.find(oc => oc.code === c.code)) {
                    setOverlayCountries(prev => [...prev, c]);
                  }
                  setAddingCountry(null);
                }}
                placeholder="Add country..." className="[&_input]:h-7 [&_input]:text-[10px]" />
            </div>
          </div>

          <div className="h-[400px] w-full">
            <ResponsiveContainer width="100%" height="100%">
              <AreaChart data={chartData}>
                <CartesianGrid strokeDasharray="3 3" strokeOpacity={0.3} />
                <XAxis
                  dataKey="label"
                  tick={{ fontSize: 10, fill: '#6b7280' }}
                  interval={Math.max(1, Math.floor(chartData.length / 10))}
                  angle={0}
                />
                <YAxis
                  tickFormatter={(v: number) => `${(v * 100).toFixed(0)}%`}
                  tick={{ fontSize: 10, fill: '#6b7280' }}
                  width={50}
                  label={{ value: 'Tariff Rate (%)', angle: -90, position: 'insideLeft', offset: 5, style: { fontSize: 11, fill: '#6b7280' } }}
                />
                <ReTooltip
                  content={({ active, payload }) => {
                    if (!active || !payload?.length) return null;
                    const d = payload[0]?.payload;
                    if (!d) return null;
                    return (
                      <div className="bg-white border border-gray-200 rounded-lg shadow-lg p-3 text-xs min-w-[260px]">
                        <div className="font-semibold text-gray-900 mb-0.5">{d.labelShort}</div>
                        <div className="text-[10px] text-gray-400 mb-2">{d.revision}</div>

                        {/* Total */}
                        <div className="flex justify-between mb-1.5 pb-1 border-b border-gray-100">
                          <span className="font-semibold text-gray-900">Total Mean Rate</span>
                          <span className="font-mono font-bold text-gray-900">{formatRateShort(d.us_mean)}</span>
                        </div>

                        {/* Stacked decomposition */}
                        <div className="space-y-0.5 mb-1.5">
                          {STACK_LAYERS.filter(l => (d[l.key] as number) > 0.00005).map(l => (
                            <div key={l.key} className="flex justify-between" title={l.description}>
                              <div className="flex items-center gap-1.5">
                                <div className="w-2.5 h-2.5 rounded-sm" style={{ backgroundColor: l.color }} />
                                <span className="text-gray-500">{l.label}</span>
                              </div>
                              <span className="font-mono text-gray-700">{formatRateShort(d[l.key] as number)}</span>
                            </div>
                          ))}
                        </div>

                        {/* Country overlays */}
                        {overlayCountries.length > 0 && (
                          <div className="pt-1.5 border-t border-gray-100 space-y-0.5">
                            {overlayCountries.map((c, i) => {
                              const val = d[`country_${c.code}`] as number | undefined;
                              return val != null ? (
                                <div key={c.code} className="flex justify-between">
                                  <div className="flex items-center gap-1.5">
                                    <div className="w-3 h-0.5 rounded" style={{ backgroundColor: COUNTRY_COLORS[i % COUNTRY_COLORS.length] }} />
                                    <span className="text-gray-600">{c.name}</span>
                                  </div>
                                  <span className="font-mono font-medium">{formatRateShort(val)}</span>
                                </div>
                              ) : null;
                            })}
                          </div>
                        )}
                      </div>
                    );
                  }}
                />

                {/* Stacked area decomposition — base + each authority */}
                {STACK_LAYERS.map(layer => {
                  if (disabledSeries.has(layer.key)) return null;
                  return (
                    <Area key={layer.key} type="stepAfter" dataKey={layer.key}
                      stackId="tariff" stroke={layer.color} strokeWidth={0.5}
                      fill={layer.color} fillOpacity={0.85} dot={false}
                      name={layer.label} />
                  );
                })}

                {/* Country overlay lines — drawn on top of the stack */}
                {overlayCountries.map((c, i) => {
                  const key = `country_${c.code}`;
                  if (disabledSeries.has(key)) return null;
                  return (
                    <Line key={c.code} type="stepAfter" dataKey={key}
                      stroke={COUNTRY_COLORS[i % COUNTRY_COLORS.length]}
                      strokeWidth={2} dot={false} name={c.name}
                      connectNulls={false} />
                  );
                })}
              </AreaChart>
            </ResponsiveContainer>
          </div>

          {/* Interactive legend */}
          <div className="flex flex-wrap gap-x-4 gap-y-1.5 mt-3 pt-3 border-t border-gray-100">
            {legendItems.map(item => {
              const isDisabled = disabledSeries.has(item.key);
              return (
                <button key={item.key} type="button" onClick={() => toggleSeries(item.key)}
                  title={item.description}
                  className={cn(
                    'flex items-center gap-1.5 text-[10px] transition-all rounded px-1 py-0.5 -mx-1',
                    isDisabled ? 'opacity-30 line-through' : 'hover:bg-gray-50'
                  )}>
                  <div className="w-2.5 h-2.5 rounded-sm" style={{ backgroundColor: item.color }} />
                  <span className="text-gray-600">{item.label}</span>
                </button>
              );
            })}
          </div>
        </CardContent>
      </Card>

      {/* Key policy events timeline */}
      <Card>
        <CardContent className="p-5">
          <div className="flex items-center gap-2 mb-4">
            <Calendar className="h-4 w-4 text-[#353CED]" />
            <h3 className="font-semibold text-sm text-gray-900">Policy Timeline</h3>
            <span className="text-xs text-gray-400 ml-auto">{keyRevisions.length} events</span>
          </div>
          <div className="space-y-2 max-h-[300px] overflow-y-auto scrollbar-hide">
            {keyRevisions.map(r => (
              <div key={r.revision} className="flex items-start gap-3 group">
                <div className="flex flex-col items-center mt-1">
                  <div className="w-2 h-2 rounded-full bg-[#353CED] group-hover:scale-125 transition-transform" />
                  <div className="w-px h-full bg-gray-200 mt-1" />
                </div>
                <div className="pb-3">
                  <div className="text-[10px] font-medium text-gray-400 uppercase tracking-wider">
                    {formatDate(r.policyEffectiveDate ?? r.effectiveDate)}
                  </div>
                  <div className="text-xs text-gray-700 mt-0.5">{r.policyEvent}</div>
                  <div className="text-[10px] text-gray-400 mt-0.5 font-mono">{r.revision}</div>
                </div>
              </div>
            ))}
          </div>
        </CardContent>
      </Card>
    </div>
  );
}
