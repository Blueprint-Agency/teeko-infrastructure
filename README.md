# Infrastructure

Central infrastructure-as-code repository for Blueprint-Agency. Manages 3 Hostinger VPS, Docker deployments, CI/CD, monitoring, and GitHub org.

## Architecture

```
Developer → push to staging/main → GitHub Actions (CI) → DockerHub
                                          │
                                          ▼
                                GitHub Actions (CD)
                                          │
                      ┌───────────────────┼───────────────────┐
                      ▼                   ▼                   ▼
                VPS1 (Staging)      VPS2 (Prod)         VPS3 (Prod)
                2 vCPU / 8GB        4 vCPU / 16GB       4 vCPU / 16GB
                Teeko Site          Teeko Site           n8n Production
                Teeko Webapp
                n8n Dev
```

- **Reverse proxy**: Traefik on all VPS (auto-discovery, Let's Encrypt via Cloudflare DNS)
- **Monitoring**: Grafana + Prometheus + cAdvisor + Node Exporter on all VPS
- **Registry**: DockerHub — `blueprintagency/<app>:<tag>`
- **Databases**: Local PostgreSQL per app (migrating to Supabase); n8n keeps local Postgres
- **External**: Supabase, Auth0, Stripe

## CI/CD Flow

| Branch | Target | Action |
|--------|--------|--------|
| `staging` | VPS1 | Build image → push to DockerHub → SSH deploy |
| `main` | VPS2 or VPS3 | Same, production tags |

## Repository Structure

```
├── vps/
│   ├── inventory.yml              VPS inventory (IPs, specs, roles)
│   ├── vps1-staging/stacks/       Per-stack compose files for VPS1
│   ├── vps2-prod/stacks/          Per-stack compose files for VPS2
│   ├── vps3-prod/stacks/          Per-stack compose files for VPS3
│   └── shared/                    Deploy, healthcheck, setup scripts
├── apps/registry.yml              App → VPS mapping, images, ports, domains
├── github/                        Org settings, team roles, repo standards
├── .env.example                   Credentials template
└── .mcp.json.example              MCP server config template
```

## Setup (New DevOps Member)

### 1. Prerequisites
- Node.js (for `npx`)
- Claude Code CLI or desktop app

### 2. Clone & Configure
```bash
git clone <repo-url>
cd infrastructure
cp .env.example .env
```

Fill in `.env`:
- VPS credentials (get from @chriskke)
- `GITHUB_PERSONAL_ACCESS_TOKEN` — GitHub PAT with repo + org read/write

### 3. SSH Key Setup
Ask @chriskke to add your public key to all VPS. Then add to `~/.ssh/config`:

```
Host vps1-staging
    HostName <VPS1_IP>
    User root
    IdentityFile ~/.ssh/<your-key>
    StrictHostKeyChecking accept-new

Host vps2-prod
    HostName <VPS2_IP>
    User root
    IdentityFile ~/.ssh/<your-key>
    StrictHostKeyChecking accept-new

Host vps3-prod
    HostName <VPS3_IP>
    User root
    IdentityFile ~/.ssh/<your-key>
    StrictHostKeyChecking accept-new
```

Verify: `ssh vps1-staging "hostname"`

### 4. MCP Setup
```bash
cp .mcp.json.example .mcp.json
```
Fill in your tokens (Cloudflare API token, n8n API key, Vercel API token). Open the repo in Claude Code — MCP servers start automatically.

## Common Operations

### Deploy
```bash
# Automated — just push to branch
git push origin staging   # → deploys to VPS1
git push origin main      # → deploys to VPS2/VPS3

# Manual deploy on VPS
ssh vps1-staging
cd /root/stacks/<stack> && docker compose pull <service> && docker compose up -d <service>
```

### Rollback
```bash
ssh vps2-prod
cd /root/stacks/<stack>
# Edit docker-compose.yml to pin to known-good tag, then:
docker compose pull <service> && docker compose up -d <service>
docker compose ps && docker compose logs -f <service>
```

### Adding a New App
1. Add entry to `apps/registry.yml`
2. Add service to target VPS stack compose file
3. Add GitHub environment secrets: `VPS_HOST`, `SSH_PRIVATE_KEY`, `DOCKERHUB_TOKEN` + app-specific vars

## Firewall

All VPS — managed via **Hostinger VPS panel**:

| Port | Status | Purpose |
|------|--------|---------|
| 22 | **Open** | SSH |
| 80 | **Open** | HTTP (Traefik redirects to 443) |
| 443 | **Open** | HTTPS (Traefik terminates TLS) |
| All others | **Closed** | Apps accessible via Traefik only |

## GitHub Actions Secrets (per environment)

| Secret | Description |
|--------|-------------|
| `VPS_HOST` | VPS IP address |
| `SSH_PRIVATE_KEY` | SSH deploy key |
| `DOCKERHUB_USERNAME` | DockerHub org |
| `DOCKERHUB_TOKEN` | DockerHub access token |

## Team

| Member | Role |
|--------|------|
| @chriskke | DevOps Lead — sole devops, admin on all VPS and GitHub org |
| TBD | Developer |
| TBD | Developer |
