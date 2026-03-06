# Cloudflare Worker – Edge Contributor

Runs at Cloudflare's edge. Fetches Gecko OHLCV and POSTs to your hub. Free tier: 100k requests/day.

## Deploy

```bash
cd server/cloudflare-worker
npm install
npx wrangler login
npx wrangler secret put HUB_URL   # Enter your hub URL, e.g. https://your-hub.com
npm run deploy
```

## Multiple Workers = Multiple IPs

Deploy multiple Workers with different names to potentially get different edge IPs:

1. Copy `cloudflare-worker/` to `cloudflare-worker-2/`
2. In `wrangler.toml`, change `name = "pump-worker-2"`
3. Deploy: `cd cloudflare-worker-2 && npm run deploy`
4. In Cloudflare dashboard, add Cron Trigger: `*/2 * * * *`

Or use one Worker – it still adds 1 IP. Deploy more for potentially more IPs (Cloudflare may route to different edges).

## Limits

- **Free:** 100k requests/day, 10ms CPU (fetch is I/O, usually fine)
- **Cron:** Runs every 2 min = 720 runs/day
- **Per run:** ~8 pools × 65 candles ≈ 520 samples

## Cost

Free. No credit card for Workers free tier.
