# Infrastructure Repository

Central infrastructure-as-code repo. Manages all VPS, Docker deployments, CI/CD, monitoring, and GitHub org.

## Credentials Rule

**All credentials live in `.env` only.** Never hardcode tokens or passwords anywhere else. `.env` is gitignored. Use `.env.example` as the template.

## MCP Servers

| Server | Purpose |
|--------|---------|
| `cloudflare` | DNS, zones |
| `n8n-mcp` | List/search/execute/create/edit n8n workflows |
| `vercel` | Projects, deployments, logs, env vars, domains |

Config in `.mcp.json` (gitignored — contains tokens). Use `.mcp.json.example` as template.

**GitHub**: use `git` (bash) for repo operations and `curl` + GitHub REST API for org/repo management, secrets, and environments. PAT stored in `.env` as `GITHUB_PERSONAL_ACCESS_TOKEN`.

**VPS/Docker**: use `ssh bp-vps1-staging` / `ssh bp-vps2-prod` / `ssh bp-vps3-prod` directly.

## VPS Access

| Alias | Role | Specs |
|-------|------|-------|
| `bp-vps1-staging` | Staging | 2 vCPU / 8GB / 100GB |
| `bp-vps2-prod` | Production | 4 vCPU / 16GB / 200GB |
| `bp-vps3-prod` | Production | 4 vCPU / 16GB / 200GB |
| `bp-bpvps1` | Kaiteki (legacy + revamp) | 187.127.122.41 |
| `bp-bpvps2` | Booking-system | 187.127.207.82 |

SSH key: `~/.ssh/infra_ed25519`. All hosts log in as **`deploy`**, not root — `deploy` is in the `docker` group and owns `/root/stacks`. Hosts defined in `~/.ssh/config`.

> ⚠️ **Always use the `bp-` prefix.** The bare aliases `vps1-staging` / `vps2-prod` in `~/.ssh/config` belong to a **different client (Inquantum AI)** on a different key — operating on them by mistake hits the wrong company's servers. There is no bare `vps3-prod`.

> ⚠️ **`bp-bpvps2` is NOT `bp-vps2-prod`.** One is the booking-system host; the other is live teeko.ai production. They differ by two characters. Re-read the alias before any `docker compose down`, volume removal, or `psql` write.

## What's Running

**VPS1 — Staging**: `traefik`, `website` (staging.teeko.ai), `n8n` (stagingn8n.teeko.ai), `tools` (drizzle-gateway at stagingpg.teeko.ai)

**VPS2 — Production**: `traefik`, `website` (teeko.ai), `tools` (drizzle-gateway at pg.teeko.ai)

**VPS3 — Production**: `traefik`, `n8n` (n8n.teeko.ai), `tools` (drizzle-gateway at pg3.teeko.ai), `ga4-mcp`, `gsc-mcp`, `ehailing`

**BPVPS2 — Booking**: `traefik`, `booking-staging` (bookingapi.teeko.ai — carries the real data), `booking-prod` (prodbookingapi.teeko.ai — fresh). Both from one parameterized compose in `vps/bpvps2/stacks/booking/`, deployed to two dirs; `ENV_NAME` keys the container names, volume, network and Traefik router so they can't collide.

> **Portainer and pgAdmin are gone** (removed 2026-07-21) — no container UI at all. Use `ssh bp-vps<n>-*` + `docker` directly. Postgres is managed via drizzle-gateway, now on all 3 Teeko VPS (`stagingpg` / `pg` / `pg3`.teeko.ai), all sharing the `GATEWAY_MASTERPASS` secret.

> **ga4-mcp / gsc-mcp stacks**: each is 3 containers (`*-mcp` backend, `*-gateway` OAuth 2.1 front, `*-dex` IdP) and **all three are required** to serve `https://ga4.teeko.ai/mcp` and `https://gsc.teeko.ai/mcp`. None are redundant — do not prune them.

## Architecture

- 3 Hostinger VPS, Docker Compose, no Kubernetes
- Reverse proxy: Traefik on all VPS (Let's Encrypt via Cloudflare DNS), ports 80→443
- Container registry: DockerHub — `blueprintagency/<app>:<tag>`
- Databases: local PostgreSQL per app (migrating to Supabase); n8n keeps local Postgres
- External: Supabase, Auth0, Stripe
- Timezone: Asia/Kuala_Lumpur

## CI/CD

| Branch | Target | Flow |
|--------|--------|------|
| `staging` | VPS1 | GHA builds image → triggers deploy workflow → SSH deploy |
| `main` | VPS2 or VPS3 | Same, production tags |

## Stack Layout

Each VPS uses: `vps/<alias>/stacks/<stack>/docker-compose.yml`
On VPS: `/root/stacks/<stack>/` (e.g. `cd /root/stacks/website && docker compose up -d`)

Each stack dir has its own `.env` (shared vars: `BASE_DOMAIN`, `ACME_EMAIL`) and per-service `.env.*` files.

## Key Files

- `apps/registry.yml` — app-to-VPS mapping, images, ports, domains
- `.env.example` — credentials template

## GitHub Org

**Blueprint-Agency** — `https://github.com/Blueprint-Agency`

Team: `@chriskke` (DevOps lead, sole devops)

## Git Commits

Do NOT add `Co-Authored-By` lines. Claude Code must not be listed as co-author.

## Operational Notes

### Adding a New App
1. Update `apps/registry.yml`
2. Update target VPS stack compose file
3. Add GitHub environment secrets: `VPS_HOST`, `SSH_PRIVATE_KEY`, `DOCKERHUB_TOKEN`, plus any app-specific vars

### Deploy / Rollback
```bash
# Manual deploy on VPS
cd /root/stacks/<stack> && docker compose pull <service> && docker compose up -d <service>

# Rollback — pin to known-good tag in docker-compose.yml, then:
docker compose pull <service> && docker compose up -d <service>

# Verify after rollback
docker compose ps
docker compose logs -f <service>
```

### Firewall (Hostinger VPS panel)
**VPS1 (staging):** Open **22**, **80**, **443**

**VPS2 + VPS3 (prod):** Open **22**, **80**, **443**. Port **9001** (portainer-agent) is no longer needed — close it.

Close everything else — especially 3000, 5432, 5678, 8080, 9090 (all accessed via Traefik only)

### Docker 29.x breaks Traefik's Docker provider — fix differs per VPS
Docker 29.x raises `MinAPIVersion` above 1.24. Traefik v3.3 **hardcodes** Docker API 1.24 and
ignores `DOCKER_API_VERSION`, so the daemon rejects it and Traefik loads **zero routes** — every
domain on that host 404s while the containers stay healthy. The fix is always daemon-side, but
the unit path depends on how Docker was installed:

| VPS | Docker install | systemd unit | Drop-in path |
|-----|----------------|--------------|--------------|
| VPS2, VPS3 | apt `docker-ce` | `docker.service` | `/etc/systemd/system/docker.service.d/min-api.conf` |
| **VPS1** | **snap** (`canonical/docker`) | **`snap.docker.dockerd.service`** | **`/etc/systemd/system/snap.docker.dockerd.service.d/min-api.conf`** |

Contents either way: `[Service]` + `Environment="DOCKER_MIN_API_VERSION=1.24"`, then
`systemctl daemon-reload && systemctl restart <unit>` (restarts all containers on that host).

> ⚠️ VPS1 runs the **snap** Docker — there is no `docker.service` there. A drop-in under
> `docker.service.d/` is silently inert. This is exactly how VPS1 sat fully 404 from
> 2026-05-10 to 2026-07-21. Verify with `systemctl list-units '*docker*'` before assuming
> the unit name. Must reapply if Docker is reinstalled.

### Shared Scripts
`vps/shared/` — deploy, healthcheck, VPS setup scripts
