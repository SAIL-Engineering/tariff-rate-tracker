import React, { useState, useMemo, useCallback } from 'react';
import { Card, CardContent } from '@/components/ui/card';
import { Input } from '@/components/ui/input';
import { Button } from '@/components/ui/button';
import { Badge } from '@/components/ui/badge';
import { DatePickerNeu } from './DatePickerNeu';
import { ShipmentImportDialog } from './ShipmentImportDialog';
import type { ProductRate, ShipmentRow } from '@/types/tariff';
import { AUTHORITIES } from '@/types/tariff';
import {
  calculateLandedCost, findRateForDate, MPF_RATE, MPF_MIN, MPF_MAX, HMF_RATE,
  exportShipmentsCSV,
} from '@/utils/tariffCalculator';
import { formatCurrency, formatRateShort, formatDate, formatHtsCode } from '@/utils/formatters';
import {
  Calculator, Plus, Trash2, Ship, Plane, Truck, ChevronDown, ChevronUp,
  Download, Upload, Info, ArrowDownUp,
} from 'lucide-react';
import { cn } from '@/lib/utils';

interface DutyCalculatorPanelProps {
  rates: ProductRate[];
  currentRate: ProductRate | null;
  countryName: string;
  htsCode: string;
}

const neuInsetShadow = 'inset 2px 2px 5px rgba(0,0,0,0.07), inset -2px -2px 5px rgba(255,255,255,0.9)';

export function DutyCalculatorPanel({ rates, currentRate, countryName, htsCode }: DutyCalculatorPanelProps) {
  const [rows, setRows] = useState<ShipmentRow[]>([
    { id: '1', customsValue: 50000, date: new Date() },
  ]);
  const [transportMode, setTransportMode] = useState<'ocean' | 'air' | 'land'>('ocean');
  const [expandedRows, setExpandedRows] = useState<Set<string>>(new Set());
  const [importOpen, setImportOpen] = useState(false);

  const addRow = () => {
    setRows(prev => [...prev, { id: String(Date.now()), customsValue: 0, date: new Date() }]);
  };

  const removeRow = (id: string) => {
    if (rows.length <= 1) return;
    setRows(prev => prev.filter(r => r.id !== id));
  };

  const updateRow = (id: string, updates: Partial<ShipmentRow>) => {
    setRows(prev => prev.map(r => r.id === id ? { ...r, ...updates } : r));
  };

  const toggleExpand = (id: string) => {
    setExpandedRows(prev => {
      const next = new Set(prev);
      next.has(id) ? next.delete(id) : next.add(id);
      return next;
    });
  };

  const sortByDate = () => {
    setRows(prev => [...prev].sort((a, b) => b.date.getTime() - a.date.getTime()));
  };

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

  const totals = useMemo(() => {
    return results.reduce((acc, { result: r }) => ({
      customsValue: acc.customsValue + (r?.customsValue ?? 0),
      totalDuty: acc.totalDuty + (r?.totalDuty ?? 0),
      mpf: acc.mpf + (r?.mpf ?? 0),
      hmf: acc.hmf + (r?.hmf ?? 0),
      totalFees: acc.totalFees + (r?.totalFees ?? 0),
      landedCost: acc.landedCost + (r?.landedCost ?? 0),
    }), { customsValue: 0, totalDuty: 0, mpf: 0, hmf: 0, totalFees: 0, landedCost: 0 });
  }, [results]);

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
        <CardContent className="p-5 space-y-4">
          {/* Header */}
          <div className="flex items-center justify-between">
            <div className="flex items-center gap-2">
              <Calculator className="h-4 w-4 text-[#353CED]" />
              <h3 className="font-semibold text-sm text-gray-900">Duty Calculator</h3>
            </div>
            <div className="flex items-center gap-2">
              <Button variant="outline" size="sm" onClick={() => setImportOpen(true)} className="h-7 text-xs gap-1.5">
                <Upload className="h-3 w-3" /> Import
              </Button>
              <Button variant="outline" size="sm" onClick={handleExportCSV} className="h-7 text-xs gap-1.5"
                disabled={results.every(r => !r.result)}>
                <Download className="h-3 w-3" /> Export CSV
              </Button>
            </div>
          </div>

          {/* Transport mode + info */}
          <div className="space-y-2">
            <div className="flex items-center gap-2">
              <span className="text-xs font-medium text-gray-700">Method of Entry</span>
              <div className="group relative">
                <Info className="h-3 w-3 text-gray-400 cursor-help" />
                <div className="absolute bottom-full left-1/2 -translate-x-1/2 mb-2 px-3 py-2 bg-gray-900 text-white text-[10px] rounded-lg whitespace-nowrap opacity-0 group-hover:opacity-100 transition-opacity pointer-events-none z-50">
                  HMF ({(HMF_RATE * 100).toFixed(3)}%) applies to ocean freight only.<br />
                  MPF ({(MPF_RATE * 100).toFixed(4)}%) applies to all modes (min ${MPF_MIN} / max ${MPF_MAX}).
                </div>
              </div>
            </div>
            <div className="inline-flex items-center h-9 rounded-lg p-1"
              style={{ boxShadow: neuInsetShadow, background: '#FAFAF8' }}>
              {([['ocean', Ship, 'Ocean'], ['air', Plane, 'Air'], ['land', Truck, 'Land']] as const).map(([mode, Icon, label]) => (
                <button key={mode} type="button" onClick={() => setTransportMode(mode)}
                  className={`flex items-center gap-1.5 px-3 py-1.5 rounded-md text-xs font-medium transition-all ${
                    transportMode === mode ? 'bg-white text-[#353CED] shadow-sm' : 'text-gray-500 hover:text-gray-700'
                  }`}>
                  <Icon className="h-3 w-3" />{label}
                </button>
              ))}
            </div>
          </div>

          {/* Shipment rows */}
          <div className="space-y-3">
            {/* Header with sort */}
            <div className="grid grid-cols-[1fr_1fr_32px] gap-3 items-end">
              <span className="text-[10px] font-medium text-gray-400 uppercase tracking-wider">Customs Value (USD)</span>
              <div className="flex items-center justify-between">
                <span className="text-[10px] font-medium text-gray-400 uppercase tracking-wider">Shipment Date</span>
                {rows.length > 1 && (
                  <button onClick={sortByDate} className="text-gray-400 hover:text-[#353CED] transition-colors" title="Sort by date">
                    <ArrowDownUp className="h-3 w-3" />
                  </button>
                )}
              </div>
              <div />
            </div>

            {rows.map(row => (
              <div key={row.id} className="space-y-1">
                <div className="grid grid-cols-[1fr_1fr_32px] gap-3 items-center">
                  <Input type="number" value={row.customsValue || ''} min={0}
                    onChange={(e) => updateRow(row.id, { customsValue: Number(e.target.value) })}
                    className="h-9 text-sm font-mono" placeholder="50,000" />
                  <DatePickerNeu
                    date={row.date}
                    onSelect={(d) => updateRow(row.id, { date: d })}
                    minDate={new Date(2025, 0, 1)}
                    maxDate={new Date(2026, 11, 31)}
                  />
                  <Button variant="ghost" size="icon" onClick={() => removeRow(row.id)}
                    disabled={rows.length <= 1}
                    className="h-9 w-8 text-gray-400 hover:text-red-500">
                    <Trash2 className="h-3.5 w-3.5" />
                  </Button>
                </div>
              </div>
            ))}

            <Button variant="outline" size="sm" onClick={addRow} className="w-full">
              <Plus className="h-3.5 w-3.5 mr-1.5" /> Add Shipment
            </Button>
          </div>

          {/* Results table */}
          <div className="rounded-lg border border-gray-200 overflow-hidden">
            <table className="w-full text-xs">
              <thead>
                <tr className="bg-gray-50 border-b border-gray-200">
                  <th className="px-3 py-2 text-left text-[10px] font-medium text-gray-500">Date</th>
                  <th className="px-3 py-2 text-right text-[10px] font-medium text-gray-500">Value</th>
                  <th className="px-3 py-2 text-right text-[10px] font-medium text-gray-500 text-red-600">Duty</th>
                  <th className="px-3 py-2 text-right text-[10px] font-medium text-gray-500 text-amber-600">Fees</th>
                  <th className="px-3 py-2 text-right text-[10px] font-medium text-gray-500">Landed</th>
                  <th className="px-3 py-2 w-8" />
                </tr>
              </thead>
              <tbody>
                {results.map(({ row, result: r, rate }, idx) => (
                  <React.Fragment key={row.id}>
                    <tr className={cn('border-b border-gray-50', expandedRows.has(row.id) && 'bg-gray-50/50')}>
                      <td className="px-3 py-2 font-mono">{row.date.toISOString().slice(0, 10)}</td>
                      <td className="px-3 py-2 text-right font-mono">{r ? formatCurrency(r.customsValue) : '—'}</td>
                      <td className="px-3 py-2 text-right font-mono text-red-600">{r ? formatCurrency(r.totalDuty) : '—'}</td>
                      <td className="px-3 py-2 text-right font-mono text-amber-600">{r ? formatCurrency(r.totalFees) : '—'}</td>
                      <td className="px-3 py-2 text-right font-mono font-semibold">{r ? formatCurrency(r.landedCost) : '—'}</td>
                      <td className="px-3 py-2">
                        {r && (
                          <button onClick={() => toggleExpand(row.id)} className="text-gray-400 hover:text-gray-600">
                            {expandedRows.has(row.id) ? <ChevronUp className="h-3 w-3" /> : <ChevronDown className="h-3 w-3" />}
                          </button>
                        )}
                      </td>
                    </tr>
                    {expandedRows.has(row.id) && r && rate && (
                      <>
                        <tr className="bg-gray-50/30">
                          <td colSpan={6} className="px-6 py-1.5 text-[10px] text-gray-400">
                            Rate period: {r.ratePeriod} &middot; Basis: Ad Valorem &middot; Rev: {rate.revision}
                          </td>
                        </tr>
                        {r.breakdown.map((b, bi) => (
                          <tr key={bi} className="bg-gray-50/30 border-t border-gray-50">
                            <td colSpan={2} className="px-6 py-1.5">
                              <div className="flex items-center gap-1.5">
                                <div className="w-2 h-2 rounded-full" style={{ backgroundColor: b.color }} />
                                <span className="text-gray-600">{b.authority}</span>
                                {b.ch99Code && <span className="text-[10px] font-mono text-[#353CED]">({b.ch99Code})</span>}
                              </div>
                            </td>
                            <td className="px-3 py-1.5 text-right font-mono text-gray-500">{formatRateShort(b.rate)}</td>
                            <td />
                            <td className="px-3 py-1.5 text-right font-mono text-red-600">{formatCurrency(b.dutyAmount)}</td>
                            <td />
                          </tr>
                        ))}
                        <tr className="bg-gray-50/30 border-t border-gray-100">
                          <td colSpan={2} className="px-6 py-1.5 text-gray-600 font-medium">Total Duty</td>
                          <td className="px-3 py-1.5 text-right font-mono text-gray-500">{formatRateShort(r.totalDutyRate)}</td>
                          <td />
                          <td className="px-3 py-1.5 text-right font-mono font-medium text-red-600">{formatCurrency(r.totalDuty)}</td>
                          <td />
                        </tr>
                        <tr className="bg-gray-50/30 border-t border-gray-50">
                          <td colSpan={2} className="px-6 py-1.5 text-gray-500">
                            MPF <span className="text-gray-400">({(MPF_RATE * 100).toFixed(4)}% · min ${MPF_MIN} / max ${MPF_MAX})</span>
                          </td>
                          <td />
                          <td />
                          <td className="px-3 py-1.5 text-right font-mono text-amber-600">{formatCurrency(r.mpf)}</td>
                          <td />
                        </tr>
                        <tr className="bg-gray-50/30 border-t border-gray-50">
                          <td colSpan={2} className="px-6 py-1.5 text-gray-500">
                            HMF <span className="text-gray-400">({transportMode === 'ocean' ? `${(HMF_RATE * 100).toFixed(3)}%` : 'Ocean only — N/A'})</span>
                          </td>
                          <td />
                          <td />
                          <td className="px-3 py-1.5 text-right font-mono text-amber-600">{formatCurrency(r.hmf)}</td>
                          <td />
                        </tr>
                        <tr className="bg-blue-50/30 border-t border-gray-200">
                          <td colSpan={2} className="px-6 py-2 font-semibold text-gray-900">Landed Cost</td>
                          <td />
                          <td />
                          <td className="px-3 py-2 text-right font-mono font-bold text-gray-900">{formatCurrency(r.landedCost)}</td>
                          <td />
                        </tr>
                      </>
                    )}
                  </React.Fragment>
                ))}
              </tbody>
              <tfoot>
                <tr className="border-t-2 border-gray-200 bg-gradient-to-r from-gray-50 to-blue-50/30">
                  <td className="px-3 py-2.5 font-semibold text-gray-900">
                    Totals <span className="font-normal text-gray-400">({rows.length} shipments)</span>
                  </td>
                  <td className="px-3 py-2.5 text-right font-mono">{formatCurrency(totals.customsValue)}</td>
                  <td className="px-3 py-2.5 text-right font-mono text-red-600 font-medium">{formatCurrency(totals.totalDuty)}</td>
                  <td className="px-3 py-2.5 text-right font-mono text-amber-600">{formatCurrency(totals.totalFees)}</td>
                  <td className="px-3 py-2.5 text-right font-mono font-bold text-gray-900">{formatCurrency(totals.landedCost)}</td>
                  <td />
                </tr>
              </tfoot>
            </table>
          </div>

          {/* Fee reference note */}
          <div className="text-[10px] text-gray-400 leading-relaxed">
            Fees are based on entered value of goods, excluding international freight, insurance, and duties.
            MPF: {(MPF_RATE * 100).toFixed(4)}% (min ${MPF_MIN}, max ${MPF_MAX}).
            HMF: {(HMF_RATE * 100).toFixed(3)}% (ocean shipments only). FY 2026 rates.
          </div>
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
