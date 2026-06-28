#!/bin/bash
# Renew the kaiteki.my LE cert (acme.sh / Cloudflare DNS-01) and reload only if it actually
# renewed. Run daily via host cron:
#   0 3 * * * /root/stacks/stalwart/renew-cert.sh >> /var/log/kaiteki-cert-renew.log 2>&1
# The CF API token (KAITEKI_CF_DNS_API_TOKEN) is read from the gitignored stack .env and
# exported as CF_Token so acme.sh's dns_cf plugin can update the challenge records.
set -e
D=/root/stacks/stalwart
SRC="$D/acme/mail.kaiteki.my_ecc/fullchain.cer"

export CF_Token="$(grep -E '^KAITEKI_CF_DNS_API_TOKEN=' "$D/.env" | cut -d= -f2-)"

docker run --rm -v "$D/acme:/acme.sh" -e CF_Token="$CF_Token" neilpang/acme.sh --cron --home /acme.sh

if [ -f "$SRC" ] && [ "$SRC" -nt "$D/certs/fullchain.pem" ]; then
  docker run --rm -v "$D/acme:/acme.sh" -v "$D/certs:/certs" \
    neilpang/acme.sh --install-cert -d mail.kaiteki.my --ecc \
    --key-file /certs/key.pem --fullchain-file /certs/fullchain.pem
  chown 2000:2000 "$D"/certs/fullchain.pem "$D"/certs/key.pem
  docker restart stalwart >/dev/null   # Traefik (file provider) auto-reloads on change
  echo "$(date -Is) cert RENEWED + Stalwart reloaded"
else
  echo "$(date -Is) cert not due for renewal"
fi
