# Onboarding Guide

Welcome to the infrastructure repo. This guide gets you set up to manage our VPS and deployments via Claude Code.

## 1. Prerequisites

Install these on your machine:
- **Node.js** (provides `npx`)
- **Python uv** (`pip install uv`, provides `uvx`)
- **Claude Code** CLI or desktop app

## 2. Clone & Configure

```bash
git clone <repo-url>
cd infrastructure

# Create your local env file
cp .env.example .env
```

Edit `.env` and fill in:
- VPS credentials (get from @chriskke)
- GitHub PAT (devops only — see step 4)

## 3. SSH Key Setup

Ask @chriskke to add your SSH public key to the VPS instances. Then add this to your `~/.ssh/config`:

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

Replace IPs with values from `.env`.

Verify: `ssh vps1-staging "hostname"` should return `staging`.

## 4. GitHub PAT (DevOps Only)

Regular developers can skip this. DevOps members need a GitHub PAT for org/repo management through Claude Code.

See [mcp/README.md](../mcp/README.md#github-pat-setup-devops-only) for full instructions.

## 5. MCP Server Setup

```bash
cp mcp/mcp-config.json .claude/settings.json
```

That's it. Open the repo in Claude Code and the MCP servers start automatically.

## 6. Verify Everything Works

Open Claude Code in this repo and ask:

| Test | What to ask Claude Code |
|------|------------------------|
| SSH access | "Check the hostname of VPS1" |
| Docker access | "List running containers on staging" |
| GitHub access (devops) | "List repos in the org" |

## What You Can Do

### As a Developer
- Check container status and logs on any VPS
- Deploy apps via scripts or Claude Code
- Monitor VPS resources
- Restart containers
- Push code to trigger CI/CD

### As DevOps (additional)
- Manage GitHub org, teams, and repos
- Configure branch protection and Actions secrets
- Create and merge PRs
- Full infrastructure control

## Key Files to Know

| File | Purpose |
|------|---------|
| `apps/registry.yml` | Which app runs where |
| `vps/inventory.yml` | VPS specs and roles |
| `vps/<alias>/docker-compose.yml` | Services on each VPS |
| `docs/runbooks/deploy.md` | How to deploy |
| `docs/runbooks/rollback.md` | How to rollback |
| `mcp/README.md` | MCP server details and roles |

## Need Help?

- Infra questions → @chriskke
- Deploy issues → check `docs/runbooks/deploy.md`
- Rollback → check `docs/runbooks/rollback.md`
