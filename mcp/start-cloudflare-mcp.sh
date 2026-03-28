#!/bin/bash
# Loads .env and starts the Cloudflare MCP server.
# This allows credentials to live in .env (gitignored) instead of settings.json.

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

exec npx -y mcp-remote https://mcp.cloudflare.com/mcp --header "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}"
