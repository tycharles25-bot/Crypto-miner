/**
 * RPC Connection with rotating endpoints
 * Round-robins across multiple free RPCs to multiply effective rate limit
 */

import { Connection } from '@solana/web3.js';

const DEFAULT_URLS = [
  'https://solana-rpc.publicnode.com',
  'https://rpc.ankr.com/solana',
  'https://solana.drpc.org',
  'https://solana.api.onfinality.io/public',
  'https://solana-mainnet.rpc.extrnode.com',
];

function getRpcUrls() {
  const primary = (process.env.SOLANA_RPC_URL || '').trim();
  const extra = [
    (process.env.SOLANA_RPC_URL_2 || '').trim(),
    (process.env.SOLANA_RPC_URL_3 || '').trim(),
    (process.env.SOLANA_RPC_URL_4 || '').trim(),
    (process.env.SOLANA_RPC_URL_5 || '').trim(),
    (process.env.SOLANA_RPC_URL_6 || '').trim(),
    (process.env.SOLANA_RPC_URL_7 || '').trim(),
    (process.env.SOLANA_RPC_URL_8 || '').trim(),
    (process.env.SOLANA_RPC_URL_9 || '').trim(),
    (process.env.SOLANA_RPC_URL_10 || '').trim(),
  ].filter(Boolean);
  const fromEnv = primary ? [primary, ...extra] : [];
  const urls = fromEnv.length > 0 ? fromEnv : DEFAULT_URLS;
  return urls
    .filter((u) => u.length > 0)
    .filter((u) => !u.includes('api.mainnet.solana.com') && !u.includes('api.mainnet-beta.solana.com'));
}

const urls = getRpcUrls();
let idx = 0;
const last429Log = new Map();
const LOG_429_THROTTLE_MS = 60000;

function rotatingFetch(input, init) {
  const url = urls[idx++ % urls.length];
  return fetch(url, init).then((res) => {
    if (res.status === 429) {
      const host = new URL(url).hostname;
      const now = Date.now();
      const last = last429Log.get(host) || 0;
      if (now - last > LOG_429_THROTTLE_MS) {
        last429Log.set(host, now);
        console.error('[RPC] 429 Too Many Requests from', host, '(throttled 1/min)');
      }
    }
    return res;
  });
}

const endpoint = urls[0] || 'https://solana-rpc.publicnode.com';
const connection = new Connection(endpoint, {
  fetch: rotatingFetch,
  disableRetryOnRateLimit: true,
});

export function getConnection() {
  return connection;
}

export function getRpcUrlCount() {
  return urls.length;
}
