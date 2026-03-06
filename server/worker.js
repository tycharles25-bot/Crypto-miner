#!/usr/bin/env node
/**
 * Worker mode: fetches Gecko OHLCV and POSTs to hub /contribute
 * Run on separate servers OR with different proxies for multi-IP on one machine.
 *
 * Usage:
 *   HUB_URL=https://your-hub.com node worker.js
 *   HTTP_PROXY=http://proxy1:8080 node worker.js  # different IP per worker
 */

import dotenv from 'dotenv';
import path from 'path';
import { fileURLToPath } from 'url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
dotenv.config({ path: path.join(__dirname, '.env') });

// Proxy setup BEFORE gecko import - each worker gets its own IP when using different proxies
const proxy = (process.env.HTTP_PROXY || process.env.HTTPS_PROXY || '').trim();
if (proxy) {
  const { ProxyAgent, fetch: undiciFetch } = await import('undici');
  globalThis.fetch = (url, opts) =>
    undiciFetch(url, { ...opts, dispatcher: new ProxyAgent(proxy) });
}

const { fetchPoolsWithOHLCVForContribution } = await import('./gecko.js');
const { addPricesBatch, isEnabled: redisEnabled } = await import('./redis-store.js');

const HUB_URL = (process.env.HUB_URL || '').trim().replace(/\/$/, '');
const REDIS_URL = (process.env.REDIS_URL || '').trim();
const WORKER_INTERVAL_MS = parseInt(process.env.WORKER_INTERVAL_MS || '120000', 10); // 2 min
const WORKER_MAX_POOLS = parseInt(process.env.WORKER_MAX_POOLS || '25', 10);

if (!HUB_URL && !REDIS_URL) {
  console.error('HUB_URL or REDIS_URL required. Set in .env');
  process.exit(1);
}

async function contribute() {
  try {
    const pools = await fetchPoolsWithOHLCVForContribution('solana', WORKER_MAX_POOLS);
    if (pools.length === 0) {
      console.log('[WORKER] No pools fetched');
      return;
    }

    if (redisEnabled()) {
      await addPricesBatch(pools);
    }

    if (HUB_URL) {
      const res = await fetch(`${HUB_URL}/contribute`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          source: 'gecko-worker',
          network: 'solana',
          pools,
        }),
      });

      if (!res.ok) {
        const err = await res.text();
        throw new Error(`${res.status} ${err}`);
      }

      const json = await res.json();
      const samples = json.samples ?? 0;
      const dest = [redisEnabled() && 'Redis', 'Hub'].filter(Boolean).join('+');
      console.log('[WORKER]', pools.length, 'pools,', samples, 'samples ->', dest);
    } else if (redisEnabled()) {
      const samples = pools.reduce((s, p) => s + (p.ohlcv?.length ?? 0), 0);
      console.log('[WORKER]', pools.length, 'pools,', samples, 'samples -> Redis');
    }
  } catch (e) {
    console.error('[WORKER]', e.message);
  }
}

async function run() {
  const proxyMsg = proxy ? ' | Proxy: on' : '';
  const dest = [HUB_URL && 'Hub', redisEnabled() && 'Redis'].filter(Boolean).join('+') || '?';
  console.log('[WORKER] Started. Dest:', dest, '| Interval:', WORKER_INTERVAL_MS / 1000, 's' + proxyMsg);
  while (true) {
    await contribute();
    await new Promise((r) => setTimeout(r, WORKER_INTERVAL_MS));
  }
}

run();
