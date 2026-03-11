/**
 * Render Pump Server - PumpApi + pump detection
 * Deploy to Render. iOS app polls GET /alerts
 */

import express from 'express';
import WebSocket from 'ws';

const PUMPAPI_WS = 'wss://stream.pumpapi.io/';
const RECONNECT_MS = 5000;
const MAX_AGE_MS = 24 * 60 * 60 * 1000;
const WINDOW_MS = 3 * 60 * 1000; // Compare to price 3 min ago
const MIN_CHANGE = parseInt(process.env.MIN_PUMP_PERCENT || '50', 10); // Min % gain — avoid flat/dumping tokens
const PRICE_MAX_AGE_MS = 60 * 1000; // Current price must be within 60 sec — avoid buying into dumps
const MAX_CHANGE = 10000; // Cap unrealistic outliers (e.g. 66M% from tiny priceBefore)
const MAX_ALERTS = 50;
const ALERT_MAX_AGE_MS = 45 * 1000; // Expire alerts after 45 sec — only buy on very fresh pumps
const SOL_MINT = 'So11111111111111111111111111111111111111112';
const JUPITER_BASE = (process.env.JUPITER_API_KEY || '').trim() ? 'https://api.jup.ag' : 'https://lite-api.jup.ag';
const ROUTE_CHECK_AMOUNT = 10_000_000; // 0.01 SOL lamports
const NO_ROUTE_CACHE_MS = 3 * 60 * 1000; // Don't re-check failed mints for 3 min
// Default true = report all pumps; set to false to only report tokens with Jupiter routes
const SKIP_ROUTE_CHECK = (process.env.SKIP_JUPITER_ROUTE_CHECK || 'true').toLowerCase() === 'true';

const priceHistory = new Map(); // mint -> [{ price, ts, solAmount, isBuy }]
const MIN_PRICE_LAMPORTS = 50_000; // ~$0.00005 — skip micro-cap noise
const MIN_SOL_VOLUME = 0.5; // Require 0.5 SOL traded in window — filter wash trades
const MIN_UNIQUE_TRADERS = parseInt(process.env.MIN_UNIQUE_TRADERS || '5', 10); // Min unique traders in window — proxy for holder interest
const MIN_HOLDERS = parseInt(process.env.MIN_HOLDERS || '150', 10); // Min token holders (requires SOLANA_RPC_URL)
const MAX_HOLDERS = parseInt(process.env.MAX_HOLDERS || '300', 10); // Max token holders — filter late pumps
const SOLANA_RPC_URL = (process.env.SOLANA_RPC_URL || '').trim();
const HOLDER_CACHE_MS = 2 * 60 * 1000; // Cache holder count 2 min
const noRouteCache = new Map(); // mint -> timestamp when we learned no route
const holderCache = new Map(); // mint -> { count, ts }
let recentAlerts = [];
let wsClient = null;
let reconnectTimer = null;
let samplesTotal = 0;
let lastWsError = null;
let lastWsClose = null;

/** Fetch token holder count via Solana RPC getProgramAccounts. Returns null on error. */
async function getHolderCount(mint) {
  if (!SOLANA_RPC_URL) return null;
  const cached = holderCache.get(mint);
  if (cached && Date.now() - cached.ts < HOLDER_CACHE_MS) return cached.count;
  try {
    const body = {
      jsonrpc: '2.0',
      id: 1,
      method: 'getProgramAccounts',
      params: [
        'TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA',
        {
          encoding: 'base64',
          filters: [{ memcmp: { offset: 0, bytes: mint } }],
          dataSlice: { offset: 0, length: 0 },
        },
      ],
    };
    const res = await fetch(SOLANA_RPC_URL, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
    });
    const json = await res.json();
    const accounts = json?.result ?? [];
    const count = Array.isArray(accounts) ? accounts.length : 0;
    holderCache.set(mint, { count, ts: Date.now() });
    return count;
  } catch (_) {
    return null;
  }
}

/** Returns true if holder count is within range (150–300). If RPC unavailable, passes. */
async function passesHolderFilter(mint) {
  if (!SOLANA_RPC_URL) return true;
  const count = await getHolderCount(mint);
  if (count == null) return true; // On error, allow (don't block on RPC failures)
  return count >= MIN_HOLDERS && count <= MAX_HOLDERS;
}

async function hasJupiterRoute(mint) {
  if (noRouteCache.has(mint)) {
    if (Date.now() - noRouteCache.get(mint) < NO_ROUTE_CACHE_MS) return false;
    noRouteCache.delete(mint);
  }
  try {
    const url = `${JUPITER_BASE}/swap/v1/quote?inputMint=${SOL_MINT}&outputMint=${mint}&amount=${ROUTE_CHECK_AMOUNT}&slippageBps=500&maxAccounts=64&restrictIntermediateTokens=false`;
    const opts = {};
    if (process.env.JUPITER_API_KEY) opts.headers = { 'x-api-key': process.env.JUPITER_API_KEY };
    const res = await fetch(url, opts);
    const json = await res.json();
    if (json?.inputMint) return true;
    noRouteCache.set(mint, Date.now());
    return false;
  } catch (_) {
    noRouteCache.set(mint, Date.now());
    return false;
  }
}

function trimHistory() {
  const cutoff = Date.now() - MAX_AGE_MS;
  for (const [mint, arr] of priceHistory) {
    while (arr.length > 0 && arr[arr.length - 1].ts < cutoff) arr.pop();
    if (arr.length === 0) priceHistory.delete(mint);
  }
}

function runPumpDetection() {
  const now = Date.now();
  const alerts = [];
  for (const [mint, arr] of priceHistory) {
    if (arr.length < 2) continue;
    const priceNow = arr[0].price;
    const tsNow = arr[0].ts;
    if (tsNow < now - PRICE_MAX_AGE_MS) continue; // priceNow must be within 60 sec — fresh only
    if (arr[0].isBuy === false) continue; // priceNow must be from a buy — sells = dump, not pump
    // Require buy momentum: of last 5 samples, at least 3 must be buys — avoid buying into sell cascades
    const last5 = arr.slice(0, 5);
    const buyCount = last5.filter((e) => e.isBuy !== false).length;
    if (buyCount < 3) continue;
    // Require price at or near recent peak: if price dropped >10% from max in last 60 sec, skip — avoid buying dumps
    const samplesLast60Sec = arr.filter((e) => e.ts >= now - 60 * 1000);
    const maxPriceRecent = Math.max(...samplesLast60Sec.map((e) => e.price));
    if (priceNow < maxPriceRecent * 0.9) continue;
    // Require no immediate decline: current price must not be <90% of previous sample
    if (arr.length >= 2 && priceNow < arr[1].price * 0.9) continue;

    const targetBefore = now - WINDOW_MS;
    // Only use prices from 2.5–3.5 min ago — strictly the previous 3 min, recent only
    const beforeCandidates = arr.filter((e) =>
      e.ts <= targetBefore + 30000 && e.ts >= targetBefore - 30000
    );
    if (beforeCandidates.length < 1) continue;
    // Require at least 5 samples in last 3 min to avoid sparse-data false pumps
    const recentSamples = arr.filter((e) => e.ts >= targetBefore - 60000);
    if (recentSamples.length < 5) continue;
    // Prefer buy prices — sells can create anomalous lows that trigger false pumps
    const beforeBuys = beforeCandidates.filter((e) => e.isBuy !== false);
    const beforeCands = beforeBuys.length >= 1 ? beforeBuys : beforeCandidates;
    const priceBefore = beforeCands[0].price;
    if (priceBefore <= 0) continue;
    if (priceBefore < MIN_PRICE_LAMPORTS) continue; // Skip micro-cap noise

    // Skip bounce-from-dump: require token wasn't dumping before the pump
    // (price 3 min ago >= 70% of price 5 min ago — not a dead-cat bounce)
    const olderCandidates = arr.filter((e) =>
      e.ts <= now - 4 * 60 * 1000 && e.ts >= now - 6 * 60 * 1000
    );
    if (olderCandidates.length >= 1) {
      const price5minAgo = olderCandidates[0].price;
      if (price5minAgo > 0 && priceBefore < price5minAgo * 0.7) continue;
    }

    // Require minimum SOL volume in window — filter wash trades / manipulation
    const windowTrades = arr.filter((e) => e.ts >= targetBefore - 60000 && e.ts <= now);
    const solVolume = windowTrades.reduce((sum, e) => sum + (e.solAmount || 0), 0);
    if (solVolume < MIN_SOL_VOLUME) continue;

    // Require minimum unique traders — proxy for holder interest, filter low-activity tokens
    const uniqueTraders = new Set();
    for (const e of windowTrades) {
      for (const addr of e.traders || []) {
        if (addr && typeof addr === 'string') uniqueTraders.add(addr);
      }
    }
    if (uniqueTraders.size < MIN_UNIQUE_TRADERS) continue;

    const changePct = (priceNow / priceBefore - 1) * 100;
    if (changePct < MIN_CHANGE) continue;
    if (changePct > MAX_CHANGE) continue; // Skip unrealistic outliers

    alerts.push({
      id: `pump_${mint}`,
      symbol: `? (solana)`,
      priceChangePercent: changePct,
      price: priceNow / 1e9,
      network: 'solana',
      baseTokenMint: mint,
      detectedAt: Date.now(),
    });
  }
  return alerts;
}

function addSamples(samples) {
  for (const s of samples) {
    let arr = priceHistory.get(s.mint);
    if (!arr) {
      arr = [];
      priceHistory.set(s.mint, arr);
    }
    arr.push({
      price: s.price,
      ts: s.timestamp,
      solAmount: s.solAmount ?? 0,
      isBuy: s.isBuy ?? true,
      traders: s.traders ?? [],
    });
    arr.sort((a, b) => b.ts - a.ts);
  }
  samplesTotal += samples.length;

  const newAlerts = runPumpDetection();
  const seen = new Set(recentAlerts.map((a) => a.baseTokenMint));
  for (const a of newAlerts) {
    if (!seen.has(a.baseTokenMint)) {
      seen.add(a.baseTokenMint);
      const addIfPasses = async () => {
        const okHolder = await passesHolderFilter(a.baseTokenMint);
        if (!okHolder) return;
        const okRoute = SKIP_ROUTE_CHECK || (await hasJupiterRoute(a.baseTokenMint));
        if (okRoute && !recentAlerts.some((x) => x.baseTokenMint === a.baseTokenMint)) {
          recentAlerts.unshift(a);
          recentAlerts.splice(MAX_ALERTS);
        }
      };
      addIfPasses();
    }
  }
  trimHistory();
  // Prune expired alerts from memory
  const cutoff = Date.now() - ALERT_MAX_AGE_MS;
  recentAlerts = recentAlerts.filter((a) => (a.detectedAt || 0) > cutoff);
}

function connect() {
  try {
    wsClient = new WebSocket(PUMPAPI_WS);
  } catch (e) {
    console.error('[PUMPAPI]', e.message);
    reconnectTimer = setTimeout(connect, RECONNECT_MS);
    return;
  }

  wsClient.on('open', () => {
    lastWsError = null;
    lastWsClose = null;
    console.log('[PUMPAPI] Connected');
  });

  wsClient.on('message', (data) => {
    try {
      const ev = JSON.parse(data.toString());
      const txType = ev?.txType || ev?.type;
      if (txType !== 'buy' && txType !== 'sell') return;

      const mint = ev?.mint;
      if (!mint || mint === 'So11111111111111111111111111111111111111112') return;

      let price = ev?.price;
      const solAmount = Number(ev?.solAmount ?? ev?.sol_amount ?? 0);
      const tokenAmount = ev?.tokenAmount ?? ev?.token_amount;
      if (!price && solAmount > 0 && tokenAmount != null && tokenAmount > 0) {
        price = solAmount / Number(tokenAmount);
      }
      price = Number(price);
      if (!price || price <= 0 || price >= 1e18) return;

      const timestamp = ev?.timestamp ?? Date.now();
      const priceLamports = Math.round(price * 1e9);
      const isBuy = txType === 'buy';
      const traders = [];
      const txSigner = ev?.txSigner;
      if (txSigner) traders.push(txSigner);
      const involved = ev?.tradersInvolved;
      if (Array.isArray(involved)) traders.push(...involved);
      else if (involved && typeof involved === 'object') traders.push(...Object.keys(involved));
      addSamples([{ mint, price: priceLamports, timestamp, solAmount, isBuy, traders }]);
    } catch (_) {}
  });

  wsClient.on('close', (code, reason) => {
    lastWsClose = { code, reason: String(reason || '') };
    console.error('[PUMPAPI] Closed', code, reason);
    wsClient = null;
    reconnectTimer = setTimeout(connect, RECONNECT_MS);
  });

  wsClient.on('error', (e) => {
    lastWsError = e.message;
    console.error('[PUMPAPI]', e.message);
  });
}

// Delay first connection on startup — during Render deploy, old instance may still
// hold Pump API connection. Wait so we don't get 1008 "only one connection".
const STARTUP_DELAY_MS = 30000; // 30 sec
setTimeout(connect, STARTUP_DELAY_MS);

const app = express();
app.use(express.json());

app.get('/', (_, res) => {
  res.redirect('/status');
});

function getFreshAlerts() {
  const cutoff = Date.now() - ALERT_MAX_AGE_MS;
  return recentAlerts.filter((a) => (a.detectedAt || 0) > cutoff);
}

app.get('/alerts', (_, res) => {
  res.json({
    alerts: getFreshAlerts(),
    tokensTracked: priceHistory.size,
    samplesTotal,
  });
});

app.get('/status', (_, res) => {
  res.json({
    ok: true,
    pumpApiConnected: wsClient?.readyState === 1,
    tokensTracked: priceHistory.size,
    samplesTotal,
    recentAlertsCount: getFreshAlerts().length,
    minPumpPercent: MIN_CHANGE,
    priceMaxAgeSeconds: PRICE_MAX_AGE_MS / 1000,
    minUniqueTraders: MIN_UNIQUE_TRADERS,
    minHolders: MIN_HOLDERS,
    maxHolders: MAX_HOLDERS,
    holderFilterEnabled: !!SOLANA_RPC_URL,
    alertMaxAgeSeconds: ALERT_MAX_AGE_MS / 1000,
    lastWsError: lastWsError || null,
    lastWsClose: lastWsClose || null,
  });
});

// Debug: tokens meeting pump threshold in 3 min window
app.get('/near-pumps', (_, res) => {
  const now = Date.now();
  const near = [];
  for (const [mint, arr] of priceHistory) {
    if (arr.length < 2) continue;
    const priceNow = arr[0].price;
    const tsNow = arr[0].ts;
    if (tsNow < now - 3 * 60 * 1000) continue;
    if (arr[0].isBuy === false) continue;
    const targetBefore = now - WINDOW_MS;
    const beforeCandidates = arr.filter((e) =>
      e.ts <= targetBefore + 30000 && e.ts >= targetBefore - 30000
    );
    if (beforeCandidates.length < 1) continue;
    const beforeBuys = beforeCandidates.filter((e) => e.isBuy !== false);
    const beforeCands = beforeBuys.length >= 1 ? beforeBuys : beforeCandidates;
    const priceBefore = beforeCands[0].price;
    const olderCandidates = arr.filter((e) =>
      e.ts <= now - 4 * 60 * 1000 && e.ts >= now - 6 * 60 * 1000
    );
    if (olderCandidates.length >= 1) {
      const price5minAgo = olderCandidates[0].price;
      if (price5minAgo > 0 && priceBefore < price5minAgo * 0.7) continue;
    }
    const recentSamples = arr.filter((e) => e.ts >= targetBefore - 60000);
    if (recentSamples.length < 5) continue;
    if (priceBefore <= 0 || priceBefore < MIN_PRICE_LAMPORTS) continue;
    const windowTrades = arr.filter((e) => e.ts >= targetBefore - 60000 && e.ts <= now);
    const solVolume = windowTrades.reduce((sum, e) => sum + (e.solAmount || 0), 0);
    if (solVolume < MIN_SOL_VOLUME) continue;
    const changePct = (priceNow / priceBefore - 1) * 100;
    if (changePct >= MIN_CHANGE) near.push({ mint: mint.slice(0, 8) + '...', changePct: Math.round(changePct) });
  }
  near.sort((a, b) => b.changePct - a.changePct);
  res.json({ nearPumps: near.slice(0, 20), minThreshold: MIN_CHANGE });
});

app.get('/health', (_, res) => {
  res.json({ ok: true });
});

const PORT = parseInt(process.env.PORT || '3000', 10);
app.listen(PORT, () => {
  console.log(`Render Pump Server on port ${PORT}`);
  console.log('GET /alerts - pump alerts for iOS');
  console.log('GET /status - health + stats');
});
