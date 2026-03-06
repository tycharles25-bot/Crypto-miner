# Free Options to Scale Workers

Stack multiple free tiers from different providers = more IPs = more samples/min.

---

## Always Free (No Expiry)

### 1. Oracle Cloud — 2 VMs free forever

- **Sign up:** [oracle.com/cloud/free](https://www.oracle.com/cloud/free/)
- **VMs:** 2× AMD (1GB RAM) or 4× ARM (up to 4 cores, 24GB)
- **Requires:** Credit card for verification (no charge if you stay in free tier)

**Steps:**
1. Create account → Create VM Instance
2. Image: Ubuntu 22.04
3. Shape: VM.Standard.E2.1.Micro (AMD) or Ampere A1 (ARM)
4. Create in your home region

**= 2 workers** (or 4 if you use ARM)

---

### 2. Google Cloud — 1 VM always free

- **Sign up:** [cloud.google.com/free](https://cloud.google.com/free)
- **VM:** 1× e2-micro (0.25–1 vCPU, 1GB) in US regions only
- **Regions:** us-west1, us-central1, us-east1
- **Note:** Add external IP in console (free tier includes it for e2-micro)

**= 1 worker**

---

## Time-Limited Free (12 Months)

### 3. AWS — 1 VM free for 12 months

- **Sign up:** [aws.amazon.com/free](https://aws.amazon.com/free/)
- **VM:** 1× t2.micro (1 vCPU, 1GB) — 750 hours/month
- **Lightsail:** $5/mo after trial, or use EC2 free tier

**= 1 worker** (for 12 months)

---

## Stack Them

| Provider   | VMs | Always Free? |
|------------|-----|--------------|
| Oracle     | 2   | Yes          |
| Google     | 1   | Yes          |
| AWS        | 1   | 12 months    |
| **Total**  | **4** | 3 forever + 1 for 12mo |

**4 workers ≈ 3,500 tokens/min** (hub + 4 workers)

---

## VPN on One Machine (Free)

Run multiple workers on **one** machine, each through a different VPN = different IPs.

- **Windscribe free:** 10GB/mo, 1 location → 1 extra IP
- **ProtonVPN free:** 1 connection → 1 extra IP
- **ProtonVPN Plus (~$5/mo):** 10 connections → 10 IPs from one machine

Use `docker-compose.workers.yml` — see [VPN-SETUP.md](VPN-SETUP.md).

**Free VPN = 2 IPs** (direct + 1 VPN) from one machine.

---

## Quick Setup Order

1. **Oracle** — 2 free VMs (best value)
2. **Google Cloud** — 1 free VM
3. **AWS** — 1 free VM (optional, 12-month limit)
4. **Your machine** — Hub + optional worker

Deploy worker on each VM:
```bash
git clone <repo>
cd "Crypto miner/server"
HUB_URL=https://your-hub.com docker compose -f docker-compose.cloud-worker.yml up -d --build
```
