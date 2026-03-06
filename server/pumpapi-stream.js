/**
 * PumpApi WebSocket stream - free real-time trades from Pump.fun, Raydium, Meteora
 * wss://stream.pumpapi.io/ - no signup, no API key
 */

import WebSocket from 'ws';

const PUMPAPI_WS = 'wss://stream.pumpapi.io/';
const RECONNECT_MS = 5000;

let wsClient = null;
let reconnectTimer = null;
let samplesTotal = 0;

/**
 * Start PumpApi stream. Calls addSamples([{ mint, price, timestamp }]) on each buy/sell.
 * price = lamports per token (SOL * 1e9) for consistency with RPC indexer.
 */
function startPumpApiStream(addSamples) {
  if (!addSamples || typeof addSamples !== 'function') return;

  const connect = () => {
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
        const txType = ev?.txType;
        if (txType !== 'buy' && txType !== 'sell') return;

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
        samplesTotal++;
      } catch (_) {}
    });

    wsClient.on('close', () => {
      wsClient = null;
      reconnectTimer = setTimeout(connect, RECONNECT_MS);
    });

    wsClient.on('error', (e) => {
      console.error('[PUMPAPI]', e.message);
    });
  };

  connect();
}

function getPumpApiSamplesTotal() {
  return samplesTotal;
}

export { startPumpApiStream, getPumpApiSamplesTotal };
