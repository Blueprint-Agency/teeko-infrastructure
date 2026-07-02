# GSC MCP on VPS3 behind an OAuth Gateway — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deploy the Google Search Console MCP (`github.com/AminForou/mcp-gsc`, PyPI `mcp-search-console`) on VPS3 at `https://gsc.teeko.ai/mcp`, fronted by an OAuth 2.1 gateway (hyprmcp `mcp-gateway` + self-hosted Dex), as a committed, CI-deployed infra stack, so it can be added as a claude.ai web custom connector.

**Architecture:** One new stack `vps/vps3-prod/stacks/gsc-mcp/` with three containers on the shared external `proxy` network: `gsc-mcp` (mcp-proxy wrapping `mcp-gsc`, internal-only), `gsc-gateway` (OAuth proxy, public), `gsc-dex` (IdP). Single public host `gsc.teeko.ai` — Traefik routes Dex OAuth paths (priority 100) to `gsc-dex:5556` and everything else (priority 1) to `gsc-gateway:9000`, which enforces Bearer and reverse-proxies in-network to `gsc-mcp:8080/servers/<token>/mcp/`. Built and deployed by existing GitHub Actions workflows.

**Tech Stack:** Docker Compose, Traefik v3.3 (label-based, Let's Encrypt DNS-01 via Cloudflare), mcp-proxy (`ghcr.io/sparfenyuk/mcp-proxy`), hyprmcp `mcp-gateway:0.4.0`, `hyprmcp/dex:2.44.0-alpine`, GitHub Actions (build + deploy over Tailscale/SSH), DockerHub `blueprintagency/gsc-mcp`.

**Design doc:** `docs/superpowers/specs/2026-07-01-gsc-mcp-oauth-gateway-design.md`

## Global Constraints

- **Credentials rule:** All credentials live in `.env`/GitHub secrets only. No tokens/passwords/keys committed to the repo. Config files with secrets are rendered at deploy time.
- **No Co-Authored-By lines** in git commits (project rule — Claude Code must not be a co-author).
- **VPS access:** always use the `bp-` prefix (`bp-vps3-prod`). A bare `vps3-prod` is a different client — never use it.
- **Image tag convention:** `blueprintagency/<app>:<tag>`; compose pins `:latest` with `pull_policy: always`.
- **Shared network:** every routable service joins the external `proxy` network.
- **Service naming:** service name == container_name for all three services (`gsc-mcp`, `gsc-gateway`, `gsc-dex`).
- **mcp-gsc auth:** service account only — `GSC_CREDENTIALS_PATH=/credentials/sa-key.json` + `GSC_SKIP_OAUTH=true`. It does NOT use `GOOGLE_APPLICATION_CREDENTIALS`; needs no project-id.
- **Python floor:** `mcp-search-console` requires Python ≥3.11 (verified in Task 1).
- **Working branch:** `feat/gsc-mcp` (already created; spec already committed there).
- **Dex config gotcha:** Dex entrypoint is overridden to `["dex"]` to avoid `$`-expansion mangling the bcrypt hash.
- **Gateway upstream URL needs a trailing slash:** `.../servers/<token>/mcp/`.

---

### Task 1: Backend image — Dockerfile + build workflow

Builds `blueprintagency/gsc-mcp` = mcp-proxy + `mcp-search-console`. Includes the Python-version verification (the one real build risk).

**Files:**
- Create: `vps/vps3-prod/stacks/gsc-mcp/Dockerfile`
- Create: `.github/workflows/build-gsc-mcp.yml`

**Interfaces:**
- Produces: DockerHub image `blueprintagency/gsc-mcp:latest` containing the `mcp-gsc` console script runnable by mcp-proxy as `--named-server <token> mcp-gsc`.

- [ ] **Step 1: Write the Dockerfile (primary variant)**

Create `vps/vps3-prod/stacks/gsc-mcp/Dockerfile`:

```dockerfile
# Wraps the upstream stdio-only Google Search Console MCP server
# (PyPI: mcp-search-console, github.com/AminForou/mcp-gsc) with mcp-proxy so it can be
# reached over HTTP behind Traefik. Upstream has no HTTP transport and no official image.
# The console script installed by the package is `mcp-gsc`.
FROM ghcr.io/sparfenyuk/mcp-proxy:latest

RUN pip install --no-cache-dir mcp-search-console
```

- [ ] **Step 2: Verify the image builds (Python ≥3.11 check)**

Run:
```bash
docker build -t gsc-mcp-test vps/vps3-prod/stacks/gsc-mcp
```
Expected: build SUCCEEDS (pip installs `mcp-search-console` and its deps). This confirms the mcp-proxy base image has Python ≥3.11.

If the build FAILS with a Python version / `requires-python` error, replace the Dockerfile with this fallback and re-run Step 2:

```dockerfile
# Fallback: mcp-proxy base image ships Python <3.11, which mcp-search-console rejects.
# Use a modern Python base and install both packages from PyPI.
FROM python:3.12-slim

RUN pip install --no-cache-dir mcp-proxy mcp-search-console

ENTRYPOINT ["mcp-proxy"]
```

- [ ] **Step 3: Verify the console script exists in the image**

Run:
```bash
docker run --rm --entrypoint sh gsc-mcp-test -c "command -v mcp-gsc && python --version"
```
Expected: prints a path to `mcp-gsc` and `Python 3.11.x` or higher.

- [ ] **Step 4: Write the build workflow**

Create `.github/workflows/build-gsc-mcp.yml`:

```yaml
name: Build gsc-mcp Image

# Builds and pushes the gsc-mcp image (mcp-proxy + mcp-search-console) to DockerHub.
# Thin wrapper around two upstream packages, so infra owns the build here (like ga4-mcp).
# No version pins (always latest mcp-proxy base + latest mcp-search-console from PyPI),
# so run manually (workflow_dispatch) to pick up upstream updates without touching the Dockerfile.
# deploy-infra.yml picks up the new tag on the next push touching vps/vps3-prod/**
# (pull_policy: always means `docker compose up -d` re-pulls it).

on:
  push:
    branches: [main]
    paths:
      - 'vps/vps3-prod/stacks/gsc-mcp/Dockerfile'
      - '.github/workflows/build-gsc-mcp.yml'
  workflow_dispatch: {}

jobs:
  build-and-push:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v5

      - name: Set up Docker Buildx
        uses: docker/setup-buildx-action@v3

      - name: Log in to DockerHub
        uses: docker/login-action@v3
        with:
          username: ${{ vars.DOCKERHUB_USERNAME }}
          password: ${{ secrets.DOCKERHUB_TOKEN }}

      - name: Build and push
        uses: docker/build-push-action@v6
        with:
          context: vps/vps3-prod/stacks/gsc-mcp
          push: true
          tags: |
            blueprintagency/gsc-mcp:latest
            blueprintagency/gsc-mcp:${{ github.sha }}
```

- [ ] **Step 5: Clean up the local test image**

Run:
```bash
docker rmi gsc-mcp-test || true
```
Expected: image removed (or already gone).

- [ ] **Step 6: Commit**

```bash
git add vps/vps3-prod/stacks/gsc-mcp/Dockerfile .github/workflows/build-gsc-mcp.yml
git commit -m "feat(vps3): add gsc-mcp backend image (mcp-proxy + mcp-search-console)"
```

---

### Task 2: Stack compose + config templates

The three-service compose plus the two config file templates (with `@@PLACEHOLDER@@` markers — no real secrets).

**Files:**
- Create: `vps/vps3-prod/stacks/gsc-mcp/docker-compose.yml`
- Create: `vps/vps3-prod/stacks/gsc-mcp/gateway-config.yaml`
- Create: `vps/vps3-prod/stacks/gsc-mcp/dex-config.yaml`

**Interfaces:**
- Consumes: `blueprintagency/gsc-mcp:latest` (Task 1); env var `${GSC_MCP_PATH_TOKEN}` and `${BASE_DOMAIN}` from the stack `.env` (written at deploy, Task 3); files `.env.gsc-mcp`, `credentials/sa-key.json`, and rendered `gateway-config.yaml`/`dex-config.yaml` (written at deploy, Task 3).
- Produces: services `gsc-mcp` (port 8080, internal), `gsc-gateway` (port 9000, router `gscgw`), `gsc-dex` (port 5556/5557, router `gscgw-dex`) — consumed by the deploy case in Task 3 and the acceptance probes in Task 7.

- [ ] **Step 1: Write docker-compose.yml**

Create `vps/vps3-prod/stacks/gsc-mcp/docker-compose.yml`:

```yaml
# Google Search Console MCP (github.com/AminForou/mcp-gsc, PyPI mcp-search-console),
# wrapped with mcp-proxy (upstream is stdio-only, no HTTP transport or image) and fronted by
# an OAuth 2.1 gateway (hyprmcp mcp-gateway) + self-hosted Dex IdP so it can be added as a
# claude.ai web custom connector. Client URL: https://gsc.<BASE_DOMAIN>/mcp
#
# Single public host gsc.<BASE_DOMAIN>:
#   - Dex OAuth endpoints (Traefik priority 100 router) -> gsc-dex:5556
#   - everything else incl. /mcp, /oauth/*, /.well-known/oauth-* (priority 1) -> gsc-gateway:9000
# The gsc-mcp backend has NO public route; the gateway reaches it in-network at
# gsc-mcp:8080/servers/<token>/mcp/ and enforces OAuth Bearer.
#
# .env, .env.gsc-mcp, credentials/sa-key.json, and the rendered gateway-config.yaml /
# dex-config.yaml are written at deploy time by .github/workflows/deploy-infra.yml (secrets
# injected via base64 over SSH). The gateway-config.yaml / dex-config.yaml committed here carry
# @@PLACEHOLDER@@ markers and are overwritten on deploy.
services:
  # Backend: mcp-proxy wrapping the stdio mcp-gsc server. Internal only (no Traefik route).
  gsc-mcp:
    image: blueprintagency/gsc-mcp:latest
    pull_policy: always
    container_name: gsc-mcp
    restart: unless-stopped
    env_file: .env.gsc-mcp
    command: ["--host=0.0.0.0", "--port=8080", "--pass-environment", "--stateless", "--allow-origin=*", "--named-server", "${GSC_MCP_PATH_TOKEN}", "mcp-gsc"]
    volumes:
      - ./credentials:/credentials:ro
    networks:
      - proxy

  # OAuth 2.1 gateway (DCR + PKCE). Public catch-all on gsc.<domain>; reverse-proxies /mcp.
  gsc-gateway:
    image: ghcr.io/hyprmcp/mcp-gateway:0.4.0
    pull_policy: always
    container_name: gsc-gateway
    restart: unless-stopped
    command: ["serve", "--config", "/opt/config.yaml", "-v", "2"]
    volumes:
      - ./gateway-config.yaml:/opt/config.yaml:ro
    depends_on:
      gsc-dex:
        condition: service_healthy
    labels:
      - "traefik.enable=true"
      - "traefik.http.services.gsc-gateway.loadbalancer.server.port=9000"
      - "traefik.http.routers.gscgw.rule=Host(`gsc.${BASE_DOMAIN}`)"
      - "traefik.http.routers.gscgw.entrypoints=websecure"
      - "traefik.http.routers.gscgw.tls.certresolver=letsencrypt"
      - "traefik.http.routers.gscgw.priority=1"
      - "traefik.http.routers.gscgw.service=gsc-gateway"
    networks:
      - proxy

  # Self-hosted Dex IdP. Serves its OAuth endpoints on gsc.<domain> via the priority-100 router.
  gsc-dex:
    image: ghcr.io/hyprmcp/dex:2.44.0-alpine
    pull_policy: always
    container_name: gsc-dex
    restart: unless-stopped
    # Bypass the upstream docker-entrypoint: it does $-env-expansion on the config and
    # mangles the $ chars in the bcrypt hash. Run dex directly instead.
    entrypoint: ["dex"]
    command: ["serve", "/config.yaml"]
    volumes:
      - ./dex-config.yaml:/config.yaml:ro
    healthcheck:
      test: ["CMD", "wget", "-qO-", "http://localhost:5556/.well-known/openid-configuration"]
      interval: 5s
      timeout: 3s
      retries: 30
      start_period: 5s
    labels:
      - "traefik.enable=true"
      - "traefik.http.services.gsc-dex.loadbalancer.server.port=5556"
      - "traefik.http.routers.gscgw-dex.rule=Host(`gsc.${BASE_DOMAIN}`) && (PathPrefix(`/auth`) || PathPrefix(`/token`) || PathPrefix(`/keys`) || PathPrefix(`/approval`) || PathPrefix(`/callback`) || PathPrefix(`/device`) || PathPrefix(`/theme`) || PathPrefix(`/static`) || Path(`/.well-known/openid-configuration`))"
      - "traefik.http.routers.gscgw-dex.entrypoints=websecure"
      - "traefik.http.routers.gscgw-dex.tls.certresolver=letsencrypt"
      - "traefik.http.routers.gscgw-dex.priority=100"
      - "traefik.http.routers.gscgw-dex.service=gsc-dex"
    networks:
      - proxy

networks:
  proxy:
    external: true
```

- [ ] **Step 2: Write the gateway config template**

Create `vps/vps3-prod/stacks/gsc-mcp/gateway-config.yaml`:

```yaml
# TEMPLATE — the deploy workflow (deploy-infra.yml) overwrites this file on VPS3 with the
# @@GSC_MCP_PATH_TOKEN@@ marker replaced by the real secret. Do not put real secrets here.
host: https://gsc.teeko.ai/
authorization:
  server: http://gsc-dex:5556/
  authorizationProxyEnabled: true
  serverMetadataProxyEnabled: true
  dynamicClientRegistration:
    enabled: true
    publicClient: true
dexGRPCClient:
  addr: gsc-dex:5557
proxy:
  - path: /mcp
    http:
      url: http://gsc-mcp:8080/servers/@@GSC_MCP_PATH_TOKEN@@/mcp/
    authentication:
      enabled: true
```

- [ ] **Step 3: Write the Dex config template**

Create `vps/vps3-prod/stacks/gsc-mcp/dex-config.yaml`:

```yaml
# TEMPLATE — the deploy workflow (deploy-infra.yml) overwrites this file on VPS3 with the
# @@GSC_DEX_ADMIN_EMAIL@@ / @@GSC_DEX_ADMIN_HASH@@ markers replaced by real values.
# Do not put a real bcrypt hash here. storage:memory is intentional (matches ga4); DCR
# re-registers clients on connect. issuer MUST equal the public gateway host.
issuer: https://gsc.teeko.ai
web:
  http: 0.0.0.0:5556
  allowedOrigins:
    - "*"
grpc:
  addr: 0.0.0.0:5557
storage:
  type: memory
oauth2:
  skipApprovalScreen: true
enablePasswordDB: true
staticPasswords:
  - email: "@@GSC_DEX_ADMIN_EMAIL@@"
    hash: "@@GSC_DEX_ADMIN_HASH@@"
    username: admin
    userID: "7f3a1e2c-9b4d-4a6e-8c1f-2d5b7e9a0c34"
```

- [ ] **Step 4: Validate compose config parses**

Run (dummy env just to satisfy interpolation; validates structure + labels):
```bash
BASE_DOMAIN=teeko.ai GSC_MCP_PATH_TOKEN=dummytoken \
  docker compose -f vps/vps3-prod/stacks/gsc-mcp/docker-compose.yml config >/dev/null && echo OK
```
Expected: prints `OK` with no errors. (A warning about the missing `.env.gsc-mcp` file is fine — it's created at deploy.)

- [ ] **Step 5: Validate the two config templates are valid YAML**

Run:
```bash
docker run --rm -v "$(pwd)/vps/vps3-prod/stacks/gsc-mcp:/w" -w /w python:3.12-slim \
  python -c "import yaml; yaml.safe_load(open('gateway-config.yaml')); yaml.safe_load(open('dex-config.yaml')); print('YAML OK')"
```
Expected: prints `YAML OK`.

- [ ] **Step 6: Commit**

```bash
git add vps/vps3-prod/stacks/gsc-mcp/docker-compose.yml \
        vps/vps3-prod/stacks/gsc-mcp/gateway-config.yaml \
        vps/vps3-prod/stacks/gsc-mcp/dex-config.yaml
git commit -m "feat(vps3): add gsc-mcp stack (backend + hyprmcp gateway + Dex)"
```

---

### Task 3: Deploy workflow wiring

Extend the `deploy-vps3` job so it injects the GSC secrets and renders the four deploy-time files (`credentials/sa-key.json`, `.env.gsc-mcp`, `gateway-config.yaml`, `dex-config.yaml`) plus appends `GSC_MCP_PATH_TOKEN` to the stack `.env`.

**Files:**
- Modify: `.github/workflows/deploy-infra.yml` (the `deploy-vps3` job's "Deploy and remove stacks" step, ~lines 361-458)

**Interfaces:**
- Consumes: GitHub `vps3-prod` env secrets `GSC_MCP_PATH_TOKEN`, `GSC_MCP_SA_KEY_JSON`, `GSC_DEX_ADMIN_HASH` and variable `GSC_DEX_ADMIN_EMAIL` (created in Task 5); the compose/service names from Task 2.
- Produces: on deploy, the files under `/root/stacks/gsc-mcp/` that Task 2's compose expects.

- [ ] **Step 1: Add the GSC env vars to the step's `env:` block**

In `.github/workflows/deploy-infra.yml`, find (in the `deploy-vps3` job):

```yaml
          GA4_MCP_PATH_TOKEN: ${{ secrets.GA4_MCP_PATH_TOKEN }}
          GA4_MCP_SA_KEY_JSON: ${{ secrets.GA4_MCP_SA_KEY_JSON }}
          GA4_MCP_PROJECT_ID: ${{ vars.GA4_MCP_PROJECT_ID }}
```

Replace with (adds four lines after the GA4 block):

```yaml
          GA4_MCP_PATH_TOKEN: ${{ secrets.GA4_MCP_PATH_TOKEN }}
          GA4_MCP_SA_KEY_JSON: ${{ secrets.GA4_MCP_SA_KEY_JSON }}
          GA4_MCP_PROJECT_ID: ${{ vars.GA4_MCP_PROJECT_ID }}
          GSC_MCP_PATH_TOKEN: ${{ secrets.GSC_MCP_PATH_TOKEN }}
          GSC_MCP_SA_KEY_JSON: ${{ secrets.GSC_MCP_SA_KEY_JSON }}
          GSC_DEX_ADMIN_HASH: ${{ secrets.GSC_DEX_ADMIN_HASH }}
          GSC_DEX_ADMIN_EMAIL: ${{ vars.GSC_DEX_ADMIN_EMAIL }}
```

- [ ] **Step 2: Add the base64 blob-building for the GSC files**

Find:

```bash
          GA4_SA_KEY=$(printf '%s' "$GA4_MCP_SA_KEY_JSON" | base64 -w0)
```

Insert immediately after it:

```bash

          GSC_ENV=$(printf 'GSC_CREDENTIALS_PATH=%s\nGSC_SKIP_OAUTH=%s\n' \
            "/credentials/sa-key.json" "true" | base64 -w0)

          GSC_SA_KEY=$(printf '%s' "$GSC_MCP_SA_KEY_JSON" | base64 -w0)

          # Full gateway-config.yaml, token substituted as a printf ARG (literal, no shell expansion).
          GSC_GATEWAY_CFG=$(printf 'host: https://gsc.%s/\nauthorization:\n  server: http://gsc-dex:5556/\n  authorizationProxyEnabled: true\n  serverMetadataProxyEnabled: true\n  dynamicClientRegistration:\n    enabled: true\n    publicClient: true\ndexGRPCClient:\n  addr: gsc-dex:5557\nproxy:\n  - path: /mcp\n    http:\n      url: http://gsc-mcp:8080/servers/%s/mcp/\n    authentication:\n      enabled: true\n' \
            "$BASE_DOMAIN" "$GSC_MCP_PATH_TOKEN" | base64 -w0)

          # Full dex-config.yaml; email + bcrypt hash passed as printf ARGs so the $ in the
          # hash stays literal. block-style allowedOrigins avoids quoting a flow sequence.
          GSC_DEX_CFG=$(printf 'issuer: https://gsc.%s\nweb:\n  http: 0.0.0.0:5556\n  allowedOrigins:\n    - "*"\ngrpc:\n  addr: 0.0.0.0:5557\nstorage:\n  type: memory\noauth2:\n  skipApprovalScreen: true\nenablePasswordDB: true\nstaticPasswords:\n  - email: "%s"\n    hash: "%s"\n    username: admin\n    userID: "7f3a1e2c-9b4d-4a6e-8c1f-2d5b7e9a0c34"\n' \
            "$BASE_DOMAIN" "$GSC_DEX_ADMIN_EMAIL" "$GSC_DEX_ADMIN_HASH" | base64 -w0)
```

- [ ] **Step 3: Pass the GSC blobs into the SSH remote shell**

Find:

```bash
          N8N_APP_ENV='$N8N_APP_ENV'
          N8N_DB_ENV='$N8N_DB_ENV'
```

Replace with:

```bash
          N8N_APP_ENV='$N8N_APP_ENV'
          N8N_DB_ENV='$N8N_DB_ENV'
          GSC_ENV='$GSC_ENV'
          GSC_SA_KEY='$GSC_SA_KEY'
          GSC_GATEWAY_CFG='$GSC_GATEWAY_CFG'
          GSC_DEX_CFG='$GSC_DEX_CFG'
          GSC_MCP_PATH_TOKEN='$GSC_MCP_PATH_TOKEN'
```

- [ ] **Step 4: Add the `gsc-mcp)` case to the deploy loop**

Find:

```bash
              ga4-mcp)
                mkdir -p /root/stacks/ga4-mcp/credentials
                echo \"\$GA4_SA_KEY\" | base64 -d > /root/stacks/ga4-mcp/credentials/sa-key.json
                chmod 644 /root/stacks/ga4-mcp/credentials/sa-key.json
                echo \"\$GA4_ENV\"    | base64 -d > /root/stacks/ga4-mcp/.env.ga4-mcp ;;
            esac
```

Replace with:

```bash
              ga4-mcp)
                mkdir -p /root/stacks/ga4-mcp/credentials
                echo \"\$GA4_SA_KEY\" | base64 -d > /root/stacks/ga4-mcp/credentials/sa-key.json
                chmod 644 /root/stacks/ga4-mcp/credentials/sa-key.json
                echo \"\$GA4_ENV\"    | base64 -d > /root/stacks/ga4-mcp/.env.ga4-mcp ;;
              gsc-mcp)
                mkdir -p /root/stacks/gsc-mcp/credentials
                echo \"\$GSC_SA_KEY\"      | base64 -d > /root/stacks/gsc-mcp/credentials/sa-key.json
                chmod 644 /root/stacks/gsc-mcp/credentials/sa-key.json
                echo \"\$GSC_ENV\"         | base64 -d > /root/stacks/gsc-mcp/.env.gsc-mcp
                echo \"GSC_MCP_PATH_TOKEN=\$GSC_MCP_PATH_TOKEN\" >> /root/stacks/gsc-mcp/.env
                echo \"\$GSC_GATEWAY_CFG\" | base64 -d > /root/stacks/gsc-mcp/gateway-config.yaml
                echo \"\$GSC_DEX_CFG\"     | base64 -d > /root/stacks/gsc-mcp/dex-config.yaml ;;
            esac
```

- [ ] **Step 5: Verify the workflow YAML still parses**

Run:
```bash
docker run --rm -v "$(pwd)/.github/workflows:/w" -w /w python:3.12-slim \
  python -c "import yaml; yaml.safe_load(open('deploy-infra.yml')); print('workflow YAML OK')"
```
Expected: prints `workflow YAML OK`.

- [ ] **Step 6: Local render test — confirm the two printf blocks produce valid YAML**

This proves the deploy-time rendering works before we ever deploy. Run the exact printf pipelines with dummy values through a base64 round-trip and validate:

```bash
BASE_DOMAIN=teeko.ai
GSC_MCP_PATH_TOKEN=deadbeefcafe
GSC_DEX_ADMIN_EMAIL='admin@teeko.ai'
# A realistic bcrypt hash containing $ and / to prove no mangling:
GSC_DEX_ADMIN_HASH='$2a$10$abcdefghijklmnopqrstuv/wxyz0123456789ABCDEFGHIJKLMNOPq'

GSC_GATEWAY_CFG=$(printf 'host: https://gsc.%s/\nauthorization:\n  server: http://gsc-dex:5556/\n  authorizationProxyEnabled: true\n  serverMetadataProxyEnabled: true\n  dynamicClientRegistration:\n    enabled: true\n    publicClient: true\ndexGRPCClient:\n  addr: gsc-dex:5557\nproxy:\n  - path: /mcp\n    http:\n      url: http://gsc-mcp:8080/servers/%s/mcp/\n    authentication:\n      enabled: true\n' "$BASE_DOMAIN" "$GSC_MCP_PATH_TOKEN" | base64 -w0)

GSC_DEX_CFG=$(printf 'issuer: https://gsc.%s\nweb:\n  http: 0.0.0.0:5556\n  allowedOrigins:\n    - "*"\ngrpc:\n  addr: 0.0.0.0:5557\nstorage:\n  type: memory\noauth2:\n  skipApprovalScreen: true\nenablePasswordDB: true\nstaticPasswords:\n  - email: "%s"\n    hash: "%s"\n    username: admin\n    userID: "7f3a1e2c-9b4d-4a6e-8c1f-2d5b7e9a0c34"\n' "$BASE_DOMAIN" "$GSC_DEX_ADMIN_EMAIL" "$GSC_DEX_ADMIN_HASH" | base64 -w0)

echo "$GSC_GATEWAY_CFG" | base64 -d > /tmp/gw.yaml
echo "$GSC_DEX_CFG"     | base64 -d > /tmp/dex.yaml
echo "----- gateway-config.yaml -----"; cat /tmp/gw.yaml
echo "----- dex-config.yaml -----";     cat /tmp/dex.yaml
docker run --rm -v /tmp:/w -w /w python:3.12-slim python -c "import yaml; g=yaml.safe_load(open('gw.yaml')); d=yaml.safe_load(open('dex.yaml')); assert g['proxy'][0]['http']['url']=='http://gsc-mcp:8080/servers/deadbeefcafe/mcp/', g; assert d['staticPasswords'][0]['hash'].startswith('\$2a\$10\$'), d; assert d['issuer']=='https://gsc.teeko.ai'; print('RENDER OK')"
```
Expected: both YAMLs print correctly, the bcrypt hash is intact (starts with `$2a$10$`, includes the `/`), the proxy URL has the trailing slash, and it prints `RENDER OK`.

- [ ] **Step 7: Clean up temp files**

Run:
```bash
rm -f /tmp/gw.yaml /tmp/dex.yaml
```
Expected: removed.

- [ ] **Step 8: Commit**

```bash
git add .github/workflows/deploy-infra.yml
git commit -m "feat(vps3): wire gsc-mcp stack into deploy-infra (gateway+dex config render)"
```

---

### Task 4: Registry entry

Document the new MCP server in the app registry.

**Files:**
- Modify: `apps/registry.yml` (append to the `mcp_servers:` list, after the `ga4-mcp` entry)

**Interfaces:**
- Consumes: nothing at runtime (documentation).
- Produces: nothing consumed by other tasks.

- [ ] **Step 1: Append the gsc-mcp entry**

In `apps/registry.yml`, find the end of the `ga4-mcp` entry under `mcp_servers:` (it ends with the closing of its `notes:` string, immediately before the `tools:` top-level key). Add this as a new list item under `mcp_servers:`, directly after the `ga4-mcp` item and before `tools:`:

```yaml
  - name: gsc-mcp
    image: blueprintagency/gsc-mcp
    tags:
      production: latest
    stack: gsc-mcp
    vps:
      production: vps3-prod
    port: 8080
    domain:
      production: gsc.teeko.ai
    notes: "Google Search Console MCP (github.com/AminForou/mcp-gsc, PyPI mcp-search-console),
      wrapped with mcp-proxy (upstream is stdio-only, no HTTP transport or image) and fronted by
      an OAuth 2.1 gateway (hyprmcp mcp-gateway 0.4.0 + self-hosted Dex 2.44.0) so it works as a
      claude.ai web custom connector. Single public host gsc.teeko.ai: Dex OAuth paths (Traefik
      priority 100) -> gsc-dex:5556; everything else incl. /mcp (priority 1) -> gsc-gateway:9000,
      which enforces OAuth Bearer and reverse-proxies in-network to gsc-mcp:8080/servers/<token>/mcp/.
      The gsc-mcp backend has NO public route. Client URL: https://gsc.teeko.ai/mcp. Backend image
      built by .github/workflows/build-gsc-mcp.yml (no version pins). Google auth via service account
      (reuses the ga4 SA): GSC_CREDENTIALS_PATH=/credentials/sa-key.json + GSC_SKIP_OAUTH=true; needs
      Search Console API enabled + the SA added as a user on the GSC property. Dex login via a static
      password (GSC_DEX_ADMIN_EMAIL / GSC_DEX_ADMIN_HASH). Secrets in vps3-prod env: GSC_MCP_PATH_TOKEN,
      GSC_MCP_SA_KEY_JSON, GSC_DEX_ADMIN_HASH."
```

- [ ] **Step 2: Validate registry YAML parses**

Run:
```bash
docker run --rm -v "$(pwd)/apps:/w" -w /w python:3.12-slim \
  python -c "import yaml; d=yaml.safe_load(open('registry.yml')); names=[m['name'] for m in d['mcp_servers']]; assert 'gsc-mcp' in names, names; print('registry OK:', names)"
```
Expected: prints `registry OK: ['ga4-mcp', 'gsc-mcp']`.

- [ ] **Step 3: Commit**

```bash
git add apps/registry.yml
git commit -m "docs(registry): add gsc-mcp entry"
```

---

### Task 5: GitHub secrets & variables (vps3-prod environment)

Create the three secrets and one variable the deploy job reads. These are execution actions (no commit). Uses the GitHub CLI (`gh`) authenticated with the PAT from `.env`.

**Files:** none.

**Interfaces:**
- Consumes: `GITHUB_PERSONAL_ACCESS_TOKEN` from `.env`; the SA key JSON pulled live from VPS3; the bcrypt hash from the user.
- Produces: `vps3-prod` env secrets `GSC_MCP_PATH_TOKEN`, `GSC_MCP_SA_KEY_JSON`, `GSC_DEX_ADMIN_HASH` and variable `GSC_DEX_ADMIN_EMAIL` consumed by Task 3's workflow at deploy time.

**Prerequisite:** the user has generated the Dex password bcrypt hash (spec §5 step 4) and provided it, OR will set `GSC_DEX_ADMIN_HASH` themselves.

- [ ] **Step 1: Authenticate gh with the PAT**

Run (loads the PAT from `.env` without printing it):
```bash
export GH_TOKEN=$(grep -E '^GITHUB_PERSONAL_ACCESS_TOKEN=' .env | cut -d= -f2- | tr -d '"'"'"'\r')
gh repo view --json nameWithOwner -q .nameWithOwner
```
Expected: prints `Blueprint-Agency/infrastructure` (confirms auth + repo detection). If it prints a different slug, use that slug with `--repo` in the following steps.

- [ ] **Step 2: Generate and set `GSC_MCP_PATH_TOKEN`**

Run:
```bash
GSC_TOKEN=$(openssl rand -hex 32)
printf '%s' "$GSC_TOKEN" | gh secret set GSC_MCP_PATH_TOKEN --env vps3-prod
echo "set GSC_MCP_PATH_TOKEN (len ${#GSC_TOKEN})"
```
Expected: `✓ Set ... secret GSC_MCP_PATH_TOKEN ...` and `set GSC_MCP_PATH_TOKEN (len 64)`.

- [ ] **Step 3: Set `GSC_MCP_SA_KEY_JSON` from the live VPS3 ga4 key**

The ga4 SA key is already on VPS3; reuse it (secrets can't be read back from GitHub). Run:
```bash
ssh bp-vps3-prod "cat /root/stacks/ga4-mcp/credentials/sa-key.json" | gh secret set GSC_MCP_SA_KEY_JSON --env vps3-prod
echo "set GSC_MCP_SA_KEY_JSON"
```
Expected: `✓ Set ... secret GSC_MCP_SA_KEY_JSON ...`. (If the SSH alias doesn't resolve under Git Bash, use the PowerShell tool: `ssh bp-vps3-prod "cat /root/stacks/ga4-mcp/credentials/sa-key.json"` and pipe into `gh secret set`.)

- [ ] **Step 4: Set `GSC_DEX_ADMIN_HASH`**

Using the bcrypt hash the user provided (a `$2a$...` string). Run (replace `<HASH>` with the value, keep the single quotes so `$` is literal):
```bash
printf '%s' '<HASH>' | gh secret set GSC_DEX_ADMIN_HASH --env vps3-prod
echo "set GSC_DEX_ADMIN_HASH"
```
Expected: `✓ Set ... secret GSC_DEX_ADMIN_HASH ...`.

- [ ] **Step 5: Set the `GSC_DEX_ADMIN_EMAIL` variable**

Run:
```bash
gh variable set GSC_DEX_ADMIN_EMAIL --env vps3-prod --body "askblueprintagency@gmail.com"
echo "set GSC_DEX_ADMIN_EMAIL"
```
Expected: `✓ Set ... variable GSC_DEX_ADMIN_EMAIL ...`.

- [ ] **Step 6: Verify all four exist in the vps3-prod environment**

Run:
```bash
echo "--- secrets ---"; gh secret list --env vps3-prod | grep -E 'GSC_' || true
echo "--- variables ---"; gh variable list --env vps3-prod | grep -E 'GSC_' || true
```
Expected: secrets list shows `GSC_MCP_PATH_TOKEN`, `GSC_MCP_SA_KEY_JSON`, `GSC_DEX_ADMIN_HASH`; variables list shows `GSC_DEX_ADMIN_EMAIL`.

---

### Task 6: DNS record for gsc.teeko.ai

Create the public DNS record, DNS-only (grey-cloud), pointing to VPS3 — matching ga4's setup. Uses the Cloudflare MCP.

**Files:** none.

**Interfaces:**
- Consumes: the VPS3 origin IP (read from the existing `ga4.teeko.ai` record).
- Produces: public resolution of `gsc.teeko.ai` → VPS3, required for Let's Encrypt issuance and client connectivity in Task 7.

- [ ] **Step 1: Find the teeko.ai zone and VPS3 IP**

Using the Cloudflare MCP, list DNS records for zone `teeko.ai` and read the `A` record for `ga4.teeko.ai` — note its `content` (VPS3 IP), `proxied` value (expected `false`), and the zone id. (ga4 is DNS-only; gsc must match.)

Expected: `ga4.teeko.ai` A → `<VPS3_IP>`, `proxied: false`.

- [ ] **Step 2: Create the gsc.teeko.ai A record (DNS-only)**

Using the Cloudflare MCP, create an `A` record in the `teeko.ai` zone: name `gsc`, content `<VPS3_IP>` (from Step 1), `proxied: false`, TTL auto.

Expected: record created; `gsc.teeko.ai` A → `<VPS3_IP>`, `proxied: false`.

- [ ] **Step 3: Verify resolution**

Run:
```bash
nslookup gsc.teeko.ai || true
```
Expected: resolves to `<VPS3_IP>`. (Cloudflare DNS-only propagation is typically near-instant; a short wait may be needed.)

---

### Task 7: Deploy & acceptance

Merge, build the image, deploy the stack, and verify end-to-end including the claude.ai web connector.

**Files:** none (uses the PR/CI).

**Prerequisites (user-side, spec §5 — must be done before Step 4 acceptance):**
- Search Console API enabled in GCP project `fluid-particle-501109-a1`.
- SA `blueprint@fluid-particle-501109-a1.iam.gserviceaccount.com` added as a user on the target GSC property (`yogasadhana.sg` unless corrected).
- Tasks 5 and 6 complete (secrets/var + DNS).

**Interfaces:**
- Consumes: everything from Tasks 1-6.
- Produces: a working claude.ai connector at `https://gsc.teeko.ai/mcp`.

- [ ] **Step 1: Push the branch and open a PR**

Run:
```bash
git push -u origin feat/gsc-mcp
gh pr create --title "feat(vps3): add gsc-mcp behind OAuth gateway" \
  --body "Adds the Google Search Console MCP on VPS3 at https://gsc.teeko.ai/mcp, fronted by hyprmcp mcp-gateway + Dex (mirrors the working ga4 pattern). See docs/superpowers/specs/2026-07-01-gsc-mcp-oauth-gateway-design.md."
```
Expected: PR created; URL printed.

- [ ] **Step 2: Merge the PR**

After review, merge to `main` (this triggers both `Build gsc-mcp Image` and `Deploy Infrastructure Stacks`):
```bash
gh pr merge --squash --delete-branch
```
Expected: merged.

- [ ] **Step 3: Wait for the image build, then (re)run the deploy**

The build and deploy start together, but deploy pulls `blueprintagency/gsc-mcp:latest` which must exist first. Run:
```bash
gh run list --workflow "Build gsc-mcp Image" --limit 1
# wait until the latest run shows "completed  success", then:
gh workflow run "Deploy Infrastructure Stacks" --ref main
gh run list --workflow "Deploy Infrastructure Stacks" --limit 1
```
Expected: build shows success; a fresh deploy run starts.

> Note: `gh workflow run` requires a `workflow_dispatch` trigger. If `Deploy Infrastructure Stacks` has no `workflow_dispatch`, instead push a trivial commit touching `vps/vps3-prod/` (e.g. a comment in the gsc-mcp compose) to re-trigger the push-based deploy after the build is green.

- [ ] **Step 4: Verify the stack is up on VPS3**

Run:
```bash
ssh bp-vps3-prod "cd /root/stacks/gsc-mcp && docker compose ps"
```
Expected: `gsc-mcp`, `gsc-gateway`, `gsc-dex` all `running`; `gsc-dex` shows `healthy`.

If any is unhealthy/restarting, inspect:
```bash
ssh bp-vps3-prod "cd /root/stacks/gsc-mcp && docker compose logs --tail=50 gsc-dex gsc-gateway gsc-mcp"
```

- [ ] **Step 5: Verify the OAuth discovery endpoints (from your machine)**

Run:
```bash
echo '--- AS metadata ---'; curl -sS -o /dev/null -w '%{http_code}\n' https://gsc.teeko.ai/.well-known/oauth-authorization-server
echo '--- OIDC (Dex) ---';   curl -sS https://gsc.teeko.ai/.well-known/openid-configuration | grep -o '"issuer":"[^"]*"'
echo '--- /mcp challenge ---'; curl -sS -o /dev/null -w '%{http_code}\n' -D - https://gsc.teeko.ai/mcp | grep -i 'www-authenticate\|^HTTP'
```
Expected: AS metadata → `200`; OIDC issuer → `"issuer":"https://gsc.teeko.ai"`; `/mcp` → `401` with `WWW-Authenticate: Bearer resource_metadata="https://gsc.teeko.ai/.well-known/oauth-protected-resource/mcp"`.

- [ ] **Step 6: Verify the backend responds through the gateway (in-network)**

Run:
```bash
ssh bp-vps3-prod "docker exec gsc-gateway wget -qO- --server-response http://gsc-mcp:8080/ 2>&1 | head -5 || true"
```
Expected: an HTTP response from the backend (any status proves reachability; the real path is token-gated). Alternatively confirm no upstream-connection errors in `gsc-gateway` logs.

- [ ] **Step 7: Add the connector on claude.ai web**

In claude.ai → Settings → Connectors → Add custom connector → URL `https://gsc.teeko.ai/mcp`. Complete the OAuth flow: you'll be redirected to the Dex login page; sign in with `GSC_DEX_ADMIN_EMAIL` + the password whose bcrypt you set.

Expected: connector shows **Connected**; GSC tools become available in a new chat.

- [ ] **Step 8: (Fallback) Verify via Claude Code CLI if web misbehaves**

If claude.ai web fails to connect (Anthropic beta bugs), confirm the server itself is correct via the CLI:
```bash
claude mcp add --transport http gsc https://gsc.teeko.ai/mcp
claude mcp list
```
Expected: `gsc` shows `✔ Connected` (the OAuth flow opens a browser once). This isolates any failure to the claude.ai web client vs. the server.

- [ ] **Step 9: Update project memory**

Add a memory file documenting the gsc-mcp deployment (mirrors the ga4 memory), noting: the hyprmcp+Dex OAuth gateway pattern, single-host `gsc.teeko.ai`, service-account reuse, the secrets, and that web connector worked (or the outcome). Link `[[project_ga4_mcp]]` and `[[reference_mcp_claude_connectors]]`, and update `MEMORY.md`.

---

## Follow-ups (out of scope, documented)

- Reconcile the ga4 OAuth gateway drift (`/root/ga4-oauth/`, uncommitted) into the repo the same way.
- Consider persistent Dex storage if forced re-logins become annoying (currently `memory`, matches ga4).

## Self-Review notes

- **Spec coverage:** §2 architecture → Tasks 1-2; §3 CI/deploy → Tasks 1,3,4; §4 GitHub config → Task 5; §5 manual steps → Task 7 prerequisites + Task 6 (DNS); §6 deploy order → Task 7 Steps 2-3; §7 acceptance → Task 7 Steps 4-8; §8 follow-ups → Follow-ups section. All covered.
- **Placeholder scan:** no TBD/TODO; all file contents and commands are literal. The only `@@...@@` / `<HASH>` markers are intentional secret placeholders rendered at deploy or supplied by the user.
- **Type/name consistency:** service names `gsc-mcp` / `gsc-gateway` / `gsc-dex`, router names `gscgw` / `gscgw-dex`, ports 8080/9000/5556/5557, token var `GSC_MCP_PATH_TOKEN`, and the trailing-slash upstream URL are consistent across compose, gateway-config, the deploy render, and the registry entry.
