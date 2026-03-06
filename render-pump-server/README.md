# Render Pump Server

PumpApi + pump detection server for the iOS app. Deploy to Render for 24/7 pump scanning.

## Deploy to Render

1. Push this repo to GitHub
2. Go to [dashboard.render.com](https://dashboard.render.com)
3. **New** → **Web Service**
4. Connect your GitHub repo
5. Set **Root Directory** to `render-pump-server`
6. **Build Command:** `npm install`
7. **Start Command:** `npm start`
8. Deploy

## After deployment

Copy your Render URL (e.g. `https://render-pump-server-xxx.onrender.com`) and set it in the iOS app: **Settings** → **Pump Server** → paste the URL.

## Endpoints

- `GET /alerts` – Pump alerts (iOS polls this)
- `GET /status` – Health + stats
- `GET /health` – Simple health check

## Free tier note

Render free web services spin down after ~15 min of inactivity. The iOS app polls every 10 seconds when open, which keeps the server awake. For 24/7 without the app open, consider a paid plan or use a cron service to ping `/health` every 5 minutes.
