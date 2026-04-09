import React, { useState, useMemo, useCallback } from 'react';
import { Card, CardContent } from '@/components/ui/card';
import { Input } from '@/components/ui/input';
import { Button } from '@/components/ui/button';
import { DatePickerNeu } from './DatePickerNeu';
import { ShipmentImportDialog } from './ShipmentImportDialog';
import type { ProductRate, ShipmentRow } from '@/types/tariff';
import {
  calculateLandedCost, findRateForDate, MPF_RATE, MPF_MIN, MPF_MAX, HMF_RATE,
  exportShipmentsCSV,
} from '@/utils/tariffCalculator';
import { formatCurrency, formatRateShort, formatDate } from '@/utils/formatters';
import {
  Calculator, Plus, Trash2, Ship, Plane, Truck, ChevronDown, ChevronRight,
  Download, Upload, Info, ArrowDownUp, DollarSign, CalendarDays,
} from 'lucide-react';
import { cn } from '@/lib/utils';

interface DutyCalculatorPanelProps {
  rates: ProductRate[];
  currentRate: ProductRate | null;
  countryName: string;
  htsCode: string;
}

type TransportMode = 'ocean' | 'air' | 'land';

const TRANSPORT_LABELS: Record<TransportMode, { label: string; icon: React.ElementType }> = {
  ocean: { label: 'Ocean', icon: Ship },
  air:   { label: 'Air',   icon: Plane },
  land:  { label: 'Land',  icon: Truck },
};

export function DutyCalculatorPanel({ rates, currentRate, countryName, htsCode }: DutyCalculatorPanelProps) {
  const [rows, setRows] = useState<ShipmentRow[]>([
    { id: '1', customsValue: 50000, date: new Date() },
  ]);
  const [transportMode, setTransportMode] = useState<TransportMode>('ocean');
  const [expandedRows, setExpandedRows] = useState<Set<string>>(new Set());
  const [importOpen, setImportOpen] = useState(false);

  const addRow = useCallback(() => {
    setRows(prev => [...prev, { id: String(Date.now()), customsValue: 0, date: new Date() }]);
  }, []);

  const removeRow = useCallback((id: string) => {
    setRows(prev => prev.length > 1 ? prev.filter(r => r.id !== id) : prev);
  }, []);

  const updateRow = useCallback((id: string, updates: Partial<ShipmentRow>) => {
    setRows(prev => prev.map(r => r.id === id ? { ...r, ...updates } : r));
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
    setRows(prev => [...prev, ...imported]);
  }, []);

  const results = useMemo(() => {
    return rows.map(row => {
      const dateStr = row.date.toISOString().slice(0, 10);
      const applicableRate = findRateForDate(rates, dateStr) ?? currentRate;
      if (!applicableRate) return { row, result: null, rate: null };
      return {
        row,
        rate: applicableRate,
        result: calculateLandedCost(applicableRate, row.customsValue, {
          includeHMF: transportMode === 'ocean',
          freight: row.freight ?? 0,
          insurance: row.insurance ?? 0,
        }),
      };
    });
  }, [rows, rates, currentRate, transportMode]);

  // Sorted indices — descending by date (newest first)
  const sortedIndices = useMemo(() => {
    return rows
      .map((_, i) => i)
      .sort((a, b) => rows[b].date.getTime() - rows[a].date.getTime());
  }, [rows]);

  const totals = useMemo(() => {
    return results.reduce((acc, { result: r }) => ({
      customsValue: acc.customsValue + (r?.customsValue ?? 0),
      totalDuty: acc.totalDuty + (r?.totalDuty ?? 0),
      mpf: acc.mpf + (r?.mpf ?? 0),
      hmf: acc.hmf + (r?.hmf ?? 0),
      totalFees: acc.totalFees + (r?.totalFees ?? 0),
      landedCost: acc.landedCost + (r?.landedCost ?? 0),
      count: acc.count + (r ? 1 : 0),
    }), { customsValue: 0, totalDuty: 0, mpf: 0, hmf: 0, totalFees: 0, landedCost: 0, count: 0 });
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
          <div className="flex items-center justify-between mb-4">
            <div className="flex items-center gap-2">
              <Calculator className="h-4 w-4 text-[#353CED]" />
              <h3 className="font-semibold text-sm text-gray-900">Duty Calculator</h3>
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
          <div className="mb-4">
            <div className="flex items-center gap-1 mb-1.5">
              <span className="text-xs font-medium text-gray-500">Method of Entry</span>
              <div className="group relative">
                <Info className="h-3 w-3 text-gray-400 cursor-help" />
                <div className="absolute bottom-full left-1/2 -translate-x-1/2 mb-2 px-3 py-2 bg-gray-900 text-white text-[10px] rounded-lg whitespace-nowrap opacity-0 group-hover:opacity-100 transition-opacity pointer-events-none z-50">
                  HMF (0.125%) applies to ocean freight only.<br />
                  MPF (0.3464%) applies to all modes (min ${MPF_MIN} / max ${MPF_MAX}).
                </div>
              </div>
            </div>
            <div className="inline-flex items-center h-9 rounded-lg p-1 shadow-[2px_2px_4px_rgba(0,0,0,0.08),_-2px_-2px_4px_rgba(255,255,255,0.9)] bg-white gap-0.5">
              {(Object.entries(TRANSPORT_LABELS) as [TransportMode, typeof TRANSPORT_LABELS['ocean']][]).map(([mode, { label, icon: Icon }]) => (
                <button key={mode} type="button" onClick={() => setTransportMode(mode)}
                  className={cn(
                    'inline-flex items-center h-7 gap-1.5 rounded-md px-3 text-xs font-medium transition-all duration-300',
                    'text-gray-500 hover:text-[#353CED]',
                    transportMode === mode
                      ? 'shadow-[inset_2px_2px_5px_rgba(0,0,0,0.07),_inset_-2px_-2px_5px_rgba(255,255,255,0.9)] text-[#353CED]'
                      : ''
                  )}>
                  <Icon className="h-3.5 w-3.5" />{label}
                </button>
              ))}
            </div>
          </div>

          {/* Shipment rows */}
          <div className="space-y-2.5 mb-4">
            <div className="grid grid-cols-[1fr_1fr_32px] gap-3 mb-1">
              <span className="text-xs font-medium text-gray-500 flex items-center gap-1">
                <DollarSign className="h-3 w-3" /> Shipment Value (USD)
              </span>
              <div className="flex items-center justify-between">
                <span className="text-xs font-medium text-gray-500 flex items-center gap-1">
                  <CalendarDays className="h-3 w-3" /> Shipment Date
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

            {rows.map(row => (
              <div key={row.id} className="grid grid-cols-[1fr_1fr_32px] gap-3 items-center">
                <Input type="number" value={row.customsValue || ''} min={0}
                  onChange={(e) => updateRow(row.id, { customsValue: Number(e.target.value) })}
                  className="h-9 text-sm font-mono" placeholder="50,000" />
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
            ))}

            <Button variant="outline" size="sm" onClick={addRow} className="text-xs gap-1.5 w-full border-dashed h-8">
              <Plus className="h-3 w-3" /> Add Shipment
            </Button>
          </div>

          {/* Results table */}
          {hasResults && (
            <div className="rounded-lg border border-gray-200 overflow-hidden">
              <table className="w-full text-sm">
                <thead>
                  <tr className="bg-gray-50 text-xs text-gray-500 font-medium">
                    <th className="text-left px-3 py-2 w-7"><span className="sr-only">Expand</span></th>
                    <th className="text-left px-3 py-2">Shipment Value</th>
                    <th className="text-left px-3 py-2">Date</th>
                    <th className="text-right px-3 py-2">Duty</th>
                    <th className="text-right px-3 py-2">Fees</th>
                    <th className="text-right px-3 py-2">Landed Cost</th>
                  </tr>
                </thead>
                <tbody>
                  {sortedIndices.map(i => {
                    const { row, result: r, rate } = results[i];
                    if (!r || !rate) return null;
                    const isExpanded = expandedRows.has(row.id);
                    return (
                      <React.Fragment key={row.id}>
                        {/* Summary row — click to expand */}
                        <tr className="border-t border-gray-100 cursor-pointer hover:bg-gray-50/50 transition-colors"
                          onClick={() => toggleExpand(row.id)}>
                          <td className="px-2 py-2 text-gray-400">
                            {isExpanded
                              ? <ChevronDown className="h-3.5 w-3.5" />
                              : <ChevronRight className="h-3.5 w-3.5" />}
                          </td>
                          <td className="px-3 py-2 font-mono text-gray-700">{formatCurrency(r.customsValue)}</td>
                          <td className="px-3 py-2 text-gray-600">{formatDate(row.date.toISOString().slice(0, 10))}</td>
                          <td className="px-3 py-2 text-right font-mono text-red-600">{formatCurrency(r.totalDuty)}</td>
                          <td className="px-3 py-2 text-right font-mono text-amber-600">{formatCurrency(r.totalFees)}</td>
                          <td className="px-3 py-2 text-right font-mono font-medium text-gray-900">{formatCurrency(r.landedCost)}</td>
                        </tr>

                        {/* Expanded breakdown */}
                        {isExpanded && (
                          <>
                            {/* Rate period metadata */}
                            <tr className="bg-slate-50/50">
                              <td />
                              <td colSpan={5} className="px-3 py-1 text-[10px] text-gray-400">
                                Rate period: {r.ratePeriod} &middot; Basis: Ad Valorem &middot; Rev: {rate.revision}
                              </td>
                            </tr>

                            {/* Duty component breakdown */}
                            {r.breakdown.map((b, bi) => (
                              <tr key={bi} className="bg-slate-50/50">
                                <td />
                                <td colSpan={2} className="px-3 py-1 text-xs text-gray-500 pl-6">
                                  <div className="flex items-center gap-1.5">
                                    <div className="w-2 h-2 rounded-full flex-shrink-0" style={{ backgroundColor: b.color }} />
                                    <span>{b.authority}</span>
                                    {b.ch99Code && <span className="text-[10px] font-mono text-[#353CED]">({b.ch99Code})</span>}
                                  </div>
                                  {b.statutoryRate != null && Math.abs(b.statutoryRate - b.rate) > 0.00001 && (
                                    <div className="text-[10px] text-gray-400 ml-3.5 mt-0.5">
                                      Statutory {formatRateShort(b.statutoryRate)} → Effective {formatRateShort(b.rate)}
                                    </div>
                                  )}
                                </td>
                                <td className="px-3 py-1 text-right font-mono text-xs text-gray-600">
                                  <span className="text-gray-400 mr-1.5">({formatRateShort(b.rate)})</span>
                                  {formatCurrency(b.dutyAmount)}
                                </td>
                                <td />
                                <td />
                              </tr>
                            ))}

                            {/* Duty subtotal */}
                            <tr className="bg-slate-50/50 border-t border-gray-100/60">
                              <td />
                              <td colSpan={2} className="px-3 py-1 text-xs font-medium text-gray-600 pl-6">
                                Total Duty
                              </td>
                              <td className="px-3 py-1 text-right font-mono text-xs font-medium text-red-600">{formatCurrency(r.totalDuty)}</td>
                              <td />
                              <td />
                            </tr>

                            {/* MPF */}
                            <tr className="bg-slate-50/50">
                              <td />
                              <td colSpan={2} className="px-3 py-1 text-xs text-gray-500 pl-6">
                                <span>MPF</span>
                                <span className="text-gray-400 ml-1.5">
                                  (0.3464% &middot; min {formatCurrency(MPF_MIN)} / max {formatCurrency(MPF_MAX)})
                                </span>
                              </td>
                              <td />
                              <td className="px-3 py-1 text-right font-mono text-xs text-amber-600">{formatCurrency(r.mpf)}</td>
                              <td />
                            </tr>

                            {/* HMF */}
                            <tr className="bg-slate-50/50">
                              <td />
                              <td colSpan={2} className="px-3 py-1 text-xs text-gray-500 pl-6">
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

                            {/* Total Fees subtotal */}
                            <tr className="bg-slate-50/50 border-t border-gray-100/60">
                              <td />
                              <td colSpan={2} className="px-3 py-1 text-xs font-medium text-gray-600 pl-6">
                                Total Fees
                              </td>
                              <td />
                              <td className="px-3 py-1 text-right font-mono text-xs font-medium text-amber-600">{formatCurrency(r.totalFees)}</td>
                              <td />
                            </tr>

                            {/* Landed cost */}
                            <tr className="bg-blue-50/30 border-t border-gray-100">
                              <td />
                              <td colSpan={2} className="px-3 py-1.5 text-xs font-semibold text-gray-700 pl-6">
                                Landed Cost
                              </td>
                              <td />
                              <td />
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
                    <td className="px-3 py-2.5 font-medium text-gray-700">
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

          {/* Fee reference note */}
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
