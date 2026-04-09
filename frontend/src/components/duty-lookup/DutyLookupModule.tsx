import React, { useState, useMemo, useCallback } from 'react';
import { QueryPanel } from './QueryPanel';
import { DutyStackBreakdown } from './DutyStackBreakdown';
import { RateComparisonTable } from './RateComparisonTable';
import { DutyTimeline } from './DutyTimeline';
import { DutyCalculatorPanel } from './DutyCalculatorPanel';
import { OverallDashboard } from './OverallDashboard';
import { CountryComparisonTable } from './CountryComparisonTable';
import { MultiCountryComparison } from './MultiCountryComparison';
import { ProductExplorer } from './ProductExplorer';
import type { Country, ProductRate } from '@/types/tariff';
import { useTariffData, useProductSearch, useCountryLookup, useRateLookup } from '@/hooks/useTariffData';
import { findRateForDate } from '@/utils/tariffCalculator';
import { Loader2, AlertCircle } from 'lucide-react';

type Tab = 'lookup' | 'dashboard' | 'countries' | 'compare';

const neuInset = 'inset 2px 2px 5px rgba(0,0,0,0.07), inset -2px -2px 5px rgba(255,255,255,0.9)';

export function DutyLookupModule() {
  const data = useTariffData();
  const sampleProducts = useProductSearch(data.sampleRates);
  const { byCode } = useCountryLookup(data.countries);
  const rateLookup = useRateLookup();

  const [activeTab, setActiveTab] = useState<Tab>('dashboard');
  const [htsCode, setHtsCode] = useState('');
  const [selectedCountry, setSelectedCountry] = useState<Country | null>(null);
  const [queryDate, setQueryDate] = useState<Date>(new Date(2026, 1, 15));
  const [lookupResult, setLookupResult] = useState<ProductRate | null>(null);
  const [productHistory, setProductHistory] = useState<ProductRate[]>([]);
  const [selectedTimelineIdx, setSelectedTimelineIdx] = useState<number | null>(null);
  const [lookupError, setLookupError] = useState<string | null>(null);

  const sortChronologically = useCallback((rates: ProductRate[]) => {
    return [...rates].sort((a, b) => a.effective_date.localeCompare(b.effective_date));
  }, []);

  const handleLookup = useCallback(async () => {
    setLookupError(null);
    const cleanCode = htsCode.replace(/\./g, '');
    if (cleanCode.length < 4) {
      setLookupError('HTS code must be at least 4 digits');
      return;
    }
    if (!selectedCountry) {
      setLookupError('Please select a country');
      return;
    }

    const dateStr = queryDate.toISOString().slice(0, 10);

    // Query the DuckDB-backed API for the full Parquet dataset
    const rates = await rateLookup.lookupRates(cleanCode, selectedCountry.code);

    if (!rates || rates.length === 0) {
      setLookupError(
        `No rates found for HTS ${htsCode} (${selectedCountry.name}). ` +
        `Verify the 10-digit HTS code and country selection.`
      );
      return;
    }

    const sorted = sortChronologically(rates);
    setProductHistory(sorted);
    const current = findRateForDate(sorted, dateStr);
    setLookupResult(current);
    setSelectedTimelineIdx(null);
    if (!current) setLookupError(`No rate found for date ${dateStr}. Showing full history.`);
    setActiveTab('lookup');
  }, [htsCode, selectedCountry, queryDate, rateLookup, sortChronologically]);

  const handleTimelineSelect = useCallback((idx: number | null) => {
    setSelectedTimelineIdx(idx);
    if (idx != null && productHistory[idx]) {
      setLookupResult(productHistory[idx]);
    }
  }, [productHistory]);

  const handleTableSelect = useCallback((idx: number) => {
    setSelectedTimelineIdx(idx);
    if (productHistory[idx]) {
      setLookupResult(productHistory[idx]);
    }
  }, [productHistory]);

  const countryName = selectedCountry?.name ?? '';

  if (data.loading) {
    return (
      <div className="flex items-center justify-center h-64 gap-3 text-gray-400">
        <Loader2 className="h-5 w-5 animate-spin" />
        <span className="text-sm">Loading tariff data...</span>
      </div>
    );
  }

  if (data.error) {
    return (
      <div className="flex items-center justify-center h-64 gap-3 text-red-500">
        <AlertCircle className="h-5 w-5" />
        <span className="text-sm">{data.error}</span>
      </div>
    );
  }

  return (
    <div className="space-y-5">
      {/* Tab navigation */}
      <div className="flex items-center gap-1 rounded-lg p-1 w-fit"
        style={{ boxShadow: neuInset, background: '#FAFAF8' }}>
        {([
          ['dashboard', 'Dashboard'],
          ['lookup', 'Rate Lookup'],
          ['compare', 'Multi-Country Compare'],
          ['countries', 'Country Rankings'],
        ] as [Tab, string][]).map(([tab, label]) => (
          <button key={tab} type="button" onClick={() => setActiveTab(tab)}
            className={`px-4 py-2 rounded-md text-sm font-medium transition-all ${
              activeTab === tab
                ? 'bg-white text-[#353CED] shadow-sm'
                : 'text-gray-500 hover:text-gray-700'
            }`}>
            {label}
          </button>
        ))}
      </div>

      {/* Query panel */}
      <QueryPanel
        countries={data.countries}
        htsCode={htsCode}
        onHtsCodeChange={setHtsCode}
        selectedCountry={selectedCountry}
        onCountryChange={setSelectedCountry}
        queryDate={queryDate}
        onDateChange={setQueryDate}
        onLookup={handleLookup}
        isLoading={rateLookup.loading}
        sampleProducts={sampleProducts}
      />

      {lookupError && (
        <div className="flex items-start gap-2 px-4 py-3 rounded-lg bg-amber-50 border border-amber-200 text-xs text-amber-800">
          <AlertCircle className="h-4 w-4 flex-shrink-0 mt-0.5" />
          <span>{lookupError}</span>
        </div>
      )}

      {/* Dashboard tab */}
      {activeTab === 'dashboard' && (
        <>
          <OverallDashboard
            dailyOverall={data.dailyOverall}
            dailyByAuthority={data.dailyByAuthority}
            dailyByCountry={data.dailyByCountry}
            revisions={data.revisions}
            countries={data.countries}
            insertAfterKpis={<ProductExplorer countries={data.countries} />}
          />
        </>
      )}

      {/* Multi-country comparison tab */}
      {activeTab === 'compare' && (
        <MultiCountryComparison
          countries={data.countries}
          sampleProducts={sampleProducts}
        />
      )}

      {/* Lookup tab */}
      {activeTab === 'lookup' && (
        <div className="space-y-5">
          {productHistory.length > 0 && (
            <div className="grid gap-5 grid-cols-1 xl:grid-cols-[1fr_380px]">
              <div className="space-y-5">
                {/* Timeline chart with integrated detail panel */}
                <DutyTimeline
                  rates={productHistory}
                  onSelectEntry={handleTimelineSelect}
                  selectedIndex={selectedTimelineIdx}
                  countryName={countryName}
                />

                {/* Rate comparison table (synced with timeline) */}
                <RateComparisonTable
                  entries={productHistory}
                  onSelectEntry={handleTableSelect}
                  selectedIndex={selectedTimelineIdx}
                />
              </div>

              <div className="space-y-5">
                {/* Stack breakdown for selected rate */}
                {lookupResult && (
                  <DutyStackBreakdown
                    rate={lookupResult}
                    countryName={countryName}
                    label={selectedTimelineIdx != null ? `Period: ${lookupResult.revision}` : 'Current Rate'}
                  />
                )}

                {/* Calculator */}
                <DutyCalculatorPanel
                  rates={productHistory}
                  currentRate={lookupResult}
                  countryName={countryName}
                  htsCode={htsCode}
                />
              </div>
            </div>
          )}

          {productHistory.length === 0 && !lookupError && (
            <div className="text-center py-12 text-gray-400">
              <p className="text-sm">Enter an HTS code, select a country, and click "Look Up Duty Rate" to see results.</p>
            </div>
          )}
        </div>
      )}

      {/* Countries tab */}
      {activeTab === 'countries' && (
        <CountryComparisonTable
          data={data.dailyByCountry}
          countries={data.countries}
          selectedDate={queryDate.toISOString().slice(0, 10)}
        />
      )}
    </div>
  );
}
