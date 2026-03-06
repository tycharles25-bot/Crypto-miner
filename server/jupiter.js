/**
 * Jupiter swap execution for Solana
 * Port of Swift JupiterSwapService logic
 */

import { Keypair, PublicKey, VersionedTransaction } from '@solana/web3.js';
import { getConnection } from './rpc-connection.js';
import bs58 from 'bs58';

// lite-api: keyless; api.jup.ag: requires JUPITER_API_KEY
const JUPITER_BASE = (process.env.JUPITER_API_KEY || '').trim()
  ? 'https://api.jup.ag'
  : 'https://lite-api.jup.ag';
const QUOTE_URL = `${JUPITER_BASE}/swap/v1/quote`;
const SWAP_URL = `${JUPITER_BASE}/swap/v1/swap`;
const SOL_MINT = 'So11111111111111111111111111111111111111112';
const JUPITER_API_KEY = (process.env.JUPITER_API_KEY || '').trim();

const connection = getConnection();

function jupiterHeaders() {
  const h = { 'Content-Type': 'application/json' };
  if (JUPITER_API_KEY) h['x-api-key'] = JUPITER_API_KEY;
  return h;
}

export function createKeypairFromPrivateKey(base58PrivateKey) {
  const secretKey = bs58.decode(base58PrivateKey.trim());
  return Keypair.fromSecretKey(secretKey);
}

async function fetchQuote(inputMint, outputMint, amount, slippageBps) {
  const params = new URLSearchParams({
    inputMint,
    outputMint,
    amount: String(amount),
    slippageBps: String(slippageBps),
  });
  const res = await fetch(`${QUOTE_URL}?${params}`, { headers: jupiterHeaders() });
  const json = await res.json();

  if (!res.ok) {
    const msg = json?.error || json?.message || json?.detail || res.statusText || 'Quote failed';
    throw new Error(`Jupiter quote: ${msg}`);
  }
  if (!json?.inputMint) {
    const msg = json?.error || json?.message || 'No route found';
    throw new Error(`Jupiter: ${msg}`);
  }
  return json;
}

async function fetchSwapTransaction(quoteResponse, userPublicKey) {
  const res = await fetch(SWAP_URL, {
    method: 'POST',
    headers: jupiterHeaders(),
    body: JSON.stringify({
      quoteResponse,
      userPublicKey,
      dynamicComputeUnitLimit: true,
      prioritizationFeeLamports: 'auto',
    }),
  });
  const json = await res.json();
  const swapTx = json?.swapTransaction;
  if (!swapTx) {
    const msg = json?.error || json?.message || json?.detail || (res.ok ? 'Invalid swap response' : res.statusText);
    throw new Error(`Jupiter swap: ${msg}`);
  }
  return swapTx;
}

async function fetchTokenBalance(userPublicKey, mint) {
  const owner = new PublicKey(userPublicKey);
  const mintKey = new PublicKey(mint);
  const { value: accounts } = await connection.getParsedTokenAccountsByOwner(owner, { mint: mintKey });
  for (const item of accounts) {
    const amount = item?.account?.data?.parsed?.info?.tokenAmount?.amount;
    if (amount) return BigInt(amount);
  }
  return 0n;
}

async function signAndSendTransaction(base64Transaction, keypair) {
  const buf = Buffer.from(base64Transaction, 'base64');
  const tx = VersionedTransaction.deserialize(new Uint8Array(buf));
  tx.sign([keypair]);
  const raw = tx.serialize();
  const sig = await connection.sendRawTransaction(raw, {
    skipPreflight: false,
    preflightCommitment: 'confirmed',
  });
  return sig;
}

/**
 * Execute buy: SOL -> token
 * @param {Keypair} keypair
 * @param {string} outputMint - token mint to buy
 * @param {number} solAmountLamports
 * @param {number} slippageBps
 * @returns {Promise<string>} transaction signature
 */
export async function executeBuy(keypair, outputMint, solAmountLamports, slippageBps = 100) {
  const userPublicKey = keypair.publicKey.toBase58();
  const quote = await fetchQuote(SOL_MINT, outputMint, solAmountLamports, slippageBps);
  const swapTxBase64 = await fetchSwapTransaction(quote, userPublicKey);
  return signAndSendTransaction(swapTxBase64, keypair);
}

/**
 * Execute sell: token -> SOL (entire balance)
 * @param {Keypair} keypair
 * @param {string} inputMint - token mint to sell
 * @param {number} slippageBps
 * @returns {Promise<string>} transaction signature
 */
export async function executeSellAll(keypair, inputMint, slippageBps = 100) {
  const userPublicKey = keypair.publicKey.toBase58();
  const balance = await fetchTokenBalance(userPublicKey, inputMint);
  if (balance === 0n) throw new Error('Insufficient token balance');
  const quote = await fetchQuote(inputMint, SOL_MINT, balance.toString(), slippageBps);
  const swapTxBase64 = await fetchSwapTransaction(quote, userPublicKey);
  return signAndSendTransaction(swapTxBase64, keypair);
}
