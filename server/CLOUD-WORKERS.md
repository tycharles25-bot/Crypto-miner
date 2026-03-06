# Deploy Workers on Cloud VMs

Each VM = one worker = one IP. No proxies needed.

## 1. Hub (one server)

Deploy the full server (hub + trading) to a single VM:

- **DigitalOcean:** $6/mo droplet
- **AWS Lightsail:** $5/mo
- **Railway / Fly.io:** Free tier or ~$5/mo

```bash
git clone <your-repo>
cd server
cp .env.example .env
# Edit: SOLANA_PRIVATE_KEY, HUB_URL not needed (hub runs here)
npm install
npm start
```

Expose port 3000. Your hub URL: `https://your-hub.com` (use ngrok for local testing).

---

## 2. Workers (one per VM)

Create N VMs in **different regions** (US, EU, Asia). Each gets its own IP.

### Per-worker VM

**Minimal .env:**
```env
HUB_URL=https://your-hub.com
WORKER_INTERVAL_MS=120000
WORKER_MAX_POOLS=25
```

**Run:**
```bash
cd server
npm install
node worker.js
```

### Quick deploy (Docker)

```bash
# On each worker VM (after git clone, cd server)
HUB_URL=https://your-hub.com docker compose -f docker-compose.cloud-worker.yml up -d --build
```

Or use the script:
```bash
HUB_URL=https://your-hub.com ./scripts/deploy-worker.sh
```

### Keep it running (systemd)
```bash
sudo nano /etc/systemd/system/pump-worker.service
```

```ini
[Unit]
Description=Pump Tracker Worker
After=network.target

[Service]
Type=simple
User=ubuntu
WorkingDirectory=/home/ubuntu/server
Environment="HUB_URL=https://your-hub.com"
ExecStart=/usr/bin/node worker.js
Restart=always

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl enable pump-worker
sudo systemctl start pump-worker
```

**Docker:**
```bash
docker run -d --restart unless-stopped \
  -e HUB_URL=https://your-hub.com \
  -v $(pwd)/server:/app -w /app node:20 \
  node worker.js
```

---

## 3. Providers

| Provider      | Cost      | Regions |
|---------------|-----------|---------|
| DigitalOcean  | $4–6/mo   | NYC, SFO, AMS, SGP, etc. |
| Vultr         | $3.50/mo  | 25+ locations |
| Linode        | $5/mo     | 11 regions |
| AWS Lightsail | $5/mo     | us-east, eu-west, ap-south |
| Oracle Cloud  | Free tier | 2 VMs free |

---

## 4. Scaling

- 1 hub + 4 workers (4 VMs) ≈ 3,500 tokens/min
- 1 hub + 9 workers ≈ 6,000 tokens/min
- Each worker adds ~500 tokens/min (Gecko per-IP limit)

Check `GET /status` → `contribute.samplesPerMinute`.
