#!/bin/bash
# Loads .env and starts the Docker MCP server for a given VPS.
# Usage: start-docker-mcp.sh <staging|prod-vps2|prod-vps3>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/../.env"

if [ -f "$ENV_FILE" ]; then
  set -a
  source "$ENV_FILE"
  set +a
else
  echo "Error: .env not found at ${ENV_FILE}" >&2
  exit 1
fi

VPS="${1:?Usage: start-docker-mcp.sh <staging|prod-vps2|prod-vps3>}"

case "$VPS" in
  staging)    export DOCKER_HOST="ssh://${VPS1_USER}@${VPS1_HOST}" ;;
  prod-vps2)  export DOCKER_HOST="ssh://${VPS2_USER}@${VPS2_HOST}" ;;
  prod-vps3)  export DOCKER_HOST="ssh://${VPS3_USER}@${VPS3_HOST}" ;;
  *)          echo "Unknown VPS: ${VPS}" >&2; exit 1 ;;
esac

exec uvx mcp-server-docker
