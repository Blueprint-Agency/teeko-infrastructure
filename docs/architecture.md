# Architecture Overview

## Infrastructure Layout

```
┌─────────────────────────────────────────────────────────┐
│                    GitHub Organization                   │
│                                                         │
│  ┌──────────┐  ┌──────────┐  ┌──────────────────────┐  │
│  │ Monorepo │  │ Monorepo │  │ infrastructure repo  │  │
│  │ Project A│  │ Project B│  │ (this repo)          │  │
│  └────┬─────┘  └────┬─────┘  └──────────┬───────────┘  │
│       │              │                   │              │
│       └──────┬───────┘                   │              │
│              ▼                           ▼              │
│     GitHub Actions (CI)         GitHub Actions (CD)     │
│     build → test → push        SSH → pull → up          │
│     image to DockerHub         on target VPS            │
└─────────────────────────────────────────────────────────┘
              │                            │
              ▼                            ▼
┌──────────────────┐    ┌──────────────────────────────────┐
│    DockerHub     │    │         Hostinger VPS             │
│                  │    │                                    │
│  org/app:tag     │───▶│  VPS1 (Staging)                   │
│                  │    │  ├── Traefik (reverse proxy)      │
│                  │    │  ├── App containers (staging)     │
│                  │    │  └── Monitoring stack             │
│                  │    │                                    │
│                  │───▶│  VPS2 (Production - Group A)      │
│                  │    │  ├── Traefik                      │
│                  │    │  ├── App containers (prod)        │
│                  │    │  └── Monitoring stack             │
│                  │    │                                    │
│                  │───▶│  VPS3 (Production - Group B)      │
│                  │    │  ├── Traefik                      │
│                  │    │  ├── App containers (prod)        │
│                  │    │  └── Monitoring stack             │
│                  │    └──────────────────────────────────┘
└──────────────────┘
              ▲
              │
┌─────────────┴────────────┐
│  Claude Code + MCP       │
│  ├── mcp-ssh-manager     │
│  └── mcp-server-docker   │
│                          │
│  Real-time ops:          │
│  - Container management  │
│  - Log tailing           │
│  - VPS monitoring        │
│  - Debugging             │
└──────────────────────────┘
```

## External Services

| Service | Purpose | Per-App? |
|---------|---------|----------|
| Supabase | Database (PostgreSQL) | Yes, each app has its own DB |
| Auth0 | Authentication | Shared across apps |
| Stripe | Payments | Per-app as needed |
| DockerHub | Container registry | Shared org account |

## Networking

Each VPS runs Traefik as the single entry point:
- Port 80 → redirects to 443
- Port 443 → routes to containers based on domain (Host rule)
- Let's Encrypt for automatic TLS certificates
- Containers are only accessible through Traefik (no exposed ports)
