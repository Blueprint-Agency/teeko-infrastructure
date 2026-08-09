#!/usr/bin/env bash
# Back up a host's named Docker volumes to /home/deploy/backups/<timestamp>/ ON that host.
# Usage: ./scripts/backup.sh bp-vps3-prod
#
# Runs over ssh in the same shape as vps/shared/snapshot-host.sh -- the previous version
# took a <vps-alias> argument and then ran docker LOCALLY, so it never touched a VPS.
# Writes under /home/deploy because `deploy` has no sudo and cannot create /opt/backups.
set -euo pipefail
HOST="${1:?usage: backup.sh <ssh-alias>   e.g. bp-vps3-prod}"

ssh -o ConnectTimeout=15 -o BatchMode=yes "$HOST" '
  set -euo pipefail
  BACKUP_DIR="/home/deploy/backups/$(date +%Y-%m-%d_%H%M%S)"
  mkdir -p "$BACKUP_DIR"
  echo "==> $BACKUP_DIR"

  # Named volumes only: the 64-hex ones are anonymous and not worth keeping.
  docker volume ls --format "{{.Name}}" | grep -vE "^[0-9a-f]{64}$" | while read -r v; do
    echo "    $v"
    docker run --rm -v "$v:/source:ro" -v "$BACKUP_DIR:/backup" \
      alpine tar czf "/backup/$v.tar.gz" -C /source .
  done

  echo "==> done"
  du -sh "$BACKUP_DIR"
  # Keep 30 days. -mindepth 1 so the parent itself is never a deletion candidate.
  find /home/deploy/backups -mindepth 1 -maxdepth 1 -type d -mtime +30 -exec rm -rf {} + 2>/dev/null || true
'
