# Firewall Rules

Firewall is managed via **Hostinger VPS GUI** (not programmatically).
These rules should be applied on all 3 VPS.

## Required Ports

| Port | Protocol | Source | Purpose |
|------|----------|--------|---------|
| 22 | TCP | Your team IPs (or all) | SSH access |
| 80 | TCP | All | HTTP (Traefik redirects to 443) |
| 443 | TCP | All | HTTPS (Traefik terminates TLS) |

## Ports That Should Be CLOSED

All other ports should be blocked. Specifically ensure these are NOT exposed:

| Port | Service | Why it should be closed |
|------|---------|------------------------|
| 3000 | App backends / Grafana | Accessed through Traefik only |
| 5432 | PostgreSQL | Internal Docker network only |
| 5678 | n8n | Accessed through Traefik only |
| 8080 | pgadmin | Accessed through Traefik only |
| 9000 | Portainer (legacy) | Being removed |
| 9090 | Prometheus | Internal monitoring network only |

## How to Update

1. Log into Hostinger panel
2. Go to VPS > Firewall
3. Update rules
4. Update this document to match

## Notes

- Traefik handles all HTTP/HTTPS routing — apps should never expose ports directly
- Docker containers communicate via internal Docker networks, not through the host firewall
- After Traefik migration, the only externally accessible ports should be 22, 80, and 443
