#!/usr/bin/env bash
# Run by CI on the host, inside /root/stacks/<dir>, after the rendered files land
# and before `docker compose up`. Replaces the mkdir/chmod/chown that used to be
# hardcoded in deploy-infra.yml's `case $stack in` block.
set -euo pipefail

# Mounted read-only into the mcp container; must be world-readable for its uid.
chmod 644 credentials/sa-key.json

# Dex stores signing keys and tokens in dex.db on this bind mount -- without it,
# every restart forces a re-login. Dex runs as uid 1001.
mkdir -p dex-data
if [ "$(stat -c %u dex-data)" != "1001" ]; then
  # CI connects as `deploy`, which is not root and cannot chown. Steady state is a
  # no-op; a FRESH host lands here and must be fixed once by hand, because
  # provisioning is deliberately not CI's job.
  chown -R 1001:1001 dex-data 2>/dev/null || {
    echo "dex-data must be owned by uid 1001 and 'deploy' cannot chown it." >&2
    echo "Run once as root:  chown -R 1001:1001 $PWD/dex-data" >&2
    exit 1
  }
fi
