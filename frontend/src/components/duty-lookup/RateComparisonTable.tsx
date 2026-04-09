import React, { useMemo, useState } from 'react';
import { Card, CardContent } from '@/components/ui/card';
import { TariffProgramBadge } from './TariffProgramBadge';
import type { ProductRate } from '@/types/tariff';
import { AUTHORITIES, MFN_COLOR } from '@/types/tariff';
import { formatRate, formatRateShort, formatDate } from '@/utils/formatters';
import { ArrowUpDown, Table2, Calendar } from 'lucide-react';
import { cn } from '@/lib/utils';

interface RateComparisonTableProps {
  entries: ProductRate[];
  onSelectEntry?: (index: number) => void;
  selectedIndex?: number | null;
}

type SortKey = 'date' | 'mfn' | 'special' | 'col2' | 'total';

export function RateComparisonTable({ entries, onSelectEntry, selectedIndex }: RateComparisonTableProps) {
  const [sortKey, setSortKey] = useState<SortKey>('date');
  const [sortDir, setSortDir] = useState<'asc' | 'desc'>('asc');

  const toggleSort = (key: SortKey) => {
    if (sortKey === key) setSortDir(d => d === 'asc' ? 'desc' : 'asc');
    else { setSortKey(key); setSortDir(key === 'date' ? 'asc' : 'desc'); }
  };

  const todayStr = new Date().toISOString().slice(0, 10);

  const sorted = useMemo(() => {
    const indexed = entries.map((e, i) => ({ entry: e, originalIndex: i }));
    indexed.sort((a, b) => {
      let cmp = 0;
      switch (sortKey) {
        case 'date': cmp = a.entry.effective_date.localeCompare(b.entry.effective_date); break;
        case 'mfn': cmp = a.entry.base_rate - b.entry.base_rate; break;
        case 'special': cmp = (a.entry.rate_special ?? -1) - (b.entry.rate_special ?? -1); break;
        case 'col2': cmp = (a.entry.rate_column2 ?? -1) - (b.entry.rate_column2 ?? -1); break;
        case 'total': cmp = a.entry.total_rate - b.entry.total_rate; break;
      }
      return sortDir === 'asc' ? cmp : -cmp;
    });
    return indexed;
  }, [entries, sortKey, sortDir]);

  if (entries.length === 0) return null;

  const SortHeader = ({ label, field }: { label: string; field: SortKey }) => (
    <button onClick={() => toggleSort(field)}
      className="flex items-center gap-1 text-[10px] font-medium text-gray-500 uppercase tracking-wider hover:text-gray-700 transition-colors">
      {label} <ArrowUpDown className="h-3 w-3" />
    </button>
  );

  return (
    <Card>
      <CardContent className="p-5">
        <div className="flex items-center gap-2 mb-4">
          <div className="w-6 h-6 rounded-lg bg-[#353CED]/6 flex items-center justify-center">
            <Table2 className="h-3.5 w-3.5 text-[#353CED]" />
          </div>
          <h3 className="font-semibold text-sm text-gray-900 tracking-[-0.01em]">Rate Periods</h3>
          <span className="text-[10px] text-gray-400 ml-auto tabular-nums">{entries.length} periods</span>
        </div>

        <div className="rounded-xl border border-gray-200/80 overflow-hidden">
          <div className="overflow-x-auto">
            <table className="w-full text-xs">
              <thead>
                <tr className="bg-gray-50/80 border-b border-gray-200/80">
                  <th className="px-3 py-2 text-left"><SortHeader label="Effective Date" field="date" /></th>
                  <th className="px-3 py-2 text-right"><SortHeader label="MFN Rate" field="mfn" /></th>
                  <th className="px-3 py-2 text-right"><SortHeader label="Special" field="special" /></th>
                  <th className="px-3 py-2 text-right"><SortHeader label="Col. 2" field="col2" /></th>
                  <th className="px-3 py-2 text-left" aria-label="Additional tariffs">
                    <span className="text-[10px] font-medium text-gray-500 uppercase tracking-wider">Additional</span>
                  </th>
                  <th className="px-3 py-2 text-right"><SortHeader label="Total Rate" field="total" /></th>
                  <th className="px-3 py-2 text-left" aria-label="Active programs">
                    <span className="text-[10px] font-medium text-gray-500 uppercase tracking-wider">Programs</span>
                  </th>
                </tr>
              </thead>
              <tbody>
                {sorted.map(({ entry, originalIndex }) => {
                  const isSelected = selectedIndex === originalIndex;
                  const isCurrent = entry.valid_from <= todayStr && entry.valid_until >= todayStr;
                  const activePrograms = AUTHORITIES.filter(a => entry[a.key] > 0);

                  return (
                    <tr key={originalIndex}
                      onClick={() => onSelectEntry?.(originalIndex)}
                      className={cn(
                        'border-b border-gray-50 cursor-pointer transition-colors',
                        isSelected && 'bg-[#353CED]/5',
                        isCurrent && !isSelected && 'bg-blue-50/50',
                        !isSelected && !isCurrent && 'hover:bg-gray-50/50'
                      )}>
                      <td className="px-3 py-2">
                        <div className="flex items-center gap-2">
                          <Calendar className="h-3 w-3 text-gray-400" />
                          <span className="font-mono text-gray-700">{formatDate(entry.effective_date)}</span>
                          {isCurrent && (
                            <span className="text-[10px] px-1.5 py-0.5 rounded-full bg-[#353CED]/8 text-[#353CED] font-medium">Current</span>
                          )}
                        </div>
                        <div className="text-[10px] text-gray-400 ml-5 mt-0.5">{entry.revision}</div>
                      </td>
                      <td className="px-3 py-2 text-right">
                        <span className="font-mono text-gray-700">{formatRate(entry.base_rate)}</span>
                        {entry.statutory_base_rate > 0 && Math.abs(entry.statutory_base_rate - entry.base_rate) > 0.00001 && (
                          <div className="text-[9px] text-gray-400 mt-0.5">
                            Stat: {formatRate(entry.statutory_base_rate)}
                          </div>
                        )}
                      </td>
                      <td className="px-3 py-2 text-right">
                        {entry.rate_special != null ? (
                          <span className="font-mono text-green-700">{formatRateShort(entry.rate_special)}</span>
                        ) : entry.rate_special_raw ? (
                          <span className="text-[10px] text-gray-500 italic truncate max-w-[80px] block">{entry.rate_special_raw.slice(0, 20)}</span>
                        ) : (
                          <span className="text-gray-300">—</span>
                        )}
                      </td>
                      <td className="px-3 py-2 text-right">
                        {entry.rate_column2 != null ? (
                          <span className="font-mono text-amber-700">{formatRateShort(entry.rate_column2)}</span>
                        ) : entry.rate_column2_raw ? (
                          <span className="text-[10px] text-gray-500 italic truncate max-w-[80px] block">{entry.rate_column2_raw.slice(0, 20)}</span>
                        ) : (
                          <span className="text-gray-300">—</span>
                        )}
                      </td>
                      <td className="px-3 py-2">
                        <div className="flex items-center gap-1">
                          {activePrograms.slice(0, 3).map(a => (
                            <div key={a.key} className="flex items-center gap-1">
                              <div className="w-2 h-2 rounded-full" style={{ backgroundColor: a.color }} />
                              <span className="text-gray-600">{formatRateShort(entry[a.key])}</span>
                            </div>
                          ))}
                          {activePrograms.length > 3 && (
                            <span className="text-gray-400">+{activePrograms.length - 3}</span>
                          )}
                        </div>
                      </td>
                      <td className="px-3 py-2 text-right">
                        <span className={cn(
                          'font-mono font-semibold',
                          entry.total_rate > 0.30 ? 'text-red-700' : entry.total_rate > 0.10 ? 'text-orange-700' : 'text-gray-900'
                        )}>
                          {formatRateShort(entry.total_rate)}
                        </span>
                      </td>
                      <td className="px-3 py-2">
                        <div className="flex flex-wrap gap-1">
                          {activePrograms.map(a => (
                            <TariffProgramBadge key={a.key} label={a.shortLabel} className="text-[9px] px-1.5 py-0" />
                          ))}
                        </div>
                      </td>
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>
        </div>

        <div className="flex items-center gap-4 mt-3 text-[10px] text-gray-400">
          <div className="flex items-center gap-1.5 tabular-nums">
            <Calendar className="h-3 w-3" />
            {entries.length} rate periods
          </div>
          <span className="text-gray-300">Click a row to view details</span>
        </div>
      </CardContent>
    </Card>
  );
}
