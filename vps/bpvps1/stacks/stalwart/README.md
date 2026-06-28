# Stalwart + Roundcube — self-hosted email for `kaiteki.my` (BPVPS1)

Replaces the earlier Mailcow stack. **Stalwart** (Rust mail server, v0.16) handles
SMTP/IMAP/POP3/JMAP/ManageSieve + DKIM + spam; **Roundcube** is the webmail.

| | URL | Login |
|---|---|---|
| Admin UI | `https://email.kaiteki.my` | `admin@kaiteki.my` (created by the setup wizard) |
| Webmail | `https://webmail.kaiteki.my` | mailbox creds (e.g. `admin@kaiteki.my`) |

Stack dir on VPS: `/root/stacks/stalwart/`. Data in the `stalwart-data` volume
(RocksDB at `/opt/stalwart/data`). Co-hosted behind the existing Traefik.

## How it fits together
- **Mail ports** (25/465/587/993/143/110/995/4190) bind directly on the host.
- **Web UIs** go through Traefik: `email.` → `stalwart:8080`, `webmail.` → `roundcube:80`,
  over the external `stalwart_mailnet` network. See `../traefik/dynamic/stalwart.yml`.
- **Roundcube → Stalwart** uses the network alias `email.kaiteki.my` (on `stalwart_mailnet`)
  so it connects internally with a **cert-matching** name (`ssl://email.kaiteki.my:993/465`).

## TLS (the tricky bit)
One LE cert for `email.kaiteki.my` + `webmail.kaiteki.my`, issued **out-of-band via
Cloudflare DNS-01** (acme.sh + `KAITEKI_CF_DNS_API_TOKEN`) because Traefik's CF token only
covers `teeko.ai`. Cert lands in `./certs/{fullchain,key}.pem`.
- **Traefik** serves it via the file provider (`stalwart.yml`).
- **Stalwart** reads the same files for mail TLS — set once in the **admin UI →
  Settings → TLS → Certificates** as **File** references (`/opt/stalwart/certs/...`).
  ⚠️ The cert files must be readable by Stalwart's user: `chown 2000:2000 ./certs/*.pem`.
- Renewal: `renew-cert.sh` (run daily by host cron) re-runs acme.sh, reinstalls to
  `./certs`, re-chowns, and restarts Stalwart.

## DNS (zone `kaiteki.my`, separate CF account — `KAITEKI_CF_DNS_API_TOKEN`)
| Record | Name | Value |
|--------|------|-------|
| A | `email.kaiteki.my` / `webmail.kaiteki.my` | `187.127.122.41` (DNS-only) |
| MX | `kaiteki.my` | `email.kaiteki.my` (10) |
| TXT (SPF) | `kaiteki.my` | `v=spf1 mx ~all` |
| TXT (DKIM) | `v1-rsa-20260628._domainkey` | `v=DKIM1; k=rsa; p=…` |
| TXT (DKIM) | `v1-ed25519-20260628._domainkey` | `v=DKIM1; k=ed25519; p=…` |
| TXT (DMARC) | `_dmarc.kaiteki.my` | `v=DMARC1; p=none; rua=mailto:dmarc@kaiteki.my; fo=1` |

Verified: SPF pass, DKIM pass (RSA), inbound + outbound working. DKIM selectors come from
Stalwart's template `v{version}-{algorithm}-{date}`; **re-publish if keys rotate.**

## ⚠️ Gotchas / landmines
- **`config.json` is persistence-critical.** It's the storage pointer Stalwart reads on
  boot (`--config /etc/stalwart/config.json`). `/etc/stalwart` is **not** a volume, so it's
  bind-mounted from `./config.json`. **Without this mount, a container recreate wipes
  Stalwart back into the bootstrap/setup wizard** (data survives in the store, but config
  is lost). Do not remove the mount.
- Config lives in the **store (DB)**, set via the **admin UI**, not a TOML file. There's no
  CLI and the settings REST API isn't readily scriptable — most config is UI-driven.
- `STALWART_RECOVERY_ADMIN` (in stack `.env`, gitignored) is a fallback admin for the
  management API on `127.0.0.1:8090`.
- Old DKIM verifiers (e.g. port25) can't evaluate Ed25519 (RFC 8463) → harmless `permerror`;
  the RSA signature still passes.

## Host requirements (Hostinger hPanel — BPVPS1)
- Firewall: `22, 25, 80, 443` (+ optionally `465/587/993/995/143/110/4190` for native
  IMAP/SMTP clients; webmail only needs `443`). PTR `187.127.122.41` → `email.kaiteki.my`.

## Ops
```bash
cd /root/stacks/stalwart
docker compose ps
docker compose up -d            # safe to recreate now (config.json is mounted)
./renew-cert.sh                 # manual cert renew (also runs daily via cron)
```
