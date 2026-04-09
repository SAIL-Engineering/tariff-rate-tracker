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

type SortKey = 'date' | 'mfn' | 'total';

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
          <Table2 className="h-4 w-4 text-[#353CED]" />
          <h3 className="font-semibold text-sm text-gray-900">Rate Periods</h3>
          <span className="text-xs text-gray-400 ml-auto">{entries.length} periods</span>
        </div>

        <div className="rounded-lg border border-gray-200 overflow-hidden">
          <div className="overflow-x-auto">
            <table className="w-full text-xs">
              <thead>
                <tr className="bg-gray-50 border-b border-gray-200">
                  <th className="px-3 py-2 text-left"><SortHeader label="Effective Date" field="date" /></th>
                  <th className="px-3 py-2 text-right"><SortHeader label="MFN Rate" field="mfn" /></th>
                  <th className="px-3 py-2 text-left">
                    <span className="text-[10px] font-medium text-gray-500 uppercase tracking-wider">Additional</span>
                  </th>
                  <th className="px-3 py-2 text-right"><SortHeader label="Total Rate" field="total" /></th>
                  <th className="px-3 py-2 text-left">
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
                            <span className="text-[10px] px-1.5 py-0.5 rounded-full bg-blue-100 text-blue-700 font-medium">Current</span>
                          )}
                        </div>
                        <div className="text-[10px] text-gray-400 ml-5 mt-0.5">{entry.revision}</div>
                      </td>
                      <td className="px-3 py-2 text-right font-mono text-gray-700">
                        {formatRateShort(entry.base_rate)}
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
          <div className="flex items-center gap-1.5">
            <Calendar className="h-3 w-3" />
            {entries.length} rate periods tracked
          </div>
          <span>Click a row to view details</span>
        </div>
      </CardContent>
    </Card>
  );
}
