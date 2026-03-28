# MCP Server Configuration

This folder contains the MCP (Model Context Protocol) server configs that allow Claude Code to manage the VPS infrastructure.

## Setup

### Prerequisites

1. SSH key-based access to all 3 VPS (no password prompts)
2. `uvx` installed (`pip install uv`)
3. `npx` installed (comes with Node.js)
4. A GitHub Personal Access Token (fine-grained) — **devops only**, see below

### Steps

1. Clone this repo
2. Copy `.env.example` to `.env` and fill in VPS credentials
3. (Devops only) Add your GitHub PAT to `.env`
4. Copy `mcp/mcp-config.json` to `.claude/settings.json`
5. Ensure SSH keys are set up for VPS access (`~/.ssh/config`)
6. Open the repo in Claude Code — MCP servers start automatically

### Available MCP Servers

| Server | Purpose |
|--------|---------|
| `ssh-manager` | SSH into any VPS, run commands, manage files, view system stats |
| `docker-staging` | Manage Docker containers on VPS1 (staging) |
| `docker-prod-vps2` | Manage Docker containers on VPS2 (production) |
| `docker-prod-vps3` | Manage Docker containers on VPS3 (production) |
| `github` | Manage GitHub repos, org, teams, PRs, issues, Actions, secrets |

### What Claude Code Can Do With These

**VPS & Docker (ssh-manager + docker-*):**
- Check container status across all VPS
- Tail logs from any container
- Deploy new versions (docker compose pull + up)
- Monitor CPU, memory, disk usage
- Restart/stop/start containers
- Read and edit files on VPS
- Run database backups

**GitHub (github):**
- Create/manage repos in the org
- Set up branch protection rules
- Manage org teams and member permissions
- Create PRs, review code, merge
- Configure repository secrets for GHA
- Trigger and monitor GitHub Actions workflows

## Roles & Access Levels

Not everyone needs all MCP servers. The table below shows what each role requires:

### Developer (pushes code, deploys)

No GitHub PAT needed. Only SSH key access.

| Capability | Works? | Provided by |
|-----------|--------|-------------|
| SSH into VPS, run commands | Yes | SSH key |
| Manage Docker containers (start/stop/restart) | Yes | SSH key (Docker over SSH) |
| View container logs | Yes | SSH key |
| Deploy via scripts | Yes | SSH key |
| Monitor VPS resources (CPU, memory, disk) | Yes | SSH key |
| `git push/pull` to repos | Yes | Their own git credentials |

### DevOps (manages org, repos, infra)

Requires a GitHub PAT in `.env`. Gets everything above **plus**:

| Capability | Works? | Provided by |
|-----------|--------|-------------|
| Create/manage GitHub repos | Yes | GitHub PAT |
| Manage org teams and members | Yes | GitHub PAT |
| Set branch protection rules | Yes | GitHub PAT |
| Configure GitHub Actions secrets | Yes | GitHub PAT |
| Create/merge PRs, manage issues | Yes | GitHub PAT |
| Trigger GitHub Actions workflows | Yes | GitHub PAT |

### GitHub PAT Setup (DevOps Only)

Each devops member generates **their own** fine-grained PAT. Do NOT share tokens.

1. Go to **github.com > Settings > Developer settings > Personal access tokens > Fine-grained tokens**
2. Click **Generate new token**
3. Set:
   - **Name**: `infra-mcp-<your-name>`
   - **Expiration**: 90 days
   - **Resource owner**: Select the org
   - **Repository access**: All repositories
   - **Permissions**:
     - Repository: Administration, Contents, Pull requests, Actions, Secrets, Workflows (read/write)
     - Organization: Members, Administration (read/write)
4. Copy the token into your `.env`:
   ```
   GITHUB_PERSONAL_ACCESS_TOKEN=github_pat_xxxxxxxxxxxx
   ```

**Why individual tokens:**
- Audit trail — you can tell who did what
- If someone leaves, revoke only their token
- If a token leaks, only one person's access is compromised
- Different permission levels per person if needed
