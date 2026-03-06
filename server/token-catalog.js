/**
 * Token Catalog - 1M token target
 * Aggregates from: Birdeye, Raydium, Jupiter, Solana list, Gecko, DexScreener
 * Run as background job; main scan samples from catalog.
 */

const BIRDEYE_BASE = 'https://public-api.birdeye.so';
const RAYDIUM_PAIRS = 'https://api.raydium.io/v2/main/pairs';
const JUPITER_URLS = [
  'https://cache.jup.ag/tokens?tags=verified',
  'https://cache.jup.ag/tokens',
  'https://token.jup.ag/strict',
  'https://token.jup.ag/all',
];
const SOLANA_TOKEN_LIST = 'https://raw.githubusercontent.com/solana-labs/token-list/main/src/tokens/solana.tokenlist.json';
const DEXSCREENER_PROFILES = 'https://api.dexscreener.com/token-profiles/latest/v1';

const catalog = new Map(); // mint -> { symbol, source, addedAt }
let lastBuildAt = 0;
let buildInProgress = false;
let lastStats = { total: 0, bySource: {}, error: null };

const SOL_MINT = 'So11111111111111111111111111111111111111112';

function add(mint, symbol = '?', source = 'unknown') {
  if (!mint || mint === SOL_MINT || mint.length < 32) return;
  if (!catalog.has(mint)) {
    catalog.set(mint, { symbol, source, addedAt: Date.now() });
  }
}

/**
 * Birdeye: 14k+ tokens, full pagination
 */
async function fetchBirdeye(apiKey, maxPages = 280) {
  const mints = [];
  const delay = parseInt(process.env.BIRDEYE_DELAY_MS || '1100', 10);
  for (let offset = 0; offset < maxPages * 50; offset += 50) {
    const url = `${BIRDEYE_BASE}/defi/tokenlist?sort_by=v24hChangePercent&sort_type=desc&offset=${offset}&limit=50`;
    const res = await fetch(url, {
      headers: { 'X-API-KEY': apiKey, 'x-chain': 'solana', Accept: 'application/json' },
    });
    if (!res.ok) break;
    const data = await res.json();
    const items = data?.data?.tokens ?? [];
    if (items.length === 0) break;
    for (const t of items) {
      if (t.address) mints.push({ mint: t.address, symbol: t.symbol || '?' });
    }
    if (items.length < 50) break;
    await new Promise((r) => setTimeout(r, delay));
  }
  return mints;
}

/**
 * Raydium: 100k+ pairs, extract baseMint/quoteMint
 */
async function fetchRaydium() {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 120_000);
  const res = await fetch(RAYDIUM_PAIRS, { signal: controller.signal });
  clearTimeout(timeout);
  if (!res.ok) return [];
  const arr = await res.json();
  const mints = [];
  const seen = new Set();
  for (const p of arr) {
    if (p.baseMint && !seen.has(p.baseMint)) {
      seen.add(p.baseMint);
      mints.push({ mint: p.baseMint, symbol: (p.name || '').split('/')[0]?.trim() || '?' });
    }
    if (p.quoteMint && !seen.has(p.quoteMint)) {
      seen.add(p.quoteMint);
      mints.push({ mint: p.quoteMint, symbol: '?' });
    }
  }
  return mints;
}

/**
 * Jupiter: token list with retries and multiple URLs
 */
async function fetchJupiter() {
  const maxRetries = 3;
  const retryDelay = 2000;

  for (const url of JUPITER_URLS) {
    for (let attempt = 1; attempt <= maxRetries; attempt++) {
      try {
        const res = await fetch(url, { signal: AbortSignal.timeout(60_000) });
        if (!res.ok) {
          if (res.status === 502 || res.status === 503) {
            await new Promise((r) => setTimeout(r, retryDelay * attempt));
            continue;
          }
          break;
        }
        const arr = await res.json();
        if (!Array.isArray(arr)) break;
        return arr.map((t) => ({ mint: t.address, symbol: t.symbol || t.name || '?' }));
      } catch (e) {
        if (attempt < maxRetries) {
          await new Promise((r) => setTimeout(r, retryDelay * attempt));
        }
      }
    }
  }
  return [];
}

/**
 * Solana official token list
 */
async function fetchSolanaList() {
  const res = await fetch(SOLANA_TOKEN_LIST, { signal: AbortSignal.timeout(30_000) });
  if (!res.ok) return [];
  const data = await res.json();
  const tokens = data?.tokens ?? [];
  return tokens.map((t) => ({ mint: t.address, symbol: t.symbol || t.name || '?' }));
}

/**
 * DexScreener token profiles (Solana only)
 */
async function fetchDexScreener() {
  const res = await fetch(DEXSCREENER_PROFILES, { signal: AbortSignal.timeout(15_000) });
  if (!res.ok) return [];
  const data = await res.json();
  if (!Array.isArray(data)) return [];
  return data
    .filter((t) => t.chainId === 'solana' && t.tokenAddress)
    .map((t) => ({ mint: t.tokenAddress, symbol: '?' }));
}

/**
 * Gecko: pool base tokens
 */
async function fetchGeckoPools() {
  const GECKO = 'https://api.geckoterminal.com/api/v2';
  const mints = [];
  const seen = new Set();
  for (const endpoint of [
    '/networks/solana/trending_pools',
    '/networks/solana/new_pools',
    '/networks/solana/pools?sort=h24_tx_count_desc',
  ]) {
    try {
      const res = await fetch(`${GECKO}${endpoint}`, {
        headers: { Accept: 'application/json;version=20230203' },
        signal: AbortSignal.timeout(15_000),
      });
      if (!res.ok) continue;
      const data = await res.json();
      const pools = data?.data ?? [];
      for (const p of pools) {
        const id = p?.relationships?.base_token?.data?.id;
        if (!id || seen.has(id)) continue;
        seen.add(id);
        const mint = id.split('_').pop();
        const name = (p?.attributes?.name || '?').split(' / ')[0];
        if (mint) mints.push({ mint, symbol: name || '?' });
      }
    } catch (_) {}
  }
  return mints;
}

/**
 * Build catalog from all sources
 */
async function buildCatalog(apiKey) {
  if (buildInProgress) return lastStats;
  buildInProgress = true;
  lastStats = { total: 0, bySource: {}, error: null };
  const start = Date.now();

  const run = async (name, fn) => {
    try {
      const list = await fn();
      for (const { mint, symbol } of list) add(mint, symbol, name);
      lastStats.bySource[name] = list.length;
      return list.length;
    } catch (e) {
      lastStats.bySource[name] = 0;
      lastStats.error = lastStats.error || e.message;
      return 0;
    }
  };

  await Promise.all([
    run('solana_list', fetchSolanaList),
    run('dexscreener', fetchDexScreener),
    run('gecko', fetchGeckoPools),
  ]);

  await run('jupiter', fetchJupiter);

  try {
    const ray = await fetchRaydium();
    for (const { mint, symbol } of ray) add(mint, symbol, 'raydium');
    lastStats.bySource.raydium = ray.length;
  } catch (_) {
    lastStats.bySource.raydium = 0;
  }

  if (apiKey) {
    try {
      const birdeye = await fetchBirdeye(apiKey);
      for (const { mint, symbol } of birdeye) add(mint, symbol, 'birdeye');
      lastStats.bySource.birdeye = birdeye.length;
    } catch (e) {
      lastStats.bySource.birdeye = 0;
      lastStats.error = lastStats.error || e.message;
    }
  } else {
    lastStats.bySource.birdeye = 0;
  }

  lastStats.total = catalog.size;
  lastStats.durationMs = Date.now() - start;
  lastBuildAt = Date.now();
  buildInProgress = false;
  return lastStats;
}

/**
 * Get catalog for scan - returns array of mints
 */
function getCatalog() {
  return Array.from(catalog.keys());
}

/**
 * Get catalog size
 */
function getCatalogSize() {
  return catalog.size;
}

/**
 * Get stats
 */
function getStats() {
  return {
    ...lastStats,
    lastBuildAt,
    buildInProgress,
  };
}

/**
 * Start background catalog builder (runs every N hours)
 */
function startCatalogBuilder(apiKey, intervalHours = 6) {
  const run = async () => {
    const stats = await buildCatalog(apiKey);
    console.log('[TOKEN_CATALOG] Built:', stats.total, 'tokens', stats.bySource);
    saveCatalogToRedis().catch(() => {});
  };
  run();
  const ms = intervalHours * 60 * 60 * 1000;
  setInterval(run, ms);
  console.log('[TOKEN_CATALOG] Builder started, refresh every', intervalHours, 'h');
}

const CATALOG_REDIS_KEY = 'pump:catalog:mints';

async function saveCatalogToRedis() {
  const { getClient } = await import('./redis-store.js');
  const c = getClient?.();
  if (!c) return;
  const mints = Array.from(catalog.keys());
  if (mints.length === 0) return;
  await c.del(CATALOG_REDIS_KEY);
  const batch = 10000;
  for (let i = 0; i < mints.length; i += batch) {
    await c.sadd(CATALOG_REDIS_KEY, ...mints.slice(i, i + batch));
  }
  console.log('[TOKEN_CATALOG] Saved', mints.length, 'to Redis');
}

async function loadCatalogFromRedis() {
  const { getClient } = await import('./redis-store.js');
  const c = getClient?.();
  if (!c) return 0;
  const mints = await c.smembers(CATALOG_REDIS_KEY);
  for (const m of mints) add(m, '?', 'redis');
  if (mints.length > 0) console.log('[TOKEN_CATALOG] Loaded', mints.length, 'from Redis');
  return mints.length;
}

export {
  buildCatalog,
  getCatalog,
  getCatalogSize,
  getStats,
  startCatalogBuilder,
  add,
  saveCatalogToRedis,
  loadCatalogFromRedis,
};
