# VPN Workers Setup

Run multiple workers, each through a different VPN server = different IP = more Gecko quota.

## 1. Get VPN Credentials

### Free Options

**Windscribe (best for multiple workers)**
- Free: **Unlimited simultaneous connections**
- 10 GB/month (with email signup; 2 GB without)
- Gluetun: `VPN_SERVICE_PROVIDER=windscribe`, WireGuard or OpenVPN
- Config: windscribe.com → Get Config → WireGuard

**ProtonVPN**
- Free: 1 connection only
- Unlimited data
- Gluetun: `VPN_SERVICE_PROVIDER=protonvpn`, set `FREE_ONLY=on`

### Paid (more data / connections)

**ProtonVPN Plus** – ~$5/mo, 10 connections  
**NordVPN** – ~$4/mo, 6 connections  
**Windscribe Pro** – ~$6/mo, unlimited data

## 2. Windscribe Free Setup (Multiple Workers)

1. Sign up at windscribe.com (free)
2. Go to windscribe.com/getconfig/wireguard
3. Generate config, copy `PrivateKey` and `Address`
4. Add to `.env`:
   ```
   VPN_SERVICE_PROVIDER=windscribe
   VPN_TYPE=wireguard
   WIREGUARD_PRIVATE_KEY=xxxxx
   WIREGUARD_ADDRESSES=100.64.x.x/32
   HUB_URL=https://your-hub.com
   ```
5. Run: `docker compose -f docker-compose.workers.yml up -d`

Note: 10 GB/mo free = ~2–3 workers sustainable. Add more workers = upgrade or use multiple free accounts.

## 3. ProtonVPN WireGuard Setup

1. Install ProtonVPN, connect, go to Settings → WireGuard
2. Export config or copy:
   - `PrivateKey` → `WIREGUARD_PRIVATE_KEY`
   - `Address` (e.g. `10.2.0.2/32`) → `WIREGUARD_ADDRESSES`
3. Add to `.env`:
   ```
   VPN_SERVICE_PROVIDER=protonvpn
   VPN_TYPE=wireguard
   WIREGUARD_PRIVATE_KEY=xxxxx
   WIREGUARD_ADDRESSES=10.2.0.2/32
   HUB_URL=https://your-hub.com
   ```

## 4. Run

```bash
cd server
docker compose -f docker-compose.workers.yml up -d
```

3 workers = 3 different IPs (US, UK, Germany). Check hub `/status` for `contribute.samplesPerMinute`.

## 5. Add More Workers

Copy a `wN-vpn` + `workerN` block in docker-compose.workers.yml, change `SERVER_COUNTRIES` (e.g. France, Netherlands, Japan). Max depends on your VPN plan.

## 6. Troubleshooting

- **VPN won't connect:** Check credentials, try `SERVER_COUNTRIES` with different country
- **Workers can't reach hub:** Ensure HUB_URL is reachable from the internet (not localhost if hub is on same machine)
- **Same IP:** Each worker must use different SERVER_COUNTRIES to get different VPN servers
