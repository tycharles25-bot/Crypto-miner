#!/usr/bin/env node
/**
 * PumpApi Ingest Worker - connects to PumpApi stream, batches events, POSTs to hub
 * 1 connection per IP. Deploy 1 per region (Render) or 1 per VM = more connections
 *
 * Usage: HUB_URL=https://your-hub.com node pumpapi-ingest-worker.js
 */

import WebSocket from 'ws';
import dotenv from 'dotenv';
import path from 'path';
import { fileURLToPath } from 'url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
dotenv.config({ path: path.join(__dirname, '.env') });

const PUMPAPI_WS = 'wss://stream.pumpapi.io/';
const RECONNECT_MS = 5000;
const BATCH_SIZE = parseInt(process.env.PUMPAPI_BATCH_SIZE || '1000', 10);
const BATCH_INTERVAL_MS = parseInt(process.env.PUMPAPI_BATCH_INTERVAL_MS || '5000', 10);

const HUB_URL = (process.env.HUB_URL || '').trim().replace(/\/$/, '');

if (!HUB_URL) {
  console.error('HUB_URL required');
  process.exit(1);
}

const batch = [];
let batchTimer = null;
let samplesTotal = 0;

function parseEvent(ev) {
  const txType = ev?.txType;
  if (txType !== 'buy' && txType !== 'sell') return null;

  const mint = ev?.mint;
  if (!mint || mint === 'So11111111111111111111111111111111111111112') return null;

  let price = ev?.price;
  const solAmount = ev?.solAmount;
  const tokenAmount = ev?.tokenAmount;
  if (!price && solAmount != null && tokenAmount != null && tokenAmount > 0) {
    price = solAmount / tokenAmount;
  }
  if (!price || price <= 0 || price >= 1e18) return null;

  const timestamp = ev?.timestamp || Date.now();
  return { mint, price, timestamp };
}

function toContributeFormat(samples) {
  const pools = samples.map((s) => ({
    tokenMint: s.mint,
    symbol: '?',
    ohlcv: [[s.timestamp, s.price, s.price, s.price, s.price, 0]],
  }));
  return { source: 'pumpapi-ingest', network: 'solana', pools };
}

async function flushBatch() {
  if (batch.length === 0) return;
  const toSend = batch.splice(0, batch.length);

  try {
    const body = toContributeFormat(toSend);
    const res = await fetch(`${HUB_URL}/contribute`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
    });
    if (!res.ok) throw new Error(`${res.status} ${await res.text()}`);
    const json = await res.json();
    samplesTotal += toSend.length;
    console.log('[PUMPAPI-INGEST]', toSend.length, 'samples -> hub (total:', samplesTotal, ')');
  } catch (e) {
    console.error('[PUMPAPI-INGEST]', e.message);
    batch.unshift(...toSend);
  }
}

function scheduleFlush() {
  if (batchTimer) return;
  batchTimer = setTimeout(() => {
    batchTimer = null;
    flushBatch();
  }, BATCH_INTERVAL_MS);
}

function addToBatch(sample) {
  batch.push(sample);
  if (batch.length >= BATCH_SIZE) {
    if (batchTimer) clearTimeout(batchTimer);
    batchTimer = null;
    flushBatch();
  } else {
    scheduleFlush();
  }
}

function connect() {
  const ws = new WebSocket(PUMPAPI_WS);
  ws.on('open', () => console.log('[PUMPAPI-INGEST] Connected to', PUMPAPI_WS));
  ws.on('message', (data) => {
    try {
      const ev = JSON.parse(data.toString());
      const sample = parseEvent(ev);
      if (sample) addToBatch(sample);
    } catch (_) {}
  });
  ws.on('close', () => {
    console.log('[PUMPAPI-INGEST] Disconnected, reconnecting in', RECONNECT_MS / 1000, 's');
    setTimeout(connect, RECONNECT_MS);
  });
  ws.on('error', (e) => console.error('[PUMPAPI-INGEST]', e.message));
}

console.log('[PUMPAPI-INGEST] Started. Hub:', HUB_URL, '| Batch:', BATCH_SIZE, '| Interval:', BATCH_INTERVAL_MS, 'ms');
connect();
