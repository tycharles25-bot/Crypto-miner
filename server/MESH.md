# Distributed Worker Mesh

Phase 2 of the scaling redesign. Redis as shared store so workers and hub converge on one data source.

**Hybrid API pooling:** Gecko + DexScreener + Birdeye + RPC + Contribute all feed Solana token data into one pool. Alerts are deduplicated by mint.

## Setup

1. **Run Redis** (local or cloud):
   ```bash
   docker compose up -d   # includes Redis + hub
   ```
   Or standalone:
   ```bash
   docker run -d -p 6379:6379 redis:7-alpine
   ```
   Or use Redis Cloud, Upstash, etc.

2. **Hub `.env`**:
   ```
   REDIS_URL=redis://localhost:6379
   HUB_URL=   # not needed for workers that write to Redis
   ```

3. **Worker `.env`** (choose one):
   - **Legacy:** `HUB_URL=https://your-hub.com` — worker POSTs to hub, hub writes to Redis
   - **Mesh:** `REDIS_URL=redis://...` — worker writes directly to Redis (no hub needed for contribute)
   - **Both:** `HUB_URL=...` and `REDIS_URL=...` — worker writes to both

## Flow

```
Workers (VPN)          Hub                    Redis
     │                  │                        │
     ├─ POST /contribute─►│── write-through ──────►│
     │                  │                        │
     └─ REDIS_URL ──────┼── direct write ──────►│
                        │                        │
RPC (WS/poll) ──────────►│── swap prices ───────►│
                        │                        │
                        └── sync every 10s ◄─────┘
                             Pump detection
```

## Scaling

| Phase | What | When |
|-------|------|------|
| 1 | Hub + many workers, POST only | Current |
| 2 | Redis shared store, write-through | **Now** |
| 3 | Regional aggregators | 50+ workers |
| 4 | Workers write direct to Redis, hub reads only | Optional |

## Redis schema

- `pump:price:{mint}` — sorted set, score=ts, value=`ts:price`
- `pump:symbol:{mint}` — token symbol (TTL 24h)
- `pump:mints` — set of tracked mints

## Maintenance

- **Trim:** Old price data (>24h) is removed every hour
- **Health:** `/status` includes `mesh.redis.connected` (PING check)
- **Symbols:** Stored in Redis so pump alerts show correct names from any worker

## Deduplication

Hub merges Redis data into memory every 10s. Same mint from multiple workers → one series (latest wins per timestamp).
