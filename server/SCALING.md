# Scaling to 1M Samples/Min

## Current Architecture

| Layer | Throughput | Notes |
|-------|------------|-------|
| Hub REST | ~400–2,000/min | Gecko, DexScreener, Birdeye, RPC poll |
| RPC WebSocket | **10k–50k+/min** | logsSubscribe (Jupiter, Raydium, Pump) – needs RPC with WebSocket |
| Workers | ~500/min each | Gecko from new IP |
| Redis mesh | Shared store | Dedupe, symbols, trim |

## Big Win: RPC WebSocket

Set `SOLANA_WS_URL` for real-time swap streaming (same host as your RPC):

```
SOLANA_WS_URL=wss://your-node.example.com
```

Use your personal node or any RPC provider that supports WebSocket.

One WebSocket connection streams every Jupiter/Raydium/Pump swap. No polling, no per-IP limits. Throughput limited by `getTransaction` rate (we queue and throttle).

## Path to 1M

1. **Enable WebSocket** – 10k–50k/min from one connection
2. **Paid RPC** – Higher `getTransaction` limits = more throughput
3. **Add workers** – Each adds ~500/min from Gecko
4. **Raise queue concurrency** – `RPC_WS_QUEUE_CONCURRENCY=10` (default 5)

Rough: WebSocket 30k + 20 workers × 500 = 40k. Still far from 1M, but 10–20× better than polling-only.
