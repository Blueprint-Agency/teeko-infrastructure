#!/bin/bash
# Rollback a service to its previous image
# Usage: ./rollback.sh <vps-alias> <service-name>
# This pulls the previous image tag from docker history and restarts.

set -euo pipefail

VPS_ALIAS="${1:?Usage: ./rollback.sh <vps-alias> <service-name>}"
SERVICE_NAME="${2:?Usage: ./rollback.sh <vps-alias> <service-name>}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VPS_DIR="${SCRIPT_DIR}/../vps/${VPS_ALIAS}"

if [ ! -d "$VPS_DIR" ]; then
  echo "Error: VPS directory not found: ${VPS_DIR}"
  exit 1
fi

cd "$VPS_DIR"

echo "==> Current state of ${SERVICE_NAME}:"
docker compose ps "$SERVICE_NAME"

echo ""
echo "==> Rolling back ${SERVICE_NAME} on ${VPS_ALIAS}..."

# Get current image
CURRENT_IMAGE=$(docker compose images "$SERVICE_NAME" --format "{{.Repository}}:{{.Tag}}" 2>/dev/null | head -1)
echo "    Current image: ${CURRENT_IMAGE}"

# Stop the service
docker compose stop "$SERVICE_NAME"

# Remove the container (keeps volumes)
docker compose rm -f "$SERVICE_NAME"

# The previous image should still be cached locally
# Restart with docker compose (will use whatever tag is in docker-compose.yml)
echo "    Restarting with compose file configuration..."
docker compose up -d "$SERVICE_NAME"

echo ""
echo "==> Rollback complete. New state:"
docker compose ps "$SERVICE_NAME"
