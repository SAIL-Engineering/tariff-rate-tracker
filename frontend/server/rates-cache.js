// =============================================================================
// The answer cache: least recently used, by entries, bytes and age
// =============================================================================
// Rate data changes only when the MotherDuck push runs, so answers are kept for
// ten minutes. A cap of 500 entries alone let a few dozen all-country answers
// (about 39 MB each) fill the server's memory (2026-11-23). The cache now also
// keeps under a byte budget (256 MB by default, RATES_CACHE_MAX_BYTES), drops the
// least recently used first, and never keeps one answer larger than a quarter of
// the budget. Arrow answers are kept gzipped ({ gz, rawBytes }), counted at their
// compressed size.
// =============================================================================

/** The bytes an entry holds: a Buffer's length, a kept gzip's compressed length, else its JSON length. */
function sizeOf(value) {
  if (Buffer.isBuffer(value)) return value.byteLength;
  if (value && Buffer.isBuffer(value.gz)) return value.gz.byteLength;
  try {
    return Buffer.byteLength(JSON.stringify(value) ?? '', 'utf8');
  } catch {
    return 0;
  }
}

export function createRatesCache({
  maxEntries = 500,
  maxBytes = 256 * 1024 * 1024,
  ttlMs = 10 * 60 * 1000,
  now = Date.now,
} = {}) {
  const entries = new Map(); // key → { value, bytes, expiresAt }; insertion order is recency
  let total = 0;

  const drop = (key) => {
    const e = entries.get(key);
    if (!e) return;
    total -= e.bytes;
    entries.delete(key);
  };

  return {
    get(key) {
      const e = entries.get(key);
      if (!e) return null;
      if (e.expiresAt <= now()) {
        drop(key);
        return null;
      }
      entries.delete(key);
      entries.set(key, e);
      return e.value;
    },
    /** Keep an answer for ttl (default: the cache's own) unless it is over a quarter of the budget. */
    set(key, value, ttl = ttlMs) {
      drop(key);
      const bytes = sizeOf(value);
      if (bytes > maxBytes / 4) return;
      while (entries.size > 0 && (entries.size >= maxEntries || total + bytes > maxBytes)) {
        drop(entries.keys().next().value);
      }
      entries.set(key, { value, bytes, expiresAt: now() + ttl });
      total += bytes;
    },
    bytes: () => total,
    size: () => entries.size,
  };
}
