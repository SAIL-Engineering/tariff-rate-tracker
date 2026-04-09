import React, { useMemo, useState } from 'react';
import { Card, CardContent } from '@/components/ui/card';
import type { DailyByCountrySummary, Country } from '@/types/tariff';
import { PARTNER_COLORS } from '@/types/tariff';
import { formatRateShort } from '@/utils/formatters';
import { Globe, ArrowUpDown, ChevronDown, ChevronUp } from 'lucide-react';

interface CountryComparisonTableProps {
  data: DailyByCountrySummary[];
  countries: Country[];
  selectedDate?: string;
}

export function CountryComparisonTable({ data, countries, selectedDate }: CountryComparisonTableProps) {
  const [sortKey, setSortKey] = useState<'name' | 'rate'>('rate');
  const [sortDir, setSortDir] = useState<'asc' | 'desc'>('desc');
  const [showAll, setShowAll] = useState(false);

  const targetDate = selectedDate ?? data[data.length - 1]?.date;

  const countryMap = useMemo(() => new Map(countries.map(c => [c.code, c])), [countries]);

  const latestByCountry = useMemo(() => {
    // Find the revision active at targetDate
    const atDate = data.filter(d => d.date <= targetDate);
    // Group by country, take latest date per country
    const map = new Map<string, DailyByCountrySummary>();
    for (const row of atDate) {
      const existing = map.get(row.country);
      if (!existing || row.date > existing.date) {
        map.set(row.country, row);
      }
    }
    return Array.from(map.values());
  }, [data, targetDate]);

  const sorted = useMemo(() => {
    const arr = [...latestByCountry];
    arr.sort((a, b) => {
      if (sortKey === 'name') {
        const cmp = (a.country_name ?? '').localeCompare(b.country_name ?? '');
        return sortDir === 'asc' ? cmp : -cmp;
      }
      const cmp = a.mean_total_all_pairs - b.mean_total_all_pairs;
      return sortDir === 'asc' ? cmp : -cmp;
    });
    return arr;
  }, [latestByCountry, sortKey, sortDir]);

  const displayed = showAll ? sorted : sorted.slice(0, 25);

  const toggleSort = (key: 'name' | 'rate') => {
    if (sortKey === key) setSortDir(d => d === 'asc' ? 'desc' : 'asc');
    else { setSortKey(key); setSortDir(key === 'rate' ? 'desc' : 'asc'); }
  };

  const maxRate = Math.max(...sorted.map(d => d.mean_total_all_pairs), 0.01);

  return (
    <Card>
      <CardContent className="p-5">
        <div className="flex items-center justify-between mb-4">
          <div className="flex items-center gap-2">
            <Globe className="h-4 w-4 text-[#353CED]" />
            <h3 className="font-semibold text-sm text-gray-900">Country Comparison</h3>
            <span className="text-xs text-gray-400">{sorted.length} countries</span>
          </div>
        </div>

        <div className="rounded-lg border border-gray-200 overflow-hidden">
          <table className="w-full text-xs">
            <thead>
              <tr className="bg-gray-50 border-b border-gray-200">
                <th className="px-3 py-2 text-left">
                  <button onClick={() => toggleSort('name')} className="flex items-center gap-1 text-[10px] font-medium text-gray-500 uppercase tracking-wider hover:text-gray-700">
                    Country <ArrowUpDown className="h-3 w-3" />
                  </button>
                </th>
                <th className="px-3 py-2 text-left w-[40%]">
                  <span className="text-[10px] font-medium text-gray-500 uppercase tracking-wider">Rate Distribution</span>
                </th>
                <th className="px-3 py-2 text-right">
                  <button onClick={() => toggleSort('rate')} className="flex items-center gap-1 text-[10px] font-medium text-gray-500 uppercase tracking-wider hover:text-gray-700 ml-auto">
                    Mean Rate <ArrowUpDown className="h-3 w-3" />
                  </button>
                </th>
              </tr>
            </thead>
            <tbody>
              {displayed.map(row => {
                const country = countryMap.get(row.country);
                const partner = country?.partner;
                const barWidth = maxRate > 0 ? (row.mean_total_all_pairs / maxRate) * 100 : 0;
                const barColor = partner ? PARTNER_COLORS[partner] ?? '#9ca3af' : '#9ca3af';
                return (
                  <tr key={row.country} className="border-b border-gray-50 hover:bg-[#353CED]/[0.02] transition-colors">
                    <td className="px-3 py-2">
                      <div className="flex items-center gap-2">
                        {partner && <div className="w-1.5 h-1.5 rounded-full flex-shrink-0" style={{ backgroundColor: barColor }} />}
                        <span className="text-gray-700">{row.country_name}</span>
                        {partner && <span className="text-[10px] text-gray-400">({partner})</span>}
                      </div>
                    </td>
                    <td className="px-3 py-2">
                      <div className="h-2 bg-gray-100 rounded-full overflow-hidden">
                        <div className="h-full rounded-full transition-all duration-500"
                          style={{ width: `${barWidth}%`, backgroundColor: barColor }} />
                      </div>
                    </td>
                    <td className="px-3 py-2 text-right font-mono font-medium text-gray-900">
                      {formatRateShort(row.mean_total_all_pairs)}
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>

        {sorted.length > 25 && (
          <button onClick={() => setShowAll(!showAll)}
            className="flex items-center gap-1 mt-3 text-xs text-[#353CED] hover:text-[#353CED]/80 transition-colors mx-auto">
            {showAll ? <ChevronUp className="h-3 w-3" /> : <ChevronDown className="h-3 w-3" />}
            {showAll ? 'Show fewer' : `Show all ${sorted.length} countries`}
          </button>
        )}
      </CardContent>
    </Card>
  );
}
