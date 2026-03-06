/**
 * Public RPC DEX Indexer
 * Polls getSignaturesForAddress for Jupiter, Raydium, Pump.fun
 * Optional: WebSocket logsSubscribe for real-time swaps (set SOLANA_WS_URL)
 * Parses swap txs from meta.preTokenBalances/postTokenBalances
 */

import { PublicKey } from '@solana/web3.js';
import { getConnection } from './rpc-connection.js';
import WebSocket from 'ws';
import { addRpcSamples } from './redis-store.js';
import { add as catalogAdd } from './token-catalog.js';
import { addMintToQueue } from './hot-mint-queue.js';
import { parseLogsForSwap } from './log-swap-parser.js';
import { startPumpApiStream, getPumpApiSamplesTotal } from './pumpapi-stream.js';

const SOL_MINT = 'So11111111111111111111111111111111111111112';
const MAX_AGE_MS = 24 * 60 * 60 * 1000;
const POLL_INTERVAL_MS = parseInt(process.env.RPC_INDEXER_POLL_MS || '15000', 10);
const BATCH_SIZE = parseInt(process.env.RPC_INDEXER_BATCH || '15', 10);
const DELAY_BETWEEN_REQUESTS_MS = parseInt(process.env.RPC_INDEXER_DELAY_MS || '400', 10);
const WS_QUEUE_CONCURRENCY = parseInt(process.env.RPC_WS_QUEUE_CONCURRENCY || '5', 10);
const WS_DELAY_MS = parseInt(process.env.RPC_WS_DELAY_MS || '50', 10);

const ALL_PROGRAM_IDS = [
  'JUP6LkbZbjS1jKKwapdHNy74zcZ3tLUZoi5QNyVTaV4', // Jupiter
  '675kPX9MHTjS2zt1qfr1NYHuzeLXfQM9H24wFSUt1Mp8', // Raydium AMM
  '6EF8rrecthR5Dkzon8Nwu78hRvfCKubJ14M5uBEwF6P', // Pump.fun
  'whirLbMiicVdio4qvUfM5KAg6Ct8VwpYzGff3uctyCc', // Orca Whirlpool
];
const RPC_INDEXER_PROGRAMS = (process.env.RPC_INDEXER_PROGRAMS || 'pump,jupiter,raydium,orca')
  .toLowerCase()
  .split(',')
  .map((s) => s.trim())
  .filter(Boolean);
const PROGRAM_MAP = { pump: ALL_PROGRAM_IDS[2], jupiter: ALL_PROGRAM_IDS[0], raydium: ALL_PROGRAM_IDS[1], orca: ALL_PROGRAM_IDS[3] };
const _mapped = RPC_INDEXER_PROGRAMS.map((p) => PROGRAM_MAP[p]).filter(Boolean);
const DEX_PROGRAM_IDS = _mapped.length > 0 ? _mapped : ALL_PROGRAM_IDS;

const priceHistory = new Map();
const lastSignature = new Map();
let connection = null;
let pollTimer = null;
let wsClient = null;
let wsReconnectTimer = null;
let wsSamplesTotal = 0;
const sigQueue = [];
const sigSeen = new Set();
const SIG_SEEN_MAX = 50000;
let queueProcessing = false;

function trimHistory() {
  const cutoff = Date.now() - MAX_AGE_MS;
  for (const [mint, arr] of priceHistory) {
    while (arr.length > 0 && arr[arr.length - 1].ts < cutoff) arr.pop();
    if (arr.length === 0) priceHistory.delete(mint);
  }
}

function sleep(ms) {
  return new Promise((r) => setTimeout(r, ms));
}

/**
 * Parse transaction meta to extract SOL/token flows and derive price
 */
function parseTransactionMeta(tx) {
  const results = [];
  const meta = tx.meta;
  if (!meta || meta.err) return results;

  const preToken = meta.preTokenBalances || [];
  const postToken = meta.postTokenBalances || [];
  const preBalances = meta.preBalances || [];
  const postBalances = meta.postBalances || [];

  const blockTime = tx.blockTime ? tx.blockTime * 1000 : Date.now();

  const preMap = new Map();
  const postMap = new Map();
  for (const p of preToken) {
    if (!p.mint || p.mint === SOL_MINT) continue;
    const key = `${p.accountIndex}|${p.mint}`;
    const amt = parseFloat(p.uiTokenAmount?.uiAmountString || p.uiTokenAmount?.uiAmount || '0') || 0;
    preMap.set(key, amt);
  }
  for (const p of postToken) {
    if (!p.mint || p.mint === SOL_MINT) continue;
    const key = `${p.accountIndex}|${p.mint}`;
    const amt = parseFloat(p.uiTokenAmount?.uiAmountString || p.uiTokenAmount?.uiAmount || '0') || 0;
    postMap.set(key, amt);
  }
  const tokenChanges = new Map();
  const allKeys = new Set([...preMap.keys(), ...postMap.keys()]);
  for (const key of allKeys) {
    const mint = key.split('|')[1];
    const preAmt = preMap.get(key) || 0;
    const postAmt = postMap.get(key) || 0;
    const change = postAmt - preAmt;
    if (Math.abs(change) < 1e-12) continue;
    tokenChanges.set(mint, (tokenChanges.get(mint) || 0) + change);
  }

  let solVolume = 0;
  const len = Math.min(preBalances.length, postBalances.length);
  for (let i = 0; i < len; i++) {
    const diff = (postBalances[i] || 0) - (preBalances[i] || 0);
    if (diff > 0) solVolume += diff;
  }

  if (solVolume < 1000 || tokenChanges.size === 0) return results;

  for (const [mint, change] of tokenChanges) {
    const absChange = Math.abs(change);
    if (absChange < 1e-12) continue;
    const price = solVolume / absChange;
    if (price > 0 && price < 1e18) {
      results.push({ mint, price, timestamp: blockTime });
    }
  }
  return results;
}

function addParsedToHistory(parsed) {
  for (const p of parsed) {
    catalogAdd(p.mint, '?', 'rpc');
    addMintToQueue(p.mint);
    let arr = priceHistory.get(p.mint);
    if (!arr) {
      arr = [];
      priceHistory.set(p.mint, arr);
    }
    arr.push({ price: p.price, ts: p.timestamp });
    arr.sort((a, b) => b.ts - a.ts);
  }
  addRpcSamples(parsed).catch(() => {});
}

/** Add price samples from chain scanner (same format: [{ mint, price, timestamp }]) */
function addPriceSamples(samples) {
  for (const p of samples) {
    let arr = priceHistory.get(p.mint);
    if (!arr) {
      arr = [];
      priceHistory.set(p.mint, arr);
    }
    arr.push({ price: p.price, ts: p.timestamp });
    arr.sort((a, b) => b.ts - a.ts);
  }
}

async function fetchAndParse(signature) {
  try {
    const tx = await connection.getTransaction(signature, {
      commitment: 'confirmed',
      maxSupportedTransactionVersion: 0,
    });
    if (!tx?.meta) return 0;
    const parsed = parseTransactionMeta(tx);
    addParsedToHistory(parsed);
    return parsed.length;
  } catch {
    return 0;
  }
}

async function processQueue() {
  if (queueProcessing || sigQueue.length === 0 || !connection) return;
  queueProcessing = true;
  const batch = sigQueue.splice(0, WS_QUEUE_CONCURRENCY);
  let total = 0;
  for (const sig of batch) {
    total += await fetchAndParse(sig);
    await sleep(WS_DELAY_MS);
  }
  if (total > 0) {
    wsSamplesTotal += total;
    trimHistory();
  }
  queueProcessing = false;
  if (sigQueue.length > 0) setImmediate(processQueue);
}

async function pollProgram(programId) {
  const until = lastSignature.get(programId) || undefined;
  const opts = { limit: BATCH_SIZE };
  if (until) opts.until = until;

  let fetched;
  try {
    fetched = await connection.getSignaturesForAddress(new PublicKey(programId), opts);
  } catch {
    return 0;
  }

  if (fetched.length === 0) return 0;

  lastSignature.set(programId, fetched[0].signature);

  let total = 0;
  for (const s of fetched) {
    const n = await fetchAndParse(s.signature);
    total += n;
    await sleep(DELAY_BETWEEN_REQUESTS_MS);
  }
  return total;
}

async function runPoll() {
  if (!connection) return;
  let total = 0;
  for (const programId of DEX_PROGRAM_IDS) {
    try {
      total += await pollProgram(programId);
    } catch (e) {
      console.error('[RPC-INDEXER]', programId.slice(0, 8) + '...', e.message);
    }
    await sleep(DELAY_BETWEEN_REQUESTS_MS);
  }
  if (total > 0) {
    trimHistory();
    console.log('[RPC-INDEXER]', total, 'price samples');
  }
}

/** Run pump detection on any price history map. */
function runPumpDetection(priceHistoryMap, pumpDef) {
  const now = Date.now();
  const window = pumpDef === 'hundredPerc10min' ? 10 * 60 * 1000 : 20 * 60 * 1000;
  const minChange = pumpDef === 'hundredPerc10min' ? 100 : 50;
  const alerts = [];
  for (const [mint, arr] of priceHistoryMap) {
    if (arr.length < 2) continue;
    const priceNow = arr[0].price;
    const tsNow = arr[0].ts;
    if (tsNow < now - 5 * 60 * 1000) continue;

    const targetBefore = now - window;
    const beforeCandidates = arr.filter((e) => e.ts <= targetBefore + 60000);
    if (beforeCandidates.length < 1) continue;
    const priceBefore = beforeCandidates[0].price;
    if (priceBefore <= 0) continue;

    const changePct = (priceNow / priceBefore - 1) * 100;
    if (changePct < minChange) continue;

    alerts.push({
      id: `rpc_${mint}`,
      source: 'rpc',
      symbol: `? (solana)`,
      priceChangePercent: changePct,
      price: priceNow / 1e9,
      network: 'solana',
      baseTokenMint: mint,
    });
  }
  return alerts;
}

function getPumpsFromRpcIndexer(pumpDef) {
  return runPumpDetection(priceHistory, pumpDef);
}

function getStats() {
  let totalSamples = 0;
  for (const arr of priceHistory.values()) totalSamples += arr.length;
  return {
    tokensTracked: priceHistory.size,
    totalSamples,
    wsSamplesTotal,
    pumpApiSamplesTotal: getPumpApiSamplesTotal(),
    lastSignature: Object.fromEntries(lastSignature),
  };
}

function startLogsSubscribe(wsUrl, rpcUrl) {
  if (wsClient) return;
  connection = connection || getConnection();
  const connect = () => {
    wsClient = new WebSocket(wsUrl);
    wsClient.on('open', () => {
      let subId = 0;
      for (const programId of DEX_PROGRAM_IDS) {
        wsClient.send(
          JSON.stringify({
            jsonrpc: '2.0',
            id: ++subId,
            method: 'logsSubscribe',
            params: [{ mentions: [programId] }, { commitment: 'confirmed' }],
          })
        );
      }
      console.log('[RPC-INDEXER] WebSocket connected,', DEX_PROGRAM_IDS.length, 'subscriptions');
    });
    wsClient.on('message', (data) => {
      try {
        const msg = JSON.parse(data.toString());
        if (msg.result && typeof msg.result === 'number') return;
        const val = msg.params?.result?.value;
        const sig = val?.signature;
        if (!sig || val?.err || sigSeen.has(sig)) return;
        const logs = val?.logs;
        // Try to parse swap from logs first; skip getTransaction when successful
        if (Array.isArray(logs) && logs.length > 0) {
          const parsed = parseLogsForSwap(logs);
          if (parsed.length > 0) {
            sigSeen.add(sig);
            if (sigSeen.size > SIG_SEEN_MAX) {
              const arr = [...sigSeen].slice(-SIG_SEEN_MAX / 2);
              sigSeen.clear();
              arr.forEach((s) => sigSeen.add(s));
            }
            addParsedToHistory(parsed);
            wsSamplesTotal += parsed.length;
            trimHistory();
            return;
          }
        }
        sigSeen.add(sig);
        if (sigSeen.size > SIG_SEEN_MAX) {
          const arr = [...sigSeen].slice(-SIG_SEEN_MAX / 2);
          sigSeen.clear();
          arr.forEach((s) => sigSeen.add(s));
        }
        sigQueue.push(sig);
        if (sigQueue.length <= 1000) processQueue();
      } catch (_) {}
    });
    wsClient.on('close', () => {
      wsClient = null;
      wsReconnectTimer = setTimeout(connect, 5000);
    });
    wsClient.on('error', (e) => console.error('[RPC-INDEXER]', e.message));
  };
  connect();
}

function startPolling(rpcUrl) {
  if (pollTimer) return;
  connection = connection || getConnection();
  const run = async () => {
    await runPoll();
    pollTimer = setTimeout(run, POLL_INTERVAL_MS);
  };
  run();
  console.log('[RPC-INDEXER] Started, poll every', POLL_INTERVAL_MS / 1000, 's');
}

function stopPolling() {
  if (pollTimer) {
    clearTimeout(pollTimer);
    pollTimer = null;
  }
  if (wsReconnectTimer) {
    clearTimeout(wsReconnectTimer);
    wsReconnectTimer = null;
  }
  if (wsClient) {
    wsClient.close();
    wsClient = null;
  }
}

function startPumpApi() {
  startPumpApiStream((samples) => {
    addParsedToHistory(samples);
    wsSamplesTotal += samples.length;
    trimHistory();
  });
}

export { runPumpDetection };
export {
  getPumpsFromRpcIndexer,
  getStats as getRpcIndexerStats,
  startPolling as startRpcIndexer,
  startLogsSubscribe,
  startPumpApi,
  stopPolling as stopRpcIndexer,
  addPriceSamples,
  DEX_PROGRAM_IDS,
};
