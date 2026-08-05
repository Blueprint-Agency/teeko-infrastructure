#!/bin/bash
# Renew the blueprintdigital.my LE cert (acme.sh / Cloudflare DNS-01) and reload only if it
# actually renewed. Runs as the `deploy` user (no sudo on this host) via its own crontab:
#   0 3 * * * /root/stacks/stalwart/renew-cert.sh >> /home/deploy/bpd-cert-renew.log 2>&1
# The CF API token (BPD_CF_DNS_API_TOKEN) is read from the gitignored stack .env and
# exported as CF_Token so acme.sh's dns_cf plugin can update the challenge records.
set -e
D=/root/stacks/stalwart
SRC="$D/acme/mail.blueprintdigital.my_ecc/fullchain.cer"

export CF_Token="$(grep -E '^BPD_CF_DNS_API_TOKEN=' "$D/.env" | cut -d= -f2-)"

docker run --rm -v "$D/acme:/acme.sh" -e CF_Token="$CF_Token" neilpang/acme.sh --cron --home /acme.sh

if [ -f "$SRC" ] && [ "$SRC" -nt "$D/certs/fullchain.pem" ]; then
  docker run --rm -v "$D/acme:/acme.sh" -v "$D/certs:/certs" \
    neilpang/acme.sh --install-cert -d mail.blueprintdigital.my --ecc \
    --key-file /certs/key.pem --fullchain-file /certs/fullchain.pem
  # Stalwart runs as uid 2000 and must be able to read these. `deploy` has no sudo here,
  # and chowning to another uid needs root — so do it from inside a container.
  docker run --rm -v "$D/certs:/certs" alpine chown 2000:2000 /certs/fullchain.pem /certs/key.pem
  docker restart stalwart >/dev/null   # Traefik (file provider) auto-reloads on change
  echo "$(date -Is) cert RENEWED + Stalwart reloaded"
else
  echo "$(date -Is) cert not due for renewal"
fi
