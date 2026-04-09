import { useState, useEffect } from 'react';

export interface DataStats {
  nRevisions: number;
  nProducts: number;
  nCountries: number;
  earliestRevision: string;
  latestRevision: string;
  earliestDate: string;
  latestDate: string;
  loading: boolean;
}

const EMPTY: DataStats = {
  nRevisions: 0, nProducts: 0, nCountries: 0,
  earliestRevision: '', latestRevision: '',
  earliestDate: '', latestDate: '', loading: true,
};

export function useDataStats(): DataStats {
  const [stats, setStats] = useState<DataStats>(EMPTY);

  useEffect(() => {
    async function load() {
      try {
        const [revisions, overall] = await Promise.all([
          fetch('/data/revision_timeline.json').then(r => r.json()),
          fetch('/data/daily_overall.json').then(r => r.json()),
        ]);

        const sorted = [...revisions].sort(
          (a: { effectiveDate: string }, b: { effectiveDate: string }) =>
            a.effectiveDate.localeCompare(b.effectiveDate)
        );
        const latest = overall[overall.length - 1];

        setStats({
          nRevisions: revisions.length,
          nProducts: latest?.n_products ?? 0,
          nCountries: latest?.n_countries ?? 0,
          earliestRevision: sorted[0]?.revision ?? '',
          latestRevision: sorted[sorted.length - 1]?.revision ?? '',
          earliestDate: sorted[0]?.effectiveDate ?? '',
          latestDate: sorted[sorted.length - 1]?.effectiveDate ?? '',
          loading: false,
        });
      } catch {
        setStats(prev => ({ ...prev, loading: false }));
      }
    }
    load();
  }, []);

  return stats;
}
