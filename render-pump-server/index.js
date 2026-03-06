/**
 * Render Pump Server - PumpApi + pump detection
 * Deploy to Render. iOS app polls GET /alerts
 */

import express from 'express';
import WebSocket from 'ws';

const PUMPAPI_WS = 'wss://stream.pumpapi.io/';
const RECONNECT_MS = 5000;
const MAX_AGE_MS = 24 * 60 * 60 * 1000;
const WINDOW_MS = 10 * 60 * 1000; // 100% in 10 min
const MIN_CHANGE = 100;
const MAX_ALERTS = 50;

const priceHistory = new Map(); // mint -> [{ price, ts }]
let recentAlerts = [];
let wsClient = null;
let reconnectTimer = null;
let samplesTotal = 0;

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
    if (tsNow < now - 5 * 60 * 1000) continue;

    const targetBefore = now - WINDOW_MS;
    const beforeCandidates = arr.filter((e) => e.ts <= targetBefore + 60000);
    if (beforeCandidates.length < 1) continue;
    const priceBefore = beforeCandidates[0].price;
    if (priceBefore <= 0) continue;

    const changePct = (priceNow / priceBefore - 1) * 100;
    if (changePct < MIN_CHANGE) continue;

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
    arr.push({ price: s.price, ts: s.timestamp });
    arr.sort((a, b) => b.ts - a.ts);
  }
  samplesTotal += samples.length;

  const newAlerts = runPumpDetection();
  const seen = new Set(recentAlerts.map((a) => a.baseTokenMint));
  for (const a of newAlerts) {
    if (!seen.has(a.baseTokenMint)) {
      seen.add(a.baseTokenMint);
      recentAlerts.unshift(a);
    }
  }
  recentAlerts = recentAlerts.slice(0, MAX_ALERTS);
  trimHistory();
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
    console.log('[PUMPAPI] Connected');
  });

  wsClient.on('message', (data) => {
    try {
      const ev = JSON.parse(data.toString());
      if (ev?.txType !== 'buy' && ev?.txType !== 'sell') return;

      const mint = ev?.mint;
      if (!mint || mint === 'So11111111111111111111111111111111111111112') return;

      let price = ev?.price;
      const solAmount = ev?.solAmount;
      const tokenAmount = ev?.tokenAmount;
      if (!price && solAmount != null && tokenAmount != null && tokenAmount > 0) {
        price = solAmount / tokenAmount;
      }
      if (!price || price <= 0 || price >= 1e18) return;

      const timestamp = ev?.timestamp || Date.now();
      const priceLamports = price * 1e9;
      addSamples([{ mint, price: priceLamports, timestamp }]);
    } catch (_) {}
  });

  wsClient.on('close', () => {
    wsClient = null;
    reconnectTimer = setTimeout(connect, RECONNECT_MS);
  });

  wsClient.on('error', (e) => {
    console.error('[PUMPAPI]', e.message);
  });
}

connect();

const app = express();
app.use(express.json());

app.get('/alerts', (_, res) => {
  res.json({
    alerts: recentAlerts,
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
    recentAlertsCount: recentAlerts.length,
  });
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
