/**
 * Birdeye API - massive token discovery
 * 14,000+ Solana tokens, 50-100 per call, pagination
 * Requires BIRDEYE_API_KEY (free at bds.birdeye.so)
 * Free tier: ~1 rps. Paid: much higher.
 */

const BIRDEYE_BASE = 'https://public-api.birdeye.so';
const DELAY_MS = parseInt(process.env.BIRDEYE_DELAY_MS || '1100', 10);
const BIRDEYE_PAGES = parseInt(process.env.BIRDEYE_PAGES || '20', 10);

function sleep(ms) {
  return new Promise((r) => setTimeout(r, ms));
}

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
 * Fetch token list sorted by 24h price change (top gainers)
 * Returns tokens with v24hChangePercent - use as pump candidates
 */
async function fetchTokenListGainers(apiKey, pages = 20) {
  const tokens = [];
  for (let offset = 0; offset < pages * 50; offset += 50) {
    const url = `${BIRDEYE_BASE}/defi/tokenlist?sort_by=v24hChangePercent&sort_type=desc&offset=${offset}&limit=50`;
    const data = await fetchJson(url, apiKey);
    const items = data?.data?.tokens ?? [];
    if (items.length === 0) break;
    tokens.push(...items);
    if (items.length < 50) break;
    await sleep(DELAY_MS);
  }
  return tokens;
}

/**
 * Fetch pumps: tokens with 100%+ 24h change (proxy for pump)
 * Different rule than Gecko 100%/10min - this is 100%+/24h
 */
async function fetchPumpsFromBirdeye(apiKey, pumpDef) {
  const minChange = pumpDef === 'fiftyPerc20min' ? 50 : 100;
  const tokens = await fetchTokenListGainers(apiKey, BIRDEYE_PAGES);
  const alerts = [];

  for (const t of tokens) {
    const change = parseFloat(t.v24hChangePercent) || 0;
    if (change < minChange) continue;

    const addr = t.address;
    if (!addr || addr === 'So11111111111111111111111111111111111111112') continue;

    const liquidity = parseFloat(t.liquidity) || 0;
    if (liquidity < 1000) continue;

    alerts.push({
      id: `birdeye_${addr}`,
      source: 'birdeye',
      symbol: `${t.symbol || '?'} (solana)`,
      priceChangePercent: change,
      price: parseFloat(t.price_usd) || 0,
      network: 'solana',
      baseTokenMint: addr,
    });
  }
  return alerts;
}

export { fetchTokenListGainers, fetchPumpsFromBirdeye };
