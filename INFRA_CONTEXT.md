# Blueprint Agency — Infrastructure Context

> **Purpose:** Complete reference for any Claude Code agent onboarding to a Blueprint Agency project. Covers VPS layout, stacks, CI/CD patterns, GitHub secrets/vars, and MCP access.

---

## 1. Organisation & Team

- **GitHub Org:** [Blueprint-Agency](https://github.com/Blueprint-Agency)
- **Team:** 3-person team; `@chriskke` is sole DevOps lead
- **Stack:** Node.js / Next.js apps, Supabase (migrating to) / Auth0 / Stripe
- **Container Registry:** DockerHub — `blueprintagency/<app>:<tag>`
- **Timezone:** `Asia/Kuala_Lumpur`

---

## 2. Infrastructure Overview

| Component | Detail |
|-----------|--------|
| Provider | Hostinger VPS (3 servers) |
| Orchestration | Docker Compose — no Kubernetes |
| Reverse proxy | Traefik v3 on all VPS (Let's Encrypt via Cloudflare DNS challenge) |
| Databases | Local PostgreSQL per app (migrating to Supabase; n8n keeps local Postgres permanently) |
| External services | Supabase, Auth0, Stripe, Cloudflare R2, SerpAPI |
| Infra repo | `Blueprint-Agency/infrastructure` (`main` branch) |

---

## 3. VPS Inventory

| Alias | Role | Specs | SSH |
|-------|------|-------|-----|
| `vps1-staging` | Staging | 2 vCPU / 8 GB / 100 GB | `ssh vps1-staging` |
| `vps2-prod` | Production | 4 vCPU / 16 GB / 200 GB | `ssh vps2-prod` |
| `vps3-prod` | Production | 4 vCPU / 16 GB / 200 GB | `ssh vps3-prod` |

- **SSH key:** `~/.ssh/infra_ed25519`
- **SSH config:** Aliases defined in `~/.ssh/config`
- **Deploy user:** `deploy` (Docker group access, used by all CI/CD)
- **Stack root on VPS:** `/root/stacks/<stack>/`

---

## 4. What's Running Per VPS

### VPS1 — Staging

| Stack | Services | Domain(s) |
|-------|----------|-----------|
| `traefik` | Traefik reverse proxy | — |
| `website` | `site-fe` (port 5000), `backend-site` (port 3000), `db-site` (Postgres) | `staging.teeko.ai`, `stagingapi.teeko.ai` |
| `n8n` | `n8n-dev` (port 5678), `db-n8n` (Postgres) | `stagingn8n.teeko.ai` |
| `tools` | `drizzle-gateway` (port 4983) | `stagingpg.teeko.ai` |

### VPS2 — Production

| Stack | Services | Domain(s) |
|-------|----------|-----------|
| `traefik` | Traefik reverse proxy | — |
| `website` | `site-fe` (port 5000), `backend-site` (port 3000), `db-site` (Postgres) | `teeko.ai`, `www.teeko.ai`, `api.teeko.ai` |
| `tools` | `drizzle-gateway` (port 4983) | `pg.teeko.ai` |

### VPS3 — Production

| Stack | Services | Domain(s) |
|-------|----------|-----------|
| `traefik` | Traefik reverse proxy | — |
| `n8n` | `n8n-prod` (port 5678), `db-n8n`, `db-waba` (Postgres) | `n8n.teeko.ai` |
| `tools` | `drizzle-gateway` (port 4983) | `pg3.teeko.ai` |
| `ga4-mcp` | `ga4-mcp`, `ga4-gateway`, `ga4-dex` | `ga4.teeko.ai` |
| `gsc-mcp` | `gsc-mcp`, `gsc-gateway`, `gsc-dex` | `gsc.teeko.ai` |
| `booking-system` | `booking-be`, `booking-db` | `bookingapi.teeko.ai` |
| `ehailing` | `ehailing-be`, `ehailing-db`, `ehailing-redis` | `ehailingapi.teeko.ai` |

> **Portainer and pgAdmin removed 2026-07-21.** No container UI, no DB UI on staging. Postgres on prod is managed via drizzle-gateway; everything else via `ssh` + `docker`. Port 9001 can be closed on VPS2/VPS3.

> **MCP stacks are 3-container units.** `*-mcp` (backend, no public route) + `*-gateway` (OAuth 2.1 front, serves `/mcp`) + `*-dex` (IdP, priority-100 router on the same host). All three are required per stack — none are redundant.

### BPVPS1 — Kaiteki (separate client, 4th VPS)

`bp-bpvps1` (`187.127.122.41`) — Kaiteki workloads, isolated from the Teeko boxes above. Not wired into `deploy-infra.yml` (managed manually).

| Stack | Services | Domain(s) |
|-------|----------|-----------|
| `traefik` | Traefik reverse proxy (+ file provider for the mail web UIs) | — |
| `kaiteki` | `kaiteki` (legacy static site) | `kaiteki.my` |
| `wordpress` | `wordpress`, `wp-db` (MariaDB) | `blog.kaiteki.my` |
| `stalwart` | Stalwart mail server + Bulwark webmail (`/root/stacks/stalwart`) | `mail.kaiteki.my`, `webmail.kaiteki.my` |

> **Stalwart + Bulwark** co-hosted behind Traefik (replaced Mailcow, then Roundcube→Bulwark). One LE cert (acme.sh Cloudflare DNS-01, `KAITEKI_CF_DNS_API_TOKEN`) for `mail.kaiteki.my` + `webmail.kaiteki.my` is shared by Stalwart (mail TLS, set in its admin UI) and Traefik (web UIs, file provider). Bulwark talks JMAP over HTTPS to `mail.kaiteki.my` (a Traefik network alias → `stalwart:8080`); this needs Stalwart's **Default Hostname = `mail.kaiteki.my`** and **Permissive CORS = on**. Stalwart config lives in its store; `config.json` is bind-mounted so a recreate doesn't re-trigger the setup wizard. DNS = separate `kaiteki.my` Cloudflare account. See `vps/bpvps1/stacks/stalwart/README.md`.

---

## 5. App Registry (`apps/registry.yml`)

| App | Image | Stack | Staging | Production |
|-----|-------|-------|---------|------------|
| `teeko-site-fe` | `blueprintagency/teeko-website-fe` | `website` | `vps1-staging` → `staging.teeko.ai` | `vps2-prod` → `teeko.ai` |
| `teeko-site-be` | `blueprintagency/teeko-website-be` | `website` | `vps1-staging` → `stagingapi.teeko.ai` | `vps2-prod` → `api.teeko.ai` |
| `n8n-dev` | `n8nio/n8n:latest` | `n8n` | `vps1-staging` → `stagingn8n.teeko.ai` | — |
| `n8n-prod` | `n8nio/n8n:latest` | `n8n` | — | `vps3-prod` → `n8n.teeko.ai` |
| `drizzle-gateway` | `ghcr.io/drizzle-team/gateway:latest` | `tools` | `vps1-staging` → `stagingpg.teeko.ai` | `vps2-prod` → `pg.teeko.ai`, `vps3-prod` → `pg3.teeko.ai` |

**Image tags:**
- `staging` branch → `:staging` tag
- `main` branch → `:latest` tag
- Both also tagged with `:<tag>-<commit-sha>`

---

## 6. Infra Repo Structure

```
infrastructure/
├── .github/workflows/
│   └── deploy-infra.yml        # Deploys infra stacks on push to main
├── apps/
│   └── registry.yml            # Central app → VPS mapping
├── vps/
│   ├── shared/
│   │   ├── setup-vps.sh        # Initial VPS provisioning (Docker, deploy user)
│   │   ├── deploy.sh           # Manual deploy helper
│   │   └── healthcheck.sh      # Container health check
│   ├── vps1-staging/stacks/
│   │   ├── traefik/docker-compose.yml
│   │   ├── website/docker-compose.yml
│   │   ├── n8n/docker-compose.yml
│   │   └── tools/docker-compose.yml
│   ├── vps2-prod/stacks/
│   │   ├── traefik/docker-compose.yml
│   │   ├── website/docker-compose.yml
│   │   └── tools/docker-compose.yml
│   └── vps3-prod/stacks/
│       ├── traefik/docker-compose.yml
│       ├── n8n/docker-compose.yml
│       └── tools/docker-compose.yml
├── .env                        # Credentials (gitignored)
├── .env.example                # Credentials template
├── .mcp.json                   # MCP server config (gitignored)
├── .mcp.json.example           # MCP config template
└── CLAUDE.md                   # Claude Code instructions
```

**Stack `.env` file pattern on VPS:**
```
/root/stacks/<stack>/
  .env             ← base vars (BASE_DOMAIN, ACME_EMAIL, CF_DNS_API_TOKEN, TRAEFIK_DASHBOARD_AUTH)
  .env.<service>   ← per-service vars (e.g. .env.site-be, .env.n8n-dev, .env.gateway)
```

---

## 7. CI/CD Workflows

### 7a. Infra Repo — `deploy-infra.yml`

**Trigger:** Push to `main`, paths `vps/vps1-staging/**`, `vps/vps2-prod/**`, `vps/vps3-prod/**`

**Pattern:**
1. `detect` job — git-diffs to determine which VPS dirs changed → outputs `vps1`, `vps2`, `vps3` booleans
2. Per-VPS deploy job (runs if that VPS changed):
   - Setup SSH key from `secrets.SSH_PRIVATE_KEY`
   - Detect which stacks were touched (added/changed = deploy; deleted = `docker compose down` + `rm -rf`)
   - `rsync` compose files to VPS (excludes `.env*` files)
   - SSH in → write `.env` files from base64-encoded secrets → `docker compose up -d --remove-orphans` → `docker image prune -af`

**Excluded from infra automation** (managed by their own app repo CI/CD):
- VPS1: `website`
- VPS2: `website`
- VPS3: nothing excluded

**GitHub Environments used:** `vps1-staging`, `vps2-prod`, `vps3-prod`

---

### 7b. App Repo — `be-deploy.yml` (teeko-website)

**Trigger:** Push to `main` or `staging`, paths `be/**`; or `workflow_dispatch`

**Environment:** `production` (main) or `staging` (staging branch)

**Steps:**
1. Docker Hub login (`vars.DOCKERHUB_USERNAME` + `secrets.DOCKERHUB_TOKEN`)
2. Build & push `blueprintagency/teeko-website-be:<tag>` and `:<tag>-<sha>`
3. SSH to VPS (`vps2-prod` for main, `vps1-staging` for staging), write `.env.site-be` and `.env.site-db`, pull image, `docker compose up -d --no-deps backend-site`, prune images

---

### 7c. App Repo — `fe-deploy.yml` (teeko-website)

**Trigger:** Push to `main` or `staging`, paths `fe/**`; or `workflow_dispatch`

**Environment:** `production` (main) or `staging` (staging branch)

**Steps:**
1. Docker Hub login
2. Build & push `blueprintagency/teeko-website-fe:<tag>` with build-args (all `NEXT_PUBLIC_*` vars baked in at build time)
3. SSH to VPS, write `.env.site-fe` (just `BACKEND_URL=http://backend-site:3000`), pull image, `docker compose up -d --no-deps site-fe`, prune images

---

## 8. GitHub Secrets & Variables Reference

### 8a. Infra Repo — GitHub Environments

Each environment (`vps1-staging`, `vps2-prod`, `vps3-prod`) holds its own set.

#### Secrets (per environment)

| Secret | Used by | Description |
|--------|---------|-------------|
| `SSH_PRIVATE_KEY` | All VPS jobs | Ed25519 private key for `deploy@<vps>` |
| `CF_DNS_API_TOKEN` | All VPS jobs | Cloudflare token for Traefik DNS challenge |
| `TRAEFIK_DASHBOARD_AUTH` | All VPS jobs | htpasswd basic-auth string for Traefik dashboard |
| `GATEWAY_MASTERPASS` | VPS1, VPS2, VPS3 | drizzle-gateway master password (shared by all three) |
| `N8N_DB_PASSWORD` | VPS1, VPS3 | n8n Postgres password |
| `N8N_ENCRYPTION_KEY` | VPS1, VPS3 | n8n credential encryption key |

#### Variables (per environment)

| Variable | Used by | Description |
|----------|---------|-------------|
| `VPS1_HOST` / `VPS2_HOST` / `VPS3_HOST` | Respective job | VPS IP or hostname |
| `BASE_DOMAIN` | All VPS jobs | e.g. `teeko.ai` |
| `ACME_EMAIL` | All VPS jobs | Let's Encrypt registration email |
| `N8N_DB_USER` | VPS1, VPS3 | n8n Postgres username |
| `N8N_DB_NAME` | VPS1, VPS3 | n8n Postgres database name |
| `N8N_EDITOR_BASE_URL` | VPS1, VPS3 | n8n editor URL (e.g. `https://stagingn8n.teeko.ai`) |
| `N8N_WEBHOOK_URL` | VPS1, VPS3 | n8n webhook base URL |

> Some variables (e.g. `BASE_DOMAIN`, `ACME_EMAIL`, VPS hosts) may be promoted to **org-level variables** to avoid duplication across environments.

---

### 8b. App Repo (`teeko-website`) — GitHub Environments

Environments: `production` (main branch) and `staging` (staging branch).

#### Secrets

| Secret | Description |
|--------|-------------|
| `DOCKERHUB_TOKEN` | DockerHub push token |
| `SSH_PRIVATE_KEY` | Ed25519 key for `deploy@<vps>` |
| `DB_PASSWORD` | PostgreSQL password |
| `JWT_SECRET` | JWT signing secret |
| `SUPERADMIN_PASSWORD` | Admin user password |
| `SERPAPI_API_KEY` | SerpAPI search key |
| `SMTP_PASS` | Email SMTP password |
| `R2_SECRET_ACCESS_KEY` | Cloudflare R2 secret key |

#### Variables

| Variable | Description |
|----------|-------------|
| `DOCKERHUB_USERNAME` | `blueprintagency` |
| `VPS1_HOST` | Staging VPS IP/hostname |
| `VPS2_HOST` | Production VPS IP/hostname |
| `PORT` | Backend listen port |
| `DB_HOST` | Postgres host (container name) |
| `DB_PORT` | Postgres port |
| `DB_USER` | Postgres username |
| `DB_NAME` | Postgres database name |
| `FRONTEND_URL` | Frontend origin URL |
| `BACKEND_URL` | Backend origin URL (internal) |
| `SUPERADMIN_USERNAME` | Admin username |
| `SMTP_SERVICE` | Email provider name |
| `SMTP_HOST` | SMTP server host |
| `SMTP_PORT` | SMTP port |
| `SMTP_USER` | SMTP login user |
| `R2_S3_API` | Cloudflare R2 S3-compatible endpoint |
| `R2_ACCESS_KEY_ID` | R2 access key ID |
| `R2_BUCKET_NAME` | R2 bucket name |
| `R2_PUBLIC_URL` | R2 public CDN URL |
| `NEXT_PUBLIC_API_URL` | FE build-time: public API URL |
| `NEXT_PUBLIC_AI_APP_URL` | FE build-time: AI app URL |
| `NEXT_PUBLIC_GOOGLE_CLIENT_ID` | FE build-time: Google OAuth client ID |
| `NEXT_PUBLIC_GTM_ID` | FE build-time: Google Tag Manager ID |
| `NEXT_PUBLIC_SITE_URL` | FE build-time: canonical site URL |

> **Important:** `NEXT_PUBLIC_*` variables are baked into the Docker image at build time (Docker `--build-arg`). Changing them requires a new image build.

---

## 9. `.env` Files on VPS — Structure

Each stack directory on the VPS uses separate env files per service:

```
# website stack
/root/stacks/website/
  .env            ← BASE_DOMAIN, ACME_EMAIL, CF_DNS_API_TOKEN, TRAEFIK_DASHBOARD_AUTH
  .env.site-fe    ← BACKEND_URL=http://backend-site:3000
  .env.site-be    ← PORT, DB_*, JWT_SECRET, FRONTEND_URL, SMTP_*, R2_*, SERPAPI_API_KEY, SUPERADMIN_*
  .env.site-db    ← POSTGRES_USER, POSTGRES_PASSWORD, POSTGRES_DB

# n8n stack
/root/stacks/n8n/
  .env            ← base vars
  .env.n8n-dev    ← DB_TYPE, DB_POSTGRESDB_*, N8N_ENCRYPTION_KEY, N8N_EDITOR_BASE_URL, WEBHOOK_URL, ...
  .env.db-n8n     ← POSTGRES_USER, POSTGRES_PASSWORD, POSTGRES_DB

# tools stack (all 3 Teeko VPS)
/root/stacks/tools/
  .env            ← base vars
  .env.gateway    ← MASTERPASS (drizzle-gateway)
```

---

## 10. n8n Configuration

**n8n settings injected via env (both staging and prod):**

```
DB_TYPE=postgresdb
DB_POSTGRESDB_HOST=db-n8n
DB_POSTGRESDB_PORT=5432
N8N_PORT=5678
N8N_SECURE_COOKIE=false
N8N_RUNNERS_ENABLED=true
N8N_DIAGNOSTICS_ENABLED=false
N8N_COMMUNITY_PACKAGES_ALLOW_TOOL_USAGE=true
N8N_DEFAULT_BINARY_DATA_MODE=filesystem
NODE_FUNCTION_ALLOW_BUILTIN=crypto
GENERIC_TIMEZONE=Asia/Kuala_Lumpur
TZ=Asia/Kuala_Lumpur
```

VPS3 also runs `db-waba` — a separate Postgres instance for WABA (WhatsApp Business API) workflow data.

---

## 11. MCP Servers

Config lives in `.mcp.json` (gitignored). Template: `.mcp.json.example`.

| Server | Protocol | Purpose |
|--------|----------|---------|
| `cloudflare` | HTTP + API token | DNS zones, records |
| `vercel` | HTTP + API token | Projects, deployments, logs, env vars, domains |
| `n8n-mcp` | stdio | List/search/create/edit/execute n8n workflows on `n8n.teeko.ai` |

**GitHub operations:** Use `git` (bash) for repo operations and `curl` + GitHub REST API for org/repo management, secrets, and environments. PAT in `.env` as `GITHUB_PERSONAL_ACCESS_TOKEN`.

**VPS operations:** SSH directly — `ssh vps1-staging`, `ssh vps2-prod`, `ssh vps3-prod`.

---

## 12. Traefik Setup

- **Version:** v3.3
- **TLS:** Let's Encrypt via Cloudflare DNS-01 challenge (`CF_DNS_API_TOKEN`)
- **Dashboard:** Protected with htpasswd basic auth (`TRAEFIK_DASHBOARD_AUTH`)
- **Docker API fix (VPS2/VPS3 — Docker 29.x):** `/etc/systemd/system/docker.service.d/min-api.conf` sets `DOCKER_MIN_API_VERSION=1.24` to fix Traefik's Docker provider breaking with the raised `MinAPIVersion`

---

## 13. Firewall Rules

| VPS | Open Ports |
|-----|-----------|
| VPS1 (staging) | 22, 80, 443 |
| VPS2 + VPS3 (prod) | 22, 80, 443 (9001 no longer needed — portainer-agent removed) |
| BPVPS1 (kaiteki) | 22, 80, 443 + mail: 25, 465, 587, 993, 995, 143, 110, 4190 |

Everything else closed — ports 3000, 5432, 5678, 8080, 9090 are accessed via Traefik only.

---

## 14. Adding a New App — Checklist

1. Add entry to `apps/registry.yml` (name, image, stack, VPS, domain, ports)
2. Add/update the target VPS stack's `docker-compose.yml` under `vps/<alias>/stacks/<stack>/`
3. Create the app repo's GitHub Actions workflows following the `fe-deploy.yml` / `be-deploy.yml` pattern
4. Add GitHub environment secrets/vars to the app repo (`production` and `staging` environments):
   - `SSH_PRIVATE_KEY`, `DOCKERHUB_TOKEN` (secrets)
   - `VPS1_HOST`, `VPS2_HOST`, `DOCKERHUB_USERNAME` (vars) + all app-specific vars
5. Ensure the infra deploy workflow excludes the new stack from automation if the app repo manages its own deploy

---

## 15. Deploy & Rollback Commands

```bash
# Manual deploy on VPS
cd /root/stacks/<stack>
docker compose pull <service> && docker compose up -d <service>

# Rollback — pin known-good tag in docker-compose.yml, then:
docker compose pull <service> && docker compose up -d <service>

# Verify
docker compose ps
docker compose logs -f <service>

# Prune images
docker image prune -af
```

---

## 16. Credentials Rule

**All credentials in `.env` only.** Never hardcode tokens or passwords. `.env` is gitignored. Use `.env.example` as the template.

---

## 17. Teeko Website App Architecture

**Repo:** `Blueprint-Agency/teeko-website`

| Layer | Tech | Port |
|-------|------|------|
| Frontend | Next.js 16, React 19, Tailwind CSS 4, TypeScript | 5000 |
| Backend | Express.js 5, TypeScript, Drizzle ORM | 3000 |
| Database | PostgreSQL 16 (local, migrating to Supabase) | 5432 |

**Backend dependencies:** JWT auth, nodemailer (SMTP), SerpAPI, Cloudflare R2 (S3-compatible), QR codes, bcrypt
**Frontend pages:** Home, Auth, Admin, Blog, Profile, Restaurant/Restaurants, Privacy, Terms, Travel Sim Malaysia
**DB migrations:** Drizzle Kit (`npm run db:generate`, `npm run db:migrate`)

---

## 18. Git Commit Rules

- **Do NOT add `Co-Authored-By` lines.** Claude Code must not be listed as co-author.
