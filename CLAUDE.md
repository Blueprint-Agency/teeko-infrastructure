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

**VPS/Docker**: use `ssh vps1-staging` / `ssh vps2-prod` / `ssh vps3-prod` directly.

## VPS Access

| Alias | Role | Specs |
|-------|------|-------|
| `vps1-staging` | Staging | 2 vCPU / 8GB / 100GB |
| `vps2-prod` | Production | 4 vCPU / 16GB / 200GB |
| `vps3-prod` | Production | 4 vCPU / 16GB / 200GB |

SSH key: `~/.ssh/infra_ed25519`. Hosts defined in `~/.ssh/config`.

## What's Running

**VPS1 — Staging**: `traefik`, `website` (staging.teeko.ai), `webapp` (staging), `n8n` (stagingn8n.teeko.ai), `tools` (pgadmin at stagingpg.teeko.ai, Portainer CE at port.teeko.ai)

**VPS2 — Production**: `traefik`, `website` (teeko.ai), `tools` (pgadmin at pg.teeko.ai, portainer-agent)

**VPS3 — Production**: `traefik`, `n8n` (n8n.teeko.ai), `tools` (portainer-agent)

> **Portainer**: VPS1 runs the Portainer CE UI and connects to portainer-agents on VPS2 and VPS3 (port 9001) to monitor all containers across all VPS. The agent stacks are required — do not remove them.

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

**VPS2 + VPS3 (prod):** Open **22**, **80**, **443**, **9001** (portainer-agent — required for Portainer on VPS1 to connect)

Close everything else — especially 3000, 5432, 5678, 8080, 9090 (all accessed via Traefik only)

### Docker 29.x on VPS2/VPS3
Raises `MinAPIVersion` to 1.44, breaking Traefik's Docker provider. Fix: `/etc/systemd/system/docker.service.d/min-api.conf` with `DOCKER_MIN_API_VERSION=1.24`. Must reapply if Docker is reinstalled.

### Shared Scripts
`vps/shared/` — deploy, healthcheck, VPS setup scripts
