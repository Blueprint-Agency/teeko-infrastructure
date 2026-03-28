# Infrastructure

Central infrastructure-as-code repository for managing all VPS, Docker deployments, CI/CD pipelines, and monitoring.

## Architecture

```
Developer → push to staging/main → GitHub Actions (CI) → DockerHub
                                        │
                                        ▼
                              GitHub Actions (CD)
                                        │
                    ┌───────────────────┼───────────────────┐
                    ▼                   ▼                   ▼
              VPS1 (Staging)     VPS2 (Prod)          VPS3 (Prod)
              2 vCPU / 8GB       4 vCPU / 16GB        4 vCPU / 16GB
              Teeko Site         Teeko Site            n8n Production
              Teeko Webapp       (production)
              n8n Dev
```

- **Reverse Proxy**: Traefik (auto-discovery, Let's Encrypt TLS)
- **Monitoring**: Grafana + Prometheus + cAdvisor + Node Exporter
- **Container Registry**: DockerHub
- **Databases**: Local PostgreSQL (migrating to Supabase) + n8n local Postgres
- **Management**: Claude Code + MCP servers (SSH + Docker)

## CI/CD Flow

| Branch | Target | Action |
|--------|--------|--------|
| `staging` | VPS1 | Monorepo GHA builds image → triggers deploy workflow → SSH deploy |
| `main` | VPS2 or VPS3 | Same flow, production tags |

## Repository Structure

```
├── .github/workflows/
│   └── deploy-infra.yml   Path-triggered deploy (vps/** changes → SSH deploy)
├── mcp/                   MCP server configs + one-time setup scripts
├── vps/
│   ├── inventory.yml      VPS inventory (IPs, specs, roles)
│   ├── vps1-staging/stacks/   Per-stack compose files for VPS1
│   ├── vps2-prod/stacks/      Per-stack compose files for VPS2
│   ├── vps3-prod/stacks/      Per-stack compose files for VPS3
│   └── shared/            Deploy scripts, healthcheck, VPS setup
├── github/                Org settings, team roles, repo standards
├── apps/                  App registry (name → VPS → ports → domains)
└── docs/                  Architecture diagrams, deploy/rollback runbooks
```

## Quick Reference

### Apps

| App | Staging (VPS1) | Production | Type |
|-----|---------------|------------|------|
| teeko-site-fe | ✅ | VPS2 | Next.js |
| teeko-site-be | ✅ | VPS2 | Node.js |
| teeko-webapp-fe | ✅ | TBD | Next.js |
| teeko-webapp-be | ✅ | TBD | Node.js |
| n8n | ✅ (dev) | VPS3 (prod) | Self-hosted |
| pgadmin | ✅ | VPS2 | Admin tool |

### Management via Claude Code

With MCP servers configured, Claude Code can:
- Check container status, tail logs, restart services
- Deploy new versions, rollback to previous
- Monitor VPS resources (CPU, memory, disk)
- Edit configs and push changes

### Manual Operations

```bash
# SSH to a VPS
ssh vps1-staging   # staging
ssh vps2-prod      # production
ssh vps3-prod      # production (n8n)

# Deploy a stack manually on VPS
cd /root/stacks/<stack> && docker compose up -d

# Health check
./vps/shared/healthcheck.sh vps1-staging
```

## Team

| Member | Role | Access |
|--------|------|--------|
| @chriskke | DevOps Lead | All VPS, all repos (admin) |
| TBD | Developer | Push to repos |
| TBD | Developer | Push to repos |

## Setup

See [mcp/README.md](mcp/README.md) for MCP server setup and [docs/runbooks/deploy.md](docs/runbooks/deploy.md) for deployment procedures.
