import { useState, useEffect, useMemo, useCallback, useRef } from 'react';
import type {
  Country,
  RevisionEntry,
  DailyOverall,
  DailyByAuthority,
  DailyByCountrySummary,
  ProductRate,
} from '@/types/tariff';
import { apiUrl } from '@/lib/apiBase';

interface TariffData {
  countries: Country[];
  revisions: RevisionEntry[];
  dailyOverall: DailyOverall[];
  dailyByAuthority: DailyByAuthority[];
  dailyByCountry: DailyByCountrySummary[];
  sampleRates: ProductRate[];
  loading: boolean;
  error: string | null;
}

async function fetchJson<T>(path: string): Promise<T> {
  const res = await fetch(path);
  if (!res.ok) throw new Error(`Failed to load ${path}: ${res.statusText}`);
  return res.json();
}

export function useTariffData(): TariffData {
  const [countries, setCountries] = useState<Country[]>([]);
  const [revisions, setRevisions] = useState<RevisionEntry[]>([]);
  const [dailyOverall, setDailyOverall] = useState<DailyOverall[]>([]);
  const [dailyByAuthority, setDailyByAuthority] = useState<DailyByAuthority[]>([]);
  const [dailyByCountry, setDailyByCountry] = useState<DailyByCountrySummary[]>([]);
  const [sampleRates, setSampleRates] = useState<ProductRate[]>([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    async function load() {
      try {
        const [c, r, d, a, dc, sr] = await Promise.all([
          fetchJson<Country[]>('/data/countries.json'),
          fetchJson<RevisionEntry[]>('/data/revision_timeline.json'),
          fetchJson<DailyOverall[]>('/data/daily_overall.json'),
          fetchJson<DailyByAuthority[]>('/data/daily_by_authority.json'),
          fetchJson<DailyByCountrySummary[]>('/data/daily_by_country_summary.json'),
          fetchJson<ProductRate[]>('/data/sample_rates.json'),
        ]);
        setCountries(c);
        setRevisions(r);
        setDailyOverall(d);
        setDailyByAuthority(a);
        setDailyByCountry(dc);
        setSampleRates(sr);
      } catch (e) {
        setError(e instanceof Error ? e.message : 'Unknown error loading data');
      } finally {
        setLoading(false);
      }
    }
    load();
  }, []);

  return { countries, revisions, dailyOverall, dailyByAuthority, dailyByCountry, sampleRates, loading, error };
}

export function useCountryLookup(countries: Country[]) {
  return useMemo(() => {
    const byCode = new Map<string, Country>();
    const byName = new Map<string, Country>();
    for (const c of countries) {
      byCode.set(c.code, c);
      byName.set(c.name.toLowerCase(), c);
    }
    return { byCode, byName };
  }, [countries]);
}

export function useCountrySearch(countries: Country[]) {
  return useCallback(
    (query: string): Country[] => {
      if (!query) return countries.slice(0, 20);
      const q = query.toLowerCase();
      return countries
        .filter(c =>
          c.name.toLowerCase().includes(q) ||
          c.code.includes(q) ||
          (c.alpha2 && c.alpha2.toLowerCase() === q) ||
          (c.alpha3 && c.alpha3.toLowerCase() === q)
        )
        .slice(0, 20);
    },
    [countries]
  );
}

export function useProductSearch(sampleRates: ProductRate[]) {
  return useMemo(() => {
    const unique = new Map<string, string>();
    for (const r of sampleRates) {
      if (!unique.has(r.hts10)) {
        unique.set(r.hts10, r.hts10);
      }
    }
    return Array.from(unique.keys()).sort();
  }, [sampleRates]);
}

// --- DuckDB-backed API lookup ---

export type RateMatchKind = 'exact' | 'prefix' | 'base_mfn_synthesized';

interface RateLookupResult {
  data: ProductRate[];
  match: RateMatchKind;
  loading: boolean;
  error: string | null;
}

/**
 * Hook that queries the DuckDB-backed API for rate data.
 * Returns a lookup function and result state.
 */
export function useRateLookup() {
  const [result, setResult] = useState<RateLookupResult>({
    data: [],
    match: 'exact',
    loading: false,
    error: null,
  });
  const abortRef = useRef<AbortController | null>(null);

  const lookupRates = useCallback(
    async (hts10: string, countryCode: string, date?: string) => {
      // Abort any in-flight request
      if (abortRef.current) abortRef.current.abort();
      const controller = new AbortController();
      abortRef.current = controller;

      setResult(prev => ({ ...prev, loading: true, error: null }));

      const cleanCode = hts10.replace(/\./g, '');
      const params = new URLSearchParams({ hts10: cleanCode, country: countryCode });
      if (date) params.set('date', date);

      try {
        const res = await fetch(apiUrl(`/api/rates?${params}`), { signal: controller.signal });
        if (!res.ok) {
          const body = await res.json().catch(() => ({}));
          throw new Error(body.error || `API error: ${res.status}`);
        }
        const json = await res.json();
        setResult({
          data: json.data as ProductRate[],
          match: json.match,
          loading: false,
          error: json.data.length === 0
            ? `No rates found for HTS ${hts10} in country ${countryCode}.`
            : null,
        });
        return json.data as ProductRate[];
      } catch (err: unknown) {
        if (err instanceof Error && err.name === 'AbortError') return [];
        const msg = err instanceof Error ? err.message : 'Unknown error';
        setResult({ data: [], match: 'exact', loading: false, error: msg });
        return [];
      }
    },
    []
  );

  const searchProducts = useCallback(async (query: string): Promise<string[]> => {
    if (query.length < 2) return [];
    try {
      const res = await fetch(apiUrl(`/api/products?q=${encodeURIComponent(query)}`));
      if (!res.ok) return [];
      const json = await res.json();
      return json.data as string[];
    } catch {
      return [];
    }
  }, []);

  return { ...result, lookupRates, searchProducts };
}

// --- Arrow IPC streaming for high-performance data transfer ---

/**
 * Fetch rate data as Arrow IPC stream for zero-copy deserialization.
 * Ideal for multi-country comparisons with large result sets.
 *
 * @param hts10 HTS code (4-10 digits)
 * @param countryCodes Array of Census country codes (or empty for all)
 * @returns Array of ProductRate objects deserialized from Arrow
 */
export async function fetchRatesArrow(
  hts10: string,
  countryCodes: string[] = [],
  signal?: AbortSignal,
): Promise<ProductRate[]> {
  const { tableFromIPC } = await import('apache-arrow');

  const cleanCode = hts10.replace(/\./g, '');
  const params = new URLSearchParams({ hts10: cleanCode });
  if (countryCodes.length > 0) {
    params.set('country', countryCodes.join(','));
  }

  const res = await fetch(apiUrl(`/api/rates/arrow?${params}`), { signal });
  if (!res.ok) {
    throw new Error(`Arrow fetch failed: ${res.status}`);
  }

  const buffer = await res.arrayBuffer();
  if (buffer.byteLength === 0) return [];

  const table = tableFromIPC(new Uint8Array(buffer));
  const rows: ProductRate[] = [];

  for (let i = 0; i < table.numRows; i++) {
    const row = table.get(i);
    if (!row) continue;
    // Convert Arrow row proxy to plain object, handling date fields
    const obj: Record<string, unknown> = {};
    for (const field of table.schema.fields) {
      const val = row[field.name];
      // Arrow returns dates as epoch-ms numbers
      if (field.name === 'effective_date' || field.name === 'valid_from' || field.name === 'valid_until') {
        if (typeof val === 'number') {
          obj[field.name] = new Date(val).toISOString().slice(0, 10);
        } else if (val instanceof Date) {
          obj[field.name] = val.toISOString().slice(0, 10);
        } else {
          obj[field.name] = val;
        }
      } else {
        obj[field.name] = val;
      }
    }
    rows.push(obj as unknown as ProductRate);
  }

  return rows;
}
