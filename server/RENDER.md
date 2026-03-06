# Deploy Workers on Render

## PumpApi Ingest (~95k samples/min)

5 workers in different regions = 5 unique IPs = 5 PumpApi connections. Cost: ~$35/month.

**Note:** Render shares outbound IPs per region. 1 worker per region = 1 PumpApi connection. 53 workers in same region = still 1 connection.

1. **Hub must be reachable** (ngrok or deployed)
2. **New Blueprint** in Render → Connect repo
3. **Blueprint file:** Select `render-pumpapi-ingest.yaml`
4. Set **HUB_URL** when prompted
5. Deploy

**Hub:** `CONTRIBUTE_RATE_LIMIT_PER_IP=60` in hub .env (optional)

---

## Gecko Workers

### 1. Hub must be reachable

Workers POST to `HUB_URL`. Your hub must be reachable from the internet:

- **Local hub:** Use [ngrok](https://ngrok.com) – `ngrok http 3000` → use the URL as HUB_URL
- **Hub on Render:** Deploy the hub as a Web Service first, get its URL
- **Hub elsewhere:** Use your deployed hub URL

## 2. Deploy via Blueprint

1. Push your repo to GitHub (if not already)
2. Go to [dashboard.render.com](https://dashboard.render.com)
3. **New** → **Blueprint**
4. Connect your GitHub repo
5. Render will detect `render.yaml` and create the worker
6. When prompted, set **HUB_URL** (e.g. `https://your-hub.onrender.com` or `https://xxx.ngrok.io`)

## 3. Deploy manually (no Blueprint)

1. **New** → **Background Worker**
2. Connect repo
3. **Root Directory:** `server`
4. **Build Command:** `npm install`
5. **Start Command:** `node worker.js`
6. **Environment:** Add `HUB_URL` = your hub URL
7. **Create**

## 4. Add more workers

Each worker = different IP = more Gecko quota.

- Uncomment the second worker in `render.yaml` and redeploy, or
- Create another Background Worker manually

## 5. Verify

Check hub `/status` – `contribute.samplesPerMinute` should increase when workers are running.
