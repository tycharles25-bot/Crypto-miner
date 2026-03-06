# Pump Tracker Deployment

## Quick Start (Single Server)

```bash
cd server
cp .env.example .env
# Edit .env: SOLANA_PRIVATE_KEY, BIRDEYE_API_KEY (optional)
npm install
npm start
```

## Docker (Recommended)

```bash
cd server
cp .env.example .env
# Edit .env
docker compose up -d
```

## Multi-Server / Duplicate Approach

**Idea:** Run 1 hub + N workers. Each worker = different IP = separate Gecko rate limit = more tokens/min.

### Architecture

```
[Hub Server]                    [Worker 1]     [Worker 2]     [Worker N]
- Gecko, DexScreener, Birdeye   - Gecko only   - Gecko only   - Gecko only
- RPC indexer                   - POSTs to     - POSTs to     - POSTs to
- /contribute (receives)          hub            hub            hub
- Trading (Jupiter)
```

### Setup

**1. Hub (main server)**

- Deploy to Server A (e.g. DigitalOcean, AWS, Railway)
- Set `SOLANA_PRIVATE_KEY` for trading
- Expose port 3000 (or use reverse proxy)
- Hub URL: `https://your-hub.com`

**2. Workers (contribute-only)**

- Deploy to Server B, C, D... (different IPs)
- No wallet needed
- Set `HUB_URL=https://your-hub.com` in `.env`
- Run: `node worker.js`

**Worker .env (minimal):**
```env
HUB_URL=https://your-hub.com
WORKER_INTERVAL_MS=120000
WORKER_MAX_POOLS=25
```

**3. Docker workers**

```bash
# On each worker server
docker run -d --restart unless-stopped \
  -e HUB_URL=https://your-hub.com \
  -e WORKER_INTERVAL_MS=120000 \
  your-registry/pump-tracker:latest \
  node worker.js
```

### VPN Workers (Recommended)

Each worker runs through a different VPN server = different IP. No proxy costs.

```bash
# Add VPN credentials to .env (see VPN-SETUP.md)
docker compose -f docker-compose.workers.yml up -d
```

3 workers by default (US, UK, Germany). Add more by duplicating services. ProtonVPN Plus = 10 connections.

### Multiple Workers on One Machine (Proxies)

Each worker can use a different proxy = different IP = separate Gecko quota.

**1. Create workers.json** (copy from workers.json.example):
```json
[
  { "HTTP_PROXY": "http://proxy1:8080" },
  { "HTTP_PROXY": "http://proxy2:8080" },
  {}
]
```

**2. Run:**
```bash
HUB_URL=https://your-hub.com npm run workers
```

Spawns one worker per config. Each uses its own IP (via proxy or direct). ~21 workers ≈ 1M samples/min.

### Finding Your Max

**1. Check live throughput**

```bash
# While server is running with workers/iOS clients
curl http://localhost:3000/status
# contribute.samplesPerMinute = current rate
```

**2. Benchmark (single IP - hits rate limit)**

```bash
HUB_URL=http://localhost:3000 npm run benchmark
# Runs 2 min, 5 simulated workers. Expect ~30 req/min cap per IP.
```

**3. Real capacity**

- **Per-IP limit:** 30 contribute requests/min
- **N unique IPs** (workers + iOS) = 30×N requests/min
- **Server CPU/memory:** Unlikely bottleneck until 1000+ tokens/min
- **Practical max:** ~30 × (workers + iOS clients) requests/min

### Scaling

| Servers | Type | Approx tokens/min |
|---------|------|-------------------|
| 1 | Hub only | ~1,500 |
| 2 | 1 hub + 1 worker | ~2,000 |
| 5 | 1 hub + 4 workers | ~3,500 |
| 10 | 1 hub + 9 workers | ~6,000 |

Each worker adds ~500 tokens/min (Gecko from new IP).

### iOS App + Workers

- Hub: 1 server
- Workers: N servers
- iOS clients: M users with "Share data" enabled

**Total ≈ 1,500 + (N × 500) + (M × 5) tokens/min**
