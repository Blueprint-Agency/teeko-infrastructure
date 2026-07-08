# Design: Unify & harden the GSC / GA4 MCP OAuth gateways

**Date:** 2026-07-08
**VPS:** bp-vps3-prod
**Status:** approved (pending spec review)

## Problem

Two MCP servers on VPS3 sit behind self-hosted OAuth (hyprmcp gateway + Dex IdP) so
they can be added as claude.ai web custom connectors:

- **GSC** (`gsc.teeko.ai`) — managed in repo (`vps/vps3-prod/stacks/gsc-mcp/`), deployed by CI.
- **GA4** — a hand-built, **uncommitted** "DEBUG" stack living only on the server at
  `/root/ga4-oauth/` (compose project `ga4-oauth`), published on `ga4gw.teeko.ai`. The
  original `ga4.teeko.ai` still serves the old **authless** secret-path endpoint
  (`/servers/<token>/mcp`).

Three defects:

1. **Frequent forced logouts.** Both Dex instances use `storage: type: memory`. On every
   container restart (redeploy, reboot, `compose up`) Dex regenerates its signing keys and
   drops all issued tokens, so every prior login becomes invalid → re-authenticate. This —
   not token TTL — is the primary cause.
2. **Divergent credentials.** GSC logs in as `askblueprintagency@gmail.com`; GA4 as
   `admin@teeko.ai`, with different password hashes.
3. **Config drift / fragility.** The entire GA4 gateway exists only on the server. One
   `docker system prune` or a VPS rebuild loses it with no source of truth. The leftover
   authless `ga4.teeko.ai` endpoint is also an open door.

## Goals

- Single shared login for **both** gateways: `askblueprintagency@gmail.com` + one shared password.
- Sessions that effectively never expire and **survive container restarts**.
- GA4 gateway committed to the repo and managed by CI, mirroring GSC.
- Remove the authless `ga4.teeko.ai` endpoint.

Non-goals: changing the GSC MCP backend, the Google service accounts, or anything on VPS1/VPS2.

## Design

### 1. Fold the GA4 gateway into the `ga4-mcp` stack (mirror GSC)

Restructure `vps/vps3-prod/stacks/ga4-mcp/docker-compose.yml` to match `gsc-mcp` exactly:

- Add `ga4-dex` (Dex IdP) and `ga4-gateway` (hyprmcp gateway) services.
- `ga4-gateway` becomes the **sole public route on `ga4.teeko.ai`** (Traefik priority 1),
  with the Dex OAuth paths on a priority-100 router — identical label set to `gsc-mcp`,
  host swapped to `ga4.${BASE_DOMAIN}`.
- `ga4-mcp` loses **all** public Traefik labels (incl. the `/status` deny router) and
  becomes internal-only, reached by the gateway at
  `http://ga4-mcp:8080/servers/${GA4_MCP_PATH_TOKEN}/mcp/`.
- Commit template `dex-config.yaml` / `gateway-config.yaml` with `@@PLACEHOLDER@@` markers,
  same convention as `gsc-mcp`.

After deploy verifies healthy, delete the live debug stack:
`cd /root/ga4-oauth && docker compose down && rm -rf /root/ga4-oauth`.

### 2. Unify credentials via shared GitHub identifiers

Replace the per-service `GSC_DEX_ADMIN_EMAIL` (var) / `GSC_DEX_ADMIN_HASH` (secret) with a
single shared pair in the **vps3-prod** environment, consumed by both render steps:

- Variable `MCP_DEX_ADMIN_EMAIL = askblueprintagency@gmail.com`
- Secret `MCP_DEX_ADMIN_HASH = bcrypt("<shared password, provided out-of-band>")`

One source → the two gateways cannot drift apart. The plaintext password is **not** stored
in the repo or this spec; only the bcrypt hash lives in the GitHub secret. `deploy-infra.yml`
renders both `dex-config.yaml` files from these values (GA4 gets a new render block copied
from the GSC one). Old `GSC_DEX_ADMIN_*` identifiers are removed after migration.

### 3. Persistent Dex storage + long expiry (both gateways)

In both `dex-config.yaml` templates:

```yaml
storage:
  type: sqlite3
  config:
    file: /var/dex/dex.db
expiry:
  idTokens: "8760h"          # 1 year
  refreshTokens:
    disableRotation: true
    validIfNotUsedFor: "87600h"   # 10 years
    absoluteLifetime: "87600h"    # 10 years
```

Add a named volume per stack (e.g. `gsc-dex-data` / `ga4-dex-data`) mounted at `/var/dex`,
and confirm the dex container can write to it (adjust user/permissions in the plan if the
image runs non-root). Persistent storage keeps signing keys stable across restarts — the
core fix. Long expiry is defense-in-depth so tokens don't age out between restarts.

## Deploy flow & blast radius

- Change is `vps/vps3-prod/**` only → triggers `deploy-vps3` job. GSC and GA4 both redeploy.
- **GSC:** URL unchanged (`gsc.teeko.ai/mcp`). One final re-login (memory→sqlite migration
  invalidates the current in-memory session). Stays logged in thereafter.
- **GA4:** connector URL **changes** `ga4gw.teeko.ai/mcp` → `ga4.teeko.ai/mcp`. User must
  remove & re-add the GA4 connector in claude.ai and log in once.
- First deploy after the switch drops both existing sessions (expected, one-time).

## Verification

1. `ssh bp-vps3-prod "docker ps"` → `gsc-dex/gsc-gateway/gsc-mcp` + `ga4-dex/ga4-gateway/ga4-mcp` all healthy; no `ga4-oauth` project remains.
2. `curl -s https://ga4.teeko.ai/.well-known/openid-configuration` → issuer `https://ga4.teeko.ai`.
3. Old authless endpoint gone: `curl https://ga4.teeko.ai/servers/<token>/mcp` → 401/unauthorized (gateway-enforced), not a raw MCP response.
4. Add both connectors in claude.ai, log in with the shared creds, confirm tools list loads.
5. Restart dex (`docker compose restart ga4-dex gsc-dex`) → existing claude.ai sessions stay valid (no re-login). This is the real regression test for the logout fix.

## Rollback

Configs are rendered from secrets at deploy; revert the commit and re-run to restore prior
templates. Dex sqlite volumes can be wiped to force a clean re-issue. The `/root/ga4-oauth`
debug stack is only deleted **after** the committed GA4 gateway is verified healthy, so it
remains as a fallback during the transition.

## Open items for the plan

- Exact bcrypt variant/cost for the hash (Dex accepts `$2a`/`$2y`, cost 10).
- Whether hyprmcp/dex `2.44.0-alpine` runs as root or a fixed UID (affects volume perms).
- Confirm the claude.ai connector actually requests `offline_access` (refresh token) so the
  long refresh lifetime is exercised; if not, `idTokens` lifetime governs and may need raising.
