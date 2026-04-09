import React, { useState, useMemo, useCallback, useEffect, useRef } from 'react';
import { Card, CardContent } from '@/components/ui/card';
import { Input } from '@/components/ui/input';
import { Badge } from '@/components/ui/badge';
import { CountryAutocomplete } from './CountryAutocomplete';
import { DatePickerNeu } from './DatePickerNeu';
import { TariffProgramBadge } from './TariffProgramBadge';
import {
  BarChart, Bar, XAxis, YAxis, CartesianGrid, Tooltip as ReTooltip,
  ResponsiveContainer, Legend, LineChart, Line, ReferenceLine,
} from 'recharts';
import type { Country, ProductRate, AuthorityKey } from '@/types/tariff';
import { AUTHORITIES, AUTHORITY_MAP, MFN_COLOR, PARTNER_COLORS } from '@/types/tariff';
import { formatRate, formatRateShort, formatHtsCode, formatDate, formatCurrency } from '@/utils/formatters';
import { findRateForDate, calculateLandedCost } from '@/utils/tariffCalculator';
import { fetchRatesArrow } from '@/hooks/useTariffData';
import {
  Globe, Hash, CalendarDays, X, BarChart3, LineChart as LineChartIcon,
  Table2, ArrowUpDown, Search, Loader2,
} from 'lucide-react';
import { cn } from '@/lib/utils';

interface MultiCountryComparisonProps {
  countries: Country[];
  sampleProducts: string[];
}

const COMPARISON_COLORS = [
  '#353CED', '#EF4444', '#22C55E', '#F59E0B', '#8B5CF6',
  '#EC4899', '#06B6D4', '#F97316', '#14B8A6', '#6366F1',
];

type ViewMode = 'table' | 'chart';

export function MultiCountryComparison({ countries, sampleProducts }: MultiCountryComparisonProps) {
  const [htsCode, setHtsCode] = useState('');
  const [selectedCountries, setSelectedCountries] = useState<Country[]>([]);
  const [queryDate, setQueryDate] = useState<Date>(new Date(2026, 1, 15));
  const [addingCountry, setAddingCountry] = useState<Country | null>(null);
  const [viewMode, setViewMode] = useState<ViewMode>('table');
  const [sortKey, setSortKey] = useState<'name' | 'total'>('total');
  const [sortDir, setSortDir] = useState<'asc' | 'desc'>('desc');
  const [customsValue, setCustomsValue] = useState(50000);
  const [fetchedRates, setFetchedRates] = useState<ProductRate[]>([]);
  const [isLoading, setIsLoading] = useState(false);
  const [fetchError, setFetchError] = useState<string | null>(null);
  const fetchRef = useRef(0);

  const countryMap = useMemo(() => new Map(countries.map(c => [c.code, c])), [countries]);

  // Derive quick-add buttons from partner groups — one representative per group
  const quickAddCountries = useMemo(() => {
    const byPartner = new Map<string, Country>();
    for (const c of countries) {
      const group = c.partner ?? 'other';
      if (!byPartner.has(group)) byPartner.set(group, c);
    }
    // Sort: named partner groups first (china, canada, mexico, eu, uk, japan), then others
    const order = ['china', 'canada', 'mexico', 'eu', 'uk', 'japan', 'ftrow'];
    return Array.from(byPartner.entries())
      .sort(([a], [b]) => {
        const ai = order.indexOf(a), bi = order.indexOf(b);
        return (ai === -1 ? 999 : ai) - (bi === -1 ? 999 : bi);
      })
      .map(([, c]) => c)
      .slice(0, 10);
  }, [countries]);

  const addCountry = useCallback((country: Country) => {
    setSelectedCountries(prev => (
      prev.some(existing => existing.code === country.code)
        ? prev
        : [...prev, country]
    ));
    setAddingCountry(null);
  }, []);

  const removeCountry = useCallback((code: string) => {
    setSelectedCountries(prev => prev.filter(c => c.code !== code));
  }, []);

  const cleanCode = htsCode.replace(/\./g, '');
  const dateStr = queryDate.toISOString().slice(0, 10);

  // Fetch rates from DuckDB via Arrow IPC when HTS code or countries change
  useEffect(() => {
    if (!cleanCode || cleanCode.length < 4 || selectedCountries.length === 0) {
      setFetchedRates([]);
      setFetchError(null);
      return;
    }

    const controller = new AbortController();
    const fetchId = ++fetchRef.current;
    setIsLoading(true);
    setFetchError(null);

    const countryCodes = selectedCountries.map(c => c.code);
    fetchRatesArrow(cleanCode, countryCodes, controller.signal)
      .then(rates => {
        if (fetchRef.current !== fetchId) return; // stale
        setFetchedRates(rates);
        setIsLoading(false);
      })
      .catch(err => {
        if (controller.signal.aborted) return; // cancelled by cleanup
        if (fetchRef.current !== fetchId) return;
        setFetchError(err instanceof Error ? err.message : 'Failed to fetch rates');
        setFetchedRates([]);
        setIsLoading(false);
      });

    return () => controller.abort();
  }, [cleanCode, selectedCountries]);

  // Build comparison data from fetched rates
  const comparisonData = useMemo(() => {
    if (!cleanCode || cleanCode.length < 4 || selectedCountries.length === 0) return [];

    return selectedCountries.map((country, idx) => {
      const matching = fetchedRates.filter(r => r.country === country.code);

      const rate = findRateForDate(matching, dateStr);
      const history = [...matching].sort((a, b) => a.effective_date.localeCompare(b.effective_date));
      const landed = rate ? calculateLandedCost(rate, customsValue) : null;

      return {
        country,
        rate,
        history,
        landed,
        color: COMPARISON_COLORS[idx % COMPARISON_COLORS.length],
        available: matching.length > 0,
      };
    });
  }, [cleanCode, selectedCountries, fetchedRates, dateStr, customsValue]);

  // Chart data for grouped bar chart
  const barChartData = useMemo(() => {
    if (comparisonData.length === 0) return [];

    const authorityKeys: AuthorityKey[] = AUTHORITIES.map(a => a.key);
    return comparisonData.filter(d => d.rate).map(d => {
      const r = d.rate!;
      const row: Record<string, number | string> = {
        country: d.country.name.length > 15 ? d.country.name.slice(0, 15) + '...' : d.country.name,
        fullName: d.country.name,
        base_rate: r.base_rate,
        statutory_base_rate: r.statutory_base_rate,
        total_rate: r.total_rate,
      };
      for (const key of authorityKeys) {
        row[key] = r[key];
      }
      return row;
    });
  }, [comparisonData]);

  // Line chart data for historical comparison
  const lineChartData = useMemo(() => {
    if (comparisonData.length === 0) return [];

    // Collect all unique dates across all countries
    const allDates = new Set<string>();
    for (const d of comparisonData) {
      for (const r of d.history) {
        allDates.add(r.effective_date);
      }
    }

    const sortedDates = Array.from(allDates).sort();
    return sortedDates.map(date => {
      const row: Record<string, number | string> = {
        date,
        label: formatDate(date),
      };
      for (const d of comparisonData) {
        const rate = d.history.find(r => r.valid_from <= date && r.valid_until >= date);
        row[d.country.code] = rate?.total_rate ?? 0;
      }
      return row;
    });
  }, [comparisonData]);

  const toggleSort = (key: 'name' | 'total') => {
    if (sortKey === key) setSortDir(d => d === 'asc' ? 'desc' : 'asc');
    else { setSortKey(key); setSortDir(key === 'total' ? 'desc' : 'asc'); }
  };

  const sortedComparison = useMemo(() => {
    return [...comparisonData].sort((a, b) => {
      if (sortKey === 'name') {
        const cmp = a.country.name.localeCompare(b.country.name);
        return sortDir === 'asc' ? cmp : -cmp;
      }
      const aRate = a.rate?.total_rate ?? 0;
      const bRate = b.rate?.total_rate ?? 0;
      return sortDir === 'asc' ? aRate - bRate : bRate - aRate;
    });
  }, [comparisonData, sortKey, sortDir]);

  const neuInset = 'inset 1px 1px 4px rgba(0,0,0,0.05), inset -1px -1px 4px rgba(255,255,255,0.85)';

  return (
    <div className="space-y-5">
      {/* Query controls */}
      <Card>
        <CardContent className="p-5 space-y-4">
          <div className="flex items-center gap-2">
            <div className="w-6 h-6 rounded-lg bg-[#353CED]/6 flex items-center justify-center">
              <Globe className="h-3.5 w-3.5 text-[#353CED]" />
            </div>
            <h3 className="font-semibold text-sm text-gray-900 tracking-[-0.01em]">Multi-Country Rate Comparison</h3>
          </div>

          <div className="grid grid-cols-1 md:grid-cols-3 gap-5">
            <div className="space-y-2">
              <label className="text-[11px] font-medium text-gray-500 flex items-center gap-1.5 uppercase tracking-wider">
                <Hash className="h-3 w-3" /> HTS-10 Code
              </label>
              <Input value={htsCode} onChange={(e) => setHtsCode(e.target.value.replace(/[^0-9.]/g, ''))}
                placeholder="e.g. 7208.51.0030" className="h-9 text-sm font-mono" />
              {sampleProducts.length > 0 && (
                <div className="flex flex-wrap gap-1 mt-1">
                  {sampleProducts.slice(0, 6).map(p => (
                    <button key={p} type="button" onClick={() => setHtsCode(p)}
                      className="text-[10px] font-mono px-1.5 py-0.5 rounded bg-gray-50 text-gray-500 hover:bg-[#353CED]/5 hover:text-[#353CED] transition-colors">
                      {formatHtsCode(p)}
                    </button>
                  ))}
                </div>
              )}
            </div>

            <div className="space-y-2">
              <label className="text-[11px] font-medium text-gray-500 flex items-center gap-1.5 uppercase tracking-wider">
                <CalendarDays className="h-3 w-3" /> Effective Date
              </label>
              <DatePickerNeu date={queryDate} onSelect={setQueryDate}
                minDate={new Date(2025, 0, 1)} maxDate={new Date(2026, 11, 31)} />
            </div>

            <div className="space-y-2">
              <label className="text-[11px] font-medium text-gray-500 uppercase tracking-wider">Customs Value (USD)</label>
              <Input type="number" value={customsValue} min={0}
                onChange={(e) => setCustomsValue(Number(e.target.value))}
                className="h-9 text-sm font-mono" />
            </div>
          </div>

          {/* Country selection */}
          <div className="space-y-2">
            <label className="text-xs font-medium text-gray-700">Countries to Compare</label>
            <div className="flex flex-wrap gap-2">
              {selectedCountries.map((c, i) => (
                <Badge key={c.code} variant="outline"
                  className="text-xs font-medium pl-2 pr-1 py-1 gap-1.5 border-gray-200">
                  <div className="w-2 h-2 rounded-full" style={{ backgroundColor: COMPARISON_COLORS[i % COMPARISON_COLORS.length] }} />
                  {c.name}
                  <button onClick={() => removeCountry(c.code)} className="text-gray-400 hover:text-red-500 hover:bg-red-50 rounded-full p-0.5 ml-1 transition-colors">
                    <X className="h-3 w-3" />
                  </button>
                </Badge>
              ))}
            </div>
            <CountryAutocomplete
              countries={countries}
              value={addingCountry}
              onChange={setAddingCountry}
              onAutoAdd={addCountry}
              placeholder="Search and select a country..."
            />
            <p className="text-[10px] text-gray-400">
              Selecting a country adds it immediately. Use the arrow keys and press Enter to confirm.
            </p>
            {/* Quick-add buttons — one representative per partner group, derived from data */}
            <div className="flex flex-wrap gap-1">
              {quickAddCountries
                .filter(c => !selectedCountries.find(sc => sc.code === c.code))
                .map(c => (
                  <button key={c.code} type="button"
                    onClick={() => addCountry(c)}
                    className="text-[10px] px-2 py-1 rounded-full bg-gray-50 text-gray-500 hover:bg-[#353CED]/10 hover:text-[#353CED] transition-colors border border-gray-100">
                    {c.name}{c.alpha2 ? ` (${c.alpha2})` : ''}
                  </button>
                ))}
            </div>
          </div>
        </CardContent>
      </Card>

      {/* Loading / error states */}
      {isLoading && (
        <div className="flex items-center justify-center py-8 gap-2 text-gray-400">
          <Loader2 className="h-4 w-4 animate-spin" />
          <span className="text-sm">Querying {selectedCountries.length} countries via Arrow IPC...</span>
        </div>
      )}

      {fetchError && (
        <div className="flex items-start gap-2 px-4 py-3 rounded-lg bg-red-50 border border-red-200 text-xs text-red-800">
          <span>{fetchError}</span>
        </div>
      )}

      {/* Results */}
      {!isLoading && comparisonData.length > 0 && cleanCode.length >= 4 && (
        <>
          {/* View toggle */}
          <div className="flex items-center justify-between">
            <h3 className="text-sm font-semibold text-gray-900">
              Comparison: {formatHtsCode(cleanCode)} — {formatDate(dateStr)}
            </h3>
            <div className="inline-flex items-center h-8 rounded-xl p-0.5"
              style={{ boxShadow: neuInset, background: '#FAFAF8' }}>
              {([['table', Table2, 'Table'], ['chart', BarChart3, 'Chart']] as [ViewMode, typeof Table2, string][]).map(([mode, Icon, label]) => (
                <button key={mode} type="button" onClick={() => setViewMode(mode)}
                  className={`flex items-center gap-1.5 px-3 py-1 rounded-lg text-xs font-medium transition-all duration-200 ease-spring ${
                    viewMode === mode ? 'bg-white text-[#353CED] shadow-glass' : 'text-gray-400 hover:text-gray-600'
                  }`}>
                  <Icon className="h-3 w-3" />{label}
                </button>
              ))}
            </div>
          </div>

          {/* Table view */}
          {viewMode === 'table' && (
            <Card>
              <CardContent className="p-5">
                <div className="rounded-xl border border-gray-200/80 overflow-hidden">
                  <div className="overflow-x-auto">
                    <table className="w-full text-xs">
                      <thead>
                        <tr className="bg-gray-50/80 border-b border-gray-200/80">
                          <th className="px-3 py-2 text-left">
                            <button onClick={() => toggleSort('name')}
                              className="flex items-center gap-1 text-[10px] font-medium text-gray-500 uppercase tracking-wider hover:text-gray-700">
                              Country <ArrowUpDown className="h-3 w-3" />
                            </button>
                          </th>
                          <th className="px-3 py-2 text-right text-[10px] font-medium text-gray-500 uppercase tracking-wider"
                            title="Most-Favored-Nation base duty rate from the Harmonized Tariff Schedule, before any additional tariffs.">MFN Base</th>
                          {AUTHORITIES.filter(a => comparisonData.some(d => d.rate && d.rate[a.key] > 0)).map(a => (
                            <th key={a.key} className="px-3 py-2 text-right text-[10px] font-medium text-gray-500 uppercase tracking-wider cursor-help"
                              title={a.description}>{a.shortLabel}</th>
                          ))}
                          <th className="px-3 py-2 text-right">
                            <button onClick={() => toggleSort('total')}
                              className="flex items-center gap-1 text-[10px] font-medium text-gray-500 uppercase tracking-wider hover:text-gray-700 ml-auto">
                              Total <ArrowUpDown className="h-3 w-3" />
                            </button>
                          </th>
                          <th className="px-3 py-2 text-right text-[10px] font-medium text-gray-500 uppercase tracking-wider">Duty (USD)</th>
                          <th className="px-3 py-2 text-right text-[10px] font-medium text-gray-500 uppercase tracking-wider">Landed Cost</th>
                        </tr>
                      </thead>
                      <tbody>
                        {sortedComparison.map((d, idx) => {
                          const activeAuths = AUTHORITIES.filter(a => comparisonData.some(dd => dd.rate && dd.rate[a.key] > 0));
                          return (
                            <tr key={d.country.code} className="border-b border-gray-50 hover:bg-gray-50/50 transition-colors">
                              <td className="px-3 py-2.5">
                                <div className="flex items-center gap-2">
                                  <div className="w-2.5 h-2.5 rounded-full flex-shrink-0" style={{ backgroundColor: d.color }} />
                                  <div>
                                    <span className="font-medium text-gray-900">{d.country.name}</span>
                                    {d.country.partner && (
                                      <span className="text-[10px] text-gray-400 ml-1.5">({d.country.partner})</span>
                                    )}
                                  </div>
                                </div>
                                {!d.available && <span className="text-[10px] text-amber-500 ml-5">No data</span>}
                              </td>
                              <td className="px-3 py-2.5 text-right">
                                {d.rate ? (
                                  <>
                                    <span className="font-mono text-gray-700">{formatRate(d.rate.base_rate)}</span>
                                    {d.rate.statutory_base_rate > 0 && Math.abs(d.rate.statutory_base_rate - d.rate.base_rate) > 0.00001 && (
                                      <div className="text-[9px] text-gray-400 mt-0.5">
                                        Stat: {formatRate(d.rate.statutory_base_rate)}
                                      </div>
                                    )}
                                  </>
                                ) : '—'}
                              </td>
                              {activeAuths.map(a => (
                                <td key={a.key} className="px-3 py-2.5 text-right font-mono">
                                  {d.rate && d.rate[a.key] > 0 ? (
                                    <span style={{ color: a.color }}>{formatRateShort(d.rate[a.key])}</span>
                                  ) : (
                                    <span className="text-gray-300">—</span>
                                  )}
                                </td>
                              ))}
                              <td className="px-3 py-2.5 text-right">
                                <span className={cn('font-mono font-semibold',
                                  d.rate && d.rate.total_rate > 0.30 ? 'text-red-700' :
                                  d.rate && d.rate.total_rate > 0.10 ? 'text-orange-700' : 'text-gray-900'
                                )}>
                                  {d.rate ? formatRateShort(d.rate.total_rate) : '—'}
                                </span>
                              </td>
                              <td className="px-3 py-2.5 text-right font-mono text-red-600">
                                {d.landed ? formatCurrency(d.landed.totalDuty) : '—'}
                              </td>
                              <td className="px-3 py-2.5 text-right font-mono font-semibold text-gray-900">
                                {d.landed ? formatCurrency(d.landed.landedCost) : '—'}
                              </td>
                            </tr>
                          );
                        })}
                      </tbody>
                    </table>
                  </div>
                </div>
              </CardContent>
            </Card>
          )}

          {/* Chart view */}
          {viewMode === 'chart' && (
            <div className="space-y-5">
              {/* Grouped bar chart — current rates */}
              <Card>
                <CardContent className="p-5">
                  <h4 className="text-xs font-semibold text-gray-900 mb-4">
                    Total Tariff Rate by Country — {formatDate(dateStr)}
                  </h4>
                  <div className="h-[300px]">
                    <ResponsiveContainer width="100%" height="100%">
                      <BarChart data={barChartData} layout="vertical">
                        <CartesianGrid horizontal={false} strokeOpacity={0.3} />
                        <XAxis type="number" tickFormatter={(v: number) => `${(v * 100).toFixed(0)}%`}
                          tick={{ fontSize: 10, fill: '#9ca3af' }}
                          label={{ value: 'Tariff Rate (%)', position: 'bottom', offset: 0, style: { fontSize: 10, fill: '#9ca3af' } }} />
                        <YAxis type="category" dataKey="country" width={120} tick={{ fontSize: 11, fill: '#374151' }} />
                        <ReTooltip
                          content={({ active, payload }) => {
                            if (!active || !payload?.length) return null;
                            const d = payload[0].payload;
                            return (
                              <div className="bg-white border border-gray-100/80 rounded-xl shadow-elevated p-3.5 text-xs min-w-[220px]">
                                <div className="font-semibold text-gray-900 mb-2">{d.fullName}</div>
                                <div className="space-y-1">
                                  <div className="flex justify-between">
                                    <span className="text-gray-500">MFN Base</span>
                                    <span className="font-mono">{formatRate(d.base_rate)}</span>
                                  </div>
                                  {AUTHORITIES.filter(a => d[a.key] > 0).map(a => (
                                    <div key={a.key} className="flex justify-between">
                                      <div className="flex items-center gap-1.5">
                                        <div className="w-2 h-2 rounded-full" style={{ backgroundColor: a.color }} />
                                        <span className="text-gray-500">{a.shortLabel}</span>
                                      </div>
                                      <span className="font-mono">{formatRateShort(d[a.key] as number)}</span>
                                    </div>
                                  ))}
                                  <div className="flex justify-between pt-1 border-t border-gray-100 font-semibold">
                                    <span>Total</span>
                                    <span className="text-[#353CED]">{formatRateShort(d.total_rate)}</span>
                                  </div>
                                  <div className="flex justify-between text-gray-400">
                                    <span>Duty on ${customsValue.toLocaleString()}</span>
                                    <span className="text-red-600">{formatCurrency(customsValue * d.total_rate)}</span>
                                  </div>
                                </div>
                              </div>
                            );
                          }}
                        />
                        <Bar dataKey="base_rate" stackId="stack" fill={MFN_COLOR} name="MFN Base" />
                        {AUTHORITIES.filter(a => barChartData.some(d => (d[a.key] as number) > 0)).map(a => (
                          <Bar key={a.key} dataKey={a.key} stackId="stack" fill={a.color} name={a.shortLabel} />
                        ))}
                      </BarChart>
                    </ResponsiveContainer>
                  </div>
                  <div className="flex flex-wrap gap-3 mt-3 pt-3 border-t border-gray-100">
                    <div className="flex items-center gap-1.5 cursor-help"
                      title="Most-Favored-Nation base duty rate from the Harmonized Tariff Schedule, before any additional tariffs.">
                      <div className="w-2.5 h-2.5 rounded-sm" style={{ backgroundColor: MFN_COLOR }} />
                      <span className="text-[10px] text-gray-500">MFN Base</span>
                    </div>
                    {AUTHORITIES.filter(a => barChartData.some(d => (d[a.key] as number) > 0)).map(a => (
                      <div key={a.key} className="flex items-center gap-1.5 cursor-help" title={a.description}>
                        <div className="w-2.5 h-2.5 rounded-sm" style={{ backgroundColor: a.color }} />
                        <span className="text-[10px] text-gray-500">{a.shortLabel}</span>
                      </div>
                    ))}
                  </div>
                </CardContent>
              </Card>

              {/* Historical line chart */}
              {lineChartData.length > 0 && (
                <Card>
                  <CardContent className="p-5">
                    <h4 className="text-xs font-semibold text-gray-900 mb-4">
                      Rate History Comparison — Total Rate by Country
                    </h4>
                    <div className="h-[350px]">
                      <ResponsiveContainer width="100%" height="100%">
                        <LineChart data={lineChartData}>
                          <CartesianGrid strokeDasharray="3 3" strokeOpacity={0.3} />
                          <XAxis dataKey="label" tick={{ fontSize: 10, fill: '#9ca3af' }} interval={Math.floor(lineChartData.length / 8)} />
                          <YAxis tickFormatter={(v: number) => `${(v * 100).toFixed(0)}%`}
                            tick={{ fontSize: 10, fill: '#9ca3af' }} width={45}
                            label={{ value: 'Tariff Rate (%)', angle: -90, position: 'insideLeft', style: { fontSize: 10, fill: '#9ca3af' } }} />
                          <ReTooltip
                            content={({ active, payload, label }) => {
                              if (!active || !payload?.length) return null;
                              return (
                                <div className="bg-white border border-gray-200 rounded-lg shadow-lg p-3 text-xs min-w-[200px]">
                                  <div className="font-semibold text-gray-900 mb-2">{label}</div>
                                  {payload.sort((a, b) => (b.value as number) - (a.value as number)).map(p => {
                                    const country = countryMap.get(p.dataKey as string);
                                    return (
                                      <div key={p.dataKey} className="flex justify-between mb-0.5">
                                        <div className="flex items-center gap-1.5">
                                          <div className="w-2 h-2 rounded-full" style={{ backgroundColor: p.color as string }} />
                                          <span className="text-gray-600">{country?.name ?? p.dataKey}</span>
                                        </div>
                                        <span className="font-mono font-medium">{formatRateShort(p.value as number)}</span>
                                      </div>
                                    );
                                  })}
                                </div>
                              );
                            }}
                          />
                          {comparisonData.map(d => (
                            <Line key={d.country.code} type="stepAfter" dataKey={d.country.code}
                              stroke={d.color} strokeWidth={2} dot={false} name={d.country.name} />
                          ))}
                        </LineChart>
                      </ResponsiveContainer>
                    </div>
                    <div className="flex flex-wrap gap-3 mt-3 pt-3 border-t border-gray-100">
                      {comparisonData.map(d => (
                        <div key={d.country.code} className="flex items-center gap-1.5">
                          <div className="w-3 h-0.5 rounded" style={{ backgroundColor: d.color }} />
                          <span className="text-[10px] text-gray-500">{d.country.name}</span>
                        </div>
                      ))}
                    </div>
                  </CardContent>
                </Card>
              )}
            </div>
          )}
        </>
      )}
    </div>
  );
}
