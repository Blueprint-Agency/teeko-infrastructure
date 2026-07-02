# GSC MCP on VPS3 behind an OAuth gateway — Design

**Date:** 2026-07-01
**Author:** chris (with Claude Code)
**Status:** Approved for planning
**Goal:** Deploy the Google Search Console MCP server (`github.com/AminForou/mcp-gsc`) on VPS3 at `gsc.teeko.ai`, fronted by an OAuth 2.1 gateway, so it can be added as a **claude.ai web custom connector**. Set it up as an infra-owned, committed, CI-deployed stack (like `ga4-mcp`, `n8n`, `tools`) — not an app with its own repo CI.

---

## 1. Background & rationale

### The precedent: ga4-mcp
VPS3 already hosts Google's Analytics MCP at `ga4.teeko.ai`. It was originally deployed **authless** (mcp-proxy + secret-token-in-URL-path). That authless server was proven 100% correct, yet **claude.ai web's custom connector could not connect** — the web connector forces an OAuth 2.1 discovery flow and fails against authless servers (documented Anthropic-side beta behaviour; Claude Code CLI connects fine to the same server).

To make ga4 work with **claude.ai web**, an OAuth gateway was added live on VPS3. That gateway pattern **works** — the `mcp__claude_ai_GA4__*` tools connect from claude.ai. This design replicates that proven pattern for GSC.

### The live ga4 gateway (reverse-engineered from VPS3)
- **Gateway:** hyprmcp `mcp-gateway` v0.4.0 (`ghcr.io/hyprmcp/mcp-gateway:0.4.0`) — a Go MCP OAuth proxy with Dynamic Client Registration (DCR) + PKCE. Listens on :9000, reverse-proxies `/mcp` to the backend, enforces Bearer.
- **IdP / Authorization Server:** self-hosted Dex (`ghcr.io/hyprmcp/dex:2.44.0-alpine`) — issues tokens, one static password login. HTTP :5556, gRPC :5557.
- **Backend:** the existing `ga4-mcp` (mcp-proxy) reached in-network at `http://ga4-mcp:8080/servers/<token>/mcp/`.
- **Public URL handed to Claude:** `https://ga4gw.teeko.ai/mcp`.

**Two facts that shape this design:**
1. The ga4 gateway lives in `/root/ga4-oauth/` — **outside `/root/stacks/`, uncommitted drift**. It is not in the repo and would be lost on a VPS rebuild. GSC will be done **properly**: committed to the repo and deployed by `deploy-infra.yml`. (Reconciling the ga4 drift is a documented follow-up, out of scope here.)
2. ga4 uses two hostnames (`ga4gw` gateway + `ga4` legacy authless backend kept live in parallel) — an artifact of history, not a design goal. GSC is greenfield, so we consolidate onto **one hostname** and keep the backend internal.

### mcp-gsc specifics (differ from ga4)
- Python **≥3.11**, published to PyPI as **`mcp-search-console`** (console script `mcp-gsc`). stdio-only (no native HTTP/OAuth) → wrap with mcp-proxy exactly like ga4.
- Google auth via **service account** is fully supported: env **`GSC_CREDENTIALS_PATH`** (path to SA JSON) + **`GSC_SKIP_OAUTH=true`**. It does **not** read `GOOGLE_APPLICATION_CREDENTIALS`, and needs **no project-id** (unlike ga4).
- Scope `https://www.googleapis.com/auth/webmasters`; requires the **Search Console API** (`searchconsole.googleapis.com`) enabled and the SA email added as a user on the target property.

---

## 2. Architecture

One new committed stack: `vps/vps3-prod/stacks/gsc-mcp/`, three containers on the shared external `proxy` network. Single public hostname `gsc.teeko.ai`.

```
Claude.ai web ──HTTPS──> gsc.teeko.ai  (Traefik, Let's Encrypt via Cloudflare DNS-01)
  │
  ├─ router gscgw-dex (priority 100):
  │     Host(gsc.teeko.ai) && ( PathPrefix /auth,/token,/keys,/approval,/callback,
  │       /device,/theme,/static  ||  Path /.well-known/openid-configuration )
  │        └──> gsc-dex:5556        (Dex IdP)
  │
  └─ router gscgw (priority 1, catch-all):
        Host(gsc.teeko.ai)          → /mcp, /oauth/*, /.well-known/oauth-*
         └──> gsc-gateway:9000       (hyprmcp mcp-gateway; enforces OAuth Bearer)
               └──(in-network)──> gsc-mcp:8080/servers/<GSC_MCP_PATH_TOKEN>/mcp/   (INTERNAL, no public route)
                                     └── mcp-proxy → mcp-gsc → Google Search Console API (service account)
```

**Client URL handed to Claude.ai:** `https://gsc.teeko.ai/mcp`

### Components

**gsc-mcp** (backend, image `blueprintagency/gsc-mcp:latest`, `pull_policy: always`)
- Dockerfile: `FROM ghcr.io/sparfenyuk/mcp-proxy:latest` + `pip install --no-cache-dir mcp-search-console`.
  - **Risk to verify at build:** the mcp-proxy base image must have Python ≥3.11 (mcp-search-console requires it). If not, fall back to a `python:3.12-slim` base with `pip install mcp-proxy mcp-search-console`.
- Command: `--host=0.0.0.0 --port=8080 --pass-environment --stateless --allow-origin=* --named-server ${GSC_MCP_PATH_TOKEN} mcp-gsc`
- `env_file: .env.gsc-mcp` → `GSC_CREDENTIALS_PATH=/credentials/sa-key.json`, `GSC_SKIP_OAUTH=true`
- Volume: `./credentials:/credentials:ro` (SA key at `sa-key.json`)
- **No Traefik labels** (internal only; `exposedbydefault=false` means Traefik ignores it). Reachable only by the gateway via service name `gsc-mcp:8080`. Secret path retained as defense-in-depth.
- `restart: unless-stopped`, network `proxy`.

**gsc-gateway** (`ghcr.io/hyprmcp/mcp-gateway:0.4.0`)
- Command: `serve --config /opt/config.yaml -v 2`
- Volume: `./gateway-config.yaml:/opt/config.yaml:ro`
- `depends_on: gsc-dex (service_healthy)`
- Traefik router `gscgw` priority 1, `Host(gsc.${BASE_DOMAIN})`, service port 9000.
- `restart: unless-stopped`, network `proxy`.

**gsc-dex** (`ghcr.io/hyprmcp/dex:2.44.0-alpine`)
- **Entrypoint override `["dex"]`, command `["serve","/config.yaml"]`** — bypasses the upstream docker-entrypoint which does `$`-expansion and mangles the bcrypt hash (copied from ga4's working fix).
- Volume: `./dex-config.yaml:/config.yaml:ro`
- Healthcheck: `wget -qO- http://localhost:5556/.well-known/openid-configuration` (interval 5s, retries 30, start_period 5s).
- Traefik router `gscgw-dex` priority 100, `Host(gsc.${BASE_DOMAIN})` + the Dex path set above, service port 5556.
- `restart: unless-stopped`, network `proxy`.

**Traefik:** unchanged. It auto-discovers the labels and issues the `gsc.teeko.ai` certificate via the existing `letsencrypt` DNS-01 resolver.

### Config file contents (rendered at deploy from secrets)

`gateway-config.yaml`:
```yaml
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
      url: http://gsc-mcp:8080/servers/<GSC_MCP_PATH_TOKEN>/mcp/   # note trailing slash
    authentication:
      enabled: true
```
> Note: all three services are namespaced — compose service names are `gsc-mcp`, `gsc-gateway`, `gsc-dex` (service name == container_name for all three). The gateway config resolves `gsc-dex:5556`/`gsc-dex:5557` and `gsc-mcp:8080` over the shared `proxy` network. (ga4 used a generic `dex` service name; we namespace it here — purely cosmetic, no functional difference.)

`dex-config.yaml`:
```yaml
issuer: https://gsc.teeko.ai
web:
  http: 0.0.0.0:5556
  allowedOrigins: ['*']
grpc:
  addr: 0.0.0.0:5557
storage:
  type: memory
oauth2:
  skipApprovalScreen: true
enablePasswordDB: true
staticPasswords:
  - email: <GSC_DEX_ADMIN_EMAIL>
    hash: "<GSC_DEX_ADMIN_HASH>"      # bcrypt
    username: admin
    userID: <fixed UUID, committed in template>
```
> `storage: memory` means Dex loses registered clients on restart — acceptable because DCR + publicClient auto-re-registers Claude on connect (matches ga4). Consequence: a gateway/dex restart forces Claude.ai to redo the OAuth login.

---

## 3. CI / deploy integration

### Image build — `.github/workflows/build-gsc-mcp.yml`
Clone of `build-ga4-mcp.yml`. Builds **only** the backend image `blueprintagency/gsc-mcp` (`:latest` + `:${{ github.sha }}`) from `vps/vps3-prod/stacks/gsc-mcp/`. Gateway and Dex use upstream images pulled directly — not built here. Triggers on push to `main` touching the Dockerfile or this workflow, plus `workflow_dispatch`. Uses org `vars.DOCKERHUB_USERNAME` + `secrets.DOCKERHUB_TOKEN`.

### Deploy — `.github/workflows/deploy-infra.yml`, `deploy-vps3` job
The stack is picked up automatically (it lives under `vps/vps3-prod/stacks/`). Additions:
- **New `env:`** on the "Deploy and remove stacks" step: `GSC_MCP_PATH_TOKEN` (secret), `GSC_MCP_SA_KEY_JSON` (secret), `GSC_DEX_ADMIN_HASH` (secret), `GSC_DEX_ADMIN_EMAIL` (var).
- **Build base64 blobs** (same channel as `GA4_SA_KEY` / `N8N_APP_ENV`, which avoids the `$`-in-sed problem):
  - `GSC_SA_KEY` = the SA key JSON
  - `GSC_ENV` = `.env.gsc-mcp` (`GSC_CREDENTIALS_PATH=/credentials/sa-key.json`, `GSC_SKIP_OAUTH=true`)
  - `GSC_GATEWAY_CFG` = fully-rendered `gateway-config.yaml` (token substituted via `printf` args — literal, no shell expansion)
  - `GSC_DEX_CFG` = fully-rendered `dex-config.yaml` (email + bcrypt hash substituted via `printf` args)
- **New `gsc-mcp)` case** in the deploy loop:
  ```sh
  gsc-mcp)
    mkdir -p /root/stacks/gsc-mcp/credentials
    echo "$GSC_SA_KEY"      | base64 -d > /root/stacks/gsc-mcp/credentials/sa-key.json
    chmod 644 /root/stacks/gsc-mcp/credentials/sa-key.json
    echo "$GSC_ENV"         | base64 -d > /root/stacks/gsc-mcp/.env.gsc-mcp
    echo "GSC_MCP_PATH_TOKEN=$GSC_MCP_PATH_TOKEN" >> /root/stacks/gsc-mcp/.env
    echo "$GSC_GATEWAY_CFG" | base64 -d > /root/stacks/gsc-mcp/gateway-config.yaml
    echo "$GSC_DEX_CFG"     | base64 -d > /root/stacks/gsc-mcp/dex-config.yaml
    ;;
  ```
  The base `.env` (BASE_ENV) is already written at the top of the loop; we append `GSC_MCP_PATH_TOKEN` so compose can substitute `${GSC_MCP_PATH_TOKEN}` in the backend command. The rendered `gateway-config.yaml`/`dex-config.yaml` overwrite the rsync'd committed placeholder templates.

> The committed `gateway-config.yaml` and `dex-config.yaml` carry `@@PLACEHOLDER@@` markers (no real secrets in the repo, satisfying the credentials rule); the workflow `printf` blocks are the source of the rendered values and must stay in sync with the templates.

### Registry — `apps/registry.yml`
New entry under `mcp_servers:` for `gsc-mcp` (image `blueprintagency/gsc-mcp`, stack `gsc-mcp`, vps `vps3-prod`, port 8080, domain `gsc.teeko.ai`, notes describing the gateway+dex pattern and the `https://gsc.teeko.ai/mcp` client URL).

---

## 4. GitHub configuration (vps3-prod environment)

| Kind | Name | Value / source |
|------|------|----------------|
| Secret | `GSC_MCP_PATH_TOKEN` | random 64-hex (`openssl rand -hex 32`); backend secret path + gateway upstream URL |
| Secret | `GSC_MCP_SA_KEY_JSON` | reuse the value of the existing `GA4_MCP_SA_KEY_JSON` (same SA) |
| Secret | `GSC_DEX_ADMIN_HASH` | bcrypt hash of the chosen Dex login password |
| Variable | `GSC_DEX_ADMIN_EMAIL` | e.g. `askblueprintagency@gmail.com` |

**Reused (no change):** `BASE_DOMAIN`, `ACME_EMAIL`, `CF_DNS_API_TOKEN`, org-level `DOCKERHUB_USERNAME` / `DOCKERHUB_TOKEN`. **No project-id variable needed** (mcp-gsc doesn't use one).

---

## 5. Out-of-repo manual steps

1. **GCP:** enable the Search Console API (`searchconsole.googleapis.com`) in project `fluid-particle-501109-a1`.
2. **Google Search Console:** add `blueprint@fluid-particle-501109-a1.iam.gserviceaccount.com` as a user on the target property. **Assumed property: `yogasadhana.sg`** (matches ga4) — confirm before this step.
3. **DNS (Cloudflare):** `gsc.teeko.ai` A record → VPS3 IP, **DNS-only / grey-cloud** (un-proxied) — matches ga4's rationale (keep Cloudflare's proxy/WAF out of the MCP + OAuth path). Can be done via the Cloudflare MCP.
4. **Dex password:** choose it and generate the bcrypt hash, e.g.
   `docker run --rm httpd:2.4-alpine htpasswd -bnBC 10 "" 'PASSWORD' | tr -d ':\n' | sed 's/^\$2y/\$2a/'`
   → store as `GSC_DEX_ADMIN_HASH`.

---

## 6. Deployment order (bootstrap wrinkle)

The build and deploy workflows both trigger on the same push to `main`. Deploy pulls `blueprintagency/gsc-mcp:latest`, which won't exist until the build finishes. Sequence:
1. Merge the PR.
2. Wait for **Build gsc-mcp Image** to go green (image pushed).
3. Re-run **Deploy Infrastructure Stacks** for vps3 (or push a trivial follow-up commit touching `vps/vps3-prod/**`).
4. Verify on VPS3: `docker compose -f /root/stacks/gsc-mcp/docker-compose.yml ps` (3 services up, dex healthy).

---

## 7. Verification / acceptance criteria

1. **Backend healthy (internal):** on VPS3, `docker exec gsc-gateway wget -qO- http://gsc-mcp:8080/servers/<token>/mcp/` responds (or gateway logs show a successful upstream connection).
2. **Discovery endpoints:** from anywhere —
   - `GET https://gsc.teeko.ai/.well-known/oauth-authorization-server` → 200 JSON
   - `GET https://gsc.teeko.ai/.well-known/openid-configuration` → 200 (Dex, issuer `https://gsc.teeko.ai`)
   - `GET https://gsc.teeko.ai/mcp` → 401 with `WWW-Authenticate: Bearer resource_metadata="https://gsc.teeko.ai/.well-known/oauth-protected-resource/mcp"`
3. **claude.ai web:** add custom connector with URL `https://gsc.teeko.ai/mcp` → OAuth redirects to Dex → log in with the static credentials → connector shows Connected and GSC tools are usable.
4. **Fallback:** if web still fails (Anthropic beta bugs), `claude mcp add --transport http gsc https://gsc.teeko.ai/mcp` from Claude Code CLI also works (guaranteed path).

---

## 8. Scope boundaries

**In scope:** the `gsc-mcp` committed stack (backend + gateway + dex), build workflow, deploy wiring, registry entry, GitHub secrets/vars, DNS, and the Google-side enablement.

**Out of scope (documented follow-ups):**
- Reconciling the ga4 OAuth gateway drift (`/root/ga4-oauth/`) into the repo.
- Persistent Dex storage (memory storage is intentional, matches ga4).
- Cutover of the legacy authless `ga4.teeko.ai` backend.
