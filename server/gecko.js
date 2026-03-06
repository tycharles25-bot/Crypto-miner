/**
 * GeckoTerminal API - pump detection
 * Port of Swift GeckoTerminalService logic
 */

const GECKO_BASE = 'https://api.geckoterminal.com/api/v2';
const SCAN_NETWORKS = ['solana', 'base', 'eth', 'arbitrum', 'bsc'];

const POOL_DELAY_MS = parseInt(process.env.POOL_DELAY_MS || '3500', 10);
const SOLANA_POOL_PAGES = parseInt(process.env.SOLANA_POOL_PAGES || '5', 10);
const MIN_LIQUIDITY_USD = parseFloat(process.env.MIN_LIQUIDITY_USD || '0', 10);
const MIN_MCAP_USD = parseFloat(process.env.MIN_MCAP_USD || '0', 10);
const MAX_POOLS_FOR_OHLCV = parseInt(process.env.MAX_POOLS_FOR_OHLCV || '30', 10);

async function fetchJson(url) {
  const res = await fetch(url, {
    headers: { Accept: 'application/json;version=20230203' },
  });
  if (!res.ok) {
    if (res.status === 429) console.error('[GECKO] 429 Too Many Requests');
    throw new Error(`Gecko ${res.status}`);
  }
  return res.json();
}

async function fetchTrendingPools(network) {
  const data = await fetchJson(`${GECKO_BASE}/networks/${network}/trending_pools`);
  return data?.data ?? [];
}

async function fetchTrendingPoolsPaginated(network, pages = 5) {
  const all = [];
  for (let p = 1; p <= Math.min(pages, 10); p++) {
    const data = await fetchJson(`${GECKO_BASE}/networks/${network}/trending_pools?page=${p}`);
    const pools = data?.data ?? [];
    if (pools.length === 0) break;
    all.push(...pools);
    if (p < pages) await sleep(POOL_DELAY_MS);
  }
  return all;
}

async function fetchNewPools(network, pages = 3) {
  const all = [];
  for (let p = 1; p <= Math.min(pages, 10); p++) {
    const data = await fetchJson(`${GECKO_BASE}/networks/${network}/new_pools?page=${p}`);
    const pools = data?.data ?? [];
    if (pools.length === 0) break;
    all.push(...pools);
    if (p < pages) await sleep(POOL_DELAY_MS);
  }
  return all;
}

async function fetchTopPools(network, pages = 3) {
  const all = [];
  for (let p = 1; p <= Math.min(pages, 10); p++) {
    const data = await fetchJson(`${GECKO_BASE}/networks/${network}/pools?page=${p}&sort=h24_tx_count_desc`);
    const pools = data?.data ?? [];
    if (pools.length === 0) break;
    all.push(...pools);
    if (p < pages) await sleep(POOL_DELAY_MS);
  }
  return all;
}

async function fetchAllSolanaPools() {
  const seen = new Set();
  const pools = [];
  const addUnique = (list) => {
    for (const p of list) {
      const addr = p?.attributes?.address;
      if (addr && !seen.has(addr)) {
        seen.add(addr);
        pools.push(p);
      }
    }
  };
  try {
    addUnique(await fetchTrendingPoolsPaginated('solana', SOLANA_POOL_PAGES));
    await sleep(POOL_DELAY_MS);
    addUnique(await fetchNewPools('solana', Math.max(1, SOLANA_POOL_PAGES)));
    await sleep(POOL_DELAY_MS);
    addUnique(await fetchTopPools('solana', Math.max(1, SOLANA_POOL_PAGES)));
  } catch (e) {
    console.error('[POOLS]', e.message);
  }
  return pools;
}

async function fetchOHLCV(network, poolAddress, limit = 5) {
  const url = `${GECKO_BASE}/networks/${network}/pools/${poolAddress}/ohlcv/hour?aggregate=1&limit=${limit}`;
  const data = await fetchJson(url);
  return data?.data?.attributes?.ohlcv_list ?? [];
}

async function fetchOHLCVMinute(network, poolAddress, limit = 65) {
  const url = `${GECKO_BASE}/networks/${network}/pools/${poolAddress}/ohlcv/minute?aggregate=1&limit=${limit}`;
  const data = await fetchJson(url);
  return data?.data?.attributes?.ohlcv_list ?? [];
}

function extractBaseMint(pool) {
  const id = pool?.relationships?.base_token?.data?.id;
  if (!id) return null;
  const parts = id.split('_');
  return parts[parts.length - 1] ?? id;
}

function has100Percent10minPump(minuteOhlcv, minPercent = 100) {
  if (!minuteOhlcv || minuteOhlcv.length < 60) return false;
  const closes = minuteOhlcv.map((r) => r[4]);
  const pairs = [
    [59, 49], [49, 39], [39, 29], [29, 19], [19, 9], [9, 0],
  ];
  for (const [prev, curr] of pairs) {
    if (closes[prev] <= 0) continue;
    const gain = (closes[curr] / closes[prev] - 1) * 100;
    if (gain >= minPercent) return true;
  }
  return false;
}

function hasSingle20minPump(minuteOhlcv, minPercent = 10) {
  if (!minuteOhlcv || minuteOhlcv.length < 60) return false;
  const closes = minuteOhlcv.map((r) => r[4]);
  const pairs = [[59, 39], [39, 19], [19, 0]];
  for (const [prev, curr] of pairs) {
    if (closes[prev] <= 0) continue;
    const gain = (closes[curr] / closes[prev] - 1) * 100;
    if (gain >= minPercent) return true;
  }
  return false;
}

function has3Consecutive20minPumps(minuteOhlcv, minPercent = 10) {
  if (!minuteOhlcv || minuteOhlcv.length < 60) return false;
  const closes = minuteOhlcv.map((r) => r[4]);
  const pairs = [[59, 39], [39, 19], [19, 0]];
  for (const [prev, curr] of pairs) {
    if (closes[prev] <= 0) return false;
    const gain = (closes[curr] / closes[prev] - 1) * 100;
    if (gain < minPercent) return false;
  }
  return true;
}

function has3ConsecutiveHourlyPumps(ohlcv, minPercent = 10) {
  if (!ohlcv || ohlcv.length < 4) return false;
  const closes = ohlcv.map((r) => r[4]);
  for (let i = 0; i < 3; i++) {
    if (closes[i + 1] <= 0) return false;
    const gain = (closes[i] / closes[i + 1] - 1) * 100;
    if (gain < minPercent) return false;
  }
  return true;
}

async function fetchPumps100perc10min(network) {
  const pools = network === 'solana'
    ? await fetchAllSolanaPools()
    : await fetchTrendingPools(network);
  const toCheck = MAX_POOLS_FOR_OHLCV > 0 ? pools.slice(0, MAX_POOLS_FOR_OHLCV) : pools;
  const alerts = [];
  for (const pool of toCheck) {
    try {
      const attrs = pool.attributes || {};
      const liquidity = parseFloat(attrs.reserve_in_usd) || 0;
      const mcap = parseFloat(attrs.fdv_usd || attrs.market_cap_usd) || 0;
      if (MIN_LIQUIDITY_USD > 0 && liquidity < MIN_LIQUIDITY_USD) continue;
      if (MIN_MCAP_USD > 0 && mcap > 0 && mcap < MIN_MCAP_USD) continue;

      const ohlcv = await fetchOHLCVMinute(network, pool.attributes.address);
      if (!has100Percent10minPump(ohlcv, 100)) continue;
      const closes = ohlcv.map((r) => r[4]);
      const lastClose = closes[0];
      const sixtyMinAgo = closes.length > 59 ? closes[59] : lastClose;
      const totalChange = sixtyMinAgo > 0 ? (lastClose / sixtyMinAgo - 1) * 100 : 0;
      const baseMint = extractBaseMint(pool);
      if (!baseMint) continue;
      alerts.push({
        id: pool.id,
        source: 'gecko',
        symbol: `${(pool.attributes.name.split(' / ')[0] || pool.attributes.name)} (${network})`,
        priceChangePercent: totalChange,
        price: parseFloat(pool.attributes.base_token_price_usd || lastClose) || lastClose,
        network,
        baseTokenMint: baseMint,
      });
    } catch (_) {}
    await sleep(POOL_DELAY_MS);
  }
  return alerts;
}

async function fetchPumps50perc20min(network) {
  const pools = network === 'solana'
    ? await fetchAllSolanaPools()
    : await fetchTrendingPools(network);
  const toCheck = MAX_POOLS_FOR_OHLCV > 0 ? pools.slice(0, MAX_POOLS_FOR_OHLCV) : pools;
  const alerts = [];
  for (const pool of toCheck) {
    try {
      const attrs = pool.attributes || {};
      const liquidity = parseFloat(attrs.reserve_in_usd) || 0;
      const mcap = parseFloat(attrs.fdv_usd || attrs.market_cap_usd) || 0;
      if (MIN_LIQUIDITY_USD > 0 && liquidity < MIN_LIQUIDITY_USD) continue;
      if (MIN_MCAP_USD > 0 && mcap > 0 && mcap < MIN_MCAP_USD) continue;

      const ohlcv = await fetchOHLCVMinute(network, pool.attributes.address);
      if (!hasSingle20minPump(ohlcv, 50)) continue;
      const closes = ohlcv.map((r) => r[4]);
      const lastClose = closes[0];
      const sixtyMinAgo = closes.length > 59 ? closes[59] : lastClose;
      const totalChange = sixtyMinAgo > 0 ? (lastClose / sixtyMinAgo - 1) * 100 : 0;
      const baseMint = extractBaseMint(pool);
      if (!baseMint) continue;
      alerts.push({
        id: pool.id,
        source: 'gecko',
        symbol: `${(pool.attributes.name.split(' / ')[0] || pool.attributes.name)} (${network})`,
        priceChangePercent: totalChange,
        price: parseFloat(pool.attributes.base_token_price_usd || lastClose) || lastClose,
        network,
        baseTokenMint: baseMint,
      });
    } catch (_) {}
    await sleep(POOL_DELAY_MS);
  }
  return alerts;
}

function sleep(ms) {
  return new Promise((r) => setTimeout(r, ms));
}

/**
 * Fetch Solana pools with minute OHLCV for contribution to hub
 * Returns [{ poolId, tokenMint, symbol, ohlcv }]
 */
async function fetchPoolsWithOHLCVForContribution(network = 'solana', maxPools = 30) {
  const pools = network === 'solana' ? await fetchAllSolanaPools() : await fetchTrendingPools(network);
  const results = [];
  for (let i = 0; i < Math.min(pools.length, maxPools); i++) {
    const pool = pools[i];
    const baseMint = extractBaseMint(pool);
    if (!baseMint) continue;
    try {
      const ohlcv = await fetchOHLCVMinute(network, pool.attributes.address);
      if (ohlcv.length < 2) continue;
      const name = (pool.attributes?.name || '?').split(' / ')[0] || '?';
      results.push({
        poolId: pool.id,
        tokenMint: baseMint,
        symbol: name,
        ohlcv,
      });
    } catch (_) {}
    await sleep(POOL_DELAY_MS);
  }
  return results;
}

export {
  SCAN_NETWORKS,
  fetchTrendingPools,
  fetchOHLCV,
  fetchOHLCVMinute,
  fetchPumps100perc10min,
  fetchPumps50perc20min,
  extractBaseMint,
  fetchPoolsWithOHLCVForContribution,
};
