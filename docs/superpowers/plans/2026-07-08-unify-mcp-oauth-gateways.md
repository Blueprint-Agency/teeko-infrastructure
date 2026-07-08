# Unify & Harden GSC/GA4 MCP OAuth Gateways — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give both MCP OAuth gateways (GSC + GA4) one shared login, sessions that survive container restarts, and put the GA4 gateway under repo/CI management on `ga4.teeko.ai`.

**Architecture:** Both stacks follow the GSC pattern: an internal MCP backend fronted by a hyprmcp gateway + Dex IdP, gateway as the sole public Traefik route. Functional Dex/gateway config is rendered inline by `printf` in `deploy-infra.yml` (it overwrites the rsynced templates); compose files are used from the repo directly. Dex gains persistent sqlite storage (host bind mount, chowned to 1001) and a long non-rotating token expiry.

**Tech Stack:** Docker Compose, Traefik, hyprmcp/dex v2.44.0, hyprmcp/mcp-gateway 0.4.0, GitHub Actions, Tailscale-over-SSH deploy.

## Global Constraints

- All secrets live in GitHub Environment `vps3-prod` (secrets) / repo variables — never hardcode tokens, hashes, or passwords in committed files. Committed configs use `@@PLACEHOLDER@@` markers. (CLAUDE.md credentials rule.)
- Do NOT add `Co-Authored-By` lines to commits. (CLAUDE.md.)
- Repo `Blueprint-Agency/infrastructure`; only `vps/vps3-prod/**` and `.github/workflows/deploy-infra.yml` change.
- Dex container runs as uid:gid `1001:1001`; the sqlite bind-mount dir must be chowned to `1001:1001` at deploy.
- The deploy workflow **overwrites** `dex-config.yaml` / `gateway-config.yaml` on the VPS with `printf`-rendered content — functional changes to those go in `deploy-infra.yml`, and the committed templates are updated only to stay documentation-accurate.
- Shared credentials: variable `MCP_DEX_ADMIN_EMAIL=askblueprintagency@gmail.com`, secret `MCP_DEX_ADMIN_HASH=bcrypt(shared password)`. Password supplied out-of-band; never written to repo.
- Work on a branch; the `deploy-vps3` job triggers only on push to `main` under `vps/vps3-prod/**`. Merge to main is the single deploy trigger — GitHub secrets MUST exist before merge.

---

### Task 1: Branch + GSC persistence & expiry (compose + template)

**Files:**
- Create branch `feat/unify-mcp-gateways`
- Modify: `vps/vps3-prod/stacks/gsc-mcp/docker-compose.yml` (add sqlite bind mount to `gsc-dex`)
- Modify: `vps/vps3-prod/stacks/gsc-mcp/dex-config.yaml` (template: sqlite storage + expiry, for docs accuracy)
- Create: `vps/vps3-prod/stacks/gsc-mcp/.gitignore` (ignore `dex-data/`)

**Interfaces:**
- Produces: bind mount `./dex-data:/var/dex` on service `gsc-dex`; Dex sqlite file at `/var/dex/dex.db`. Task 3 relies on the deploy step creating+chowning `/root/stacks/gsc-mcp/dex-data`.

- [ ] **Step 1: Create the branch**

```bash
git checkout -b feat/unify-mcp-gateways
```

- [ ] **Step 2: Add the sqlite bind mount to `gsc-dex`**

In `vps/vps3-prod/stacks/gsc-mcp/docker-compose.yml`, change the `gsc-dex` `volumes:` block from:

```yaml
    volumes:
      - ./dex-config.yaml:/config.yaml:ro
```

to:

```yaml
    volumes:
      - ./dex-config.yaml:/config.yaml:ro
      - ./dex-data:/var/dex
```

- [ ] **Step 3: Update the committed GSC dex-config template (docs accuracy)**

Replace the body of `vps/vps3-prod/stacks/gsc-mcp/dex-config.yaml` with (keep the existing top comment block, update the `storage` section and add `expiry`):

```yaml
# TEMPLATE — deploy-infra.yml overwrites this on VPS3 with @@markers@@ replaced.
# storage is sqlite3 on the ./dex-data bind mount so signing keys + tokens survive
# restarts (memory storage was causing forced re-logins). issuer MUST equal the public host.
issuer: https://gsc.teeko.ai
web:
  http: 0.0.0.0:5556
  allowedOrigins:
    - "*"
grpc:
  addr: 0.0.0.0:5557
storage:
  type: sqlite3
  config:
    file: /var/dex/dex.db
oauth2:
  skipApprovalScreen: true
expiry:
  idTokens: "8760h"
  refreshTokens:
    disableRotation: true
    validIfNotUsedFor: "87600h"
    absoluteLifetime: "87600h"
enablePasswordDB: true
staticPasswords:
  - email: "@@MCP_DEX_ADMIN_EMAIL@@"
    hash: "@@MCP_DEX_ADMIN_HASH@@"
    username: admin
    userID: "7f3a1e2c-9b4d-4a6e-8c1f-2d5b7e9a0c34"
```

- [ ] **Step 4: Ignore the sqlite data dir**

Create `vps/vps3-prod/stacks/gsc-mcp/.gitignore`:

```
dex-data/
```

- [ ] **Step 5: Validate compose syntax locally**

Run: `docker compose -f vps/vps3-prod/stacks/gsc-mcp/docker-compose.yml config -q && echo OK`
Expected: `OK` (warnings about unset `${BASE_DOMAIN}` are fine).

- [ ] **Step 6: Commit**

```bash
git add vps/vps3-prod/stacks/gsc-mcp/docker-compose.yml vps/vps3-prod/stacks/gsc-mcp/dex-config.yaml vps/vps3-prod/stacks/gsc-mcp/.gitignore
git commit -m "feat(vps3): persistent Dex storage + long expiry for gsc gateway"
```

---

### Task 2: GA4 — fold gateway+Dex into the ga4-mcp stack (cut over to ga4.teeko.ai)

**Files:**
- Modify: `vps/vps3-prod/stacks/ga4-mcp/docker-compose.yml` (add `ga4-dex` + `ga4-gateway`; make `ga4-mcp` internal-only)
- Create: `vps/vps3-prod/stacks/ga4-mcp/dex-config.yaml` (template with markers)
- Create: `vps/vps3-prod/stacks/ga4-mcp/gateway-config.yaml` (template with markers)
- Create: `vps/vps3-prod/stacks/ga4-mcp/.gitignore` (ignore `dex-data/`)

**Interfaces:**
- Consumes: `${BASE_DOMAIN}` and `${GA4_MCP_PATH_TOKEN}` from the stack `.env` (already written to every stack's `.env` via `BASE_ENV` in deploy-infra.yml).
- Produces: public host `ga4.${BASE_DOMAIN}` served by `ga4-gateway`; `ga4-mcp` reachable only in-network at `http://ga4-mcp:8080/servers/${GA4_MCP_PATH_TOKEN}/mcp/`. Dex OAuth paths on a priority-100 router. Mirrors gsc-mcp service naming (`ga4-dex`, `ga4-gateway`, `ga4-mcp`).

- [ ] **Step 1: Rewrite `vps/vps3-prod/stacks/ga4-mcp/docker-compose.yml`**

Replace the whole file with:

```yaml
# Google Analytics MCP (github.com/googleanalytics/google-analytics-mcp), wrapped with
# mcp-proxy (stdio-only upstream), fronted by an OAuth 2.1 gateway (hyprmcp mcp-gateway) +
# self-hosted Dex IdP so it can be a claude.ai web custom connector. Client URL:
# https://ga4.<BASE_DOMAIN>/mcp
#
# Single public host ga4.<BASE_DOMAIN>:
#   - Dex OAuth endpoints (Traefik priority 100) -> ga4-dex:5556
#   - everything else incl. /mcp, /oauth/*, /.well-known/oauth-* (priority 1) -> ga4-gateway:9000
# ga4-mcp has NO public route; the gateway reaches it in-network at
# ga4-mcp:8080/servers/<token>/mcp/ and enforces OAuth Bearer.
#
# .env, .env.ga4-mcp, credentials/sa-key.json, dex-data/, and the rendered
# gateway-config.yaml / dex-config.yaml are written at deploy time by deploy-infra.yml.
# Committed gateway-config.yaml / dex-config.yaml carry @@PLACEHOLDER@@ markers.
services:
  # Backend: mcp-proxy wrapping the stdio analytics-mcp server. Internal only.
  ga4-mcp:
    image: blueprintagency/ga4-mcp:latest
    pull_policy: always
    container_name: ga4-mcp
    restart: unless-stopped
    env_file: .env.ga4-mcp
    command: ["--host=0.0.0.0", "--port=8080", "--pass-environment", "--stateless", "--allow-origin=*", "--named-server", "${GA4_MCP_PATH_TOKEN}", "analytics-mcp"]
    volumes:
      - ./credentials:/credentials:ro
    networks:
      - proxy

  # OAuth 2.1 gateway (DCR + PKCE). Public catch-all on ga4.<domain>; reverse-proxies /mcp.
  ga4-gateway:
    image: ghcr.io/hyprmcp/mcp-gateway:0.4.0
    pull_policy: always
    container_name: ga4-gateway
    restart: unless-stopped
    command: ["serve", "--config", "/opt/config.yaml", "-v", "2"]
    volumes:
      - ./gateway-config.yaml:/opt/config.yaml:ro
    depends_on:
      ga4-dex:
        condition: service_healthy
    labels:
      - "traefik.enable=true"
      - "traefik.http.services.ga4-gateway.loadbalancer.server.port=9000"
      - "traefik.http.routers.ga4gw.rule=Host(`ga4.${BASE_DOMAIN}`)"
      - "traefik.http.routers.ga4gw.entrypoints=websecure"
      - "traefik.http.routers.ga4gw.tls.certresolver=letsencrypt"
      - "traefik.http.routers.ga4gw.priority=1"
      - "traefik.http.routers.ga4gw.service=ga4-gateway"
    networks:
      - proxy

  # Self-hosted Dex IdP. Serves its OAuth endpoints on ga4.<domain> via the priority-100 router.
  ga4-dex:
    image: ghcr.io/hyprmcp/dex:2.44.0-alpine
    pull_policy: always
    container_name: ga4-dex
    restart: unless-stopped
    # Bypass upstream docker-entrypoint: its $-env-expansion mangles $ in the bcrypt hash.
    entrypoint: ["dex"]
    command: ["serve", "/config.yaml"]
    volumes:
      - ./dex-config.yaml:/config.yaml:ro
      - ./dex-data:/var/dex
    healthcheck:
      test: ["CMD", "wget", "-qO-", "http://localhost:5556/.well-known/openid-configuration"]
      interval: 5s
      timeout: 3s
      retries: 30
      start_period: 5s
    labels:
      - "traefik.enable=true"
      - "traefik.http.services.ga4-dex.loadbalancer.server.port=5556"
      - "traefik.http.routers.ga4gw-dex.rule=Host(`ga4.${BASE_DOMAIN}`) && (PathPrefix(`/auth`) || PathPrefix(`/token`) || PathPrefix(`/keys`) || PathPrefix(`/approval`) || PathPrefix(`/callback`) || PathPrefix(`/device`) || PathPrefix(`/theme`) || PathPrefix(`/static`) || Path(`/.well-known/openid-configuration`))"
      - "traefik.http.routers.ga4gw-dex.entrypoints=websecure"
      - "traefik.http.routers.ga4gw-dex.tls.certresolver=letsencrypt"
      - "traefik.http.routers.ga4gw-dex.priority=100"
      - "traefik.http.routers.ga4gw-dex.service=ga4-dex"
    networks:
      - proxy

networks:
  proxy:
    external: true
```

- [ ] **Step 2: Create `vps/vps3-prod/stacks/ga4-mcp/dex-config.yaml` template**

```yaml
# TEMPLATE — deploy-infra.yml overwrites this on VPS3 with @@markers@@ replaced.
# sqlite3 on ./dex-data so tokens/signing keys survive restarts. issuer MUST equal public host.
issuer: https://ga4.teeko.ai
web:
  http: 0.0.0.0:5556
  allowedOrigins:
    - "*"
grpc:
  addr: 0.0.0.0:5557
storage:
  type: sqlite3
  config:
    file: /var/dex/dex.db
oauth2:
  skipApprovalScreen: true
expiry:
  idTokens: "8760h"
  refreshTokens:
    disableRotation: true
    validIfNotUsedFor: "87600h"
    absoluteLifetime: "87600h"
enablePasswordDB: true
staticPasswords:
  - email: "@@MCP_DEX_ADMIN_EMAIL@@"
    hash: "@@MCP_DEX_ADMIN_HASH@@"
    username: admin
    userID: "7ea943f4-f0d5-4af2-a386-fc20eacb2ff1"
```

- [ ] **Step 3: Create `vps/vps3-prod/stacks/ga4-mcp/gateway-config.yaml` template**

```yaml
# TEMPLATE — deploy-infra.yml overwrites this on VPS3 with @@GA4_MCP_PATH_TOKEN@@ replaced.
host: https://ga4.teeko.ai/
authorization:
  server: http://ga4-dex:5556/
  authorizationProxyEnabled: true
  serverMetadataProxyEnabled: true
  dynamicClientRegistration:
    enabled: true
    publicClient: true
dexGRPCClient:
  addr: ga4-dex:5557
proxy:
  - path: /mcp
    http:
      url: http://ga4-mcp:8080/servers/@@GA4_MCP_PATH_TOKEN@@/mcp/
    authentication:
      enabled: true
```

- [ ] **Step 4: Ignore the sqlite data dir**

Create `vps/vps3-prod/stacks/ga4-mcp/.gitignore`:

```
dex-data/
```

- [ ] **Step 5: Validate compose syntax locally**

Run: `docker compose -f vps/vps3-prod/stacks/ga4-mcp/docker-compose.yml config -q && echo OK`
Expected: `OK`.

- [ ] **Step 6: Commit**

```bash
git add vps/vps3-prod/stacks/ga4-mcp/
git commit -m "feat(vps3): put ga4 MCP OAuth gateway under repo, cut over to ga4.teeko.ai"
```

---

### Task 3: Wire `deploy-infra.yml` — shared creds, GA4 render, sqlite dirs

**Files:**
- Modify: `.github/workflows/deploy-infra.yml` (deploy-vps3 job only)

**Interfaces:**
- Consumes: `secrets.MCP_DEX_ADMIN_HASH`, `vars.MCP_DEX_ADMIN_EMAIL`, existing `secrets.GA4_MCP_PATH_TOKEN`, `secrets.GSC_MCP_PATH_TOKEN`.
- Produces: rendered `dex-config.yaml`/`gateway-config.yaml` for both stacks; `dex-data` dirs chowned to 1001:1001.

- [ ] **Step 1: Swap the env block to the shared identifiers**

In the `deploy-vps3` job `env:` map, replace:

```yaml
          GSC_DEX_ADMIN_HASH: ${{ secrets.GSC_DEX_ADMIN_HASH }}
          GSC_DEX_ADMIN_EMAIL: ${{ vars.GSC_DEX_ADMIN_EMAIL }}
```

with:

```yaml
          MCP_DEX_ADMIN_HASH: ${{ secrets.MCP_DEX_ADMIN_HASH }}
          MCP_DEX_ADMIN_EMAIL: ${{ vars.MCP_DEX_ADMIN_EMAIL }}
```

- [ ] **Step 2: Update the GSC dex-config `printf` to sqlite + expiry + shared creds**

Replace the `GSC_DEX_CFG=$(printf ...)` assignment with:

```bash
          GSC_DEX_CFG=$(printf 'issuer: https://gsc.%s\nweb:\n  http: 0.0.0.0:5556\n  allowedOrigins:\n    - "*"\ngrpc:\n  addr: 0.0.0.0:5557\nstorage:\n  type: sqlite3\n  config:\n    file: /var/dex/dex.db\noauth2:\n  skipApprovalScreen: true\nexpiry:\n  idTokens: "8760h"\n  refreshTokens:\n    disableRotation: true\n    validIfNotUsedFor: "87600h"\n    absoluteLifetime: "87600h"\nenablePasswordDB: true\nstaticPasswords:\n  - email: "%s"\n    hash: "%s"\n    username: admin\n    userID: "7f3a1e2c-9b4d-4a6e-8c1f-2d5b7e9a0c34"\n' \
            "$BASE_DOMAIN" "$MCP_DEX_ADMIN_EMAIL" "$MCP_DEX_ADMIN_HASH" | base64 -w0)
```

- [ ] **Step 3: Add GA4 gateway + dex `printf` renders**

Immediately after the `GSC_DEX_CFG=...` block, add:

```bash
          GA4_GATEWAY_CFG=$(printf 'host: https://ga4.%s/\nauthorization:\n  server: http://ga4-dex:5556/\n  authorizationProxyEnabled: true\n  serverMetadataProxyEnabled: true\n  dynamicClientRegistration:\n    enabled: true\n    publicClient: true\ndexGRPCClient:\n  addr: ga4-dex:5557\nproxy:\n  - path: /mcp\n    http:\n      url: http://ga4-mcp:8080/servers/%s/mcp/\n    authentication:\n      enabled: true\n' \
            "$BASE_DOMAIN" "$GA4_MCP_PATH_TOKEN" | base64 -w0)

          GA4_DEX_CFG=$(printf 'issuer: https://ga4.%s\nweb:\n  http: 0.0.0.0:5556\n  allowedOrigins:\n    - "*"\ngrpc:\n  addr: 0.0.0.0:5557\nstorage:\n  type: sqlite3\n  config:\n    file: /var/dex/dex.db\noauth2:\n  skipApprovalScreen: true\nexpiry:\n  idTokens: "8760h"\n  refreshTokens:\n    disableRotation: true\n    validIfNotUsedFor: "87600h"\n    absoluteLifetime: "87600h"\nenablePasswordDB: true\nstaticPasswords:\n  - email: "%s"\n    hash: "%s"\n    username: admin\n    userID: "7ea943f4-f0d5-4af2-a386-fc20eacb2ff1"\n' \
            "$BASE_DOMAIN" "$MCP_DEX_ADMIN_EMAIL" "$MCP_DEX_ADMIN_HASH" | base64 -w0)
```

- [ ] **Step 4: Pass the new vars into the SSH heredoc**

In the `ssh ... "` block variable-assignment preamble (where `GSC_GATEWAY_CFG='$GSC_GATEWAY_CFG'` etc. are set), add:

```bash
          GA4_GATEWAY_CFG='$GA4_GATEWAY_CFG'
          GA4_DEX_CFG='$GA4_DEX_CFG'
```

- [ ] **Step 5: Extend the `ga4-mcp)` case to write configs + chown sqlite dir**

Replace the existing `ga4-mcp)` case body with:

```bash
              ga4-mcp)
                mkdir -p /root/stacks/ga4-mcp/credentials /root/stacks/ga4-mcp/dex-data
                echo \"\$GA4_SA_KEY\" | base64 -d > /root/stacks/ga4-mcp/credentials/sa-key.json
                chmod 644 /root/stacks/ga4-mcp/credentials/sa-key.json
                echo \"\$GA4_ENV\"    | base64 -d > /root/stacks/ga4-mcp/.env.ga4-mcp
                echo \"\$GA4_GATEWAY_CFG\" | base64 -d > /root/stacks/ga4-mcp/gateway-config.yaml
                echo \"\$GA4_DEX_CFG\"     | base64 -d > /root/stacks/ga4-mcp/dex-config.yaml
                chown -R 1001:1001 /root/stacks/ga4-mcp/dex-data ;;
```

- [ ] **Step 6: Add sqlite-dir chown to the `gsc-mcp)` case**

In the `gsc-mcp)` case, after the `dex-config.yaml` write line, add before the `;;`:

```bash
                mkdir -p /root/stacks/gsc-mcp/dex-data
                chown -R 1001:1001 /root/stacks/gsc-mcp/dex-data
```

- [ ] **Step 7: Lint the workflow YAML**

Run: `docker run --rm -v "$(pwd):/w" -w /w pipelinecomponents/yamllint yamllint -d relaxed .github/workflows/deploy-infra.yml || true`
Expected: no errors (relaxed profile). If yamllint image unavailable, instead run `python -c "import yaml,sys; yaml.safe_load(open('.github/workflows/deploy-infra.yml')); print('OK')"`.

- [ ] **Step 8: Commit**

```bash
git add .github/workflows/deploy-infra.yml
git commit -m "ci(vps3): render ga4 gateway + shared Dex creds + persistent storage"
```

---

### Task 4: Generate the bcrypt hash and set GitHub env secrets

**Files:** none (GitHub Environment `vps3-prod`)

- [ ] **Step 1: Generate the bcrypt hash of the shared password**

Run (password supplied out-of-band — substitute the real value; do not commit it):

```bash
HASH=$(docker run --rm httpd:2.4-alpine sh -c "htpasswd -bnBC 10 '' 'VDSBdcEMH5wkPqillRgZ' | tr -d '\n' | sed 's/^://'")
echo "$HASH"
```

Expected: a string beginning `$2y$10$...` (about 60 chars).

- [ ] **Step 2: Set the shared variable + secret in the vps3-prod environment**

Preferred (gh CLI handles secret encryption):

```bash
gh variable set MCP_DEX_ADMIN_EMAIL --env vps3-prod --repo Blueprint-Agency/infrastructure --body 'askblueprintagency@gmail.com'
gh secret   set MCP_DEX_ADMIN_HASH  --env vps3-prod --repo Blueprint-Agency/infrastructure --body "$HASH"
```

If `gh` is not authenticated, authenticate with the PAT: `echo "$GITHUB_PERSONAL_ACCESS_TOKEN" | gh auth login --with-token` then re-run.

- [ ] **Step 3: Verify they exist**

```bash
gh variable list --env vps3-prod --repo Blueprint-Agency/infrastructure | grep MCP_DEX_ADMIN_EMAIL
gh secret   list --env vps3-prod --repo Blueprint-Agency/infrastructure | grep MCP_DEX_ADMIN_HASH
```

Expected: both listed.

- [ ] **Step 4: (Deferred to Task 6 post-verify) remove obsolete secrets**

Do NOT delete `GSC_DEX_ADMIN_HASH` / `GSC_DEX_ADMIN_EMAIL` yet — keep them as rollback until the deploy is verified. Deletion happens in Task 6.

---

### Task 5: Merge to main → CI deploys both stacks

**Files:** none (git + GitHub Actions)

- [ ] **Step 1: Push the branch and open a PR**

```bash
git push -u origin feat/unify-mcp-gateways
gh pr create --repo Blueprint-Agency/infrastructure --base main --head feat/unify-mcp-gateways \
  --title "Unify + harden GSC/GA4 MCP OAuth gateways" \
  --body "Shared Dex login, persistent sqlite storage + long expiry, GA4 gateway committed and cut over to ga4.teeko.ai. See docs/superpowers/specs/2026-07-08-unify-mcp-oauth-gateways-design.md"
```

- [ ] **Step 2: Confirm secrets exist (guard against a broken deploy)**

Re-run Task 4 Step 3 checks. Both MUST be present before merge, or the render emits empty creds.

- [ ] **Step 3: Merge to trigger deploy-vps3**

```bash
gh pr merge feat/unify-mcp-gateways --repo Blueprint-Agency/infrastructure --squash --delete-branch
```

- [ ] **Step 4: Watch the deploy run**

```bash
gh run list --repo Blueprint-Agency/infrastructure --workflow deploy-infra.yml --limit 1
gh run watch <run-id> --repo Blueprint-Agency/infrastructure
```

Expected: `deploy-vps3` job succeeds; log shows `ga4-mcp done` and `gsc-mcp done`.

---

### Task 6: Verify, remove the debug stack, clean up secrets, reconnect

**Files:** none (SSH + claude.ai + GitHub)

- [ ] **Step 1: Confirm all six containers healthy**

```bash
ssh bp-vps3-prod "docker ps --format '{{.Names}}\t{{.Status}}' | grep -E 'gsc-|ga4-'"
```

Expected: `gsc-dex/gsc-gateway/gsc-mcp` and `ga4-dex/ga4-gateway/ga4-mcp` all `Up` (dex `healthy`).

- [ ] **Step 2: Confirm GA4 OAuth metadata + issuer**

```bash
ssh bp-vps3-prod "curl -s https://ga4.teeko.ai/.well-known/openid-configuration | head -c 200"
```

Expected: JSON containing `"issuer":"https://ga4.teeko.ai"`.

- [ ] **Step 3: Confirm the old authless endpoint is gone**

```bash
ssh bp-vps3-prod "curl -s -o /dev/null -w '%{http_code}\n' https://ga4.teeko.ai/servers/<GA4_MCP_PATH_TOKEN>/mcp"
```

Expected: `401` (gateway-enforced), not `200`.

- [ ] **Step 4: Confirm sqlite persisted (the real logout regression test)**

```bash
ssh bp-vps3-prod "ls -l /root/stacks/ga4-mcp/dex-data /root/stacks/gsc-mcp/dex-data && docker exec ga4-dex ls -l /var/dex/dex.db"
ssh bp-vps3-prod "docker restart ga4-dex gsc-dex && sleep 8 && docker ps --format '{{.Names}} {{.Status}}' | grep -E 'ga4-dex|gsc-dex'"
```

Expected: `dex.db` present (non-zero size after first login); dex containers return healthy. After a login (Step 6), a restart must NOT force re-auth.

- [ ] **Step 5: Remove the uncommitted debug stack**

```bash
ssh bp-vps3-prod "cd /root/ga4-oauth && docker compose down && cd / && rm -rf /root/ga4-oauth && echo removed"
```

Expected: `removed`; `ga4gw.teeko.ai` no longer served (Traefik drops the routers).

- [ ] **Step 6: Reconnect the claude.ai connectors**

- GSC: connector URL unchanged (`https://gsc.teeko.ai/mcp`); re-login once with `askblueprintagency@gmail.com` + shared password.
- GA4: remove the old connector, add a new one with `https://ga4.teeko.ai/mcp`; log in with the same creds. Confirm the tool list loads.
- Then repeat Step 4's restart and confirm both stay logged in.

- [ ] **Step 7: Delete the obsolete GSC-specific secrets (rollback window closed)**

```bash
gh secret   delete GSC_DEX_ADMIN_HASH  --env vps3-prod --repo Blueprint-Agency/infrastructure
gh variable delete GSC_DEX_ADMIN_EMAIL --env vps3-prod --repo Blueprint-Agency/infrastructure
```

Expected: removed. (Skip if you want to retain them longer as rollback.)

- [ ] **Step 8: Update memory**

Update the `[[project_gsc_mcp]]` and `[[project_ga4_mcp]]` memory files: GA4 now behind Dex+gateway on `ga4.teeko.ai`, both gateways share `MCP_DEX_ADMIN_EMAIL`/`MCP_DEX_ADMIN_HASH`, sqlite persistence fixes the restart-logout, `/root/ga4-oauth` retired.

---

## Self-Review

**Spec coverage:**
- Shared login → Task 3 (shared printf vars) + Task 4 (shared secret/var). ✅
- Sessions survive restarts → Task 1/2 (sqlite bind mount) + Task 3 (chown + sqlite render) + Task 6 Step 4 (restart regression test). ✅
- GA4 committed + CI-managed → Task 2 + Task 3. ✅
- Cut over to ga4.teeko.ai, remove authless endpoint → Task 2 (gateway owns ga4.<domain>, ga4-mcp internal) + Task 6 Steps 3,5. ✅
- Long expiry → Task 1/2/3 expiry block. ✅

**Placeholder scan:** `@@MARKER@@` and `<GA4_MCP_PATH_TOKEN>` / `<run-id>` are intentional runtime substitutions, not plan gaps. Password shown as the literal the user provided for the hash-gen command only; never committed. No TBD/TODO.

**Type/name consistency:** service/container names `ga4-dex`/`ga4-gateway`/`ga4-mcp` used identically in compose, gateway-config (`http://ga4-dex:5556/`, `ga4-dex:5557`, `http://ga4-mcp:8080/...`), and deploy renders. Dex uid `1001:1001` consistent across constraints, chown steps. sqlite path `/var/dex/dex.db` consistent with bind mount `./dex-data:/var/dex`. Shared identifiers `MCP_DEX_ADMIN_EMAIL`/`MCP_DEX_ADMIN_HASH` consistent across Tasks 3–4.

**Known residual risk (from spec open items):** if the claude.ai connector does not request `offline_access`, session lifetime is governed by `idTokens: 8760h` (1 year) rather than the 10-year refresh token — still far beyond the current pain. Persistent signing keys (sqlite) is the load-bearing fix regardless.
