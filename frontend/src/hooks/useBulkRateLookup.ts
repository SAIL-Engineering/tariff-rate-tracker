// =============================================================================
// useBulkRateLookup — batched rate fetching with LRU cache
// =============================================================================
// Accepts a deduped list of rate keys, chunks them to avoid oversized POSTs,
// hits /api/rates/batch (Arrow IPC), and returns a Map<key, ProductRate[]>
// that the bulk calculator consumes.
//
// Cache is module-scoped so it survives multiple jobs in the same session.
// Keyed by (hts10, country, revision) so that two jobs that look up the same
// combination don't round-trip to the server twice.

import { useCallback, useRef, useState } from 'react';
import type { ProductRate } from '@/types/tariff';
import { buildRateKey } from '@/types/bulk';

const BATCH_SIZE = 1500; // stay under the 2000 server cap with margin
const CACHE_MAX = 20_000;

// -----------------------------------------------------------------------------
// Module-scoped LRU cache
// -----------------------------------------------------------------------------

interface CacheEntry {
  key: string;
  rates: ProductRate[];
}

const cache = new Map<string, CacheEntry>();

function cacheGet(key: string): ProductRate[] | undefined {
  const entry = cache.get(key);
  if (!entry) return undefined;
  // LRU: refresh insertion order
  cache.delete(key);
  cache.set(key, entry);
  return entry.rates;
}

function cacheSet(key: string, rates: ProductRate[]): void {
  if (cache.has(key)) cache.delete(key);
  cache.set(key, { key, rates });
  while (cache.size > CACHE_MAX) {
    const oldest = cache.keys().next().value;
    if (oldest) cache.delete(oldest);
    else break;
  }
}

// -----------------------------------------------------------------------------
// Arrow parsing
// -----------------------------------------------------------------------------

async function parseBatchArrowResponse(
  buffer: ArrayBuffer,
): Promise<Array<ProductRate & { request_hts10: string; request_country: string; request_date: string }>> {
  if (buffer.byteLength === 0) return [];
  const { tableFromIPC } = await import('apache-arrow');
  const table = tableFromIPC(new Uint8Array(buffer));
  const rows: Array<ProductRate & {
    request_hts10: string;
    request_country: string;
    request_date: string;
  }> = [];
  for (let i = 0; i < table.numRows; i++) {
    const r = table.get(i);
    if (!r) continue;
    const obj: Record<string, unknown> = {};
    for (const field of table.schema.fields) {
      const val = (r as Record<string, unknown>)[field.name];
      if (
        field.name === 'effective_date' ||
        field.name === 'valid_from' ||
        field.name === 'valid_until'
      ) {
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
    rows.push(obj as unknown as ProductRate & {
      request_hts10: string;
      request_country: string;
      request_date: string;
    });
  }
  return rows;
}

// -----------------------------------------------------------------------------
// Public hook
// -----------------------------------------------------------------------------

export interface BulkRateKey {
  key: string;
  hts10: string;
  country: string;
  date: string;
}

export interface BulkRateLookupProgress {
  fetched: number;
  total: number;
  found: number;
  missing: number;
}

export interface BulkRateLookupResult {
  rateMap: Map<string, ProductRate[]>;
  missingKeys: string[];
}

export function useBulkRateLookup() {
  const [progress, setProgress] = useState<BulkRateLookupProgress>({
    fetched: 0,
    total: 0,
    found: 0,
    missing: 0,
  });
  const [loading, setLoading] = useState(false);
  const abortRef = useRef<AbortController | null>(null);

  const cancel = useCallback(() => {
    if (abortRef.current) abortRef.current.abort();
    setLoading(false);
  }, []);

  const lookup = useCallback(
    async (keys: BulkRateKey[]): Promise<BulkRateLookupResult> => {
      setLoading(true);
      setProgress({ fetched: 0, total: keys.length, found: 0, missing: 0 });

      const rateMap = new Map<string, ProductRate[]>();
      const toFetch: BulkRateKey[] = [];

      // 1. Serve from cache
      for (const k of keys) {
        const cached = cacheGet(k.key);
        if (cached) rateMap.set(k.key, cached);
        else toFetch.push(k);
      }

      const controller = new AbortController();
      abortRef.current = controller;

      // 2. Chunk remainder and fetch
      for (let i = 0; i < toFetch.length; i += BATCH_SIZE) {
        if (controller.signal.aborted) break;
        const chunk = toFetch.slice(i, i + BATCH_SIZE);
        try {
          const res = await fetch('/api/rates/batch', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            signal: controller.signal,
            body: JSON.stringify({
              keys: chunk.map(({ hts10, country, date }) => ({
                hts10,
                country,
                date,
              })),
            }),
          });
          if (!res.ok) {
            throw new Error(`Batch lookup failed: ${res.status}`);
          }
          const buffer = await res.arrayBuffer();
          const parsed = await parseBatchArrowResponse(buffer);

          // Group parsed rows by request key.
          const perKey = new Map<string, ProductRate[]>();
          for (const row of parsed) {
            const k = buildRateKey(
              row.request_hts10,
              row.request_country,
              row.request_date,
            );
            const bucket = perKey.get(k) ?? [];
            bucket.push(row as ProductRate);
            perKey.set(k, bucket);
          }

          // Merge into rateMap + cache; any chunk key without a match is
          // recorded as an empty array (so callers can distinguish cached
          // miss vs cache absence).
          for (const c of chunk) {
            const rows = perKey.get(c.key) ?? [];
            rateMap.set(c.key, rows);
            cacheSet(c.key, rows);
          }

          setProgress((prev) => ({
            ...prev,
            fetched: Math.min(prev.total, i + chunk.length),
          }));
        } catch (err) {
          if (
            err instanceof DOMException &&
            (err.name === 'AbortError' || err.name === 'TimeoutError')
          ) {
            break;
          }
          throw err;
        }
      }

      // 3. Tally missing
      const missingKeys: string[] = [];
      let found = 0;
      for (const k of keys) {
        const rows = rateMap.get(k.key);
        if (!rows || rows.length === 0) {
          missingKeys.push(k.key);
        } else {
          found++;
        }
      }

      setProgress({
        fetched: keys.length,
        total: keys.length,
        found,
        missing: missingKeys.length,
      });
      setLoading(false);
      abortRef.current = null;

      return { rateMap, missingKeys };
    },
    [],
  );

  return { lookup, progress, loading, cancel };
}
