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
    <Card className="relative z-10">
      <CardContent className="p-5">
        <div className="flex items-center gap-2 mb-5">
          <div className="w-6 h-6 rounded-lg bg-[#353CED]/8 flex items-center justify-center">
            <Search className="h-3.5 w-3.5 text-[#353CED]" />
          </div>
          <h3 className="font-semibold text-sm text-gray-900 tracking-[-0.01em]">Duty Rate Lookup</h3>
        </div>

        <div className="grid grid-cols-1 md:grid-cols-3 gap-5 mb-5">
          <div className="space-y-2">
            <label className="text-[11px] font-medium text-gray-500 flex items-center gap-1.5 uppercase tracking-wider">
              <Hash className="h-3 w-3" /> HTS-10 Code
            </label>
            <Input
              value={htsCode}
              onChange={(e) => onHtsCodeChange(e.target.value.replace(/[^0-9.]/g, ''))}
              placeholder="e.g. 7208.51.0030"
              className="h-9 text-sm font-mono"
            />
            {sampleProducts.length > 0 && (
              <div className="flex flex-wrap gap-1.5 mt-1">
                {sampleProducts.slice(0, 6).map(p => (
                  <button key={p} type="button" onClick={() => onHtsCodeChange(p)}
                    className="text-[10px] font-mono px-2 py-0.5 rounded-md bg-gray-50 text-gray-500 hover:bg-[#353CED]/5 hover:text-[#353CED] transition-all duration-200 ease-spring border border-transparent hover:border-[#353CED]/10">
                    {formatHtsCode(p)}
                  </button>
                ))}
              </div>
            )}
          </div>

          <div className="space-y-2">
            <label className="text-[11px] font-medium text-gray-500 flex items-center gap-1.5 uppercase tracking-wider">
              <Globe className="h-3 w-3" /> Country of Origin
            </label>
            <CountryAutocomplete
              countries={countries}
              value={selectedCountry}
              onChange={onCountryChange}
              placeholder="Search country..."
            />
          </div>

          <div className="space-y-2">
            <label className="text-[11px] font-medium text-gray-500 flex items-center gap-1.5 uppercase tracking-wider">
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
