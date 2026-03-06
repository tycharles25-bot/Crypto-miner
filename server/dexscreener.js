/**
 * DexScreener API - alternative token discovery (Solana)
 * 300 req/min for pairs, no API key required
 */

const DEXSCREENER_BASE = 'https://api.dexscreener.com';
const DELAY_MS = parseInt(process.env.DEXSCREENER_DELAY_MS || '250', 10);

function sleep(ms) {
  return new Promise((r) => setTimeout(r, ms));
}

async function fetchJson(url) {
  const res = await fetch(url);
  if (!res.ok) throw new Error(`DexScreener ${res.status}`);
  return res.json();
}

async function fetchLatestTokenProfiles() {
  const data = await fetchJson(`${DEXSCREENER_BASE}/token-profiles/latest/v1`);
  if (!Array.isArray(data)) return [];
  return data.filter((t) => t.chainId === 'solana');
}

async function fetchTokenPairs(tokenAddress) {
  const data = await fetchJson(
    `${DEXSCREENER_BASE}/token-pairs/v1/solana/${tokenAddress}`
  );
  if (!Array.isArray(data) || data.length === 0) return null;
  return data[0];
}

/**
 * Fetch pumps from DexScreener using priceChange
 * 100%/5min: priceChange.m5 >= 100
 * 100%/1h: priceChange.h1 >= 100
 * 50%/1h: priceChange.h1 >= 50
 */
async function fetchPumpsFromDexScreener(pumpDef) {
  const tokens = await fetchLatestTokenProfiles();
  const alerts = [];
  // hundredPerc10min: use m5 (5min) only - h1 (1hr) is too loose for "10min pump"
  // fiftyPerc20min: use h1 (1hr) as proxy for 20min
  const minM5 = pumpDef === 'hundredPerc10min' ? 100 : 0;
  const minH1 = pumpDef === 'fiftyPerc20min' ? 50 : 0;

  for (const token of tokens) {
    const addr = token.tokenAddress;
    if (!addr) continue;
    try {
      const pair = await fetchTokenPairs(addr);
      if (!pair?.priceChange) continue;

      const pc = pair.priceChange;
      const m5 = parseFloat(pc.m5) || 0;
      const h1 = parseFloat(pc.h1) || 0;

      const hitsRule = (minM5 > 0 && m5 >= minM5) || (minH1 > 0 && h1 >= minH1);
      if (!hitsRule) continue;

      const symbol = pair.baseToken?.symbol || '?';
      const name = pair.baseToken?.name || symbol;
      const priceChange = Math.max(m5, h1);
      const price = parseFloat(pair.priceUsd) || 0;

      alerts.push({
        id: `dexscreener_${addr}`,
        source: 'dexscreener',
        symbol: `${name} (solana)`,
        priceChangePercent: priceChange,
        price,
        network: 'solana',
        baseTokenMint: addr,
      });
    } catch (_) {}
    await sleep(DELAY_MS);
  }
  return alerts;
}

export { fetchLatestTokenProfiles, fetchTokenPairs, fetchPumpsFromDexScreener };
