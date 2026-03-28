#!/bin/bash
# Backup Docker volumes for a VPS
# Usage: ./backup.sh <vps-alias>
# Backs up all named volumes to /opt/backups/<date>/

set -euo pipefail

VPS_ALIAS="${1:?Usage: ./backup.sh <vps-alias>}"
BACKUP_DIR="/opt/backups/$(date +%Y-%m-%d_%H%M%S)"

echo "==> Creating backup directory: ${BACKUP_DIR}"
mkdir -p "$BACKUP_DIR"

echo "==> Backing up Docker volumes for ${VPS_ALIAS}..."

# Get all named volumes (excludes anonymous volumes)
for VOLUME in $(docker volume ls --format '{{.Name}}' | grep -v '^[0-9a-f]\{64\}$'); do
  echo "    Backing up volume: ${VOLUME}"
  docker run --rm \
    -v "${VOLUME}:/source:ro" \
    -v "${BACKUP_DIR}:/backup" \
    alpine tar czf "/backup/${VOLUME}.tar.gz" -C /source .
done

echo ""
echo "==> Backup complete: ${BACKUP_DIR}"
ls -lh "$BACKUP_DIR"

# Clean up backups older than 30 days
echo "==> Cleaning up backups older than 30 days..."
find /opt/backups -maxdepth 1 -type d -mtime +30 -exec rm -rf {} + 2>/dev/null || true
