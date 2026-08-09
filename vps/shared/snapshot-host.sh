#!/usr/bin/env bash
# Prints a deterministic snapshot of a host's docker state, for before/after diffing
# around deploys. Sorted so `diff` output means something.
set -euo pipefail
HOST="${1:?usage: snapshot-host.sh <ssh-alias>}"
ssh -o ConnectTimeout=15 -o BatchMode=yes "$HOST" '
  echo "== containers"
  docker ps --format "{{.Names}}\t{{.Image}}\t{{.State}}" | sort
  echo "== volumes"
  docker volume ls --format "{{.Name}}" | sort
  echo "== stacks"
  ls -1 /root/stacks | sort
'
