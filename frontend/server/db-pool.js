// =============================================================================
// Guarded connection pool: every request query has a deadline
// =============================================================================
// A MotherDuck session can stop answering without failing: the query never
// returns, the request hangs, and every later request handed the same session
// queues behind it. The process stays up, so Railway (which restarts only on
// exit) never replaces it, and the Tariff Explorer and Duty Stack hang with it
// (2026-11-23).
//
// Each query handed out by pick() now:
//   - fails with QueryTimeoutError (HTTP 503) when it has not answered within
//     the deadline (90 s by default, DB_QUERY_TIMEOUT_MS; a full 1,500-key
//     batch takes about 17 s), so the caller fails fast and can retry;
//   - interrupts the stuck query and replaces its session with a fresh one in
//     the background; pick() skips a session while it is being replaced;
//   - asks for a restart (onFatal, by default process exit 1, so Railway's
//     restart policy brings up a clean process) when a fresh session cannot be
//     opened within the deadline, or when more than maxReplacements sessions
//     were replaced within replacementWindowMs.
// A query that fails for any other reason fails as before and keeps its session.
// =============================================================================

export class QueryTimeoutError extends Error {
  constructor(ms) {
    super(`The rates database did not answer within ${Math.round(ms / 1000)} seconds`);
    this.name = 'QueryTimeoutError';
    this.status = 503;
  }
}

/** The promise, or QueryTimeoutError after `ms`. A late failure of an abandoned promise is not left unhandled. */
function withDeadline(promise, ms) {
  let timer;
  const deadline = new Promise((_, reject) => {
    timer = setTimeout(() => reject(new QueryTimeoutError(ms)), ms);
  });
  promise.catch(() => {});
  return Promise.race([promise, deadline]).finally(() => clearTimeout(timer));
}

/**
 * @param {object} opts
 * @param {Array<{ runAndReadAll(sql: string): Promise<any>, interrupt?(): void }>} opts.connections  the opened sessions
 * @param {(() => Promise<any>) | null} opts.openConnection  opens one fresh session; null: a stuck one cannot be replaced
 * @param {number} [opts.timeoutMs]  the deadline for each query and for opening a session
 * @param {number} [opts.maxReplacements]  replacements allowed within the window before a restart is asked for
 * @param {number} [opts.replacementWindowMs]
 * @param {(why: string) => void} [opts.onFatal]
 * @param {{ warn: Function, error: Function }} [opts.log]
 */
export function createGuardedPool({
  connections,
  openConnection,
  timeoutMs = 90_000,
  maxReplacements = 8,
  replacementWindowMs = 30 * 60_000,
  onFatal = (why) => {
    console.error(`[db] ${why}; exiting so the service restarts`);
    process.exit(1);
  },
  log = console,
}) {
  if (!connections || connections.length === 0) throw new Error('createGuardedPool needs at least one connection');
  const slots = connections.map((connection) => ({ connection, replacing: null }));
  let cursor = 0;
  let replacedAt = [];
  let fatal = false;
  const pending = new Set();

  const fail = (why) => {
    if (fatal) return;
    fatal = true;
    onFatal(why);
  };

  function replace(slot, stuck) {
    if (slot.connection !== stuck || slot.replacing || fatal) return;
    try { stuck.interrupt?.(); } catch { /* the session may already be gone */ }
    const now = Date.now();
    replacedAt = replacedAt.filter((t) => now - t < replacementWindowMs);
    replacedAt.push(now);
    if (replacedAt.length > maxReplacements) {
      fail(`replaced ${replacedAt.length} stuck database sessions within ${Math.round(replacementWindowMs / 60_000)} minutes`);
      return;
    }
    if (!openConnection) {
      fail('a database session stopped answering and this database cannot open another');
      return;
    }
    const work = withDeadline(Promise.resolve().then(openConnection), timeoutMs).then(
      (fresh) => {
        slot.connection = fresh;
        log.warn(`[db] a database session stopped answering; replaced it (${replacedAt.length} in the last ${Math.round(replacementWindowMs / 60_000)} minutes)`);
      },
      (err) => fail(`could not open a new database session: ${err?.message ?? err}`),
    ).finally(() => {
      slot.replacing = null;
      pending.delete(work);
    });
    slot.replacing = work;
    pending.add(work);
  }

  // The connection methods the routes call (server.js, shipment-routes.js, shipment-store.js), each under the deadline.
  function guarded(slot) {
    const call = (method, args) => {
      const conn = slot.connection;
      return withDeadline(Promise.resolve().then(() => conn[method](...args)), timeoutMs).catch((err) => {
        if (err instanceof QueryTimeoutError) replace(slot, conn);
        throw err;
      });
    };
    return {
      runAndReadAll: (...args) => call('runAndReadAll', args),
      run: (...args) => call('run', args),
    };
  }

  return {
    /** The next session, round robin, skipping one being replaced (unless every one is). */
    pick() {
      for (let i = 0; i < slots.length; i++) {
        const slot = slots[(cursor + i) % slots.length];
        if (!slot.replacing) {
          cursor = (cursor + i + 1) % slots.length;
          return guarded(slot);
        }
      }
      const slot = slots[cursor];
      cursor = (cursor + 1) % slots.length;
      return guarded(slot);
    },
    get size() { return slots.length; },
    /** Resolves when no replacement is in flight (tests). */
    async settled() {
      while (pending.size > 0) await Promise.allSettled([...pending]);
    },
  };
}
