/**
 * Pump Tracker Server - runs 24/7
 * Detects pumps via GeckoTerminal, executes Jupiter swaps on Solana
 */

import dotenv from 'dotenv';
import path from 'path';
import { fileURLToPath } from 'url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
dotenv.config({ path: path.join(__dirname, '.env') });
import express from 'express';
import {
  fetchPumps100perc10min,
  fetchPumps50perc20min,
} from './gecko.js';
import { fetchPumpsFromDexScreener } from './dexscreener.js';
import { fetchPumpsFromBirdeye } from './birdeye.js';
import {
  getPumpsFromRpcIndexer,
  getRpcIndexerStats,
  startRpcIndexer,
  startLogsSubscribe,
  startPumpApi,
} from './rpc-indexer.js';
import {
  startChainPriceScanner,
  getStats as getChainScannerStats,
} from './chain-price-scanner.js';
import {
  startPageScanner,
  getPumpsFromPageScanner,
  getPageScannerStats,
} from './page-scanner.js';
import {
  buildCatalog,
  getCatalogSize,
  getStats as getCatalogStats,
  startCatalogBuilder,
} from './token-catalog.js';
import {
  processContribution,
  getPumpsFromContributed,
  getContributeStats,
  initContributeRedis,
} from './contribute.js';
import { isEnabled as redisEnabled, getHealth as getRedisHealth } from './redis-store.js';
import { getRpcUrlCount } from './rpc-connection.js';
import {
  createKeypairFromPrivateKey,
  executeBuy,
  executeSellAll,
} from './jupiter.js';

const app = express();
app.use(express.json());

const PORT = process.env.PORT || 3000;
const SOL_PER_TRADE = parseInt(process.env.SOL_PER_TRADE_LAMPORTS || '10000000', 10);
const SLIPPAGE_BPS = parseInt(process.env.SLIPPAGE_BPS || '500', 10);
const PUMP_DEFINITION = process.env.PUMP_DEFINITION || 'hundredPerc10min';
const DATA_SOURCE = (process.env.DATA_SOURCE || 'both').toLowerCase();
const CHAIN_ONLY = process.env.CHAIN_ONLY === 'true' || DATA_SOURCE === 'chain';
const BIRDEYE_API_KEY = (process.env.BIRDEYE_API_KEY || '').trim();
const RPC_INDEXER_ENABLED = process.env.RPC_INDEXER_ENABLED !== 'false';
const PUMPAPI_STREAM_ENABLED = process.env.PUMPAPI_STREAM_ENABLED !== 'false';
const PAGE_SCANNER_ENABLED = process.env.PAGE_SCANNER_ENABLED === 'true';
const TOKEN_CATALOG_ENABLED = process.env.TOKEN_CATALOG_ENABLED === 'true';
const CHAIN_SCANNER_ENABLED = process.env.CHAIN_SCANNER_ENABLED === 'true';
const DRY_RUN = process.env.DRY_RUN === 'true';

let keypair = null;
const tradedSymbols = new Set();
const pendingCashouts = new Map();

function loadWallet() {
  const pk = (process.env.SOLANA_PRIVATE_KEY || '').trim();
  if (!pk) {
    console.warn('SOLANA_PRIVATE_KEY is empty in .env - no auto-trading. Add your base58 private key.');
    return;
  }

  try {
    keypair = createKeypairFromPrivateKey(pk);
    console.log('Wallet loaded:', keypair.publicKey.toBase58().slice(0, 8) + '...');
  } catch (e) {
    console.error('Invalid SOLANA_PRIVATE_KEY:', e.message);
    console.error('Key should be base58 (starts with a number, ~88 chars). No quotes or extra spaces.');
  }
}

function getCashoutSeconds() {
  return 5 * 60; // 5 min — strict 300%/1min criteria
}

function useSource(name) {
  if (CHAIN_ONLY) return false; // No 3rd party APIs
  if (DATA_SOURCE === 'all') return true;
  if (DATA_SOURCE === name) return true;
  if (DATA_SOURCE === 'both') return name === 'gecko' || name === 'dexscreener' || name === 'birdeye';
  return false;
}

async function runScan() {
  try {
    let alerts = [];
    const seen = new Set();
    const addAlert = (a) => {
      if (!a?.baseTokenMint || a.network !== 'solana') return;
      if (seen.has(a.baseTokenMint)) return;
      seen.add(a.baseTokenMint);
      alerts.push(a);
    };

    // Run all big token pages in parallel (Gecko, DexScreener, Birdeye)
    const fetchPumps =
      PUMP_DEFINITION === 'fiftyPerc20min' ? fetchPumps50perc20min : fetchPumps100perc10min;
    const [geckoRes, dexRes, birdeyeRes] = await Promise.allSettled([
      useSource('gecko') ? fetchPumps('solana') : [],
      useSource('dexscreener') ? fetchPumpsFromDexScreener(PUMP_DEFINITION) : [],
      useSource('birdeye') && BIRDEYE_API_KEY
        ? fetchPumpsFromBirdeye(BIRDEYE_API_KEY, PUMP_DEFINITION)
        : [],
    ]);

    [geckoRes, dexRes, birdeyeRes].forEach((r, i) => {
      if (r.status === 'rejected') {
        const src = ['gecko', 'dexscreener', 'birdeye'][i];
        console.error(`[${src.toUpperCase()}]`, r.reason?.message || r.reason);
      }
    });

    (geckoRes.status === 'fulfilled' ? geckoRes.value : []).forEach(addAlert);
    (dexRes.status === 'fulfilled' ? dexRes.value : []).forEach(addAlert);
    (birdeyeRes.status === 'fulfilled' ? birdeyeRes.value : []).forEach(addAlert);
    getPumpsFromRpcIndexer(PUMP_DEFINITION).forEach(addAlert);
    if (!CHAIN_ONLY || process.env.CHAIN_USE_CONTRIBUTE === 'true') {
      getPumpsFromContributed(PUMP_DEFINITION).forEach(addAlert);
    }
    if (!CHAIN_ONLY && PAGE_SCANNER_ENABLED) {
      getPumpsFromPageScanner(PUMP_DEFINITION).forEach(addAlert);
    }

    for (const pump of alerts) {
        if (pump.network !== 'solana' || !pump.baseTokenMint) continue;

        const key = pump.baseTokenMint;
        if (tradedSymbols.has(key)) continue;

        if (!keypair) {
          console.log('[SKIP] No wallet - would trade:', pump.symbol);
          continue;
        }

        if (DRY_RUN) {
          const src = pump.source || (pump.id || '').split('_')[0] || '?';
          const solAmt = (SOL_PER_TRADE / 1e9).toFixed(6);
          const pct = pump.priceChangePercent != null ? `${pump.priceChangePercent.toFixed(0)}%` : '?';
          console.log(`[DRY RUN] Would buy ${pump.symbol} (${src}) ${solAmt} SOL | pump: ${pct}`);
          tradedSymbols.add(key);
          continue;
        }

        try {
          const sig = await executeBuy(keypair, pump.baseTokenMint, SOL_PER_TRADE, SLIPPAGE_BPS);
          const src = pump.source || (pump.id || '').split('_')[0] || '?';
          console.log(`[BUY] ${pump.symbol} (${src}) tx: ${sig.slice(0, 16)}...`);
          tradedSymbols.add(key);

          const cashoutSecs = getCashoutSeconds();
          const cashoutAt = Date.now() + cashoutSecs * 1000;
          pendingCashouts.set(pump.id, {
            pump,
            cashoutAt,
            timeoutId: setTimeout(() => runCashout(pump), cashoutSecs * 1000),
          });
        } catch (e) {
          console.error(`[BUY FAIL] ${pump.symbol}:`, e.message);
        }
      }
  } catch (e) {
    console.error('[SCAN]', e.message);
  }
}

async function runCashout(pump) {
  pendingCashouts.delete(pump.id);
  if (!keypair) return;

  try {
    const sig = await executeSellAll(keypair, pump.baseTokenMint, SLIPPAGE_BPS);
    console.log(`[SELL] ${pump.symbol} tx: ${sig.slice(0, 16)}...`);
  } catch (e) {
    console.error(`[SELL FAIL] ${pump.symbol}:`, e.message);
  }
}

function startScanner() {
  const defaultInterval = CHAIN_ONLY && !RPC_INDEXER_ENABLED ? 120 : CHAIN_ONLY ? 60 : 120;
  const scanIntervalSec = parseInt(process.env.SCAN_INTERVAL_SEC || String(defaultInterval), 10);
  const scanInterval = scanIntervalSec * 1000;
  const run = async () => {
    await runScan();
    setTimeout(run, scanInterval);
  };
  run();
  console.log('Scanner started: Solana | data:', DATA_SOURCE, '| interval:', scanInterval / 1000, 's');
}

app.get('/health', async (_, res) => {
  const out = { ok: true };
  if (redisEnabled()) {
    const h = await getRedisHealth();
    out.redis = h.connected ? 'ok' : 'disconnected';
  }
  res.json(out);
});

app.post('/contribute', (req, res) => {
  const ip = req.ip || req.socket?.remoteAddress || req.headers['x-forwarded-for']?.split(',')[0]?.trim() || 'unknown';
  try {
    const result = processContribution(req.body, ip);
    if (result.rateLimited) return res.status(429).json({ error: 'Rate limited' });
    res.json({ ok: true, samples: result.count });
    if (result.count > 0) console.log('[CONTRIBUTE]', result.count, 'samples from', String(ip).slice(0, 15));
  } catch (e) {
    console.error('[CONTRIBUTE]', e.message);
    res.status(400).json({ error: e.message });
  }
});

function getSearchConfig() {
  const geckoDelay = parseInt(process.env.POOL_DELAY_MS || '3500', 10);
  const geckoPages = parseInt(process.env.SOLANA_POOL_PAGES || '5', 10);
  const dexDelay = parseInt(process.env.DEXSCREENER_DELAY_MS || '250', 10);
  const birdeyeDelay = parseInt(process.env.BIRDEYE_DELAY_MS || '1100', 10);
  const birdeyePages = parseInt(process.env.BIRDEYE_PAGES || '20', 10);
  const rpcPoll = parseInt(process.env.RPC_INDEXER_POLL_MS || '15000', 10);
  const rpcBatch = parseInt(process.env.RPC_INDEXER_BATCH || '15', 10);
  const rpcDelay = parseInt(process.env.RPC_INDEXER_DELAY_MS || '400', 10);
  const geckoEst = Math.floor(50 * (1 + geckoPages / 5));
  const dexEst = Math.floor(60000 / dexDelay);
  const birdeyeEst = BIRDEYE_API_KEY ? birdeyePages * 50 : 0;
  const rpcEst = Math.floor((60000 / rpcPoll) * rpcBatch * 3);
  const pageScannerEst = PAGE_SCANNER_ENABLED && BIRDEYE_API_KEY ? 50 : 0; // 1 page/min = 50 tokens
  return {
    gecko: { delayMs: geckoDelay, pages: geckoPages, estTokensPerMin: geckoEst },
    dexscreener: { delayMs: dexDelay, estTokensPerMin: dexEst },
    birdeye: { delayMs: birdeyeDelay, pages: birdeyePages, estTokensPerMin: birdeyeEst },
    rpc: { pollMs: rpcPoll, batch: rpcBatch, delayMs: rpcDelay, estTokensPerMin: rpcEst },
    pageScanner: { intervalMs: parseInt(process.env.PAGE_SCANNER_INTERVAL_MS || '60000', 10), estTokensPerMin: pageScannerEst },
    hubEstTotal: geckoEst + dexEst + birdeyeEst + rpcEst + pageScannerEst,
  };
}

app.get('/status', async (_, res) => {
  const rpcStats = getRpcIndexerStats();
  const contributeStats = getContributeStats();
  const searchConfig = getSearchConfig();
  const redisHealth = redisEnabled() ? await getRedisHealth() : null;
  const totalSamplesPerMin =
    (contributeStats.samplesPerMinute || 0) + searchConfig.hubEstTotal;
  res.json({
    wallet: keypair ? keypair.publicKey.toBase58().slice(0, 8) + '...' : null,
    pumpDefinition: PUMP_DEFINITION,
    dataSource: DATA_SOURCE,
    chainOnly: CHAIN_ONLY,
    birdeyeEnabled: !!BIRDEYE_API_KEY,
    mesh: redisEnabled() ? { redis: true, connected: redisHealth?.connected } : { redis: false },
    rpcRotation: getRpcUrlCount(),
    search: {
      samplesPerMinute: totalSamplesPerMin,
      contribute: contributeStats,
      rpc: rpcStats,
      config: searchConfig,
    },
    rpcIndexer: rpcStats,
    pageScanner: PAGE_SCANNER_ENABLED ? getPageScannerStats() : null,
    tokenCatalog: TOKEN_CATALOG_ENABLED ? { size: getCatalogSize(), ...getCatalogStats() } : null,
    chainScanner: CHAIN_SCANNER_ENABLED ? getChainScannerStats() : null,
    contribute: contributeStats,
    cashoutSeconds: getCashoutSeconds(),
    pendingCashouts: pendingCashouts.size,
    tradedCount: tradedSymbols.size,
  });
});

app.post('/config', (req, res) => {
  const { privateKey } = req.body || {};
  if (privateKey) {
    try {
      keypair = createKeypairFromPrivateKey(privateKey);
      res.json({ ok: true }); // Don't echo key back
    } catch (e) {
      res.status(400).json({ error: e.message });
    }
  } else {
    res.status(400).json({ error: 'privateKey required' });
  }
});

loadWallet();

if (!CHAIN_ONLY && PAGE_SCANNER_ENABLED && BIRDEYE_API_KEY) {
  startPageScanner(BIRDEYE_API_KEY);
}

if (TOKEN_CATALOG_ENABLED && !CHAIN_ONLY) {
  const catalogIntervalHours = parseInt(process.env.TOKEN_CATALOG_INTERVAL_HOURS || '6', 10);
  startCatalogBuilder(BIRDEYE_API_KEY, catalogIntervalHours);
}

if (RPC_INDEXER_ENABLED) {
  const rpcUrl = process.env.SOLANA_RPC_URL || 'https://solana-rpc.publicnode.com';
  const wsEnabled = process.env.RPC_WS_ENABLED !== 'false';
  const wsUrl = wsEnabled ? (process.env.SOLANA_WS_URL || '').trim() : '';
  startRpcIndexer(rpcUrl);
  if (wsUrl) startLogsSubscribe(wsUrl, rpcUrl);
}
if (PUMPAPI_STREAM_ENABLED && (RPC_INDEXER_ENABLED || DATA_SOURCE === 'chain')) {
  startPumpApi();
}

if (CHAIN_SCANNER_ENABLED && RPC_INDEXER_ENABLED) {
  startChainPriceScanner();
}

startScanner();
initContributeRedis();

app.listen(PORT, () => {
  console.log(`Server on http://localhost:${PORT}`);
  console.log('RPC rotation:', getRpcUrlCount(), 'endpoints');
  console.log('Pump definition:', PUMP_DEFINITION);
  const wsMsg = process.env.SOLANA_WS_URL ? '+ WS' : '';
  const pumpApiMsg = PUMPAPI_STREAM_ENABLED ? '+ PumpApi' : '';
const pageScannerMsg = PAGE_SCANNER_ENABLED ? '+ PageScanner' : '';
const catalogMsg = TOKEN_CATALOG_ENABLED ? '+ TokenCatalog' : '';
const chainMsg = CHAIN_ONLY ? 'CHAIN-ONLY (no 3rd party APIs)' : '';
const chainScannerMsg = CHAIN_SCANNER_ENABLED ? '+ ChainScanner (892k/min)' : '';
console.log(chainMsg || ('Data source: ' + DATA_SOURCE), BIRDEYE_API_KEY && !CHAIN_ONLY ? '+ Birdeye' : '', pageScannerMsg, catalogMsg, chainScannerMsg, '| RPC:', RPC_INDEXER_ENABLED ? 'on' + wsMsg + pumpApiMsg : 'PumpApi only', '| Contribute: POST /contribute');
  console.log('SOL per trade:', SOL_PER_TRADE / 1e9);
  if (DRY_RUN) console.log('*** DRY RUN: no real buys/sells ***');
  if (CHAIN_ONLY) {
    console.log(RPC_INDEXER_ENABLED ? 'Chain mode: pump detection from RPC + PumpApi stream (no Gecko/DexScreener)' : 'Chain mode: pump detection from PumpApi stream only (no RPC polling)');
  }
});
