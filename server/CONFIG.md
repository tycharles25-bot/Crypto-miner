# Pump Tracker Config

## Current setup (chain-only)

- **Data:** On-chain swap data via RPC (no Gecko/DexScreener)
- **Pump detection:** 100% gain in 10 min from RPC price history
- **RPC:** 5 free endpoints, Pump.fun only, poll every 90s

## If you get 429 errors

Free RPCs have strict limits. Options:

1. **PumpApi only** – Set `RPC_INDEXER_ENABLED=false`. Pump detection uses the PumpApi stream (no RPC polling). RPC still used for Jupiter swaps.

2. **Paid RPC (recommended)** – Add to `.env`:
   ```
   SOLANA_RPC_URL=https://mainnet.helius-rpc.com/?api_key=YOUR_KEY
   ```
   Remove other SOLANA_RPC_URL_2 through _5. Helius free tier: 1M credits/mo.

2. **Slower polling** – Increase `RPC_INDEXER_POLL_MS` to 120000 or 180000.

3. **Single program** – `RPC_INDEXER_PROGRAMS=pump` (already set).

## Key env vars

| Var | Purpose |
|-----|---------|
| `DATA_SOURCE=chain` | Use RPC only |
| `RPC_INDEXER_PROGRAMS` | pump, jupiter, raydium, orca |
| `DRY_RUN=true` | No real buys/sells |
| `SOL_PER_TRADE_LAMPORTS` | 75000 = 0.000075 SOL |
