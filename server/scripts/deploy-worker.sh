#!/bin/bash
# Deploy worker on a fresh cloud VM (Ubuntu/Debian).
# Usage: HUB_URL=https://your-hub.com ./scripts/deploy-worker.sh
#
# On the VM: git clone, cd server, then run this script.

set -e
HUB_URL="${HUB_URL:?Set HUB_URL=https://your-hub.com}"

echo "=== Pump Tracker Worker ==="
echo "Hub: $HUB_URL"

if ! command -v docker &>/dev/null; then
  echo "Installing Docker..."
  curl -fsSL https://get.docker.com | sh
  sudo usermod -aG docker "$USER" 2>/dev/null || true
fi

echo "Starting worker..."
HUB_URL="$HUB_URL" docker compose -f docker-compose.cloud-worker.yml up -d --build

echo "Done. Check: docker compose -f docker-compose.cloud-worker.yml logs -f"
