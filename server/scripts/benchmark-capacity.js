#!/usr/bin/env node
/**
 * Benchmark your server's contribute capacity
 * Simulates workers posting OHLCV data, measures sustained throughput
 *
 * Usage: HUB_URL=http://localhost:3000 node scripts/benchmark-capacity.js
 */

const HUB_URL = (process.env.HUB_URL || 'http://localhost:3000').replace(/\/$/, '');
const DURATION_SEC = parseInt(process.env.BENCHMARK_DURATION || '120', 10);
const CONCURRENT_WORKERS = parseInt(process.env.BENCHMARK_WORKERS || '5', 10);
const POOLS_PER_REQUEST = 5;
const CANDLES_PER_POOL = 65;

function makePayload() {
  const pools = [];
  for (let i = 0; i < POOLS_PER_REQUEST; i++) {
    const ts = Date.now() / 1000 - Math.random() * 3600;
    const ohlcv = [];
    for (let j = 0; j < CANDLES_PER_POOL; j++) {
      const price = 0.00001 + Math.random() * 0.01;
      ohlcv.push([ts - j * 60, price, price, price, price, 1000]);
    }
    pools.push({
      poolId: `bench_${i}_${Date.now()}`,
      tokenMint: `Mint${i}${Date.now().toString(36)}`,
      symbol: `BENCH${i}`,
      ohlcv,
    });
  }
  return { source: 'benchmark', network: 'solana', pools };
}

async function worker(workerId) {
  let success = 0;
  let samples = 0;
  let rateLimited = 0;
  for (let i = 0; i < 1000; i++) {
    try {
      const res = await fetch(`${HUB_URL}/contribute`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(makePayload()),
      });
      if (res.status === 429) {
        rateLimited++;
        await new Promise((r) => setTimeout(r, 2000));
        continue;
      }
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      const json = await res.json();
      success++;
      samples += json.samples ?? 0;
    } catch (e) {
      console.error(`[W${workerId}]`, e.message);
    }
    await new Promise((r) => setTimeout(r, 2500));
  }
  return { success, samples, rateLimited };
}

async function run() {
  console.log('Benchmark:', HUB_URL);
  console.log('Duration:', DURATION_SEC, 's | Workers:', CONCURRENT_WORKERS);
  console.log('Each request:', POOLS_PER_REQUEST, 'pools ×', CANDLES_PER_POOL, 'candles =', POOLS_PER_REQUEST * CANDLES_PER_POOL, 'samples');
  console.log('');

  const start = Date.now();
  const endAt = start + DURATION_SEC * 1000;

  const workers = [];
  for (let i = 0; i < CONCURRENT_WORKERS; i++) {
    workers.push((async () => {
      let totalSuccess = 0;
      let totalSamples = 0;
      let totalRateLimited = 0;
      while (Date.now() < endAt) {
        try {
          const res = await fetch(`${HUB_URL}/contribute`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(makePayload()),
          });
          if (res.status === 429) {
            totalRateLimited++;
            await new Promise((r) => setTimeout(r, 2000));
            continue;
          }
          if (!res.ok) throw new Error(`HTTP ${res.status}`);
          const json = await res.json();
          totalSuccess++;
          totalSamples += json.samples ?? 0;
        } catch (e) {
          console.error(`[W${i}]`, e.message);
        }
        await new Promise((r) => setTimeout(r, 2500));
      }
      return { success: totalSuccess, samples: totalSamples, rateLimited: totalRateLimited };
    })());
  }

  const results = await Promise.all(workers);
  const elapsed = (Date.now() - start) / 1000;

  const totalSuccess = results.reduce((s, r) => s + r.success, 0);
  const totalSamples = results.reduce((s, r) => s + r.samples, 0);
  const totalRateLimited = results.reduce((s, r) => s + r.rateLimited, 0);

  console.log('');
  console.log('--- Results ---');
  console.log('Elapsed:', elapsed.toFixed(1), 's');
  console.log('Requests:', totalSuccess, 'successful');
  console.log('Rate limited:', totalRateLimited);
  console.log('Samples received:', totalSamples);
  console.log('Samples/min:', ((totalSamples / elapsed) * 60).toFixed(0));
  console.log('Requests/min:', ((totalSuccess / elapsed) * 60).toFixed(1));
  console.log('');
  console.log('Note: Server rate limit is 30 req/min per IP. All workers use same IP in benchmark.');
  console.log('For real capacity, run workers on different servers (different IPs).');
}

run().catch((e) => {
  console.error(e);
  process.exit(1);
});
