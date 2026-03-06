/**
 * Redis shared store for distributed worker mesh
 * Workers + hub write here; hub reads for pump detection
 * Optional: set REDIS_URL to enable
 */

import Redis from 'ioredis';

const REDIS_URL = (process.env.REDIS_URL || '').trim();
const KEY_PREFIX = 'pump:';
const MAX_AGE_MS = 24 * 60 * 60 * 1000;
const SYNC_INTERVAL_MS = 10 * 1000;
const TRIM_INTERVAL_MS = 60 * 60 * 1000; // 1 hour

let client = null;
let syncTimer = null;
let trimTimer = null;

export function getClient() {
  if (!REDIS_URL) return null;
  if (!client) {
    client = new Redis(REDIS_URL, {
      maxRetriesPerRequest: 3,
      connectTimeout: 10000,
      retryStrategy: (times) => (times < 3 ? 2000 : null),
    });
    client.on('error', (e) => console.error('[REDIS]', e.message));
  }
  return client;
}

function priceKey(mint) {
  return `${KEY_PREFIX}price:${mint}`;
}

function symbolKey(mint) {
  return `${KEY_PREFIX}symbol:${mint}`;
}

/**
 * Add RPC-derived price samples (from swap tx parsing). Batched.
 */
export async function addRpcSamples(samples) {
  const c = getClient();
  if (!c || !samples?.length) return;
  const pipeline = c.pipeline();
  let count = 0;
  for (const p of samples) {
    if (!p?.mint || !p?.price || !p?.timestamp) continue;
    pipeline.zadd(priceKey(p.mint), p.timestamp, `${p.timestamp}:${p.price}`);
    pipeline.sadd(`${KEY_PREFIX}mints`, p.mint);
    count++;
  }
  if (count > 0) await pipeline.exec();
}

/**
 * Add price sample. Called from contribute handler or worker.
 */
export async function addPrice(mint, ts, price) {
  const c = getClient();
  if (!c) return;
  await c.zadd(priceKey(mint), ts, `${ts}:${price}`);
  await c.sadd(`${KEY_PREFIX}mints`, mint);
}

/**
 * Bulk add OHLCV candles for a mint
 */
export async function addPrices(mint, candles, symbol) {
  const c = getClient();
  if (!c) return;
  const args = [];
  for (const candle of candles) {
    if (!Array.isArray(candle) || candle.length < 5) continue;
    const ts = candle[0] >= 1e12 ? candle[0] : candle[0] * 1000;
    const price = candle[4];
    if (!ts || !price || price <= 0) continue;
    args.push(ts, `${ts}:${price}`);
  }
  if (args.length > 0) {
    await c.zadd(priceKey(mint), ...args);
    await c.sadd(`${KEY_PREFIX}mints`, mint);
    if (symbol) await c.set(symbolKey(mint), symbol, 'EX', Math.ceil(MAX_AGE_MS / 1000));
  }
}

/**
 * Batch add multiple pools in one pipeline (worker use)
 */
export async function addPricesBatch(pools) {
  const c = getClient();
  if (!c) return;
  const pipeline = c.pipeline();
  for (const p of pools) {
    if (!p?.ohlcv?.length || !p.tokenMint) continue;
    const mint = p.tokenMint;
    const symbol = p.symbol || '?';
    const args = [];
    for (const candle of p.ohlcv) {
      if (!Array.isArray(candle) || candle.length < 5) continue;
      const ts = candle[0] >= 1e12 ? candle[0] : candle[0] * 1000;
      const price = candle[4];
      if (!ts || !price || price <= 0) continue;
      args.push(ts, `${ts}:${price}`);
    }
    if (args.length > 0) {
      pipeline.zadd(priceKey(mint), ...args);
      pipeline.sadd(`${KEY_PREFIX}mints`, mint);
      pipeline.set(symbolKey(mint), symbol, 'EX', Math.ceil(MAX_AGE_MS / 1000));
    }
  }
  await pipeline.exec();
}

/**
 * Load all price history from Redis into a Map<mint, {price,ts}[]>
 */
export async function loadPriceHistory() {
  const c = getClient();
  if (!c) return new Map();
  const mints = await c.smembers(`${KEY_PREFIX}mints`);
  const out = new Map();
  const pipeline = c.pipeline();
  for (const mint of mints) {
    pipeline.zrangebyscore(priceKey(mint), Date.now() - MAX_AGE_MS, '+inf', 'WITHSCORES');
  }
  const results = await pipeline.exec();
  for (let i = 0; i < mints.length; i++) {
    const mint = mints[i];
    const [, rows] = results[i] || [null, []];
    if (!Array.isArray(rows) || rows.length < 2) continue;
    const arr = [];
    for (let j = 0; j < rows.length; j += 2) {
      const val = rows[j] || '';
      const score = parseFloat(rows[j + 1]) || 0;
      const price = parseFloat(String(val).split(':')[1]) || 0;
      if (price > 0) arr.push({ ts: score, price });
    }
    arr.sort((a, b) => b.ts - a.ts);
    if (arr.length > 0) out.set(mint, arr);
  }
  return out;
}

/**
 * Load token symbols from Redis
 */
async function loadSymbols() {
  const c = getClient();
  if (!c) return new Map();
  const mints = await c.smembers(`${KEY_PREFIX}mints`);
  const out = new Map();
  const pipeline = c.pipeline();
  for (const mint of mints) {
    pipeline.get(symbolKey(mint));
  }
  const results = await pipeline.exec();
  for (let i = 0; i < mints.length; i++) {
    const [, val] = results[i] || [null, null];
    if (val) out.set(mints[i], val);
  }
  return out;
}

/**
 * Trim old data for all mints. Run periodically.
 */
async function trimAll() {
  const c = getClient();
  if (!c) return;
  const cutoff = Date.now() - MAX_AGE_MS;
  const mints = await c.smembers(`${KEY_PREFIX}mints`);
  const pipeline = c.pipeline();
  for (const mint of mints) {
    pipeline.zremrangebyscore(priceKey(mint), '-inf', cutoff);
  }
  await pipeline.exec();
}

/**
 * Start background sync from Redis into the given priceHistory Map.
 * Call with the contribute module's priceHistory so pump detection sees merged data.
 */
export function startSync(priceHistory, tokenSymbols) {
  if (!REDIS_URL) return;
  const sync = async () => {
    try {
      const [fromRedis, symbols] = await Promise.all([loadPriceHistory(), loadSymbols()]);
      for (const [mint, sym] of symbols) {
        tokenSymbols.set(mint, sym);
      }
      for (const [mint, arr] of fromRedis) {
        let existing = priceHistory.get(mint);
        if (!existing) {
          priceHistory.set(mint, [...arr]);
          continue;
        }
        const byTs = new Map(existing.map((e) => [e.ts, e]));
        for (const e of arr) {
          if (!byTs.has(e.ts)) byTs.set(e.ts, e);
        }
        const merged = [...byTs.values()].sort((a, b) => b.ts - a.ts);
        priceHistory.set(mint, merged);
      }
    } catch (e) {
      console.error('[REDIS] sync', e.message);
    }
  };
  sync();
  syncTimer = setInterval(sync, SYNC_INTERVAL_MS);
  trimTimer = setInterval(() => trimAll().catch((e) => console.error('[REDIS] trim', e.message)), TRIM_INTERVAL_MS);
}

export function stopSync() {
  if (syncTimer) {
    clearInterval(syncTimer);
    syncTimer = null;
  }
  if (trimTimer) {
    clearInterval(trimTimer);
    trimTimer = null;
  }
  if (client) {
    client.disconnect();
    client = null;
  }
}

export function isEnabled() {
  return !!REDIS_URL;
}

/**
 * Check Redis connection health
 */
export async function getHealth() {
  const c = getClient();
  if (!c) return { connected: false };
  try {
    const pong = await c.ping();
    return { connected: pong === 'PONG' };
  } catch {
    return { connected: false };
  }
}
