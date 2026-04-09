import React from 'react';
import { DutyLookupModule } from '@/components/duty-lookup/DutyLookupModule';
import { useDataStats } from '@/hooks/useDataStats';
import { Shield, Database, Layers, Package, Globe } from 'lucide-react';

function formatRevisionLabel(rev: string): string {
  const parts = rev.split('_');
  const year = parts[0];
  if (parts[1] === 'basic') return `Baseline (${year})`;
  const num = parts[2];
  return `Rev ${num} (${year})`;
}

function formatDateShort(dateStr: string): string {
  if (!dateStr) return '';
  const d = new Date(dateStr + 'T00:00:00');
  return d.toLocaleDateString('en-US', { month: 'short', day: 'numeric', year: 'numeric' });
}

function App() {
  const stats = useDataStats();

  const coverageLabel = stats.loading
    ? 'Loading...'
    : `${formatRevisionLabel(stats.earliestRevision)} — ${formatRevisionLabel(stats.latestRevision)}`;

  const coverageDates = stats.loading
    ? ''
    : `${formatDateShort(stats.earliestDate)} – ${formatDateShort(stats.latestDate)}`;

  return (
    <div className="min-h-[100dvh] bg-gradient-to-br from-white via-[#FAFAF8] to-gray-50/60">
      {/* Header */}
      <header className="border-b border-gray-100/80 glass-surface sticky top-0 z-30">
        <div className="max-w-7xl mx-auto px-6 py-3.5 flex items-center justify-between">
          <div className="flex items-center gap-3">
            <div className="w-8 h-8 rounded-[10px] bg-[#353CED] flex items-center justify-center shadow-pop">
              <Shield className="h-4 w-4 text-white" />
            </div>
            <div>
              <h1 className="text-sm font-semibold text-gray-900 tracking-[-0.01em]">SAIL Duty Rate Calculator</h1>
              <p className="text-[10px] text-gray-400 tracking-wide">SAIL GTX &middot; Tariff Rate Tracker</p>
            </div>
          </div>

          {/* Dynamic coverage badge */}
          {!stats.loading && (
            <div className="flex items-center gap-3">
              <div className="hidden sm:flex items-center gap-1.5 text-[10px] text-gray-400">
                <Database className="h-3 w-3" />
                <span>{coverageDates}</span>
              </div>
              <div className="flex items-center gap-1.5 px-3 py-1.5 rounded-full bg-emerald-50/80 border border-emerald-200/60 shadow-neu-sm">
                <Layers className="h-3 w-3 text-emerald-600" />
                <span className="text-[10px] font-medium text-emerald-700">{coverageLabel}</span>
              </div>
            </div>
          )}
        </div>
      </header>

      {/* Main content */}
      <main className="max-w-7xl mx-auto px-6 py-8">
        <DutyLookupModule />
      </main>

      {/* Footer */}
      <footer className="border-t border-gray-100/60 mt-16">
        <div className="max-w-7xl mx-auto px-6 py-5">
          <div className="flex items-center justify-between">
            <div className="flex items-center gap-5 text-[10px] text-gray-400">
              <span className="flex items-center gap-1.5">
                <Database className="h-3 w-3" />
                USITC HTS Archives
              </span>
              {!stats.loading && (
                <>
                  <span className="flex items-center gap-1.5">
                    <Layers className="h-3 w-3" />
                    {stats.nRevisions} revisions
                  </span>
                  <span className="flex items-center gap-1.5">
                    <Package className="h-3 w-3" />
                    {stats.nProducts.toLocaleString()} products
                  </span>
                  <span className="flex items-center gap-1.5">
                    <Globe className="h-3 w-3" />
                    {stats.nCountries.toLocaleString()} countries
                  </span>
                </>
              )}
            </div>
            <span className="text-[10px] text-gray-300">SAIL GTX &middot; Tariff Rate Tracker</span>
          </div>
        </div>
      </footer>
    </div>
  );
}

export default App;
