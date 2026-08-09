# Infrastructure Repository

Central infrastructure-as-code repo. Manages all VPS, Docker deployments, CI/CD, monitoring, and GitHub org.

## Credentials Rule

**All credentials live in `.env` only.** Never hardcode tokens or passwords anywhere else. `.env` is gitignored. Use `.env.example` as the template.

## Two Accounts — Read This First

**Only Cloudflare and Hostinger are split.** Everything else is single-tenant. Verified 2026-08-09.

| | Teeko | Blueprint |
|---|---|---|
| Cloudflare account | `Teekoaitech@gmail.com` | `Askblueprintagency@gmail.com` |
| Zones | teeko.ai | kaiteki.my, blueprintdigital.my, reservetoday.app |
| Hostinger account | ⚠️ unknown — see below | holds bpvps1 + bpvps2 |
| Hosts | vps1-staging, vps2-prod, vps3-prod | bpvps1, bpvps2 |
| CI (`deploy-infra.yml`) | automated | **not** automated — deploy by hand |

Shared across both, with **no** per-account split:

| | Single tenant |
|---|---|
| GitHub | one org, `Blueprint-Agency` |
| Vercel | one team, `askblueprintagency-7138s-projects` — holds `teeko-ehailing-*` **and** `booking-system-*`, `blueprint-marketing-website`, `vatti-web`, `persistence-chiro` |
| Tailscale | one tailnet, `taild19da3.ts.net` — all 5 VPS are members |

**MCP servers carry a `-<account>` suffix only where a split actually exists** (Cloudflare,
Hostinger). `vercel` has no suffix on purpose — suffixing it would imply a boundary that isn't
there. There is deliberately no generic `cloudflare` server; picking one forces you to pick a side.

> ⚠️ The GitHub PAT can also see **`Inquantum-AI`** — a different client's org. Same hazard as the
> bare `vps1-staging` / `vps2-prod` SSH aliases. Check the org name before any write via the REST API.

## MCP Servers

| Server | Account | Purpose |
|--------|---------|---------|
| `cloudflare-teeko` | Teeko | DNS + zones for teeko.ai |
| `n8n-teeko` | Teeko | List/search/execute/create/edit n8n workflows (n8n.teeko.ai) |
| `cloudflare-blueprint` | Blueprint | DNS + zones for kaiteki.my, blueprintdigital.my, reservetoday.app |
| `hostinger-vps-blueprint` | Blueprint | VPS firewall, snapshots, reboot/rebuild, metrics, PTR — bpvps1 + bpvps2 |
| `hostinger-billing-blueprint` | Blueprint | Subscriptions + renewal dates for the two KVM plans |
| `vercel` | both | Projects, deployments, logs, env vars, domains |

**Deliberately not MCP servers** — each was evaluated and rejected:

| | Why not |
|---|---|
| GitHub | `curl` + REST API with the `.env` PAT already covers repos, secrets, environments. An MCP adds ~90 tools to replace ~4 calls. No `gh` CLI installed either. |
| Tailscale | No official server exists; the community ones are unsupported (one is reverse-engineered). Joining a host to the tailnet is one `tailscale up --authkey` in a post-install script. |
| `hostinger-{dns,domains,hosting,mail,reach}` | Both accounts own **zero** registered domains and zero hosting/email subscriptions — these servers would manage nothing. DNS is Cloudflare, mail is self-hosted Stalwart. |

Config in `.mcp.json` (gitignored — contains tokens). Use `.mcp.json.example` as template.

`hostinger-api-mcp` ships one binary per product area — always use the scoped binary, never the
unified `hostinger-api-mcp` (314 tools). Add an area only when that account owns resources of that
type; verify first with a curl against the matching endpoint rather than assuming.

> ⚠️ **VPS1/2/3 are in no Hostinger account we hold a token for — parked, not solved.** Verified
> 2026-08-09: the Teeko token authenticates fine (`/vps/v1/data-centers` returns 9; a bogus token
> 401s) but `/vps/v1/virtual-machines`, `/domains/v1/portfolio` and `/billing/v1/subscriptions` all
> return **empty**. The Blueprint token sees only bpvps1 + bpvps2. So `72.61.114.7`,
> `72.60.235.226`, `72.62.74.77` live under a **third login**. The token is parked in `.env` as
> `HOSTINGER_TEEKO_API_TOKEN`; **no `hostinger-*-teeko` server is configured**, because one would
> answer "VPS not found" instead of failing loudly. VPS1/2/3 firewalls and snapshots stay
> hPanel-only until the right account is found.

**GitHub**: use `git` (bash) for repo operations and `curl` + GitHub REST API for org/repo
management, secrets, and environments. PAT in `.env` as `GITHUB_PERSONAL_ACCESS_TOKEN`.
No GitHub MCP and no `gh` CLI installed — don't reach for either.

**VPS/Docker**: use `ssh bp-vps1-staging` / `ssh bp-vps2-prod` / `ssh bp-vps3-prod` directly.
The Hostinger MCP does **not** replace SSH — it is the hypervisor control plane (power, firewall,
snapshots), and cannot see inside the VM. Anything about containers, files, logs, or `docker
compose` is still SSH.

## VPS Access

| Alias | Role | Specs |
|-------|------|-------|
| `bp-vps1-staging` | Staging | 2 vCPU / 8GB / 100GB |
| `bp-vps2-prod` | Production | 4 vCPU / 16GB / 200GB |
| `bp-vps3-prod` | Production | 4 vCPU / 16GB / 200GB |
| `bp-bpvps1` | Kaiteki (legacy + revamp) | 187.127.122.41 |
| `bp-bpvps2` | Booking-system | 187.127.207.82 |

SSH key: `~/.ssh/infra_ed25519`. All hosts log in as **`deploy`**, not root — `deploy` is in the `docker` group and owns `/root/stacks`. Hosts defined in `~/.ssh/config`.

> `deploy` has **no sudo** — only `docker` group membership. Root login is still permitted on purpose:
> it is the break-glass path for anything daemon-level, including the Docker 29.x systemd drop-in
> below. Don't set `PermitRootLogin no` without granting `deploy` sudo first, or that fix becomes
> unappliable. (VPS1/2/3 `deploy` accounts got the `chriskke-infra` key on 2026-08-09; before that
> only the CI key was authorized and interactive logins went in as root.)

> ⚠️ **Always use the `bp-` prefix.** The bare aliases `vps1-staging` / `vps2-prod` in `~/.ssh/config` belong to a **different client (Inquantum AI)** on a different key — operating on them by mistake hits the wrong company's servers. There is no bare `vps3-prod`.

> ⚠️ **`bp-bpvps2` is NOT `bp-vps2-prod`.** One is the booking-system host; the other is live teeko.ai production. They differ by two characters. Re-read the alias before any `docker compose down`, volume removal, or `psql` write.

## What's Running

**VPS1 — Staging**: `traefik`, `website` (staging.teeko.ai), `n8n` (stagingn8n.teeko.ai), `tools` (drizzle-gateway at stagingpg.teeko.ai)

**VPS2 — Production**: `traefik`, `website` (teeko.ai), `tools` (drizzle-gateway at pg.teeko.ai)

**VPS3 — Production**: `traefik`, `n8n` (n8n.teeko.ai), `tools` (drizzle-gateway at pg3.teeko.ai), `ga4-mcp`, `gsc-mcp`, `ehailing`

> The `n8n` stack on VPS3 carries **three** containers, not two: `n8n-prod`, `n8n-db`, and
> `waba-db` (service `db-waba`, `postgres:alpine`). `waba-db` is a separate database that happens to
> live in the n8n compose — don't read it as an orphan and prune it.

**BPVPS1 — Kaiteki**: `traefik`, `kaiteki`, `kaiteki-staging`, `stalwart` (+`bulwark`), `wordpress` (+`wp-db`)

**BPVPS2 — Booking**: `traefik`, `booking-staging` (bookingapi.teeko.ai — carries the real data), `booking-prod` (prodbookingapi.teeko.ai — fresh). Both from one parameterized compose in `vps/bpvps2/stacks/booking/`, deployed to two dirs; `ENV_NAME` keys the container names, volume, network and Traefik router so they can't collide.

> **Portainer and pgAdmin are gone** (removed 2026-07-21) — no container UI at all. Use `ssh bp-vps<n>-*` + `docker` directly. Postgres is managed via drizzle-gateway, now on all 3 Teeko VPS (`stagingpg` / `pg` / `pg3`.teeko.ai), all sharing the `GATEWAY_MASTERPASS` secret.

> **ga4-mcp / gsc-mcp stacks**: each is 3 containers (`*-mcp` backend, `*-gateway` OAuth 2.1 front, `*-dex` IdP) and **all three are required** to serve `https://ga4.teeko.ai/mcp` and `https://gsc.teeko.ai/mcp`. None are redundant — do not prune them.

## Architecture

- 5 Hostinger VPS across two accounts, Docker Compose, no Kubernetes
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

`.github/workflows/deploy-infra.yml` deploys **all five hosts** from one matrix job (was three
copy-pasted ~120-line jobs). `vps/hosts.json` is the source of truth:

| Field | Meaning |
|---|---|
| `key` | also the GitHub Environment name |
| `dir` | repo path, e.g. `vps/bpvps1` |
| `env_name` | host default, written as `ENV_NAME` into each stack's `.env` |
| `exclude` | stacks CI must never touch |
| `app_stacks` | compose is rsynced, but `docker compose up` belongs to the app's own repo |
| `fanout` | one repo stack → several host dirs, **each with its own `env_name`** |

**Adding a host**: one entry in `vps/hosts.json` + a GitHub Environment named after its `key`,
containing at minimum `TAILSCALE_HOST`. Helper scripts: `vps/shared/select-hosts.py` (diff → hosts),
`vps/shared/expand-targets.py` (stack → `dir|env_name|stack`), `vps/shared/render-ci.py`
(stack `ci/` templates → rendered files), `vps/shared/snapshot-host.sh` (before/after docker state,
for verifying a deploy changed only what you expected).

### Per-stack secrets live in `ci/`, never in the workflow

**`deploy-infra.yml` knows nothing about any individual stack.** A stack that needs generated files
carries them itself, in `vps/<host>/stacks/<stack>/ci/`, as templates with `@@MARKER@@` placeholders.
`render-ci.py` fills each marker from the same-named env var in the deploy step and rsyncs the result.

| Path under `ci/` | Lands on the host as | Notes |
|---|---|---|
| `.env.n8n`, `gateway-config.yaml`, … | `/root/stacks/<dir>/<same path>` | overwritten every deploy |
| `credentials/sa-key.json` | `/root/stacks/<dir>/credentials/sa-key.json` | subdirs are preserved |
| `env.ci` | merged **into** `.env` | for keys the stack's own compose interpolates |
| `post-sync.sh` | run in the stack dir before `docker compose up` | the `mkdir`/`chmod`/`chown` a stack needs |

**Adding a stack that needs a secret**: add the template under `ci/`, add the secret to the deploy
step's `env:` block, add it to the host's GitHub Environment. Never add a branch to the workflow.

> An unset or empty marker **fails the deploy**. This is deliberate: a blank secret is not a smaller
> failure than a missing file — it is a Dex with no admin password that starts happily and serves
> 401s, or a Postgres that initialises a brand new empty database. `render-ci.py` names the variable
> and the file and exits 1. `vps/shared/test_render_ci.py` covers this and runs as a CI step.

> Until 2026-08-09 all of this was a `case $stack in` block plus ~30 `printf | base64` lines inside
> the workflow's remote-shell string. That coupling is why `stalwart` was excluded ("no CI case
> arm") and why `.env.db-waba` is still host-only — onboarding a stack meant editing YAML-inside-
> shell-inside-ssh. The rendered output is byte-identical to what that block produced.

> **`.env` is MERGED, not replaced.** CI-owned keys (`BASE_DOMAIN`, `ACME_EMAIL`,
> `CF_DNS_API_TOKEN`, `TRAEFIK_DASHBOARD_AUTH`, `ENV_NAME`, plus whatever the stack's own `ci/env.ci`
> contributes) win; every other line, comments included, is preserved. This is what lets stacks keep
> host-managed values such as booking's `BOOKING_HOST`/`IMAGE_TAG`. Before 2026-08-09 it overwrote
> the file wholesale.

> `GA4_MCP_PATH_TOKEN` left the host-wide key list on 2026-08-09 and moved to
> `ga4-mcp/ci/env.ci`, where it belongs — only ga4-mcp's compose reads it, but it was previously
> written into **every** stack's `.env` on **every** host. Stale copies still sit in other stacks'
> `.env` files; they are inert, and the merge no longer refreshes them.

> **`env_name` is per fanout destination, not per host.** bpvps2 deploys one `booking` compose into
> `booking-staging` and `booking-prod`. A host-level `ENV_NAME` would give both `prod`, making
> booking-**staging** resolve to booking-prod's container, volume and network — on the instance that
> holds the real data.

### ⚠️ Org-level vars are consumed by OTHER repos — check before deleting one

`deploy-infra.yml` reads only `vars.TAILSCALE_HOST` (per-Environment). Every `VPS*_HOST` /
`*_TAILSCALE_HOST` org variable exists for a **different repo's** deploy workflow:

| Org variable | Consumed by |
|---|---|
| `VPS1_HOST`, `VPS2_HOST` | `teeko-website` → `be-deploy.yml`, `fe-deploy.yml` |
| `VPS3_HOST`, `VPS3_TAILSCALE_HOST` | `teeko-ehailing` → `deploy-backend.yml` |
| `BPVPS1`, `BPVPS1_TAILSCALE_HOST` | `kaiteki-web` → `deploy-prod.yml`, `deploy-staging.yml` |
| `BPVPS2_TAILSCALE_HOST` | `booking-system` → `deploy-be.yml` |
| `VPS1_TAILSCALE_HOST`, `VPS2_TAILSCALE_HOST`, `BPVPS2` | nothing today — keep; they are what teeko-website needs when it migrates off public IPs |

> **The GitHub code-search API does not index these workflow files.** A `/search/code?q=VPS1_HOST`
> returns `total_count: 0` for names that are demonstrably in use. On 2026-08-09 that false
> negative got `VPS1_HOST` deleted, which would have broken both teeko-website deploys; it was
> restored to `72.61.114.7`. **Verify by reading `.github/workflows/` from each repo's contents
> API**, never by code search.

> **All five deploy paths now reach the VPS over Tailscale.** `teeko-website` was the last holdout
> — `be-deploy.yml`/`fe-deploy.yml` SSH'd to `VPS1_HOST`/`VPS2_HOST` public IPs, which is why port 22
> had to stay open. Migrated to `VPS{1,2}_TAILSCALE_HOST` + `tailscale/github-action` on 2026-08-09
> (both `main` and `staging` branches) and verified by dispatching both workflows against VPS1.
> `VPS1_HOST`/`VPS2_HOST` are now unreferenced but **kept until a production (`main`) deploy has
> actually run over the tailnet** — only the staging path is proven so far.

> **Seven secrets referenced by app workflows do not exist anywhere** (checked repo-level, and every
> environment, as both secret and variable). These predate the 2026-08-09 CI work and are unrelated
> to it, but each one is silently written as an empty value into the app's `.env`:
> `booking-system` → `R2_ACCESS_KEY_ID`, `R2_ACCOUNT_ID`, `R2_BUCKET_NAME`, `R2_PUBLIC_URL`,
> `R2_SECRET_ACCESS_KEY` (object storage — uploads);
> `teeko-ehailing` → `CLERK_DRIVER_WEBHOOK_SIGNING_SECRET`, `CLERK_RIDER_WEBHOOK_SIGNING_SECRET`
> (webhook signature verification).

**App repo deploys are compatible with the `.env` merge** — no changes needed there.
`booking-system` rewrites its keys idempotently (`sed -i "/^${k}=/d"` then append), which is the
same key-level merge CI does, so neither clobbers the other. `ehailing` and `kaiteki-web` write
only their own `.env.*` files, which CI's rsync excludes.

**Currently excluded from CI, and why:**

| Host | Excluded | Reason |
|---|---|---|
| bpvps1 | `stalwart`, `traefik`, `wordpress` | dirs are `root:root`; CI connects as `deploy` and rsync fails |
| bpvps2 | `stalwart` | hand-managed mail secrets; now onboardable via `ci/` — needs the secrets adding to the Environment first |
| VPS1, VPS2 | `website` | deployed by their own repo's CI |

> A stack dir must be owned by **`deploy`** for CI to deploy it. `vps1-staging/tools` was `root:root`
> until 2026-08-09 and silently failed at rsync; it was chowned. Check ownership before onboarding.

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
> ⚠️ **The `hostinger-vps` MCP token only covers bpvps1 + bpvps2.** The teeko.ai VPS1/2/3 live in a
> **different Hostinger account** — their firewalls are still hPanel-only until a token is generated
> there too. Verified 2026-08-09: `GET /vps/v1/virtual-machines` returns exactly those two hosts.

For bpvps1/bpvps2: both share **one** firewall group, `319466` ("default") — editing it hits *both*
hosts. Rules are per-group and must be re-synced onto each VPS after editing; check `is_synced`,
because an edited-but-unsynced group silently keeps the old rules.
Current 319466 rules: **25, 80, 443, 465, 587, 993, 995** `accept TCP` from any, plus **22**
`accept TCP` from **`100.64.0.0/10` only** (the Tailscale CGNAT range) as of 2026-08-09.

**Port 22 on bpvps1 + bpvps2 is closed to the internet as of 2026-08-09.** Rule 22 was
**restricted rather than deleted** — reversible, self-documenting, and the tailnet source keeps a
way in without recreating a rule. Verified after sync: TCP 22 refused on both public IPs, SSH over
`100.x` working, 443 and all mail ports unaffected, kaiteki + booking serving 200.

> Syncing **one** VM applied the group to **both** — expected, since 319466 is shared. The sync
> action sits in state `started` for ~100s before `success`; the rules do **not** take effect until
> then. Poll `/virtual-machines/<id>/actions/<actionId>` rather than trusting the group's
> `is_synced` flag, which flips to `true` while the action is still running.

> Testing ports from a laptop is unreliable: home ISPs block outbound **25**, so it reads BLOCKED
> even when open. Test server-to-server (`ssh bp-vps3-prod` → `/dev/tcp/<ip>/<port>`). Port **587**
> reads BLOCKED because nothing listens on it, not because of the firewall.

> ⚠️ **bpvps1 and bpvps2 are user-owned Tailscale nodes, not tagged, so their keys EXPIRE** —
> bpvps1 `2026-12-23`, bpvps2 `2027-01-17`. When a key expires the node leaves the tailnet; with 22
> restricted to the tailnet that means no SSH at all, recoverable only via Hostinger's browser
> console. Fix once in the Tailscale admin console: **Machines → ⋯ → Disable key expiry** on both.
> (VPS1/2/3 are `tag:ci` tagged devices and do not expire.) There is no Tailscale API token in
> `.env`, so this cannot be scripted.

**VPS1 (staging):** Open **22**, **80**, **443**

**VPS2 + VPS3 (prod):** Open **22**, **80**, **443**. Port **9001** (portainer-agent) is no longer needed — close it.

Close everything else — especially 3000, 5432, 5678, 8080, 9090 (all accessed via Traefik only)

### Docker 29.x breaks Traefik's Docker provider — fix differs per VPS
Docker 29.x raises `MinAPIVersion` above 1.24. Traefik v3.3 **hardcodes** Docker API 1.24 and
ignores `DOCKER_API_VERSION`, so the daemon rejects it and Traefik loads **zero routes** — every
domain on that host 404s while the containers stay healthy. The fix is always daemon-side, but
the unit path depends on how Docker was installed:

| VPS | Docker install | systemd unit | Drop-in path |
|-----|----------------|--------------|--------------|
| VPS2, VPS3 | apt `docker-ce` | `docker.service` | `/etc/systemd/system/docker.service.d/min-api.conf` |
| **VPS1** | **snap** (`canonical/docker`) | **`snap.docker.dockerd.service`** | **`/etc/systemd/system/snap.docker.dockerd.service.d/min-api.conf`** |

Contents either way: `[Service]` + `Environment="DOCKER_MIN_API_VERSION=1.24"`, then
`systemctl daemon-reload && systemctl restart <unit>` (restarts all containers on that host).

> ⚠️ VPS1 runs the **snap** Docker — there is no `docker.service` there. A drop-in under
> `docker.service.d/` is silently inert. This is exactly how VPS1 sat fully 404 from
> 2026-05-10 to 2026-07-21. Verify with `systemctl list-units '*docker*'` before assuming
> the unit name. Must reapply if Docker is reinstalled.

### Shared Scripts
`vps/shared/` — `select-hosts.py`, `expand-targets.py`, `render-ci.py`, `test_render_ci.py`,
`snapshot-host.sh`, `setup-vps.sh`.
`scripts/backup.sh <bp-alias>` tars every named volume on that host into `/home/deploy/backups/`.

> `deploy.sh` and `healthcheck.sh` were **deleted 2026-08-09** — both `cd`'d into `vps/<host>/`,
> which holds no compose file, and ran `docker compose` on your laptop rather than the VPS. They
> also named aliases (`prod-vps2`) that never existed. Deploy is `deploy-infra.yml`; health is
> `snapshot-host.sh`.
