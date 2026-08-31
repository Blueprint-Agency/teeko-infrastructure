# bpvps2 cannot issue a wildcard certificate for `reservetoday.app`

Recorded 2026-08-31. **No action needed** — this is written down so it is not
rediscovered the next time someone asks "why aren't the frontends on the VPS?"

## The constraint

Traefik on bpvps2 has two ACME resolvers:

| Resolver | Challenge | Can do wildcards? |
|---|---|---|
| `le-tls` | TLS-ALPN-01 | **No** |
| `letsencrypt` | DNS-01 (Cloudflare) | Yes, but only for the Teeko zone |

`booking-be` uses `le-tls`. Two independent reasons block a wildcard:

1. **TLS-ALPN-01 cannot issue wildcards.** The challenge proves control of port 443
   for one exact hostname. Let's Encrypt only issues `*.example.com` off DNS-01.

2. **The DNS-01 resolver cannot reach the right Cloudflare account.**
   `CF_DNS_API_TOKEN` on this host is an org-level secret holding the **Teeko**
   token, scoped to `teeko.ai`. `reservetoday.app` lives in the **Blueprint**
   Cloudflare account. Traefik reads that token from the **process environment**,
   not per-resolver — so adding a second DNS-01 resolver for reservetoday.app
   would silently reuse the Teeko token and fail. bpvps1 has the opposite problem
   and overrides the token at the host level; bpvps2 cannot, because its Teeko
   certs would then break.

## What follows from it

- **The frontends stay on Vercel.** Vercel issues the wildcard certificates itself.
  This is the concrete reason, not a preference.
- **Every backend hostname on bpvps2 must be named explicitly**, one Traefik router
  rule per exact FQDN, with a DNS record to match.
- **A new backend hostname needs its DNS record created first, DNS-only (grey
  cloud), pointing at 187.127.207.82.** TLS-ALPN-01 proves control of port 443 on
  that IP. If the record is proxied (orange cloud) or points at Vercel, Traefik
  gets no certificate and the hostname serves a TLS handshake failure.
- **Keep the old hostname as a router alias through any rename**, until the new
  name is confirmed serving a valid certificate.

## If this ever needs to change

Split Traefik's DNS-01 credentials per resolver. As of Traefik v3.3 the Cloudflare
provider still reads `CF_DNS_API_TOKEN` process-wide, so the realistic options are
a second Traefik instance, or moving `reservetoday.app` into the Teeko Cloudflare
account. Neither is worth it while Vercel fronts the customer-facing hosts.
