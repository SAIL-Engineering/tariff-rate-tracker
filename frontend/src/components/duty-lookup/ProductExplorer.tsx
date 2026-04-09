import React, { useState, useMemo, useEffect, useRef, useCallback, useId } from 'react';
import { Card, CardContent } from '@/components/ui/card';
import { Input } from '@/components/ui/input';
import { Badge } from '@/components/ui/badge';
import { CountryAutocomplete } from './CountryAutocomplete';
import {
  LineChart, Line, XAxis, YAxis, CartesianGrid, Tooltip as ReTooltip,
  ResponsiveContainer,
} from 'recharts';
import type { Country, ProductRate } from '@/types/tariff';
import { AUTHORITIES, MFN_COLOR } from '@/types/tariff';
import { formatRate, formatRateShort, formatDate, formatHtsCode } from '@/utils/formatters';
import { fetchRatesArrow } from '@/hooks/useTariffData';
import {
  Search, Hash, X, Loader2, Package, Globe, ShieldCheck,
} from 'lucide-react';
import { cn } from '@/lib/utils';

interface ProductExplorerProps {
  countries: Country[];
}

const COMPARISON_COLORS = [
  '#353CED', '#EF4444', '#22C55E', '#F59E0B', '#8B5CF6',
  '#EC4899', '#06B6D4', '#F97316', '#14B8A6', '#6366F1',
];

const QUICK_COUNTRIES = [
  { code: '5700', name: 'China' },
  { code: '1220', name: 'Canada' },
  { code: '2010', name: 'Mexico' },
  { code: '4280', name: 'Germany' },
  { code: '5880', name: 'Japan' },
  { code: '4120', name: 'UK' },
];

export function ProductExplorer({ countries }: ProductExplorerProps) {
  const [htsQuery, setHtsQuery] = useState('');
  const [htsResults, setHtsResults] = useState<string[]>([]);
  const [selectedHts, setSelectedHts] = useState<string | null>(null);
  const [showHtsDropdown, setShowHtsDropdown] = useState(false);
  const [highlightedHtsIndex, setHighlightedHtsIndex] = useState(-1);
  const [selectedCountries, setSelectedCountries] = useState<Country[]>([]);
  const [addingCountry, setAddingCountry] = useState<Country | null>(null);
  const [fetchedRates, setFetchedRates] = useState<ProductRate[]>([]);
  const [isLoading, setIsLoading] = useState(false);
  const [fetchError, setFetchError] = useState<string | null>(null);
  const [htsSearchLoading, setHtsSearchLoading] = useState(false);

  const fetchRef = useRef(0);
  const searchTimerRef = useRef<ReturnType<typeof setTimeout>>();
  const htsDropdownRef = useRef<HTMLDivElement>(null);
  const htsOptionRefs = useRef<Array<HTMLButtonElement | null>>([]);
  const htsListboxId = useId();
  const countryMap = useMemo(() => new Map(countries.map(c => [c.code, c])), [countries]);

  // Close HTS dropdown on outside click
  useEffect(() => {
    function handleClick(e: MouseEvent) {
      if (htsDropdownRef.current && !htsDropdownRef.current.contains(e.target as Node)) {
        setShowHtsDropdown(false);
        setHighlightedHtsIndex(-1);
      }
    }
    document.addEventListener('mousedown', handleClick);
    return () => document.removeEventListener('mousedown', handleClick);
  }, []);

  // Debounced HTS search
  useEffect(() => {
    if (searchTimerRef.current) clearTimeout(searchTimerRef.current);
    const query = htsQuery.replace(/\./g, '');
    if (query.length < 2) {
      setHtsResults([]);
      setHighlightedHtsIndex(-1);
      setHtsSearchLoading(false);
      return;
    }
    setHtsSearchLoading(true);
    searchTimerRef.current = setTimeout(async () => {
      try {
        const res = await fetch(`/api/products?q=${encodeURIComponent(query)}`);
        if (res.ok) {
          const json = await res.json();
          setHtsResults(json.data as string[]);
        }
      } catch {
        // silently fail — user can retry
      } finally {
        setHtsSearchLoading(false);
      }
    }, 300);
    return () => { if (searchTimerRef.current) clearTimeout(searchTimerRef.current); };
  }, [htsQuery]);

  const addCountry = useCallback((country: Country) => {
    setSelectedCountries(prev => (
      prev.some(existing => existing.code === country.code)
        ? prev
        : [...prev, country]
    ));
    setAddingCountry(null);
  }, []);

  const selectHts = useCallback((code: string) => {
    setSelectedHts(code);
    setHtsQuery('');
    setShowHtsDropdown(false);
    setHighlightedHtsIndex(-1);
  }, []);

  const removeCountry = useCallback((code: string) => {
    setSelectedCountries(prev => prev.filter(c => c.code !== code));
  }, []);

  useEffect(() => {
    if (!showHtsDropdown || selectedHts) {
      setHighlightedHtsIndex(-1);
      return;
    }
    if (htsResults.length === 0) {
      setHighlightedHtsIndex(-1);
      return;
    }
    setHighlightedHtsIndex(prev => (prev >= 0 && prev < htsResults.length ? prev : 0));
  }, [htsResults, selectedHts, showHtsDropdown]);

  useEffect(() => {
    if (!showHtsDropdown || highlightedHtsIndex < 0) return;
    htsOptionRefs.current[highlightedHtsIndex]?.scrollIntoView({ block: 'nearest' });
  }, [highlightedHtsIndex, showHtsDropdown]);

  // Fetch product-level rates when HTS + countries selected
  useEffect(() => {
    const cleanCode = selectedHts?.replace(/\./g, '') ?? '';
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
        if (fetchRef.current !== fetchId) return;
        setFetchedRates(rates);
        setIsLoading(false);
      })
      .catch(err => {
        if (controller.signal.aborted) return;
        if (fetchRef.current !== fetchId) return;
        setFetchError(err instanceof Error ? err.message : 'Failed to fetch rates');
        setFetchedRates([]);
        setIsLoading(false);
      });

    return () => controller.abort();
  }, [selectedHts, selectedCountries]);

  // Build per-country data
  const countryData = useMemo(() => {
    return selectedCountries.map((country, idx) => {
      const rates = fetchedRates
        .filter(r => r.country === country.code)
        .sort((a, b) => a.effective_date.localeCompare(b.effective_date));
      const latest = rates.length > 0 ? rates[rates.length - 1] : null;
      return {
        country,
        rates,
        latest,
        color: COMPARISON_COLORS[idx % COMPARISON_COLORS.length],
      };
    });
  }, [selectedCountries, fetchedRates]);

  // Build line chart data
  const lineChartData = useMemo(() => {
    if (countryData.length === 0) return [];

    const allDates = new Set<string>();
    for (const d of countryData) {
      for (const r of d.rates) {
        allDates.add(r.effective_date);
      }
    }

    const sortedDates = Array.from(allDates).sort();
    return sortedDates.map(date => {
      const row: Record<string, number | string> = {
        date,
        label: formatDate(date),
      };
      for (const d of countryData) {
        const rate = d.rates.find(r => r.valid_from <= date && r.valid_until >= date);
        if (rate) {
          row[d.country.code] = rate.total_rate;
          // Store full duty stack for tooltip
          for (const a of AUTHORITIES) {
            row[`${d.country.code}_${a.key}`] = rate[a.key];
          }
          row[`${d.country.code}_base`] = rate.base_rate;
          row[`${d.country.code}_statutory_base`] = rate.statutory_base_rate;
          row[`${d.country.code}_additional`] = rate.total_additional;
          row[`${d.country.code}_usmca`] = rate.usmca_eligible ? 1 : 0;
          row[`${d.country.code}_metal_share`] = rate.metal_share;
        }
      }
      return row;
    });
  }, [countryData]);

  const hasData = selectedHts && selectedCountries.length > 0 && countryData.some(d => d.rates.length > 0);
  const populatedCountryCount = countryData.filter(d => d.rates.length > 0).length;
  const moveHighlightedHts = (direction: 1 | -1) => {
    if (htsResults.length === 0 || selectedHts) return;
    setShowHtsDropdown(true);
    setHighlightedHtsIndex(prev => {
      if (prev < 0) return direction === 1 ? 0 : htsResults.length - 1;
      return (prev + direction + htsResults.length) % htsResults.length;
    });
  };

  return (
    <Card className="relative overflow-hidden border-slate-200/80 bg-[linear-gradient(180deg,rgba(255,255,255,0.98)_0%,rgba(247,249,255,0.98)_100%)] shadow-[0_24px_60px_rgba(15,23,42,0.06)] hover:shadow-[0_28px_72px_rgba(15,23,42,0.08)]">
      <div className="pointer-events-none absolute inset-x-0 top-0 h-40 bg-[radial-gradient(circle_at_top_right,rgba(53,60,237,0.18),transparent_45%)]" />
      <CardContent className="relative space-y-6 p-6 md:p-7">
        <div className="flex flex-col gap-5 xl:flex-row xl:items-start xl:justify-between">
          <div className="space-y-3">
            <div className="inline-flex items-center gap-2 rounded-full border border-[#353CED]/15 bg-[#353CED]/10 px-3 py-1 text-[11px] font-semibold tracking-wide text-[#353CED]">
              <Package className="h-3.5 w-3.5" />
              Product Explorer
            </div>
            <div className="space-y-2">
              <h3 className="text-lg font-semibold tracking-tight text-slate-950">
                Compare product-level duty stacks across countries
              </h3>
              <p className="max-w-2xl text-sm leading-6 text-slate-600">
                Search an HTS code, add countries immediately from the dropdown, and review both the latest stack and revision-by-revision rate history in one workspace.
              </p>
            </div>
          </div>

          <div className="grid grid-cols-2 gap-3 sm:min-w-[320px]">
            <div className="rounded-2xl border border-slate-200/80 bg-white/85 px-4 py-3 shadow-sm">
              <div className="text-[10px] font-semibold uppercase tracking-[0.18em] text-slate-400">Selected HTS</div>
              <div className="mt-2 text-sm font-semibold font-mono text-slate-900">
                {selectedHts ? formatHtsCode(selectedHts) : 'Awaiting selection'}
              </div>
            </div>
            <div className="rounded-2xl border border-slate-200/80 bg-white/85 px-4 py-3 shadow-sm">
              <div className="text-[10px] font-semibold uppercase tracking-[0.18em] text-slate-400">Active Countries</div>
              <div className="mt-2 text-sm font-semibold text-slate-900">{selectedCountries.length}</div>
            </div>
            <div className="rounded-2xl border border-slate-200/80 bg-white/85 px-4 py-3 shadow-sm">
              <div className="text-[10px] font-semibold uppercase tracking-[0.18em] text-slate-400">Data Coverage</div>
              <div className="mt-2 text-sm font-semibold text-slate-900">
                {selectedCountries.length > 0 ? `${populatedCountryCount}/${selectedCountries.length} loaded` : 'No comparisons yet'}
              </div>
            </div>
            <div className="rounded-2xl border border-slate-200/80 bg-white/85 px-4 py-3 shadow-sm">
              <div className="text-[10px] font-semibold uppercase tracking-[0.18em] text-slate-400">Selection Mode</div>
              <div className="mt-2 text-sm font-semibold text-slate-900">Auto-add on select</div>
            </div>
          </div>
        </div>

        <div className="rounded-[24px] border border-white/80 bg-white/85 p-4 shadow-[0_18px_40px_rgba(15,23,42,0.04)] backdrop-blur-sm md:p-5">
          <div className="grid grid-cols-1 gap-5 xl:grid-cols-[minmax(0,1fr)_360px]">
            <div className="space-y-2">
              <label className="text-xs font-medium text-slate-700 flex items-center gap-1.5">
                <Hash className="h-3 w-3" /> HTS Code
              </label>
              <div ref={htsDropdownRef} className="relative">
                <div className="relative">
                  <Search className="absolute left-3.5 top-1/2 -translate-y-1/2 h-4 w-4 text-slate-400 pointer-events-none" />
                  <Input
                    value={selectedHts ? formatHtsCode(selectedHts) : htsQuery}
                    onChange={(e) => {
                      const val = e.target.value.replace(/[^0-9.]/g, '');
                      setHtsQuery(val);
                      setSelectedHts(null);
                      setShowHtsDropdown(true);
                    }}
                    onFocus={() => { if (!selectedHts) setShowHtsDropdown(true); }}
                    onKeyDown={(e) => {
                      if (e.key === 'ArrowDown') {
                        e.preventDefault();
                        moveHighlightedHts(1);
                        return;
                      }
                      if (e.key === 'ArrowUp') {
                        e.preventDefault();
                        moveHighlightedHts(-1);
                        return;
                      }
                      if (e.key === 'Enter') {
                        if (!showHtsDropdown || highlightedHtsIndex < 0 || !htsResults[highlightedHtsIndex]) return;
                        e.preventDefault();
                        selectHts(htsResults[highlightedHtsIndex]);
                        return;
                      }
                      if (e.key === 'Escape') {
                        setShowHtsDropdown(false);
                        setHighlightedHtsIndex(-1);
                      }
                    }}
                    placeholder="Search by HTS code (for example 7208 or 7208.51.0030)"
                    className="h-11 rounded-xl border-slate-200 bg-white/95 pl-10 pr-10 text-sm font-mono shadow-sm focus-visible:ring-[#353CED]/30 focus-visible:ring-offset-0"
                    role="combobox"
                    aria-expanded={showHtsDropdown && !selectedHts}
                    aria-controls={showHtsDropdown && !selectedHts ? htsListboxId : undefined}
                    aria-activedescendant={
                      showHtsDropdown && !selectedHts && highlightedHtsIndex >= 0 && htsResults[highlightedHtsIndex]
                        ? `${htsListboxId}-${htsResults[highlightedHtsIndex]}`
                        : undefined
                    }
                    aria-autocomplete="list"
                  />
                  {htsSearchLoading && (
                    <Loader2 className={cn(
                      'absolute top-1/2 -translate-y-1/2 h-4 w-4 text-slate-400 animate-spin',
                      selectedHts ? 'right-10' : 'right-3.5'
                    )} />
                  )}
                </div>
                {selectedHts && (
                  <button
                    type="button"
                    onClick={() => {
                      setSelectedHts(null);
                      setHtsQuery('');
                      setHighlightedHtsIndex(-1);
                    }}
                    className="absolute right-3.5 top-1/2 -translate-y-1/2 rounded-full p-1 text-slate-400 transition-colors hover:bg-red-50 hover:text-red-500"
                    aria-label="Clear HTS code"
                  >
                    <X className="h-3.5 w-3.5" />
                  </button>
                )}
                {showHtsDropdown && !selectedHts && (
                  <div
                    id={htsListboxId}
                    role="listbox"
                    className="absolute top-full left-0 right-0 mt-2 z-[200] max-h-56 overflow-auto rounded-2xl border border-slate-200 bg-white/98 p-1.5 shadow-[0_18px_40px_rgba(15,23,42,0.12)]"
                  >
                    {htsResults.length > 0 ? (
                      htsResults.map((code, index) => (
                        <button
                          key={code}
                          id={`${htsListboxId}-${code}`}
                          ref={(node) => { htsOptionRefs.current[index] = node; }}
                          type="button"
                          role="option"
                          aria-selected={highlightedHtsIndex === index}
                          className={cn(
                            'w-full rounded-xl px-3 py-2.5 text-left text-sm font-mono transition-colors',
                            highlightedHtsIndex === index
                              ? 'bg-[#353CED]/10 text-[#353CED]'
                              : 'text-slate-700 hover:bg-slate-50'
                          )}
                          onMouseEnter={() => setHighlightedHtsIndex(index)}
                          onClick={() => selectHts(code)}
                        >
                          {formatHtsCode(code)}
                        </button>
                      ))
                    ) : (
                      <div className="px-3 py-2.5 text-sm text-slate-400">
                        {htsQuery.replace(/\./g, '').length < 2
                          ? 'Enter at least two digits to search.'
                          : 'No HTS codes found.'}
                      </div>
                    )}
                  </div>
                )}
              </div>
              <p className="text-xs text-slate-500">
                Use the arrow keys to move through matches and press Enter to select.
              </p>
            </div>

            <div className="space-y-2">
              <label className="text-xs font-medium text-slate-700 flex items-center gap-1.5">
                <Globe className="h-3 w-3" /> Countries
              </label>
              <CountryAutocomplete
                countries={countries}
                value={addingCountry}
                onChange={setAddingCountry}
                onAutoAdd={addCountry}
                placeholder="Search and select countries to compare..."
                className="[&_input]:h-11 [&_input]:rounded-xl [&_input]:border-slate-200 [&_input]:bg-white/95 [&_input]:pl-10 [&_input]:text-sm [&_input]:shadow-sm [&_input]:focus-visible:ring-[#353CED]/30 [&_input]:focus-visible:ring-offset-0"
              />
              <p className="text-xs text-slate-500">
                Selecting a country adds it immediately. Press Enter to add the highlighted match.
              </p>
            </div>
          </div>
        </div>

        <div className="rounded-[24px] border border-slate-200/80 bg-white/80 p-4 shadow-sm md:p-5">
          <div className="flex flex-col gap-3 md:flex-row md:items-start md:justify-between">
            <div className="space-y-1">
              <h4 className="text-sm font-semibold text-slate-900">Countries in comparison</h4>
              <p className="text-xs text-slate-500">
                Active selections stay pinned here and drive both the chart and the latest-duty-stack views.
              </p>
            </div>
            <div className="text-xs font-medium text-slate-500">
              {selectedCountries.length > 0 ? `${selectedCountries.length} selected` : 'No countries selected'}
            </div>
          </div>

          <div className="mt-4 flex flex-wrap gap-2">
            {selectedCountries.length === 0 && (
              <div className="rounded-xl border border-dashed border-slate-200 bg-slate-50/80 px-3 py-2 text-xs text-slate-500">
                Select countries to begin building a comparison set.
              </div>
            )}
            {selectedCountries.map((c, i) => (
              <Badge
                key={c.code}
                variant="outline"
                className="rounded-xl border-slate-200 bg-white px-2.5 py-1.5 text-xs font-medium text-slate-700 shadow-sm"
              >
                <div className="mr-1.5 h-2.5 w-2.5 rounded-full" style={{ backgroundColor: COMPARISON_COLORS[i % COMPARISON_COLORS.length] }} />
                <span>{c.name}</span>
                {c.alpha2 && <span className="ml-1 text-[10px] font-mono text-slate-400">{c.alpha2}</span>}
                <button
                  type="button"
                  onClick={() => removeCountry(c.code)}
                  className="ml-1 rounded-full p-0.5 text-slate-400 transition-colors hover:bg-red-50 hover:text-red-500"
                  title={`Remove ${c.name}`}
                >
                  <X className="h-3 w-3" />
                </button>
              </Badge>
            ))}
          </div>

          <div className="mt-4 flex flex-wrap gap-2">
            {QUICK_COUNTRIES
              .filter(p => !selectedCountries.find(c => c.code === p.code))
              .slice(0, 4)
              .map(p => {
                const country = countryMap.get(p.code);
                return country ? (
                  <button
                    key={p.code}
                    type="button"
                    onClick={() => addCountry(country)}
                    className="rounded-full border border-slate-200 bg-slate-50 px-3 py-1.5 text-[11px] font-medium text-slate-600 transition-colors hover:border-[#353CED]/25 hover:bg-[#353CED]/6 hover:text-[#353CED]"
                  >
                    {p.name}
                  </button>
                ) : null;
              })}
          </div>
        </div>

        {/* Loading / error */}
        {isLoading && (
          <div className="flex items-center justify-center gap-2 rounded-2xl border border-slate-200 bg-white/80 py-6 text-slate-500 shadow-sm">
            <Loader2 className="h-4 w-4 animate-spin" />
            <span className="text-sm">Fetching product rates...</span>
          </div>
        )}

        {fetchError && (
          <div className="rounded-2xl border border-red-200 bg-red-50/80 px-4 py-3 text-xs text-red-700 shadow-sm">
            {fetchError}
          </div>
        )}

        {/* Chart + full duty breakdown */}
        {!isLoading && hasData && (
          <div className="space-y-5">
            {/* Rate history line chart */}
            <div className="rounded-[24px] border border-slate-200/80 bg-white/85 p-5 shadow-sm">
              <div className="mb-4 flex flex-col gap-2 md:flex-row md:items-end md:justify-between">
                <div>
                  <h4 className="text-sm font-semibold text-slate-900">
                    Rate History: {formatHtsCode(selectedHts!)}
                  </h4>
                  <p className="text-xs text-slate-500 mt-1">
                    Total tariff rate by country over time using step-wise changes at each revision boundary.
                  </p>
                </div>
                <div className="text-xs font-medium text-slate-500">
                  {populatedCountryCount} {populatedCountryCount === 1 ? 'country' : 'countries'} with matching data
                </div>
              </div>
              <div className="h-[320px]">
                <ResponsiveContainer width="100%" height="100%">
                  <LineChart data={lineChartData}>
                    <CartesianGrid strokeDasharray="3 3" strokeOpacity={0.3} />
                    <XAxis dataKey="label" tick={{ fontSize: 10, fill: '#9ca3af' }}
                      interval={Math.max(1, Math.floor(lineChartData.length / 8))} />
                    <YAxis tickFormatter={(v: number) => `${(v * 100).toFixed(0)}%`}
                      tick={{ fontSize: 10, fill: '#9ca3af' }} width={45}
                      label={{ value: 'Tariff Rate (%)', angle: -90, position: 'insideLeft', style: { fontSize: 10, fill: '#9ca3af' } }} />
                    <ReTooltip
                      content={({ active, payload, label }) => {
                        if (!active || !payload?.length) return null;
                        return (
                          <div className="bg-white border border-gray-200 rounded-lg shadow-lg p-3 text-xs min-w-[280px]">
                            <div className="font-semibold text-gray-900 mb-2">{label}</div>
                            {payload
                              .filter(p => !String(p.dataKey).includes('_'))
                              .sort((a, b) => (b.value as number) - (a.value as number))
                              .map(p => {
                                const countryCode = String(p.dataKey);
                                const country = countryMap.get(countryCode);
                                const d = p.payload;
                                const baseRate = d[`${countryCode}_base`] as number | undefined;
                                const statutoryBase = d[`${countryCode}_statutory_base`] as number | undefined;
                                return (
                                  <div key={countryCode} className="mb-2.5 last:mb-0">
                                    {/* Country header + total */}
                                    <div className="flex justify-between mb-1 pb-0.5 border-b border-gray-100">
                                      <div className="flex items-center gap-1.5">
                                        <div className="w-2 h-2 rounded-full" style={{ backgroundColor: p.color as string }} />
                                        <span className="font-semibold text-gray-900">{country?.name ?? countryCode}</span>
                                      </div>
                                      <span className="font-mono font-bold">{formatRateShort(p.value as number)}</span>
                                    </div>
                                    {baseRate != null && (
                                      <div className="ml-[18px] space-y-0.5">
                                        {/* MFN base (with statutory if different) */}
                                        <div className="flex justify-between text-gray-500">
                                          <div className="flex items-center gap-1">
                                            <div className="w-1.5 h-1.5 rounded-sm" style={{ backgroundColor: MFN_COLOR }} />
                                            <span>MFN Base</span>
                                          </div>
                                          <span className="font-mono">{formatRateShort(baseRate)}</span>
                                        </div>
                                        {statutoryBase != null && statutoryBase !== baseRate && (
                                          <div className="flex justify-between text-gray-300 ml-[14px]">
                                            <span className="text-[10px]">Statutory</span>
                                            <span className="font-mono text-[10px]">{formatRateShort(statutoryBase)}</span>
                                          </div>
                                        )}
                                        {/* Authority breakdown */}
                                        {AUTHORITIES.filter(a => {
                                          const v = d[`${countryCode}_${a.key}`] as number | undefined;
                                          return v != null && v > 0.0001;
                                        }).map(a => (
                                          <div key={a.key} className="flex justify-between text-gray-500" title={a.description}>
                                            <div className="flex items-center gap-1">
                                              <div className="w-1.5 h-1.5 rounded-sm" style={{ backgroundColor: a.color }} />
                                              <span>{a.shortLabel}</span>
                                              {a.ch99Prefix && (
                                                <span className="text-[9px] text-gray-300 font-mono">Ch.99</span>
                                              )}
                                            </div>
                                            <span className="font-mono">
                                              {formatRateShort(d[`${countryCode}_${a.key}`] as number)}
                                            </span>
                                          </div>
                                        ))}
                                        {/* Additional total */}
                                        {(() => {
                                          const addl = d[`${countryCode}_additional`] as number | undefined;
                                          return addl != null && addl > 0 ? (
                                            <div className="flex justify-between text-gray-400 pt-0.5 border-t border-gray-50">
                                              <span className="text-[10px]">Additional duties</span>
                                              <span className="font-mono text-[10px]">{formatRateShort(addl)}</span>
                                            </div>
                                          ) : null;
                                        })()}
                                        {/* Metadata badges */}
                                        {(() => {
                                          const usmca = d[`${countryCode}_usmca`];
                                          const metalShare = d[`${countryCode}_metal_share`] as number | undefined;
                                          return (usmca || (metalShare != null && metalShare > 0 && metalShare < 1)) ? (
                                            <div className="flex gap-1.5 mt-0.5">
                                              {usmca && <span className="text-[9px] text-emerald-600 bg-emerald-50 rounded px-1">USMCA</span>}
                                              {metalShare != null && metalShare > 0 && metalShare < 1 && (
                                                <span className="text-[9px] text-gray-400 bg-gray-50 rounded px-1">Metal: {(metalShare * 100).toFixed(0)}%</span>
                                              )}
                                            </div>
                                          ) : null;
                                        })()}
                                      </div>
                                    )}
                                  </div>
                                );
                              })}
                          </div>
                        );
                      }}
                    />
                    {countryData.map(d => (
                      <Line key={d.country.code} type="stepAfter" dataKey={d.country.code}
                        stroke={d.color} strokeWidth={2} dot={false} name={d.country.name} />
                    ))}
                  </LineChart>
                </ResponsiveContainer>
              </div>
              <div className="flex flex-wrap gap-3 mt-4 pt-4 border-t border-slate-100">
                {countryData.map(d => (
                  <div key={d.country.code} className="flex items-center gap-1.5">
                    <div className="w-3 h-0.5 rounded" style={{ backgroundColor: d.color }} />
                    <span className="text-[10px] text-slate-500">{d.country.name}</span>
                  </div>
                ))}
              </div>
            </div>

            {/* Full duty breakdown table */}
            <div className="rounded-[24px] border border-slate-200/80 bg-white/85 p-5 shadow-sm">
              <div className="mb-4">
                <h4 className="text-sm font-semibold text-slate-900">Full Duty Stack — Latest Revision</h4>
                <p className="text-xs text-slate-500 mt-1">
                  Complete rate decomposition including MFN base, Ch. 99 authorities, and trade program eligibility.
                </p>
              </div>
              <div className="overflow-hidden rounded-2xl border border-slate-200">
                <div className="overflow-x-auto">
                  <table className="w-full text-xs">
                    <thead>
                      <tr className="bg-gray-50 border-b border-gray-200">
                        <th className="px-3 py-2 text-left text-[10px] font-medium text-gray-500 uppercase tracking-wider">Country</th>
                        <th className="px-3 py-2 text-right text-[10px] font-medium text-gray-500 uppercase tracking-wider cursor-help"
                          title="Most-Favored-Nation base duty rate from the Harmonized Tariff Schedule, before any additional tariffs.">MFN Base</th>
                        <th className="px-3 py-2 text-right text-[10px] font-medium text-gray-500 uppercase tracking-wider cursor-help"
                          title="The statutory column-1 general rate before any FTA/GSP preference adjustments.">Statutory</th>
                        {AUTHORITIES.map(a => (
                          <th key={a.key} className="px-3 py-2 text-right text-[10px] font-medium text-gray-500 uppercase tracking-wider whitespace-nowrap cursor-help"
                            title={a.description}>
                            <div>{a.shortLabel}</div>
                            {a.ch99Prefix && <div className="text-[8px] font-mono text-gray-300 font-normal">{a.ch99Prefix}</div>}
                          </th>
                        ))}
                        <th className="px-3 py-2 text-right text-[10px] font-medium text-gray-500 uppercase tracking-wider cursor-help"
                          title="Sum of all additional duties above MFN base (after mutual-exclusion stacking rules).">Addl.</th>
                        <th className="px-3 py-2 text-right text-[10px] font-medium text-gray-500 uppercase tracking-wider">Total</th>
                        <th className="px-3 py-2 text-center text-[10px] font-medium text-gray-500 uppercase tracking-wider cursor-help"
                          title="Trade program eligibility and product metadata.">Info</th>
                      </tr>
                    </thead>
                    <tbody>
                      {countryData.map(d => {
                        const r = d.latest;
                        return (
                          <tr key={d.country.code} className="border-b border-gray-50 hover:bg-gray-50/50 transition-colors">
                            <td className="px-3 py-2.5">
                              <div className="flex items-center gap-2">
                                <div className="w-2.5 h-2.5 rounded-full flex-shrink-0" style={{ backgroundColor: d.color }} />
                                <div>
                                  <span className="font-medium text-gray-900">{d.country.name}</span>
                                  {r && <div className="text-[10px] text-gray-400 font-mono">{r.revision}</div>}
                                </div>
                              </div>
                              {d.rates.length === 0 && <span className="text-[10px] text-amber-500 ml-5">No data for this product</span>}
                            </td>
                            <td className="px-3 py-2.5 text-right font-mono text-gray-700">
                              {r ? formatRate(r.base_rate) : '—'}
                            </td>
                            <td className="px-3 py-2.5 text-right font-mono text-gray-400">
                              {r ? (r.statutory_base_rate !== r.base_rate
                                ? formatRate(r.statutory_base_rate)
                                : <span className="text-gray-300">same</span>
                              ) : '—'}
                            </td>
                            {AUTHORITIES.map(a => (
                              <td key={a.key} className="px-3 py-2.5 text-right font-mono">
                                {r && r[a.key] > 0 ? (
                                  <span style={{ color: a.color }}>{formatRate(r[a.key])}</span>
                                ) : (
                                  <span className="text-gray-200">—</span>
                                )}
                              </td>
                            ))}
                            <td className="px-3 py-2.5 text-right font-mono text-gray-600">
                              {r ? formatRate(r.total_additional) : '—'}
                            </td>
                            <td className="px-3 py-2.5 text-right">
                              <span className={cn('font-mono font-bold',
                                r && r.total_rate > 0.30 ? 'text-red-700' :
                                r && r.total_rate > 0.10 ? 'text-orange-700' : 'text-gray-900'
                              )}>
                                {r ? formatRate(r.total_rate) : '—'}
                              </span>
                            </td>
                            <td className="px-3 py-2.5">
                              <div className="flex flex-wrap gap-1 justify-center">
                                {r?.usmca_eligible && (
                                  <span className="text-[9px] bg-emerald-50 text-emerald-700 border border-emerald-200 rounded px-1.5 py-0.5 whitespace-nowrap"
                                    title="This product is eligible for USMCA preferential treatment.">
                                    <ShieldCheck className="h-2.5 w-2.5 inline mr-0.5" />USMCA
                                  </span>
                                )}
                                {r && r.metal_share > 0 && r.metal_share < 1 && (
                                  <span className="text-[9px] bg-gray-50 text-gray-600 border border-gray-200 rounded px-1.5 py-0.5 whitespace-nowrap"
                                    title={`${(r.metal_share * 100).toFixed(0)}% metal content — Section 232 applies to the metal portion, IEEPA/S122 apply to the remainder.`}>
                                    Metal {(r.metal_share * 100).toFixed(0)}%
                                  </span>
                                )}
                                {r && r.metal_share === 1 && (
                                  <span className="text-[9px] bg-orange-50 text-orange-700 border border-orange-200 rounded px-1.5 py-0.5 whitespace-nowrap"
                                    title="Pure metal product — Section 232 takes full precedence; IEEPA reciprocal and S122 do not apply.">
                                    Pure metal
                                  </span>
                                )}
                                {r && AUTHORITIES.filter(a => r[a.key] === 0 && a.key !== 'rate_other' && a.key !== 'rate_section_201').length > 0 && (
                                  <span className="text-[9px] text-gray-400"
                                    title={`Exempt from: ${AUTHORITIES.filter(a => r[a.key] === 0 && a.key !== 'rate_other' && a.key !== 'rate_section_201').map(a => a.shortLabel).join(', ')}`}>
                                    {AUTHORITIES.filter(a => r[a.key] === 0 && a.key !== 'rate_other' && a.key !== 'rate_section_201').length} exempt
                                  </span>
                                )}
                              </div>
                            </td>
                          </tr>
                        );
                      })}
                    </tbody>
                  </table>
                </div>
              </div>

              {/* Rate bar visualization per country */}
              <div className="mt-4 space-y-2">
                {countryData.filter(d => d.latest).map(d => {
                  const r = d.latest!;
                  const total = r.total_rate;
                  if (total <= 0) return null;
                  const segments: Array<{ key: string; value: number; color: string; label: string }> = [];
                  if (r.base_rate > 0) segments.push({ key: 'mfn', value: r.base_rate, color: MFN_COLOR, label: 'MFN' });
                  for (const a of AUTHORITIES) {
                    if (r[a.key] > 0) segments.push({ key: a.key, value: r[a.key], color: a.color, label: a.shortLabel });
                  }
                  return (
                    <div key={d.country.code} className="flex items-center gap-3">
                      <span className="text-[10px] text-gray-600 w-20 text-right flex-shrink-0 truncate">{d.country.name}</span>
                      <div className="h-2.5 bg-gray-100 rounded-full overflow-hidden flex flex-1">
                        {segments.map((s, i) => (
                          <div key={s.key} title={`${s.label}: ${formatRateShort(s.value)}`}
                            className={cn('h-full transition-all duration-500', i === 0 && 'rounded-l-full', i === segments.length - 1 && 'rounded-r-full')}
                            style={{ width: `${(s.value / total) * 100}%`, backgroundColor: s.color }} />
                        ))}
                      </div>
                      <span className="text-[10px] font-mono font-semibold text-gray-700 w-12 text-right flex-shrink-0">{formatRateShort(total)}</span>
                    </div>
                  );
                })}
                {/* Compact legend for rate bars */}
                <div className="flex flex-wrap gap-x-3 gap-y-1 pt-1">
                  <div className="flex items-center gap-1 cursor-help"
                    title="Most-Favored-Nation base duty rate from the Harmonized Tariff Schedule, before any additional tariffs.">
                    <div className="w-2 h-2 rounded-sm" style={{ backgroundColor: MFN_COLOR }} />
                    <span className="text-[9px] text-gray-400">MFN</span>
                  </div>
                  {AUTHORITIES.filter(a => countryData.some(d => d.latest && d.latest[a.key] > 0)).map(a => (
                    <div key={a.key} className="flex items-center gap-1 cursor-help" title={a.description}>
                      <div className="w-2 h-2 rounded-sm" style={{ backgroundColor: a.color }} />
                      <span className="text-[9px] text-gray-400">{a.shortLabel}</span>
                    </div>
                  ))}
                </div>
              </div>
            </div>
          </div>
        )}

        {/* Empty state */}
        {!isLoading && !hasData && !fetchError && (
          <div className="rounded-[24px] border border-dashed border-slate-200 bg-white/70 px-6 py-10 text-center shadow-sm">
            <div className="mx-auto max-w-xl space-y-2">
              <h4 className="text-sm font-semibold text-slate-900">No product comparison loaded</h4>
              <p className="text-sm text-slate-500">
                {!selectedHts
                  ? 'Search for an HTS code and then choose countries to compare individual tariff rates.'
                  : selectedCountries.length === 0
                    ? 'Choose at least one country to populate the comparison views.'
                    : 'No rate data was found for this product and country combination.'}
              </p>
            </div>
          </div>
        )}
      </CardContent>
    </Card>
  );
}
