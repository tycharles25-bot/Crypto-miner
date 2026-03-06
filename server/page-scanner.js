/**
 * Page-by-page token scanner
 * Birdeye has the most tokens available via API (14k+), 50 per page
 * Runs at 1 page per minute
 * DexScreener website (43k pairs) is Cloudflare-protected - not scrapeable
 */

const BIRDEYE_BASE = 'https://public-api.birdeye.so';
const PAGE_INTERVAL_MS = parseInt(process.env.PAGE_SCANNER_INTERVAL_MS || '60000', 10); // 1 page per minute
const MIN_LIQUIDITY = parseFloat(process.env.PAGE_SCANNER_MIN_LIQUIDITY || '1000', 10);

const pumpCandidates = new Map(); // mint -> { symbol, priceChangePercent, price, ... }
let currentOffset = 0;
let lastPageAt = 0;
let lastError = null;

async function fetchJson(url, apiKey) {
  const res = await fetch(url, {
    headers: {
      'X-API-KEY': apiKey,
      'x-chain': 'solana',
      Accept: 'application/json',
    },
  });
  if (!res.ok) throw new Error(`Birdeye ${res.status}`);
  return res.json();
}

/**
 * Fetch one page of tokens (50) from Birdeye, sorted by 24h price change
 */
async function fetchOnePage(apiKey, offset) {
  const url = `${BIRDEYE_BASE}/defi/tokenlist?sort_by=v24hChangePercent&sort_type=desc&offset=${offset}&limit=50`;
  const data = await fetchJson(url, apiKey);
  return data?.data?.tokens ?? [];
}

/**
 * Process one page and add pump candidates to store
 * Store all with 50%+ so we can filter at read time
 */
function processPage(tokens) {
  for (const t of tokens) {
    const change = parseFloat(t.v24hChangePercent) || 0;
    if (change < 50) continue;

    const addr = t.address;
    if (!addr || addr === 'So11111111111111111111111111111111111111112') continue;

    const liquidity = parseFloat(t.liquidity) || 0;
    if (liquidity < MIN_LIQUIDITY) continue;

    pumpCandidates.set(addr, {
      id: `page_${addr}`,
      source: 'page',
      symbol: `${t.symbol || '?'} (solana)`,
      priceChangePercent: change,
      price: parseFloat(t.price_usd) || 0,
      network: 'solana',
      baseTokenMint: addr,
    });
  }
}

/**
 * Get pump candidates from page scanner (for main scan)
 */
function getPumpsFromPageScanner(pumpDef) {
  const minChange = pumpDef === 'fiftyPerc20min' ? 50 : 100;
  return Array.from(pumpCandidates.values()).filter(
    (p) => (p.priceChangePercent || 0) >= minChange
  );
}

/**
 * Start page scanner loop
 */
function startPageScanner(apiKey) {
  if (!apiKey) return;

  const run = async () => {
    try {
      const tokens = await fetchOnePage(apiKey, currentOffset);
      lastPageAt = Date.now();
      lastError = null;

      if (tokens.length > 0) {
        processPage(tokens);
        currentOffset += tokens.length;
        if (tokens.length < 50) currentOffset = 0; // wrap around
      } else {
        currentOffset = 0;
      }
    } catch (e) {
      lastError = e.message;
      console.error('[PAGE_SCANNER]', e.message);
    }
    setTimeout(() => run(), PAGE_INTERVAL_MS);
  };

  run();
  console.log(`[PAGE_SCANNER] Birdeye 1 page/${PAGE_INTERVAL_MS / 1000}s, offset ${currentOffset}`);
}

function getPageScannerStats() {
  return {
    enabled: pumpCandidates.size >= 0,
    candidatesCount: pumpCandidates.size,
    currentOffset,
    lastPageAt,
    lastError,
    intervalMs: PAGE_INTERVAL_MS,
  };
}

export {
  startPageScanner,
  getPumpsFromPageScanner,
  getPageScannerStats,
};
