import React, { useState, useMemo, useCallback, useEffect, useRef } from 'react';
import { Card, CardContent } from '@/components/ui/card';
import { Input } from '@/components/ui/input';
import { Button } from '@/components/ui/button';
import { DatePickerNeu } from './DatePickerNeu';
import { CountryAutocomplete } from './CountryAutocomplete';
import { ShipmentImportDialog } from './ShipmentImportDialog';
import type { Country, ProductRate, ShipmentRow, RateBasis, CompositionOverrides, AuthorityTrigger } from '@/types/tariff';
import type { RateMatchKind } from '@/hooks/useTariffData';
import {
  calculateLandedCost, findRateForDate, MPF_RATE, MPF_MIN, MPF_MAX, HMF_RATE,
  exportShipmentsCSV, detectAuthorityTriggers,
} from '@/utils/tariffCalculator';
import { formatCurrency, formatRate, formatRateShort, formatDate } from '@/utils/formatters';
import {
  Calculator, Plus, Trash2, Ship, Plane, Truck, ChevronDown, ChevronRight,
  Download, Upload, Info, ArrowDownUp, DollarSign, CalendarDays, Globe, Package,
  Container, ShieldCheck,
} from 'lucide-react';
import { cn } from '@/lib/utils';

interface DutyCalculatorPanelProps {
  rates: ProductRate[];
  currentRate: ProductRate | null;
  countryName: string;
  htsCode: string;
  countries: Country[];
  selectedCountry: Country | null;
  /** Match kind for the initial (default-country) lookup, from useRateLookup. */
  initialMatch?: RateMatchKind;
}

type TransportMode = 'ocean' | 'air' | 'land';

const TRANSPORT_LABELS: Record<TransportMode, { label: string; icon: React.ElementType }> = {
  ocean: { label: 'Ocean', icon: Ship },
  air:   { label: 'Air',   icon: Plane },
  land:  { label: 'Land',  icon: Truck },
};

export function DutyCalculatorPanel({
  rates, currentRate, countryName, htsCode, countries, selectedCountry, initialMatch,
}: DutyCalculatorPanelProps) {
  const defaultCountryCode = selectedCountry?.code ?? '';

  const [rows, setRows] = useState<ShipmentRow[]>([
    { id: '1', customsValue: 50000, date: new Date(), countryCode: defaultCountryCode },
  ]);
  const [transportMode, setTransportMode] = useState<TransportMode>('ocean');
  const [expandedRows, setExpandedRows] = useState<Set<string>>(new Set());
  const [importOpen, setImportOpen] = useState(false);

  // Per-country rate cache: countryCode → ProductRate[]
  const [rateCache, setRateCache] = useState<Map<string, ProductRate[]>>(new Map());
  // Per-country match kind from the API. Mirrors the /api/rates `match` field
  // so the UI can label base-MFN-synthesized rows as such.
  const [matchCache, setMatchCache] = useState<Map<string, RateMatchKind>>(new Map());
  const fetchingRef = useRef(new Set<string>());

  // Seed the cache with the initial lookup's rates
  useEffect(() => {
    if (defaultCountryCode && rates.length > 0) {
      setRateCache(prev => {
        const next = new Map(prev);
        next.set(defaultCountryCode, rates);
        return next;
      });
      setMatchCache(prev => {
        const next = new Map(prev);
        next.set(defaultCountryCode, initialMatch ?? 'exact');
        return next;
      });
    }
  }, [defaultCountryCode, rates, initialMatch]);

  // When selectedCountry changes, update new rows' default
  const latestDefaultRef = useRef(defaultCountryCode);
  latestDefaultRef.current = defaultCountryCode;

  // Build a country lookup map
  const countryMap = useMemo(() => new Map(countries.map(c => [c.code, c])), [countries]);

  // Fetch rates for a country if not in cache
  const ensureCountryRates = useCallback(async (countryCode: string) => {
    if (!countryCode || !htsCode) return;
    if (rateCache.has(countryCode)) return;
    if (fetchingRef.current.has(countryCode)) return;

    fetchingRef.current.add(countryCode);
    const cleanCode = htsCode.replace(/\./g, '');
    try {
      const res = await fetch(`/api/rates?hts10=${encodeURIComponent(cleanCode)}&country=${encodeURIComponent(countryCode)}`);
      if (!res.ok) return;
      const json = await res.json();
      const data = (json.data as ProductRate[]).sort(
        (a: ProductRate, b: ProductRate) => a.effective_date.localeCompare(b.effective_date)
      );
      const matchKind: RateMatchKind = (json.match as RateMatchKind | undefined) ?? 'exact';
      setRateCache(prev => {
        const next = new Map(prev);
        next.set(countryCode, data);
        return next;
      });
      setMatchCache(prev => {
        const next = new Map(prev);
        next.set(countryCode, matchKind);
        return next;
      });
    } catch {
      // silently fail — rate will show as unavailable
    } finally {
      fetchingRef.current.delete(countryCode);
    }
  }, [htsCode, rateCache]);

  const addRow = useCallback(() => {
    setRows(prev => [...prev, {
      id: String(Date.now()),
      customsValue: 0,
      date: new Date(),
      countryCode: latestDefaultRef.current,
    }]);
  }, []);

  const removeRow = useCallback((id: string) => {
    setRows(prev => prev.length > 1 ? prev.filter(r => r.id !== id) : prev);
  }, []);

  const updateRow = useCallback((id: string, updates: Partial<ShipmentRow>) => {
    setRows(prev => prev.map(r => r.id === id ? { ...r, ...updates } : r));
  }, []);

  const updateRowCountry = useCallback((id: string, countryCode: string) => {
    setRows(prev => prev.map(r => r.id === id ? { ...r, countryCode } : r));
    ensureCountryRates(countryCode);
  }, [ensureCountryRates]);

  const updateRowComposition = useCallback((id: string, key: keyof CompositionOverrides, value: number | string | undefined) => {
    setRows(prev => prev.map(r => {
      if (r.id !== id) return r;
      const comp = { ...r.composition, [key]: value };
      return { ...r, composition: comp };
    }));
  }, []);

  const toggleExpand = useCallback((id: string) => {
    setExpandedRows(prev => {
      const next = new Set(prev);
      next.has(id) ? next.delete(id) : next.add(id);
      return next;
    });
  }, []);

  const sortByDate = useCallback(() => {
    setRows(prev => [...prev].sort((a, b) => b.date.getTime() - a.date.getTime()));
  }, []);

  const handleImport = useCallback((imported: ShipmentRow[]) => {
    // Set default country on imported rows
    const withCountry = imported.map(r => ({
      ...r,
      countryCode: r.countryCode || latestDefaultRef.current,
    }));
    setRows(prev => [...prev, ...withCountry]);
  }, []);

  // Compute results using per-shipment country rates
  const results = useMemo(() => {
    return rows.map(row => {
      const cc = row.countryCode || defaultCountryCode;
      const countryRates = rateCache.get(cc) ?? (cc === defaultCountryCode ? rates : []);
      const dateStr = row.date.toISOString().slice(0, 10);
      const applicableRate = findRateForDate(countryRates, dateStr) ?? (cc === defaultCountryCode ? currentRate : null);
      // The per-row __synthesized flag is authoritative. The country-level
      // match kind from matchCache can say 'base_mfn_synthesized' when the
      // response was augmented with fillers for OTHER revisions, so relying
      // on it would mislabel real rows. Honor per-row only.
      const matchKind: RateMatchKind = applicableRate?.__synthesized === true
        ? 'base_mfn_synthesized'
        : 'exact';
      if (!applicableRate) return { row, result: null, rate: null, countryCode: cc, matchKind };
      return {
        row,
        rate: applicableRate,
        countryCode: cc,
        matchKind,
        result: calculateLandedCost(applicableRate, row.customsValue, {
          includeHMF: transportMode === 'ocean',
          freight: row.freight ?? 0,
          insurance: row.insurance ?? 0,
          quantity: row.quantity,
          countryCode: cc,
          composition: row.composition,
        }),
      };
    });
  }, [rows, rateCache, rates, currentRate, transportMode, defaultCountryCode, matchCache]);

  const sortedIndices = useMemo(() => {
    return rows.map((_, i) => i).sort((a, b) => rows[b].date.getTime() - rows[a].date.getTime());
  }, [rows]);

  const totals = useMemo(() => {
    return results.reduce((acc, { row, result: r }) => ({
      customsValue: acc.customsValue + (r?.customsValue ?? 0),
      totalDuty: acc.totalDuty + (r?.totalDuty ?? 0),
      mpf: acc.mpf + (r?.mpf ?? 0),
      hmf: acc.hmf + (r?.hmf ?? 0),
      totalFees: acc.totalFees + (r?.totalFees ?? 0),
      freight: acc.freight + (row.freight ?? 0),
      insurance: acc.insurance + (row.insurance ?? 0),
      landedCost: acc.landedCost + (r?.landedCost ?? 0),
      count: acc.count + (r ? 1 : 0),
    }), { customsValue: 0, totalDuty: 0, mpf: 0, hmf: 0, totalFees: 0, freight: 0, insurance: 0, landedCost: 0, count: 0 });
  }, [results]);

  const hasResults = totals.count > 0;

  const handleExportCSV = useCallback(() => {
    const exportRows = results.filter(r => r.result).map(r => ({
      date: r.row.date,
      customsValue: r.row.customsValue,
      result: r.result!,
    }));
    exportShipmentsCSV(exportRows, htsCode, countryName);
  }, [results, htsCode, countryName]);

  if (!currentRate && rates.length === 0) {
    return (
      <Card>
        <CardContent className="p-5">
          <div className="flex items-center gap-2 mb-3">
            <Calculator className="h-4 w-4 text-[#353CED]" />
            <h3 className="font-semibold text-sm text-gray-900">Duty Calculator</h3>
          </div>
          <p className="text-sm text-gray-400">Look up a duty rate to enable calculation.</p>
        </CardContent>
      </Card>
    );
  }

  return (
    <>
      <Card>
        <CardContent className="p-5">
          {/* Header */}
          <div className="flex items-center justify-between mb-5">
            <div className="flex items-center gap-2">
              <div className="w-6 h-6 rounded-lg bg-[#353CED]/6 flex items-center justify-center">
                <Calculator className="h-3.5 w-3.5 text-[#353CED]" />
              </div>
              <h3 className="font-semibold text-sm text-gray-900 tracking-[-0.01em]">Duty Calculator</h3>
            </div>
            <div className="flex items-center gap-2">
              <Button variant="outline" size="sm" onClick={() => setImportOpen(true)} className="h-7 text-xs gap-1.5">
                <Upload className="h-3 w-3" /> Bulk Import
              </Button>
              <Button variant="outline" size="sm" onClick={handleExportCSV} className="h-7 text-xs gap-1.5"
                disabled={!hasResults}>
                <Download className="h-3 w-3" /> Export CSV
              </Button>
            </div>
          </div>

          {/* Transport mode selector */}
          <div className="mb-5">
            <div className="flex items-center gap-1.5 mb-2">
              <span className="text-[11px] font-medium text-gray-500 uppercase tracking-wider">Method of Entry</span>
              <div className="group relative">
                <Info className="h-3 w-3 text-gray-400 cursor-help" />
                <div className="absolute bottom-full left-1/2 -translate-x-1/2 mb-2 px-3 py-2 bg-gray-900 text-white text-[10px] rounded-lg whitespace-nowrap opacity-0 group-hover:opacity-100 transition-opacity pointer-events-none z-50">
                  HMF (0.125%) applies to ocean freight only.<br />
                  MPF (0.3464%) applies to all modes (min ${MPF_MIN} / max ${MPF_MAX}).
                </div>
              </div>
            </div>
            <div className="inline-flex items-center h-9 rounded-xl p-1 bg-white gap-0.5" style={{ boxShadow: 'inset 1px 1px 4px rgba(0,0,0,0.05), inset -1px -1px 4px rgba(255,255,255,0.85)' }}>
              {(Object.entries(TRANSPORT_LABELS) as [TransportMode, typeof TRANSPORT_LABELS['ocean']][]).map(([mode, { label, icon: Icon }]) => (
                <button key={mode} type="button" onClick={() => setTransportMode(mode)}
                  className={cn(
                    'inline-flex items-center h-7 gap-1.5 rounded-lg px-3 text-xs font-medium transition-all duration-200 ease-spring',
                    'text-gray-400 hover:text-gray-600',
                    transportMode === mode && 'shadow-glass text-[#353CED] bg-white'
                  )}>
                  <Icon className="h-3.5 w-3.5" />{label}
                </button>
              ))}
            </div>
          </div>

          {/* Shipment rows — column headers */}
          <div className="space-y-2.5 mb-5">
            <div className="grid grid-cols-[minmax(0,1fr)_180px_minmax(0,1fr)_32px] gap-3 mb-1">
              <span className="text-[11px] font-medium text-gray-500 flex items-center gap-1 uppercase tracking-wider">
                <DollarSign className="h-3 w-3" /> Value (USD)
              </span>
              <span className="text-[11px] font-medium text-gray-500 flex items-center gap-1 uppercase tracking-wider">
                <Globe className="h-3 w-3" /> Origin
              </span>
              <div className="flex items-center justify-between">
                <span className="text-[11px] font-medium text-gray-500 flex items-center gap-1 uppercase tracking-wider">
                  <CalendarDays className="h-3 w-3" /> Date
                </span>
                {rows.length > 1 && (
                  <button type="button" onClick={sortByDate} title="Sort by date (newest first)"
                    className="h-5 w-5 flex items-center justify-center rounded text-gray-400 hover:text-[#353CED] transition-colors">
                    <ArrowDownUp className="h-3 w-3" />
                  </button>
                )}
              </div>
              <span />
            </div>

            {rows.map(row => {
              const rowCountry = row.countryCode ? countryMap.get(row.countryCode) ?? null : selectedCountry;
              const cc = row.countryCode || defaultCountryCode;
              const rowRates = rateCache.get(cc) ?? (cc === defaultCountryCode ? rates : []);
              const dateStr = row.date.toISOString().slice(0, 10);
              const rowRate = findRateForDate(rowRates, dateStr) ?? (cc === defaultCountryCode ? currentRate : null);
              const needsQuantity = rowRate?.is_qty_duty_relevant === true;
              return (
                <React.Fragment key={row.id}>
                <div className="grid grid-cols-[minmax(0,1fr)_180px_minmax(0,1fr)_32px] gap-3 items-center">
                  <Input type="number" value={row.customsValue || ''} min={0}
                    onChange={(e) => updateRow(row.id, { customsValue: Number(e.target.value) })}
                    className="h-9 text-sm font-mono" placeholder="50,000" />
                  <CountryAutocomplete
                    countries={countries}
                    value={rowCountry}
                    onChange={(c) => {
                      if (c) updateRowCountry(row.id, c.code);
                    }}
                    placeholder="Country..."
                    className="[&_input]:h-9 [&_input]:text-[11px]"
                  />
                  <DatePickerNeu
                    date={row.date}
                    onSelect={(d) => updateRow(row.id, { date: d })}
                    minDate={new Date(2025, 0, 1)}
                    maxDate={new Date(2026, 11, 31)}
                  />
                  <button type="button" onClick={() => removeRow(row.id)} disabled={rows.length <= 1}
                    title="Remove shipment"
                    className={cn(
                      'h-8 w-8 flex items-center justify-center rounded-lg transition-all duration-300',
                      rows.length <= 1
                        ? 'text-gray-300 cursor-not-allowed opacity-50'
                        : 'text-gray-400 hover:text-red-500 shadow-[2px_2px_4px_rgba(0,0,0,0.08),_-2px_-2px_4px_rgba(255,255,255,0.9)] hover:shadow-[inset_2px_2px_5px_rgba(0,0,0,0.07),_inset_-2px_-2px_5px_rgba(255,255,255,0.9)] bg-white'
                    )}>
                    <Trash2 className="h-3.5 w-3.5" />
                  </button>
                </div>
                {needsQuantity && (
                  <div className="ml-4 flex items-center gap-2 text-xs">
                    <Package className="h-3 w-3 text-amber-500 flex-shrink-0" />
                    <span className="text-gray-500 flex-shrink-0">Quantity ({rowRate?.duty_basis_unit || 'units'}):</span>
                    <Input type="number" value={row.quantity ?? ''} min={0}
                      onChange={(e) => updateRow(row.id, { quantity: Number(e.target.value) || undefined })}
                      className="h-7 text-xs font-mono w-32" placeholder="Enter quantity" />
                    {!row.quantity && (
                      <span className="text-amber-600 text-[10px] italic">Required for {rowRate?.rate_basis} duty</span>
                    )}
                  </div>
                )}
                {/* Freight & Insurance */}
                <div className="ml-4 flex items-center gap-4 text-xs">
                  <div className="flex items-center gap-1.5">
                    <Container className="h-3 w-3 text-gray-400 flex-shrink-0" />
                    <span className="text-gray-500 flex-shrink-0">Freight:</span>
                    <Input type="number" value={row.freight ?? ''} min={0}
                      onChange={(e) => updateRow(row.id, { freight: Number(e.target.value) || undefined })}
                      className="h-7 text-xs font-mono w-28" placeholder="0.00" />
                  </div>
                  <div className="flex items-center gap-1.5">
                    <ShieldCheck className="h-3 w-3 text-gray-400 flex-shrink-0" />
                    <span className="text-gray-500 flex-shrink-0">Insurance:</span>
                    <Input type="number" value={row.insurance ?? ''} min={0}
                      onChange={(e) => updateRow(row.id, { insurance: Number(e.target.value) || undefined })}
                      className="h-7 text-xs font-mono w-28" placeholder="0.00" />
                  </div>
                </div>
                {/* Authority-specific composition fields */}
                {rowRate && (() => {
                  const triggers = detectAuthorityTriggers(rowRate, cc);
                  if (triggers.length === 0) return null;
                  return (
                    <div className="ml-4 space-y-2 mt-1">
                      {triggers.map(trigger => {
                        const authorityColor = trigger.authority === 'rate_232' ? '#ff7c43'
                          : trigger.authority === 'rate_ieepa_recip' ? '#665191' : '#008dff';
                        return (
                          <div key={trigger.authority} className="rounded-lg border-l-2 bg-gray-50/50 px-3 py-2"
                            style={{ borderLeftColor: authorityColor }}>
                            <div className="text-[10px] font-medium text-gray-500 mb-1.5">{trigger.label}</div>
                            <div className="flex flex-wrap items-center gap-2">
                              {trigger.fields.map(field => (
                                <div key={field.key} className="flex items-center gap-1.5">
                                  <span className="text-[10px] text-gray-400 whitespace-nowrap">{field.label}:</span>
                                  {field.type === 'country' ? (
                                    <CountryAutocomplete
                                      countries={countries}
                                      value={row.composition?.[field.key] ? countryMap.get(row.composition[field.key] as string) ?? null : null}
                                      onChange={(c) => updateRowComposition(row.id, field.key, c?.code)}
                                      placeholder="Select..."
                                      className="[&_input]:h-6 [&_input]:text-[10px] w-32"
                                    />
                                  ) : (
                                    <Input
                                      type="number"
                                      value={row.composition?.[field.key] ?? ''}
                                      min={0}
                                      max={field.type === 'percent' ? 1 : undefined}
                                      step={field.type === 'percent' ? 0.01 : undefined}
                                      onChange={(e) => {
                                        const v = e.target.value === '' ? undefined : Number(e.target.value);
                                        updateRowComposition(row.id, field.key, v);
                                      }}
                                      className="h-6 text-[10px] font-mono w-24"
                                      placeholder={field.type === 'percent' ? '0.00–1.00' : '0'}
                                    />
                                  )}
                                  <div className="group relative">
                                    <Info className="h-3 w-3 text-gray-300 cursor-help" />
                                    <div className="absolute bottom-full left-1/2 -translate-x-1/2 mb-2 px-2.5 py-1.5 bg-gray-900 text-white text-[10px] rounded-lg w-48 opacity-0 group-hover:opacity-100 transition-opacity pointer-events-none z-50">
                                      {field.hint}
                                    </div>
                                  </div>
                                </div>
                              ))}
                            </div>
                          </div>
                        );
                      })}
                    </div>
                  );
                })()}
                </React.Fragment>
              );
            })}

            <Button variant="outline" size="sm" onClick={addRow} className="text-xs gap-1.5 w-full border-dashed h-9 text-gray-400 hover:text-[#353CED] hover:border-[#353CED]/20">
              <Plus className="h-3 w-3" /> Add Shipment
            </Button>
          </div>

          {/* Results table */}
          {hasResults && (
            <div className="rounded-xl border border-gray-200/80 overflow-hidden">
              <table className="w-full text-sm">
                <thead>
                  <tr className="bg-gray-50/80 text-xs text-gray-500 font-medium">
                    <th className="text-left px-3 py-2 w-7"><span className="sr-only">Expand</span></th>
                    <th className="text-left px-3 py-2">Shipment Value</th>
                    <th className="text-left px-3 py-2">Country</th>
                    <th className="text-left px-3 py-2">Date</th>
                    <th className="text-right px-3 py-2">Duty</th>
                    <th className="text-right px-3 py-2">Fees</th>
                    <th className="text-right px-3 py-2">Landed Cost</th>
                  </tr>
                </thead>
                <tbody>
                  {sortedIndices.map(i => {
                    const { row, result: r, rate, countryCode: cc, matchKind } = results[i];
                    const rowCountryObj = cc ? countryMap.get(cc) : null;
                    const isSynth = matchKind === 'base_mfn_synthesized';
                    if (!r || !rate) {
                      // Show row even when rate is unavailable
                      return (
                        <tr key={row.id} className="border-t border-gray-100">
                          <td className="px-2 py-2 text-gray-300"><ChevronRight className="h-3.5 w-3.5" /></td>
                          <td className="px-3 py-2 font-mono text-gray-700">{formatCurrency(row.customsValue)}</td>
                          <td className="px-3 py-2 text-gray-500 text-xs">{rowCountryObj?.name ?? cc ?? '—'}</td>
                          <td className="px-3 py-2 text-gray-600">{formatDate(row.date.toISOString().slice(0, 10))}</td>
                          <td colSpan={3} className="px-3 py-2 text-right text-xs text-amber-500 italic">
                            {rateCache.has(cc ?? '') || cc === defaultCountryCode
                              ? 'No rate for this date'
                              : 'Loading rate...'}
                          </td>
                        </tr>
                      );
                    }
                    const isExpanded = expandedRows.has(row.id);
                    return (
                      <React.Fragment key={row.id}>
                        <tr className="border-t border-gray-100 cursor-pointer hover:bg-gray-50/50 transition-colors"
                          onClick={() => toggleExpand(row.id)}>
                          <td className="px-2 py-2 text-gray-400">
                            {isExpanded ? <ChevronDown className="h-3.5 w-3.5" /> : <ChevronRight className="h-3.5 w-3.5" />}
                          </td>
                          <td className="px-3 py-2 font-mono text-gray-700">{formatCurrency(r.customsValue)}</td>
                          <td className="px-3 py-2 text-xs text-gray-500">{rowCountryObj?.name ?? cc}</td>
                          <td className="px-3 py-2 text-gray-600">{formatDate(row.date.toISOString().slice(0, 10))}</td>
                          <td className="px-3 py-2 text-right font-mono text-red-600">
                            {formatCurrency(r.totalDuty)}
                            {isSynth && (
                              <div className="text-[9px] text-sky-600 italic font-sans font-normal mt-0.5 whitespace-nowrap">
                                MFN only — no Ch. 99 duties
                              </div>
                            )}
                          </td>
                          <td className="px-3 py-2 text-right font-mono text-amber-600">{formatCurrency(r.totalFees)}</td>
                          <td className="px-3 py-2 text-right font-mono font-medium text-gray-900">{formatCurrency(r.landedCost)}</td>
                        </tr>

                        {isExpanded && (
                          <>
                            <tr className="bg-slate-50/50">
                              <td />
                              <td colSpan={6} className="px-3 py-1 text-[10px] text-gray-400">
                                Rate period: {r.ratePeriod} &middot; Basis: Ad Valorem &middot; Rev: {rate.revision}
                                {rowCountryObj && <> &middot; Origin: {rowCountryObj.name}</>}
                              </td>
                            </tr>

                            {r.breakdown.map((b, bi) => {
                              const isBaseTier = !b.ch99Code;
                              const fmtRate = isBaseTier ? formatRate : formatRateShort;
                              return (
                              <tr key={bi} className="bg-slate-50/50">
                                <td />
                                <td colSpan={3} className="px-3 py-1 text-xs text-gray-500 pl-6">
                                  <div className="flex items-center gap-1.5">
                                    <div className="w-2 h-2 rounded-full flex-shrink-0" style={{ backgroundColor: b.color }} />
                                    <span>{b.authority}</span>
                                    {b.ch99Code && <span className="text-[10px] font-mono text-[#353CED]">({b.ch99Code})</span>}
                                  </div>
                                  {b.statutoryRate != null && Math.abs(b.statutoryRate - b.rate) > 0.00001 && (
                                    <div className="text-[10px] text-gray-400 ml-3.5 mt-0.5">
                                      Statutory {fmtRate(b.statutoryRate)} → Effective {fmtRate(b.rate)}
                                    </div>
                                  )}
                                  {b.isMetalScaled && b.grossRate != null && b.nonmetalShare != null && (
                                    <div className="text-[10px] text-amber-500 ml-3.5 mt-0.5">
                                      {formatRateShort(b.grossRate)} × {(b.nonmetalShare * 100).toFixed(0)}% non-metal = {formatRateShort(b.rate)}
                                    </div>
                                  )}
                                </td>
                                <td className="px-3 py-1 text-right font-mono text-xs text-gray-600">
                                  <span className="text-gray-400 mr-1.5">({fmtRate(b.rate)})</span>
                                  {formatCurrency(b.dutyAmount)}
                                </td>
                                <td />
                                <td />
                              </tr>
                              );
                            })}

                            <tr className="bg-slate-50/50 border-t border-gray-100/60">
                              <td />
                              <td colSpan={3} className="px-3 py-1 text-xs font-medium text-gray-600 pl-6">Total Duty</td>
                              <td className="px-3 py-1 text-right font-mono text-xs font-medium text-red-600">{formatCurrency(r.totalDuty)}</td>
                              <td /><td />
                            </tr>

                            <tr className="bg-slate-50/50">
                              <td />
                              <td colSpan={3} className="px-3 py-1 text-xs text-gray-500 pl-6">
                                <span>MPF</span>
                                <span className="text-gray-400 ml-1.5">(0.3464% &middot; min {formatCurrency(MPF_MIN)} / max {formatCurrency(MPF_MAX)})</span>
                              </td>
                              <td />
                              <td className="px-3 py-1 text-right font-mono text-xs text-amber-600">{formatCurrency(r.mpf)}</td>
                              <td />
                            </tr>

                            <tr className="bg-slate-50/50">
                              <td />
                              <td colSpan={3} className="px-3 py-1 text-xs text-gray-500 pl-6">
                                <span>HMF</span>
                                {transportMode === 'ocean' ? (
                                  <span className="text-gray-400 ml-1.5">(0.125%)</span>
                                ) : (
                                  <span className="ml-1.5 text-[10px] text-gray-300 italic">Ocean only — N/A</span>
                                )}
                              </td>
                              <td />
                              <td className="px-3 py-1 text-right font-mono text-xs text-amber-600">
                                {r.hmf > 0 ? formatCurrency(r.hmf) : '—'}
                              </td>
                              <td />
                            </tr>

                            <tr className="bg-slate-50/50 border-t border-gray-100/60">
                              <td />
                              <td colSpan={3} className="px-3 py-1 text-xs font-medium text-gray-600 pl-6">Total Fees</td>
                              <td />
                              <td className="px-3 py-1 text-right font-mono text-xs font-medium text-amber-600">{formatCurrency(r.totalFees)}</td>
                              <td />
                            </tr>

                            {(row.freight != null && row.freight > 0) && (
                              <tr className="bg-slate-50/50">
                                <td />
                                <td colSpan={3} className="px-3 py-1 text-xs text-gray-500 pl-6">
                                  <span>Freight</span>
                                </td>
                                <td /><td />
                                <td className="px-3 py-1 text-right font-mono text-xs text-gray-500">{formatCurrency(row.freight)}</td>
                              </tr>
                            )}

                            {(row.insurance != null && row.insurance > 0) && (
                              <tr className="bg-slate-50/50">
                                <td />
                                <td colSpan={3} className="px-3 py-1 text-xs text-gray-500 pl-6">
                                  <span>Insurance</span>
                                </td>
                                <td /><td />
                                <td className="px-3 py-1 text-right font-mono text-xs text-gray-500">{formatCurrency(row.insurance)}</td>
                              </tr>
                            )}

                            <tr className="bg-blue-50/30 border-t border-gray-100">
                              <td />
                              <td colSpan={3} className="px-3 py-1.5 text-xs font-semibold text-gray-700 pl-6">Landed Cost</td>
                              <td /><td />
                              <td className="px-3 py-1.5 text-right font-mono text-xs font-bold text-gray-900">{formatCurrency(r.landedCost)}</td>
                            </tr>
                          </>
                        )}
                      </React.Fragment>
                    );
                  })}
                </tbody>
                <tfoot>
                  <tr className="border-t-2 border-gray-200 bg-gradient-to-r from-gray-50 to-blue-50/30">
                    <td />
                    <td className="px-3 py-2.5 font-medium text-gray-700" colSpan={2}>
                      Total ({totals.count} shipment{totals.count !== 1 ? 's' : ''})
                    </td>
                    <td className="px-3 py-2.5 font-mono text-xs text-gray-400">{formatCurrency(totals.customsValue)}</td>
                    <td className="px-3 py-2.5 text-right font-mono font-bold text-red-600">{formatCurrency(totals.totalDuty)}</td>
                    <td className="px-3 py-2.5 text-right font-mono font-bold text-amber-600">{formatCurrency(totals.totalFees)}</td>
                    <td className="px-3 py-2.5 text-right font-mono font-bold text-gray-900">{formatCurrency(totals.landedCost)}</td>
                  </tr>
                </tfoot>
              </table>
            </div>
          )}

          {/* Fee reference */}
          {hasResults && (
            <div className="mt-3 rounded-lg bg-gray-50 px-3.5 py-2.5 text-[10px] text-gray-400 leading-relaxed space-y-1">
              <div className="grid grid-cols-1 sm:grid-cols-2 gap-x-6 gap-y-0.5">
                <div><span className="font-medium text-gray-500">HMF</span> — 0.125% of cargo value, ocean freight only, no min/max</div>
                <div><span className="font-medium text-gray-500">MPF</span> — 0.3464% of merch. value, all modes, min {formatCurrency(MPF_MIN)} / max {formatCurrency(MPF_MAX)}</div>
              </div>
              <p className="text-gray-300">Fees are based on entered value of goods, excluding international freight, insurance, and duties. FY 2026 rates.</p>
            </div>
          )}

          {!hasResults && rows.some(r => r.customsValue > 0) && (
            <p className="text-xs text-gray-400 text-center py-3">
              Enter a valid shipment value to calculate duty.
            </p>
          )}
        </CardContent>
      </Card>

      <ShipmentImportDialog
        open={importOpen}
        onClose={() => setImportOpen(false)}
        onImport={handleImport}
        minDate={new Date(2025, 0, 1)}
        maxDate={new Date(2026, 11, 31)}
      />
    </>
  );
}
