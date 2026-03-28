#!/bin/bash
# Health check script - verifies all expected containers are running
# Usage: ./healthcheck.sh <vps-alias>

set -euo pipefail

VPS_ALIAS="${1:?Usage: ./healthcheck.sh <vps-alias>}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VPS_DIR="${SCRIPT_DIR}/../${VPS_ALIAS}"

if [ ! -d "$VPS_DIR" ]; then
  echo "Error: VPS directory not found: ${VPS_DIR}"
  exit 1
fi

cd "$VPS_DIR"

echo "==> Health check for ${VPS_ALIAS}"
echo ""

# Check all containers
UNHEALTHY=0
while IFS= read -r line; do
  NAME=$(echo "$line" | awk '{print $1}')
  STATE=$(echo "$line" | awk '{print $2}')
  STATUS=$(echo "$line" | awk '{$1=$2=""; print $0}' | xargs)

  if [ "$STATE" != "running" ]; then
    echo "  FAIL  ${NAME} (state: ${STATE})"
    UNHEALTHY=$((UNHEALTHY + 1))
  else
    echo "  OK    ${NAME} (${STATUS})"
  fi
done < <(docker compose ps --format "{{.Name}} {{.State}} {{.Status}}" 2>/dev/null)

echo ""
if [ "$UNHEALTHY" -gt 0 ]; then
  echo "==> ${UNHEALTHY} service(s) not healthy!"
  exit 1
else
  echo "==> All services healthy."
fi
