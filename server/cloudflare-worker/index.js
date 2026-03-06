/**
 * Cloudflare Worker: fetches Gecko OHLCV, POSTs to hub /contribute
 * Deploy multiple Workers (different names) - may run from different edge locations = different IPs
 * Free tier: 100k requests/day
 */

const GECKO_BASE = 'https://api.geckoterminal.com/api/v2';
const MAX_POOLS = 8;
const DELAY_MS = 1200;

function sleep(ms) {
  return new Promise((r) => setTimeout(r, ms));
}

function extractBaseMint(pool) {
  const id = pool?.relationships?.base_token?.data?.id;
  if (!id) return null;
  return id.split('_').pop() || id;
}

async function fetchGecko(url) {
  const res = await fetch(url, {
    headers: { Accept: 'application/json;version=20230203' },
  });
  if (!res.ok) throw new Error(`Gecko ${res.status}`);
  return res.json();
}

async function run(env) {
    const hubUrl = env.HUB_URL?.replace(/\/$/, '');
    if (!hubUrl) {
      console.error('HUB_URL secret required');
      return;
    }

    try {
      const poolsData = await fetchGecko(`${GECKO_BASE}/networks/solana/trending_pools`);
      const pools = poolsData?.data ?? [];
      const results = [];

      for (let i = 0; i < Math.min(pools.length, MAX_POOLS); i++) {
        const pool = pools[i];
        const baseMint = extractBaseMint(pool);
        if (!baseMint) continue;

        try {
          const ohlcvRes = await fetchGecko(
            `${GECKO_BASE}/networks/solana/pools/${pool.attributes.address}/ohlcv/minute?aggregate=1&limit=65`
          );
          const ohlcv = ohlcvRes?.data?.attributes?.ohlcv_list ?? [];
          if (ohlcv.length < 2) continue;

          const name = (pool.attributes?.name || '?').split(' / ')[0] || '?';
          results.push({
            poolId: pool.id,
            tokenMint: baseMint,
            symbol: name,
            ohlcv,
          });
        } catch (_) {}
        await sleep(DELAY_MS);
      }

      if (results.length === 0) return;

      const contributeRes = await fetch(`${hubUrl}/contribute`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          source: 'cloudflare-worker',
          network: 'solana',
          pools: results,
        }),
      });

      if (!contributeRes.ok) {
        console.error('Contribute', contributeRes.status, await contributeRes.text());
      }
    } catch (e) {
      console.error('Worker error:', e.message);
    }
}

export default {
  async scheduled(event, env, ctx) {
    await run(env);
  },
  async fetch(request, env, ctx) {
    await run(env);
    return new Response('OK', { status: 200 });
  },
};
