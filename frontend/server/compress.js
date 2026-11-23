// =============================================================================
// Compressed answers
// =============================================================================
// Rate answers are highly repetitive: one product's rates for every country
// (the Scenario Planning corpus, the Tariff Explorer's all-countries view) are
// about 39 MB of Arrow and gzip to about 1.2 MB. Sent raw, a browser waited tens
// of seconds and a network change cut the download (2026-11-23). Every answer of
// 1 KB or more now goes gzipped to a client that accepts it (every browser does);
// browsers unzip it before the page reads it, so the website needs no change.
// =============================================================================

import zlib from 'node:zlib';
import { promisify } from 'node:util';

const gzip = promisify(zlib.gzip);
const gunzip = promisify(zlib.gunzip);

/** Answers smaller than this are sent as they are. */
export const MIN_COMPRESS_BYTES = 1024;

export function acceptsGzip(req) {
  return /\bgzip\b/i.test(String(req.headers['accept-encoding'] ?? ''));
}

/** Gzip off the event loop (level 6: the 39 MB corpus in well under a second). */
export function gzipBuffer(buf) {
  return gzip(buf, { level: 6 });
}

/**
 * Middleware: each res.send (res.json goes through it) of a string or Buffer of
 * MIN_COMPRESS_BYTES or more is gzipped for a client that accepts gzip. An
 * answer that already names its Content-Encoding (sendGzipped) passes as is.
 */
export function compressResponses() {
  return (req, res, next) => {
    if (!acceptsGzip(req)) return next();
    const send = res.send.bind(res);
    res.send = (body) => {
      if (res.getHeader('Content-Encoding')) return send(body);
      const buf = Buffer.isBuffer(body) ? body : typeof body === 'string' ? Buffer.from(body, 'utf8') : null;
      if (!buf || buf.length < MIN_COMPRESS_BYTES) return send(body);
      gzipBuffer(buf).then(
        (gz) => {
          res.setHeader('Content-Encoding', 'gzip');
          res.vary('Accept-Encoding');
          send(gz);
        },
        () => send(body),
      );
      return res;
    };
    next();
  };
}

/** A body kept gzipped (the answer cache): sent as is to a client that accepts gzip, else unzipped first. */
export async function sendGzipped(req, res, gz) {
  res.vary('Accept-Encoding');
  if (acceptsGzip(req)) {
    res.setHeader('Content-Encoding', 'gzip');
    return res.send(gz);
  }
  return res.send(await gunzip(gz));
}
