#!/bin/bash
# Generic deploy script - called by GitHub Actions or manually
# Usage: ./deploy.sh <vps-alias> [service-name]
#   vps-alias: staging | prod-vps2 | prod-vps3
#   service-name: (optional) specific service to update, or all if omitted

set -euo pipefail

VPS_ALIAS="${1:?Usage: ./deploy.sh <vps-alias> [service-name]}"
SERVICE_NAME="${2:-}"

# Resolve paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VPS_DIR="${SCRIPT_DIR}/../${VPS_ALIAS}"

if [ ! -d "$VPS_DIR" ]; then
  echo "Error: VPS directory not found: ${VPS_DIR}"
  exit 1
fi

echo "==> Deploying to ${VPS_ALIAS}..."

cd "$VPS_DIR"

if [ -n "$SERVICE_NAME" ]; then
  echo "==> Pulling latest image for ${SERVICE_NAME}..."
  docker compose pull "$SERVICE_NAME"
  echo "==> Restarting ${SERVICE_NAME}..."
  docker compose up -d "$SERVICE_NAME"
else
  echo "==> Pulling all images..."
  docker compose pull
  echo "==> Restarting all services..."
  docker compose up -d
fi

echo "==> Cleaning up old images..."
docker image prune -f

echo "==> Deploy complete. Current status:"
docker compose ps
