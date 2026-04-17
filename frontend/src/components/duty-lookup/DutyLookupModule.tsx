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
import { BulkDutyWorkflow } from './bulk/BulkDutyWorkflow';
import type { Country, ProductRate } from '@/types/tariff';
import { useTariffData, useProductSearch, useCountryLookup, useRateLookup } from '@/hooks/useTariffData';
import { findRateForDate } from '@/utils/tariffCalculator';
import { Loader2, AlertCircle, Search } from 'lucide-react';

type Tab = 'lookup' | 'dashboard' | 'countries' | 'compare' | 'bulk';

const neuInset = 'inset 1px 1px 4px rgba(0,0,0,0.05), inset -1px -1px 4px rgba(255,255,255,0.85)';

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
      <div className="flex flex-col items-center justify-center h-64 gap-3 text-gray-400 animate-fade-in">
        <Loader2 className="h-5 w-5 animate-spin text-[#353CED]/40" />
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
      <div className="flex items-center gap-1 rounded-xl p-1 w-fit"
        style={{ boxShadow: neuInset, background: '#FAFAF8' }}>
        {([
          ['dashboard', 'Dashboard'],
          ['lookup', 'Rate Lookup'],
          ['compare', 'Multi-Country Compare'],
          ['countries', 'Country Rankings'],
          ['bulk', 'Bulk Duty Analysis'],
        ] as [Tab, string][]).map(([tab, label]) => (
          <button key={tab} type="button" onClick={() => setActiveTab(tab)}
            className={`px-4 py-2 rounded-lg text-[13px] font-medium transition-all duration-200 ease-spring ${
              activeTab === tab
                ? 'bg-white text-[#353CED] shadow-glass'
                : 'text-gray-400 hover:text-gray-600'
            }`}>
            {label}
          </button>
        ))}
      </div>

      {/* Query panel — hidden on the bulk analysis tab (which has its own inputs) */}
      {activeTab !== 'bulk' && (
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
      )}

      {lookupError && (
        <div className="flex items-start gap-2.5 px-4 py-3 rounded-xl bg-amber-50/80 border border-amber-200/60 text-xs text-amber-800 animate-fade-in-down">
          <AlertCircle className="h-4 w-4 flex-shrink-0 mt-0.5 text-amber-500" />
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
            <>
              {/* Rate history: timeline + table (left) with stack breakdown (right) */}
              <div className="grid gap-5 grid-cols-1 xl:grid-cols-[1fr_380px]">
                <div className="space-y-5">
                  <DutyTimeline
                    rates={productHistory}
                    onSelectEntry={handleTimelineSelect}
                    selectedIndex={selectedTimelineIdx}
                    countryName={countryName}
                  />

                  <RateComparisonTable
                    entries={productHistory}
                    onSelectEntry={handleTableSelect}
                    selectedIndex={selectedTimelineIdx}
                  />
                </div>

                <div className="space-y-5">
                  {lookupResult && (
                    <DutyStackBreakdown
                      rate={lookupResult}
                      countryName={countryName}
                      label={selectedTimelineIdx != null ? `Period: ${lookupResult.revision}` : 'Current Rate'}
                    />
                  )}
                </div>
              </div>

              {/* Duty calculator — full width below rate history */}
              <DutyCalculatorPanel
                rates={productHistory}
                currentRate={lookupResult}
                countryName={countryName}
                htsCode={htsCode}
                countries={data.countries}
                selectedCountry={selectedCountry}
                initialMatch={rateLookup.match}
              />
            </>
          )}

          {productHistory.length === 0 && !lookupError && (
            <div className="text-center py-16 text-gray-400 animate-fade-in">
              <div className="w-12 h-12 rounded-2xl bg-gray-50 flex items-center justify-center mx-auto mb-4">
                <Search className="h-5 w-5 text-gray-300" />
              </div>
              <p className="text-sm">Enter an HTS code, select a country, and click "Look Up Duty Rate" to see results.</p>
            </div>
          )}
        </div>
      )}

      {/* Bulk Duty Analysis tab */}
      {activeTab === 'bulk' && (
        <BulkDutyWorkflow countries={data.countries} />
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
