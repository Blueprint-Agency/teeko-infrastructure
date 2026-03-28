# Infrastructure Repository

Central infrastructure-as-code repo. Manages all VPS, Docker deployments, CI/CD, monitoring, and GitHub org.

## MCP Servers Available

The following MCP servers are configured in `.claude/settings.json`:

- **`github`** — GitHub org + repo management. Use this to manage teams, repos, PRs, branch protection, and Actions secrets.
- **`docker-staging`** / **`docker-prod-vps2`** / **`docker-prod-vps3`** — Docker access per VPS.

VPS access is via direct SSH (Bash). Use `ssh vps1-staging`, `ssh vps2-prod`, `ssh vps3-prod`.

## VPS Access

| SSH Alias | Role | Specs | Hostname |
|-----------|------|-------|----------|
| `vps1-staging` | Staging | 2 vCPU / 8GB / 100GB | staging |
| `vps2-prod` | Production | 4 vCPU / 16GB / 200GB | prod1 |
| `vps3-prod` | Production | 4 vCPU / 16GB / 200GB | prod2 |

VPS IPs and credentials are in `.env` (never committed). SSH key: `~/.ssh/infra_ed25519`.

To SSH manually: `ssh vps1-staging` (uses ~/.ssh/config aliases)

## What's Running

### VPS1 - Staging
- `site-fe` / `site-be` / `site-db` — Teeko Site (staging)
- `webapp-fe` / `webapp-be` / `webapp-db` — Teeko Webapp (staging)
- `n8n-dev` / `n8n-db` — n8n development
- `pgadmin` — Database admin UI
- `nginx-proxy-manager` — Reverse proxy (migrating to Traefik)

### VPS2 - Production
- `site-fe` / `site-be` / `site-db` — Teeko Site (production)
- `pgadmin` — Database admin UI
- `nginx-proxy-manager` — Reverse proxy (migrating to Traefik)

### VPS3 - Production
- `n8n-prod` / `n8n-db` — n8n production
- `nginx-proxy-manager` — Reverse proxy (migrating to Traefik)

## Architecture

- **3 Hostinger VPS** managed via Docker Compose (no Kubernetes)
- **Reverse proxy**: Nginx Proxy Manager (migrating to Traefik)
- **Monitoring**: Grafana + Prometheus + cAdvisor + Node Exporter (not yet deployed)
- **Container registry**: DockerHub (images: `chriskke/<app>:<tag>`)
- **Databases**: Local PostgreSQL per app (migrating to Supabase), n8n keeps local Postgres
- **External services**: Supabase, Auth0, Stripe
- **Timezone**: Asia/Kuala_Lumpur across all services

## CI/CD Flow

| Branch | Target | Action |
|--------|--------|--------|
| `staging` | VPS1 | Monorepo GHA builds image → triggers deploy workflow → SSH deploy |
| `main` | VPS2 or VPS3 | Same flow, production tags |

## Key Files

- `vps/inventory.yml` — VPS inventory (IPs, specs, roles)
- `apps/registry.yml` — App-to-VPS mapping, images, ports, domains
- `github/teams.yml` — Team members and roles
- `github/repo-standards.yml` — Branching, tagging, CI/CD conventions
- `mcp/mcp-config.json` — MCP server template (copy to `.claude/settings.json`)
- `.env.example` — Required environment variables template

## Team

- **@chriskke** — DevOps lead (sole devops), admin on all VPS and GitHub org
- 2 other developers (TBD)

## Git Commit Rules

- Do NOT include `Co-Authored-By` lines in commits. Claude Code should not be listed as co-author.

## Working in This Repo

- Never commit secrets or `.env` files. Use `.env.example` as template.
- **All credentials must live in `.env` only** — never hardcode tokens or passwords in `.claude/settings.json` or any other file. MCP servers must use wrapper scripts (e.g. `mcp/start-*.sh`) that source `.env` at startup.
- `.claude/settings.json` is gitignored (contains tokens). Use `mcp/mcp-config.json` as template.
- Each VPS folder has its own `docker-compose.yml` under `vps/<alias>/`.
- **Docker 29.x on VPS2/VPS3**: These VPS run Docker 29.1.3 which raises `MinAPIVersion` to 1.44. Traefik's Docker provider negotiates from 1.24 and gets rejected. Fix applied via `/etc/systemd/system/docker.service.d/min-api.conf` (`DOCKER_MIN_API_VERSION=1.24`) on each VPS. Must reapply if Docker is reinstalled.
- When adding a new app: update `apps/registry.yml` AND the target VPS `docker-compose.yml`.
- Shared deploy/healthcheck/setup scripts are in `vps/shared/`.

## Migration Status

- [x] SSH key access to all 3 VPS
- [x] MCP servers configured (github)
- [x] Container audit complete
- [x] App registry populated
- [x] Nginx Proxy Manager → Traefik migration (VPS1 staging docker-compose updated)
- [x] Deploy Traefik on VPS1 (cut over from nginx-proxy-manager)
- [x] Deploy monitoring stack (Grafana + Prometheus + cAdvisor + Node Exporter) on VPS1
- [x] Nginx Proxy Manager → Traefik migration (VPS2, VPS3)
- [x] Deploy Traefik + monitoring stack (Grafana + Prometheus + cAdvisor + Node Exporter) on VPS2, VPS3
- [x] Remove Watchtower (VPS2 — dropped from compose)
- [ ] Remove Portainer (VPS1)
- [ ] Wire up GHA deploy workflows in monorepos
- [ ] Migrate local Postgres → Supabase
