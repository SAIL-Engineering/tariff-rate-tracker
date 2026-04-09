import React from 'react';
import { Card, CardContent } from '@/components/ui/card';
import { Input } from '@/components/ui/input';
import { Button } from '@/components/ui/button';
import { CountryAutocomplete } from './CountryAutocomplete';
import { DatePickerNeu } from './DatePickerNeu';
import { Search, Loader2, Globe, Hash, CalendarDays } from 'lucide-react';
import type { Country } from '@/types/tariff';
import { formatHtsCode } from '@/utils/formatters';

interface QueryPanelProps {
  countries: Country[];
  htsCode: string;
  onHtsCodeChange: (code: string) => void;
  selectedCountry: Country | null;
  onCountryChange: (country: Country | null) => void;
  queryDate: Date;
  onDateChange: (date: Date) => void;
  onLookup: () => void;
  isLoading: boolean;
  sampleProducts: string[];
}

export function QueryPanel({
  countries, htsCode, onHtsCodeChange, selectedCountry, onCountryChange,
  queryDate, onDateChange, onLookup, isLoading, sampleProducts,
}: QueryPanelProps) {
  return (
    <Card className="relative z-10 hover:shadow-[3px_3px_6px_rgba(0,0,0,0.10),_-3px_-3px_6px_rgba(255,255,255,0.95)]">
      <CardContent className="p-5">
        <div className="flex items-center gap-2 mb-4">
          <Search className="h-4 w-4 text-[#353CED]" />
          <h3 className="font-semibold text-sm text-gray-900">Duty Rate Lookup</h3>
        </div>

        <div className="grid grid-cols-1 md:grid-cols-3 gap-4 mb-4">
          <div className="space-y-1.5">
            <label className="text-xs font-medium text-gray-700 flex items-center gap-1.5">
              <Hash className="h-3 w-3" /> HTS-10 Code
            </label>
            <Input
              value={htsCode}
              onChange={(e) => onHtsCodeChange(e.target.value.replace(/[^0-9.]/g, ''))}
              placeholder="e.g. 7208.51.0030"
              className="h-9 text-sm font-mono"
            />
            {sampleProducts.length > 0 && (
              <div className="flex flex-wrap gap-1 mt-1">
                {sampleProducts.slice(0, 6).map(p => (
                  <button key={p} type="button" onClick={() => onHtsCodeChange(p)}
                    className="text-[10px] font-mono px-1.5 py-0.5 rounded bg-gray-50 text-gray-500 hover:bg-[#353CED]/5 hover:text-[#353CED] transition-colors">
                    {formatHtsCode(p)}
                  </button>
                ))}
              </div>
            )}
          </div>

          <div className="space-y-1.5">
            <label className="text-xs font-medium text-gray-700 flex items-center gap-1.5">
              <Globe className="h-3 w-3" /> Country of Origin
            </label>
            <CountryAutocomplete
              countries={countries}
              value={selectedCountry}
              onChange={onCountryChange}
              placeholder="Search country..."
            />
          </div>

          <div className="space-y-1.5">
            <label className="text-xs font-medium text-gray-700 flex items-center gap-1.5">
              <CalendarDays className="h-3 w-3" /> Effective Date
            </label>
            <DatePickerNeu
              date={queryDate}
              onSelect={onDateChange}
              minDate={new Date(2025, 0, 1)}
              maxDate={new Date(2026, 11, 31)}
            />
          </div>
        </div>

        <Button onClick={onLookup} disabled={isLoading || !htsCode || !selectedCountry} size="sm"
          className="w-full md:w-auto">
          {isLoading ? <Loader2 className="h-4 w-4 animate-spin mr-2" /> : <Search className="h-4 w-4 mr-2" />}
          Look Up Duty Rate
        </Button>
      </CardContent>
    </Card>
  );
}
