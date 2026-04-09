import React, { useState, useMemo, useEffect, useRef, useCallback, useId } from 'react';
import { Card, CardContent } from '@/components/ui/card';
import { Input } from '@/components/ui/input';
import { Badge } from '@/components/ui/badge';
import { CountryAutocomplete } from './CountryAutocomplete';
import {
  AreaChart, Area, XAxis, YAxis, CartesianGrid, Tooltip as ReTooltip,
  ResponsiveContainer,
} from 'recharts';
import type { Country, ProductRate } from '@/types/tariff';
import { AUTHORITIES, MFN_COLOR, STATUTORY_KEY_MAP, hasStatutoryDelta } from '@/types/tariff';
import { formatRate, formatRateShort, formatDate, formatHtsCode } from '@/utils/formatters';
import { fetchRatesArrow } from '@/hooks/useTariffData';
import {
  Search, Hash, X, Loader2, Package, Globe, ShieldCheck, ChevronRight, History,
} from 'lucide-react';
import { cn } from '@/lib/utils';

/* ── types ── */

interface ProductExplorerProps {
  countries: Country[];
}

interface HtsDescriptionLevel {
  level: string;
  htsno: string;
  description: string;
}

interface HtsProductInfo {
  hts10: string;
  descriptions: HtsDescriptionLevel[];
  fullDescription: string;
}

/* ── constants ── */

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

/* ── component ── */

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
  const [productInfo, setProductInfo] = useState<HtsProductInfo | null>(null);
  const [selectedRevision, setSelectedRevision] = useState<string | null>(null);

  const fetchRef = useRef(0);
  const searchTimerRef = useRef<ReturnType<typeof setTimeout>>();
  const htsDropdownRef = useRef<HTMLDivElement>(null);
  const htsOptionRefs = useRef<Array<HTMLButtonElement | null>>([]);
  const htsListboxId = useId();
  const countryMap = useMemo(() => new Map(countries.map(c => [c.code, c])), [countries]);

  /* ── outside click ── */
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

  /* ── debounced HTS search ── */
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
      } catch { /* silently fail */ }
      finally { setHtsSearchLoading(false); }
    }, 300);
    return () => { if (searchTimerRef.current) clearTimeout(searchTimerRef.current); };
  }, [htsQuery]);

  /* ── fetch HTS product description ── */
  useEffect(() => {
    if (!selectedHts) { setProductInfo(null); return; }
    const cleanCode = selectedHts.replace(/\./g, '');
    if (cleanCode.length < 4) return;
    let cancelled = false;
    fetch(`/api/product-info?hts10=${encodeURIComponent(cleanCode)}`)
      .then(r => r.ok ? r.json() : null)
      .then(json => { if (!cancelled && json?.data) setProductInfo(json.data); })
      .catch(() => {});
    return () => { cancelled = true; };
  }, [selectedHts]);

  /* ── helpers ── */
  const addCountry = useCallback((country: Country) => {
    setSelectedCountries(prev =>
      prev.some(c => c.code === country.code) ? prev : [...prev, country]
    );
    setAddingCountry(null);
  }, []);

  const selectHts = useCallback((code: string) => {
    setSelectedHts(code);
    setHtsQuery('');
    setShowHtsDropdown(false);
    setHighlightedHtsIndex(-1);
    setSelectedRevision(null);
  }, []);

  const removeCountry = useCallback((code: string) => {
    setSelectedCountries(prev => prev.filter(c => c.code !== code));
  }, []);

  const moveHighlightedHts = (direction: 1 | -1) => {
    if (htsResults.length === 0 || selectedHts) return;
    setShowHtsDropdown(true);
    setHighlightedHtsIndex(prev => {
      if (prev < 0) return direction === 1 ? 0 : htsResults.length - 1;
      return (prev + direction + htsResults.length) % htsResults.length;
    });
  };

  useEffect(() => {
    if (!showHtsDropdown || selectedHts) { setHighlightedHtsIndex(-1); return; }
    if (htsResults.length === 0) { setHighlightedHtsIndex(-1); return; }
    setHighlightedHtsIndex(prev => (prev >= 0 && prev < htsResults.length ? prev : 0));
  }, [htsResults, selectedHts, showHtsDropdown]);

  useEffect(() => {
    if (!showHtsDropdown || highlightedHtsIndex < 0) return;
    htsOptionRefs.current[highlightedHtsIndex]?.scrollIntoView({ block: 'nearest' });
  }, [highlightedHtsIndex, showHtsDropdown]);

  /* ── fetch rates ── */
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

  /* ── derived data ── */
  const countryData = useMemo(() => {
    return selectedCountries.map((country, idx) => {
      const rates = fetchedRates
        .filter(r => r.country === country.code)
        .sort((a, b) => a.effective_date.localeCompare(b.effective_date));
      const latest = rates.length > 0 ? rates[rates.length - 1] : null;
      return { country, rates, latest, color: COMPARISON_COLORS[idx % COMPARISON_COLORS.length] };
    });
  }, [selectedCountries, fetchedRates]);

  /* All available revisions across all selected countries */
  const availableRevisions = useMemo(() => {
    const revSet = new Map<string, string>(); // revision → effective_date
    for (const d of countryData) {
      for (const r of d.rates) {
        if (!revSet.has(r.revision)) revSet.set(r.revision, r.effective_date);
      }
    }
    return Array.from(revSet.entries())
      .sort((a, b) => a[1].localeCompare(b[1]))
      .map(([revision, effectiveDate]) => ({ revision, effectiveDate }));
  }, [countryData]);

  /* The revision used for the duty stack table */
  const activeRevision = selectedRevision ?? (availableRevisions.length > 0 ? availableRevisions[availableRevisions.length - 1].revision : null);

  /* Country data resolved at the active revision */
  const revisionCountryData = useMemo(() => {
    if (!activeRevision) return countryData;
    return countryData.map(d => {
      const atRevision = d.rates.find(r => r.revision === activeRevision) ?? null;
      return { ...d, latest: atRevision };
    });
  }, [countryData, activeRevision]);

  const lineChartData = useMemo(() => {
    if (countryData.length === 0) return [];
    const allDates = new Set<string>();
    for (const d of countryData) for (const r of d.rates) allDates.add(r.effective_date);
    return Array.from(allDates).sort().map(date => {
      const row: Record<string, number | string> = { date, label: formatDate(date) };
      for (const d of countryData) {
        const rate = d.rates.find(r => r.valid_from <= date && r.valid_until >= date);
        if (rate) {
          row[d.country.code] = rate.total_rate;
          for (const a of AUTHORITIES) {
            row[`${d.country.code}_${a.key}`] = rate[a.key];
            const sk = STATUTORY_KEY_MAP[a.key];
            row[`${d.country.code}_${sk}`] = rate[sk] ?? 0;
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

  /* ── render ── */
  return (
    <Card>
      <CardContent className="p-5 space-y-5">
        {/* Header */}
        <div className="flex items-center gap-2">
          <Package className="h-4 w-4 text-[#353CED]" />
          <h3 className="font-semibold text-sm text-gray-900">Product Explorer</h3>
          <span className="text-[10px] text-gray-400">Compare duty stacks for a specific product across countries</span>
        </div>

        {/* Controls */}
        <div className="grid grid-cols-1 md:grid-cols-[1fr_320px] gap-4">
          {/* HTS code search */}
          <div className="space-y-1.5">
            <label className="text-xs font-medium text-gray-700 flex items-center gap-1.5">
              <Hash className="h-3 w-3" /> HTS Code
            </label>
            <div ref={htsDropdownRef} className="relative">
              <div className="relative">
                <Search className="absolute left-3 top-1/2 -translate-y-1/2 h-3.5 w-3.5 text-gray-400 pointer-events-none" />
                <Input
                  value={selectedHts ? formatHtsCode(selectedHts) : htsQuery}
                  onChange={(e) => {
                    setHtsQuery(e.target.value.replace(/[^0-9.]/g, ''));
                    setSelectedHts(null);
                    setShowHtsDropdown(true);
                  }}
                  onFocus={() => { if (!selectedHts) setShowHtsDropdown(true); }}
                  onKeyDown={(e) => {
                    if (e.key === 'ArrowDown') { e.preventDefault(); moveHighlightedHts(1); return; }
                    if (e.key === 'ArrowUp') { e.preventDefault(); moveHighlightedHts(-1); return; }
                    if (e.key === 'Enter') {
                      if (!showHtsDropdown || highlightedHtsIndex < 0 || !htsResults[highlightedHtsIndex]) return;
                      e.preventDefault(); selectHts(htsResults[highlightedHtsIndex]); return;
                    }
                    if (e.key === 'Escape') { setShowHtsDropdown(false); setHighlightedHtsIndex(-1); }
                  }}
                  placeholder="e.g. 7208.51.0030"
                  className="h-9 text-sm font-mono pl-9"
                  role="combobox"
                  aria-expanded={showHtsDropdown && !selectedHts}
                  aria-controls={showHtsDropdown && !selectedHts ? htsListboxId : undefined}
                  aria-activedescendant={
                    showHtsDropdown && !selectedHts && highlightedHtsIndex >= 0 && htsResults[highlightedHtsIndex]
                      ? `${htsListboxId}-${htsResults[highlightedHtsIndex]}` : undefined
                  }
                  aria-autocomplete="list"
                />
                {htsSearchLoading && <Loader2 className="absolute right-3 top-1/2 -translate-y-1/2 h-3.5 w-3.5 text-gray-400 animate-spin" />}
                {selectedHts && !htsSearchLoading && (
                  <button type="button"
                    onClick={() => { setSelectedHts(null); setHtsQuery(''); setHighlightedHtsIndex(-1); }}
                    className="absolute right-3 top-1/2 -translate-y-1/2 text-gray-400 hover:text-red-500" aria-label="Clear HTS code">
                    <X className="h-3.5 w-3.5" />
                  </button>
                )}
              </div>
              {showHtsDropdown && !selectedHts && (
                <div id={htsListboxId} role="listbox"
                  className="absolute top-full left-0 right-0 mt-1 z-[200] max-h-56 overflow-auto rounded-lg border border-gray-200 bg-white shadow-lg">
                  {htsResults.length > 0 ? htsResults.map((code, index) => (
                    <button key={code} id={`${htsListboxId}-${code}`}
                      ref={(node) => { htsOptionRefs.current[index] = node; }}
                      type="button" role="option" aria-selected={highlightedHtsIndex === index ? true : undefined}
                      className={cn('w-full text-left px-3 py-2 text-sm font-mono transition-colors',
                        highlightedHtsIndex === index ? 'bg-[#353CED]/10 text-[#353CED]' : 'text-gray-700 hover:bg-gray-50'
                      )}
                      onMouseEnter={() => setHighlightedHtsIndex(index)}
                      onClick={() => selectHts(code)}>
                      {formatHtsCode(code)}
                    </button>
                  )) : (
                    <div className="px-3 py-2 text-sm text-gray-400">
                      {htsQuery.replace(/\./g, '').length < 2 ? 'Enter at least two digits.' : 'No HTS codes found.'}
                    </div>
                  )}
                </div>
              )}
            </div>
            {productInfo && productInfo.descriptions.length > 0 && (
              <div className="flex flex-wrap items-center gap-x-1 gap-y-0.5 text-[10px] leading-relaxed mt-1">
                {productInfo.descriptions.map((d, i) => (
                  <React.Fragment key={i}>
                    {i > 0 && <ChevronRight className="h-2.5 w-2.5 text-gray-300 flex-shrink-0" />}
                    <span className={cn(i === productInfo.descriptions.length - 1 ? 'text-gray-700 font-medium' : 'text-gray-400')}>
                      {d.description}
                    </span>
                  </React.Fragment>
                ))}
              </div>
            )}
          </div>

          {/* Country picker */}
          <div className="space-y-1.5">
            <label className="text-xs font-medium text-gray-700 flex items-center gap-1.5">
              <Globe className="h-3 w-3" /> Countries
            </label>
            <CountryAutocomplete countries={countries} value={addingCountry} onChange={setAddingCountry}
              onAutoAdd={addCountry} placeholder="Search countries..." />
          </div>
        </div>

        {/* Selected countries + quick-add */}
        <div className="flex flex-wrap items-center gap-2">
          {selectedCountries.map((c, i) => (
            <Badge key={c.code} variant="outline" className="text-[10px] font-medium pl-1.5 pr-1 py-0.5 gap-1 border-gray-200">
              <div className="w-2 h-2 rounded-full" style={{ backgroundColor: COMPARISON_COLORS[i % COMPARISON_COLORS.length] }} />
              {c.name}
              <button type="button" onClick={() => removeCountry(c.code)} className="text-gray-400 hover:text-red-500 ml-0.5" title={`Remove ${c.name}`}>
                <X className="h-2.5 w-2.5" />
              </button>
            </Badge>
          ))}
          {QUICK_COUNTRIES.filter(p => !selectedCountries.find(c => c.code === p.code)).slice(0, 5).map(p => {
            const country = countryMap.get(p.code);
            return country ? (
              <button key={p.code} type="button" onClick={() => addCountry(country)}
                className="text-[10px] px-2 py-1 rounded-full bg-gray-50 text-gray-500 hover:bg-[#353CED]/5 hover:text-[#353CED] transition-colors border border-gray-100">
                + {p.name}
              </button>
            ) : null;
          })}
        </div>

        {/* Loading / error */}
        {isLoading && (
          <div className="flex items-center justify-center py-8 gap-2 text-gray-400">
            <Loader2 className="h-4 w-4 animate-spin" /><span className="text-sm">Fetching product rates...</span>
          </div>
        )}
        {fetchError && (
          <div className="flex items-start gap-2 px-4 py-3 rounded-lg bg-red-50 border border-red-200 text-xs text-red-800">{fetchError}</div>
        )}

        {/* ── Results ── */}
        {!isLoading && hasData && (
          <>
            {/* ── Rate history chart ── */}
            <div>
              <div className="flex items-center justify-between mb-3">
                <div>
                  <h4 className="text-xs font-semibold text-gray-900">Rate History — {formatHtsCode(selectedHts!)}</h4>
                  <p className="text-[10px] text-gray-400 mt-0.5">Total tariff rate by country, step-wise at each revision boundary</p>
                </div>
              </div>
              <div className="h-[340px]">
                <ResponsiveContainer width="100%" height="100%">
                  <AreaChart data={lineChartData}>
                    <defs>
                      {countryData.map(d => (
                        <linearGradient key={d.country.code} id={`fill-${d.country.code}`} x1="0" y1="0" x2="0" y2="1">
                          <stop offset="0%" stopColor={d.color} stopOpacity={0.12} />
                          <stop offset="100%" stopColor={d.color} stopOpacity={0.01} />
                        </linearGradient>
                      ))}
                    </defs>
                    <CartesianGrid stroke="#f0f0f0" strokeDasharray="none" />
                    <XAxis dataKey="label" tick={{ fontSize: 10, fill: '#9ca3af' }} tickLine={false}
                      axisLine={{ stroke: '#e5e7eb' }} interval={Math.max(1, Math.floor(lineChartData.length / 8))} />
                    <YAxis tickFormatter={(v: number) => `${(v * 100).toFixed(0)}%`}
                      tick={{ fontSize: 10, fill: '#9ca3af' }} tickLine={false} axisLine={false} width={42} />
                    <ReTooltip
                      content={({ active, payload, label }) => {
                        if (!active || !payload?.length) return null;
                        return (
                          <div className="bg-white rounded-lg shadow-[0_8px_30px_rgba(0,0,0,0.12)] border border-gray-100 p-0 text-xs min-w-[300px] overflow-hidden">
                            <div className="px-3.5 py-2.5 bg-gray-50 border-b border-gray-100">
                              <div className="font-semibold text-gray-900">{label}</div>
                            </div>
                            <div className="p-3.5 space-y-3">
                              {payload
                                .filter(p => !String(p.dataKey).includes('_'))
                                .sort((a, b) => (b.value as number) - (a.value as number))
                                .map(p => {
                                  const cc = String(p.dataKey);
                                  const country = countryMap.get(cc);
                                  const d = p.payload;
                                  const baseRate = d[`${cc}_base`] as number | undefined;
                                  const statutoryBase = d[`${cc}_statutory_base`] as number | undefined;
                                  return (
                                    <div key={cc}>
                                      <div className="flex justify-between items-center mb-1.5">
                                        <div className="flex items-center gap-1.5">
                                          <div className="w-2.5 h-2.5 rounded-full" style={{ backgroundColor: p.color as string }} />
                                          <span className="font-semibold text-gray-900">{country?.name ?? cc}</span>
                                        </div>
                                        <span className="font-mono font-bold text-gray-900">{formatRateShort(p.value as number)}</span>
                                      </div>
                                      {baseRate != null && (
                                        <div className="ml-4 space-y-1 text-[11px]">
                                          {/* MFN Base */}
                                          <div className="flex justify-between">
                                            <div className="flex items-center gap-1.5">
                                              <div className="w-2 h-2 rounded-sm" style={{ backgroundColor: MFN_COLOR }} />
                                              <span className="text-gray-600">MFN Base</span>
                                            </div>
                                            <span className="font-mono text-gray-700">{formatRateShort(baseRate)}</span>
                                          </div>
                                          {statutoryBase != null && statutoryBase !== baseRate && (
                                            <div className="flex justify-between ml-[22px]">
                                              <span className="text-gray-400 italic">Statutory base</span>
                                              <span className="font-mono text-gray-400">{formatRateShort(statutoryBase)}</span>
                                            </div>
                                          )}
                                          {/* Authority breakdown */}
                                          {AUTHORITIES.filter(a => {
                                            const v = d[`${cc}_${a.key}`] as number | undefined;
                                            return v != null && v > 0.0001;
                                          }).map(a => {
                                            const effectiveVal = d[`${cc}_${a.key}`] as number;
                                            const statutoryVal = d[`${cc}_${STATUTORY_KEY_MAP[a.key]}`] as number | undefined;
                                            const hasDelta = statutoryVal != null && statutoryVal > 0 && Math.abs(statutoryVal - effectiveVal) > 0.00001;
                                            return (
                                              <React.Fragment key={a.key}>
                                                <div className="flex justify-between">
                                                  <div className="flex items-center gap-1.5">
                                                    <div className="w-2 h-2 rounded-sm" style={{ backgroundColor: a.color }} />
                                                    <span className="text-gray-600">{a.shortLabel}</span>
                                                    {a.ch99Prefix && (
                                                      <span className="font-mono text-[9px] text-[#353CED]/60 bg-[#353CED]/5 rounded px-1 py-px">{a.ch99Prefix}</span>
                                                    )}
                                                  </div>
                                                  <span className="font-mono text-gray-700">{formatRateShort(effectiveVal)}</span>
                                                </div>
                                                {hasDelta && (
                                                  <div className="flex justify-between ml-[22px]">
                                                    <span className="text-gray-400 italic">Statutory</span>
                                                    <span className="font-mono text-gray-400">{formatRateShort(statutoryVal!)}</span>
                                                  </div>
                                                )}
                                              </React.Fragment>
                                            );
                                          })}
                                          {/* Additional total */}
                                          {(() => {
                                            const addl = d[`${cc}_additional`] as number | undefined;
                                            return addl != null && addl > 0 ? (
                                              <div className="flex justify-between pt-1 mt-1 border-t border-gray-100">
                                                <span className="text-gray-500 font-medium">Additional duties</span>
                                                <span className="font-mono text-gray-600">{formatRateShort(addl)}</span>
                                              </div>
                                            ) : null;
                                          })()}
                                          {/* USMCA / metal */}
                                          {(() => {
                                            const usmca = d[`${cc}_usmca`];
                                            const ms = d[`${cc}_metal_share`] as number | undefined;
                                            return (usmca || (ms != null && ms > 0 && ms < 1)) ? (
                                              <div className="flex gap-1.5 mt-1">
                                                {usmca ? <span className="text-[9px] text-emerald-700 bg-emerald-50 border border-emerald-200 rounded px-1.5 py-0.5">USMCA</span> : null}
                                                {ms != null && ms > 0 && ms < 1 && (
                                                  <span className="text-[9px] text-gray-500 bg-gray-100 rounded px-1.5 py-0.5">Metal: {(ms * 100).toFixed(0)}%</span>
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
                          </div>
                        );
                      }}
                    />
                    {countryData.map(d => (
                      <Area key={d.country.code} type="stepAfter" dataKey={d.country.code}
                        stroke={d.color} strokeWidth={2} fill={`url(#fill-${d.country.code})`}
                        dot={false} name={d.country.name} />
                    ))}
                  </AreaChart>
                </ResponsiveContainer>
              </div>
              <div className="flex flex-wrap gap-x-4 gap-y-1.5 mt-3 pt-3 border-t border-gray-100">
                {countryData.map(d => (
                  <div key={d.country.code} className="flex items-center gap-1.5">
                    <div className="w-3 h-0.5 rounded" style={{ backgroundColor: d.color }} />
                    <span className="text-[10px] text-gray-500">{d.country.name}</span>
                  </div>
                ))}
              </div>
            </div>

            {/* ── Full duty breakdown table ── */}
            <div>
              <div className="flex items-center justify-between mb-3">
                <div>
                  <h4 className="text-xs font-semibold text-gray-900">Full Duty Stack</h4>
                  <p className="text-[10px] text-gray-400 mt-0.5">
                    MFN base, all Ch. 99 authorities, and trade program eligibility
                  </p>
                </div>
                {/* Revision selector */}
                {availableRevisions.length > 1 && (
                  <div className="flex items-center gap-1.5">
                    <History className="h-3 w-3 text-gray-400" />
                    <select
                      value={activeRevision ?? ''}
                      onChange={(e) => setSelectedRevision(e.target.value || null)}
                      title="Select revision to view"
                      aria-label="Select revision to view"
                      className="text-[10px] font-mono text-gray-600 bg-white border border-gray-200 rounded-md px-2 py-1 focus:outline-none focus:ring-1 focus:ring-[#353CED]/30 cursor-pointer"
                    >
                      {availableRevisions.map(r => (
                        <option key={r.revision} value={r.revision}>
                          {r.revision} ({formatDate(r.effectiveDate)})
                        </option>
                      ))}
                    </select>
                  </div>
                )}
              </div>
              <div className="rounded-lg border border-gray-200 overflow-hidden">
                <div className="overflow-x-auto">
                  <table className="w-full text-xs">
                    <thead>
                      <tr className="bg-gray-50 border-b border-gray-200">
                        <th className="px-3 py-2 text-left text-[10px] font-medium text-gray-500 uppercase tracking-wider">Country</th>
                        <th className="px-3 py-2 text-right text-[10px] font-medium text-gray-500 uppercase tracking-wider cursor-help"
                          title="Most-Favored-Nation base duty rate from the Harmonized Tariff Schedule.">MFN Base</th>
                        <th className="px-3 py-2 text-right text-[10px] font-medium text-gray-500 uppercase tracking-wider cursor-help"
                          title="The statutory column-1 general rate before FTA/GSP preference adjustments.">Statutory</th>
                        {AUTHORITIES.map(a => (
                          <th key={a.key} className="px-3 py-2.5 text-right text-[10px] font-medium text-gray-500 uppercase tracking-wider whitespace-nowrap cursor-help"
                            title={a.description}>
                            <div>{a.shortLabel}</div>
                            {a.ch99Prefix && (
                              <div className="font-mono text-[8px] text-[#353CED]/50 font-normal mt-0.5">{a.ch99Prefix}</div>
                            )}
                          </th>
                        ))}
                        <th className="px-3 py-2 text-right text-[10px] font-medium text-gray-500 uppercase tracking-wider cursor-help"
                          title="Sum of all additional duties above MFN base (after stacking rules).">Addl.</th>
                        <th className="px-3 py-2 text-right text-[10px] font-medium text-gray-500 uppercase tracking-wider">Total</th>
                        <th className="px-3 py-2 text-center text-[10px] font-medium text-gray-500 uppercase tracking-wider cursor-help"
                          title="Trade program eligibility and product metadata.">Info</th>
                      </tr>
                    </thead>
                    <tbody>
                      {revisionCountryData.map(d => {
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
                              {!r && <span className="text-[10px] text-amber-500 ml-5">No data for this revision</span>}
                            </td>
                            <td className="px-3 py-2.5 text-right font-mono text-gray-700">
                              {r ? formatRate(r.base_rate) : '—'}
                            </td>
                            <td className="px-3 py-2.5 text-right font-mono text-gray-400">
                              {r ? (r.statutory_base_rate !== r.base_rate
                                ? formatRate(r.statutory_base_rate) : <span className="text-gray-300">same</span>
                              ) : '—'}
                            </td>
                            {AUTHORITIES.map(a => (
                              <td key={a.key} className="px-3 py-2.5 text-right font-mono">
                                {r && r[a.key] > 0 ? (
                                  <div>
                                    <span style={{ color: a.color }}>{formatRate(r[a.key])}</span>
                                    {hasStatutoryDelta(r, a.key) && (
                                      <div className="text-[9px] text-gray-400 italic">
                                        stat: {formatRateShort(r[STATUTORY_KEY_MAP[a.key]])}
                                      </div>
                                    )}
                                  </div>
                                ) : <span className="text-gray-200">—</span>}
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
                                    title="USMCA preferential treatment eligible.">
                                    <ShieldCheck className="h-2.5 w-2.5 inline mr-0.5" />USMCA
                                  </span>
                                )}
                                {r && r.metal_share > 0 && r.metal_share < 1 && (
                                  <span className="text-[9px] bg-gray-100 text-gray-600 border border-gray-200 rounded px-1.5 py-0.5 whitespace-nowrap"
                                    title={`${(r.metal_share * 100).toFixed(0)}% metal — 232 on metal portion, IEEPA/S122 on remainder.`}>
                                    Metal {(r.metal_share * 100).toFixed(0)}%
                                  </span>
                                )}
                                {r && r.metal_share === 1 && (
                                  <span className="text-[9px] bg-orange-50 text-orange-700 border border-orange-200 rounded px-1.5 py-0.5 whitespace-nowrap"
                                    title="Pure metal — 232 takes full precedence.">Pure metal</span>
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

              {/* Rate bar visualization */}
              <div className="mt-4 space-y-1.5">
                {revisionCountryData.filter(d => d.latest).map(d => {
                  const r = d.latest!;
                  const total = r.total_rate;
                  if (total <= 0) return null;
                  const segments: Array<{ key: string; value: number; color: string; label: string }> = [];
                  if (r.base_rate > 0) segments.push({ key: 'mfn', value: r.base_rate, color: MFN_COLOR, label: 'MFN Base' });
                  for (const a of AUTHORITIES) {
                    if (r[a.key] > 0) segments.push({ key: a.key, value: r[a.key], color: a.color, label: a.shortLabel });
                  }
                  return (
                    <div key={d.country.code} className="flex items-center gap-2.5">
                      <span className="text-[10px] text-gray-600 w-20 text-right flex-shrink-0 truncate font-medium">{d.country.name}</span>
                      <div className="h-3 bg-gray-50 border border-gray-100 rounded-md overflow-hidden flex flex-1">
                        {segments.map((s) => (
                          <div key={s.key} title={`${s.label}: ${formatRateShort(s.value)}`}
                            className="h-full first:rounded-l-[3px] last:rounded-r-[3px]"
                            style={{ width: `${(s.value / total) * 100}%`, backgroundColor: s.color }} />
                        ))}
                      </div>
                      <span className="text-[10px] font-mono font-bold text-gray-800 w-12 text-right flex-shrink-0">{formatRateShort(total)}</span>
                    </div>
                  );
                })}
                <div className="flex flex-wrap gap-x-3 gap-y-1 pt-2">
                  <div className="flex items-center gap-1.5 cursor-help"
                    title="Most-Favored-Nation base duty rate.">
                    <div className="w-2.5 h-2.5 rounded-sm" style={{ backgroundColor: MFN_COLOR }} />
                    <span className="text-[9px] text-gray-500">MFN Base</span>
                  </div>
                  {AUTHORITIES.filter(a => revisionCountryData.some(d => d.latest && d.latest[a.key] > 0)).map(a => (
                    <div key={a.key} className="flex items-center gap-1.5 cursor-help" title={a.description}>
                      <div className="w-2.5 h-2.5 rounded-sm" style={{ backgroundColor: a.color }} />
                      <span className="text-[9px] text-gray-500">{a.shortLabel}</span>
                    </div>
                  ))}
                </div>
              </div>
            </div>
          </>
        )}

        {/* Empty state */}
        {!isLoading && !hasData && !fetchError && (
          <div className="text-center py-10 text-gray-400">
            <p className="text-sm">
              {!selectedHts
                ? 'Search for an HTS code and select countries to compare individual tariff rates.'
                : selectedCountries.length === 0
                  ? 'Select at least one country to view rates.'
                  : 'No rate data found for this product/country combination.'}
            </p>
          </div>
        )}
      </CardContent>
    </Card>
  );
}
