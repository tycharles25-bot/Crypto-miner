/**
 * Chain Price Scanner - Event-driven (solution #4)
 * Only fetches bonding curves for mints that had a swap (from logsSubscribe/RPC poll).
 * ~99% RPC reduction vs full 892k scan. Works with public RPC.
 */

import { PublicKey } from '@solana/web3.js';
import { getConnection } from './rpc-connection.js';
import { takeBatch, getQueueSize } from './hot-mint-queue.js';
import { addPriceSamples } from './rpc-indexer.js';

const PUMP_PROGRAM = new PublicKey('6EF8rrecthR5Dkzon8Nwu78hRvfCKubJ14M5uBEwF6P');
const LAMPORTS_PER_SOL = 1e9;
const TOKEN_DECIMALS = 6;
const VIRTUAL_TOKEN_OFFSET = 0x08;
const VIRTUAL_SOL_OFFSET = 0x10;

const BATCH_SIZE = parseInt(process.env.CHAIN_SCANNER_BATCH || '100', 10);
const POLL_INTERVAL_MS = parseInt(process.env.CHAIN_SCANNER_INTERVAL_MS || '2000', 10);

let connection = null;
let lastScanAt = 0;
let lastScanCount = 0;
let scanInProgress = false;

function deriveBondingCurve(mint) {
  const [pda] = PublicKey.findProgramAddressSync(
    [Buffer.from('bonding-curve'), new PublicKey(mint).toBuffer()],
    PUMP_PROGRAM
  );
  return pda;
}

function parseBondingCurvePrice(data) {
  if (!data || data.length < 0x20) return null;
  const virtualToken = data.readBigUInt64LE(VIRTUAL_TOKEN_OFFSET);
  const virtualSol = data.readBigUInt64LE(VIRTUAL_SOL_OFFSET);
  if (virtualToken <= 0n || virtualSol <= 0n) return null;
  const priceSol = Number(virtualSol) / LAMPORTS_PER_SOL / (Number(virtualToken) / 10 ** TOKEN_DECIMALS);
  return Math.round(priceSol * LAMPORTS_PER_SOL);
}

async function scanBatch(mints, conn) {
  const pubkeys = mints.map((m) => deriveBondingCurve(m));
  const accounts = await conn.getMultipleAccountsInfo(pubkeys);
  const now = Date.now();
  const samples = [];
  for (let i = 0; i < mints.length; i++) {
    const acc = accounts[i];
    if (!acc?.data) continue;
    const priceLamports = parseBondingCurvePrice(acc.data);
    if (!priceLamports || priceLamports <= 0) continue;
    samples.push({ mint: mints[i], price: priceLamports, timestamp: now });
  }
  return samples;
}

async function runScan() {
  if (scanInProgress) return lastScanCount;
  const mints = takeBatch(BATCH_SIZE);
  if (mints.length === 0) {
    return lastScanCount;
  }

  scanInProgress = true;
  connection = connection || getConnection();
  const conn = connection;

  try {
    const samples = await scanBatch(mints, conn);
    if (samples.length > 0) {
      addPriceSamples(samples);
      lastScanCount += samples.length;
    }
  } catch (e) {
    console.error('[CHAIN_SCANNER]', e.message);
  }

  lastScanAt = Date.now();
  scanInProgress = false;
  return lastScanCount;
}

function startChainPriceScanner() {
  const run = () => {
    runScan();
    setTimeout(run, POLL_INTERVAL_MS);
  };
  run();
  console.log('[CHAIN_SCANNER] Event-driven: queue → bonding curves, batch', BATCH_SIZE, ', poll every', POLL_INTERVAL_MS / 1000, 's');
}

function getStats() {
  return { lastScanAt, lastScanCount, scanInProgress, queueSize: getQueueSize() };
}

export { runScan, startChainPriceScanner, getStats };
