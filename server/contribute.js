/**
 * Client-side contribution store
 * Receives price/OHLCV data from iOS app (and future clients)
 * Each client fetches from Gecko/etc from their own IP - multiplies coverage
 * Redis: when REDIS_URL set, writes to shared store for distributed mesh
 */

import { addPrices, isEnabled, startSync } from './redis-store.js';
import { add as catalogAdd } from './token-catalog.js';

const MAX_AGE_MS = 24 * 60 * 60 * 1000;
const RATE_LIMIT_WINDOW_MS = 60 * 1000;
const RATE_LIMIT_MAX_PER_IP = parseInt(process.env.CONTRIBUTE_RATE_LIMIT_PER_IP || '30', 10);
const priceHistory = new Map();
const tokenSymbols = new Map();
const ipRequestCount = new Map();
const throughputSamples = [];
const THROUGHPUT_WINDOW_MS = 60 * 1000;

function trimHistory() {
  const cutoff = Date.now() - MAX_AGE_MS;
  for (const [mint, arr] of priceHistory) {
    while (arr.length > 0 && arr[arr.length - 1].ts < cutoff) arr.pop();
    if (arr.length === 0) priceHistory.delete(mint);
  }
}

function rateLimit(ip) {
  const now = Date.now();
  let bucket = ipRequestCount.get(ip) || { count: 0, resetAt: now + RATE_LIMIT_WINDOW_MS };
  if (now > bucket.resetAt) bucket = { count: 0, resetAt: now + RATE_LIMIT_WINDOW_MS };
  bucket.count++;
  ipRequestCount.set(ip, bucket);
  return bucket.count <= RATE_LIMIT_MAX_PER_IP;
}

/**
 * Handle contributed data from clients
 * Body: { source, network, pools: [{ poolId, tokenMint, symbol, ohlcv: [[ts,o,h,l,c,v], ...] }] }
 */
function handleContribution(body) {
  if (!body?.pools || !Array.isArray(body.pools)) return 0;
  const network = (body.network || 'solana').toLowerCase();
  if (network !== 'solana') return 0;

  let count = 0;
  for (const pool of body.pools) {
    const mint = pool.tokenMint;
    const ohlcv = pool.ohlcv;
    const symbol = pool.symbol || '?';
    if (!mint || !Array.isArray(ohlcv)) continue;
    catalogAdd(mint, symbol, 'contribute');
    tokenSymbols.set(mint, symbol);

    for (const candle of ohlcv) {
      if (!Array.isArray(candle) || candle.length < 5) continue;
      const ts = candle[0];
      const close = candle[4];
      if (!ts || !close || close <= 0) continue;

      const timestamp = ts >= 1e12 ? ts : ts * 1000;
      let arr = priceHistory.get(mint);
      if (!arr) {
        arr = [];
        priceHistory.set(mint, arr);
      }
      arr.push({ price: close, ts: timestamp });
      arr.sort((a, b) => b.ts - a.ts);
      count++;
    }
    if (isEnabled()) addPrices(mint, ohlcv, symbol).catch(() => {});
  }
  if (count > 0) {
    trimHistory();
    const now = Date.now();
    throughputSamples.push({ ts: now, count });
    while (throughputSamples.length > 0 && throughputSamples[0].ts < now - THROUGHPUT_WINDOW_MS) {
      throughputSamples.shift();
    }
  }
  return count;
}

function getPumpsFromContributed(pumpDef) {
  const now = Date.now();
  const window = pumpDef === 'hundredPerc10min' ? 10 * 60 * 1000 : 20 * 60 * 1000;
  const minChange = pumpDef === 'hundredPerc10min' ? 100 : 50;

  const alerts = [];
  for (const [mint, arr] of priceHistory) {
    if (arr.length < 2) continue;
    const priceNow = arr[0].price;
    const tsNow = arr[0].ts;
    if (tsNow < now - 5 * 60 * 1000) continue;

    const targetBefore = now - window;
    const beforeCandidates = arr.filter((e) => e.ts <= targetBefore + 60000);
    if (beforeCandidates.length < 1) continue;
    const priceBefore = beforeCandidates[0].price;
    if (priceBefore <= 0) continue;

    const changePct = (priceNow / priceBefore - 1) * 100;
    if (changePct < minChange) continue;

    const symbol = tokenSymbols.get(mint) || '?';
    alerts.push({
      id: `contribute_${mint}`,
      source: 'contribute',
      symbol: `${symbol} (solana)`,
      priceChangePercent: changePct,
      price: priceNow,
      network: 'solana',
      baseTokenMint: mint,
    });
  }
  return alerts;
}

function getStats() {
  let totalSamples = 0;
  for (const arr of priceHistory.values()) totalSamples += arr.length;
  const now = Date.now();
  const samplesLastMin = throughputSamples
    .filter((s) => s.ts >= now - THROUGHPUT_WINDOW_MS)
    .reduce((sum, s) => sum + s.count, 0);
  return {
    tokensTracked: priceHistory.size,
    totalSamples,
    samplesPerMinute: samplesLastMin,
    rateLimitPerIP: RATE_LIMIT_MAX_PER_IP,
  };
}

function processContribution(body, ip) {
  if (!rateLimit(ip)) return { ok: false, rateLimited: true };
  const count = handleContribution(body);
  return { ok: true, count };
}

export function initContributeRedis() {
  if (isEnabled()) startSync(priceHistory, tokenSymbols);
}

export { handleContribution, processContribution, getPumpsFromContributed, getStats as getContributeStats };
