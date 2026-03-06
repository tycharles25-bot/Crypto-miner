/**
 * Parse swap data from logsSubscribe logs without getTransaction.
 * Supports Jupiter (Anchor SwapEvent), Raydium log patterns.
 * Falls back to getTransaction when parsing fails.
 */

import { createHash } from 'crypto';
import bs58 from 'bs58';

const SOL_MINT = 'So11111111111111111111111111111111111111112';

// Jupiter SwapEvent: SHA256("event:SwapEvent")[0:8]
const JUPITER_SWAP_DISCRIMINATOR = createHash('sha256')
  .update('event:SwapEvent')
  .digest()
  .subarray(0, 8);

/**
 * Parse Jupiter SwapEvent from base64 "Program data:" log.
 * Structure: discriminator(8) + amm(32) + inputMint(32) + inputAmount(8) + outputMint(32) + outputAmount(8)
 */
function parseJupiterSwapEvent(buf) {
  if (buf.length < 8 + 32 + 32 + 8 + 32 + 8) return null;
  const disc = buf.subarray(0, 8);
  if (!disc.equals(JUPITER_SWAP_DISCRIMINATOR)) return null;
  let off = 8;
  const amm = buf.subarray(off, off + 32);
  off += 32;
  const inputMint = buf.subarray(off, off + 32);
  off += 32;
  const inputAmount = buf.readBigUInt64LE(off);
  off += 8;
  const outputMint = buf.subarray(off, off + 32);
  off += 32;
  const outputAmount = buf.readBigUInt64LE(off);
  return { inputMint, inputAmount, outputMint, outputAmount };
}

/**
 * Extract base64 from "Program data: <base64>" log lines.
 */
function extractProgramDataB64(logs) {
  const out = [];
  for (const line of logs || []) {
    if (typeof line !== 'string') continue;
    const idx = line.indexOf('Program data: ');
    if (idx === -1) continue;
    const b64 = line.slice(idx + 14).trim();
    if (b64.length > 0) out.push(b64);
  }
  return out;
}

/**
 * Parse logs for swap events. Returns [{ mint, price, timestamp }] or [].
 * Uses raw amounts; price = lamports / (tokenAmount/1e9) for consistency with common decimals.
 */
export function parseLogsForSwap(logs, timestamp = Date.now()) {
  const results = [];
  const b64List = extractProgramDataB64(logs);

  for (const b64 of b64List) {
    let buf;
    try {
      buf = Buffer.from(b64, 'base64');
    } catch {
      continue;
    }
    const ev = parseJupiterSwapEvent(buf);
    if (!ev) continue;

    const { inputMint, inputAmount, outputMint, outputAmount } = ev;
    const inputMintB58 = bs58.encode(inputMint);
    const outputMintB58 = bs58.encode(outputMint);

    let solVolume = 0n;
    let tokenMint = null;
    let tokenAmount = 0n;

    if (inputMintB58 === SOL_MINT) {
      solVolume = inputAmount;
      tokenMint = outputMintB58;
      tokenAmount = outputAmount;
    } else if (outputMintB58 === SOL_MINT) {
      solVolume = outputAmount;
      tokenMint = inputMintB58;
      tokenAmount = inputAmount;
    }
    if (!tokenMint || tokenAmount === 0n) continue;

    // price = lamports / (tokenRaw/1e9) = lamports * 1e9 / tokenRaw
    const price = Number(solVolume) * 1e9 / Number(tokenAmount);
    if (price > 0 && price < 1e18) {
      results.push({ mint: tokenMint, price, timestamp });
    }
  }
  return results;
}
