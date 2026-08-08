# Deploy Workflow Matrix Refactor + n8n Convergence

**Date:** 2026-08-09
**Status:** Approved, not yet implemented
**Scope:** Project A of two. Project B (the "provision a new app" skill) is specced separately and depends on this.

## Problem

`.github/workflows/deploy-infra.yml` is 498 lines: three near-identical jobs (`deploy-vps1` L49,
`deploy-vps2` L186, `deploy-vps3` L298) of ~120 lines each. Adding a host means copy-pasting a
fourth block; fixing a bug means applying it three times.

Two consequences:

1. **bpvps1 and bpvps2 have no CI at all.** `on.push.paths` lists only the three Teeko host
   directories, so Blueprint-account hosts are deployed by hand.
2. **A provision skill cannot add a host.** Any skill that provisions a new app onto a new host
   would have to generate a 120-line YAML block, which is not something to automate.

A second, related problem: the same app deployed to two environments is modelled inconsistently.
`n8n` uses distinct service/container/env-file names per host (`n8n-dev` vs `n8n-prod`,
`.env.n8n-dev` vs `.env.n8n-prod`), which is precisely what forces per-host special-casing inside
the deploy step. The `booking` stack on bpvps2 already solves this correctly.

## Approach

Collapse the three jobs into one matrix job, and converge `n8n` onto the `ENV_NAME` pattern that
`booking` already proves. These are one piece of work: the convergence is what makes the matrix
clean, and a matrix over divergent stacks just relocates the special-casing into matrix parameters.

Rejected alternatives:

- **Reusable workflow (`workflow_call`)** — clean boundary, but five call blocks remain, so adding
  a host stays a multi-line edit.
- **Composite action** — smallest blast radius, but keeps the per-host job/`if`/`detect` structure
  that is the actual problem.
- **Matrix only, leave n8n alone** — carries the env-file divergence forward as a matrix parameter
  and leaves VPS1's unpinned Postgres in place.

## Design

### 1. Host model

`vps/hosts.json` becomes the single source of truth, read by the workflow and later by the
provision skill:

```json
[{"key":"vps1-staging","dir":"vps/vps1-staging","env_name":"dev","exclude":"website","app_stacks":""},
 {"key":"vps2-prod","dir":"vps/vps2-prod","env_name":"prod","exclude":"website","app_stacks":""},
 {"key":"vps3-prod","dir":"vps/vps3-prod","env_name":"prod","exclude":"","app_stacks":"booking-system ehailing"},
 {"key":"bpvps1","dir":"vps/bpvps1","env_name":"prod","exclude":"","app_stacks":""},
 {"key":"bpvps2","dir":"vps/bpvps2","env_name":"prod","exclude":"","app_stacks":"booking-staging booking-prod",
  "fanout":{"booking":["booking-staging","booking-prod"]}}]
```

`key` doubles as the GitHub Environment name. The three existing Environments
(`vps1-staging`, `vps2-prod`, `vps3-prod`) already match this naming, so no renaming is required
for Teeko hosts.

`app_stacks` lists stacks whose compose file is rsynced but whose `docker compose up` is owned by
the application's own repository workflow. The deploy step skips `up` for these.

### 2. detect job

Replaces three boolean outputs with one JSON array. It diffs the push range (same
`github.event.before` handling as today, including the all-zeroes first-push case), maps changed
paths to host `dir` values from `hosts.json`, and emits the matching host objects.

`on.push.paths` widens to include `vps/bpvps1/**` and `vps/bpvps2/**`.

### 3. deploy job

One job, `strategy.matrix.host: ${{ fromJSON(needs.detect.outputs.hosts) }}`, with
`environment: ${{ matrix.host.key }}`. Steps are today's steps with `vps/vps1-staging` replaced by
`${{ matrix.host.dir }}` and the per-host var replaced by `vars.TAILSCALE_HOST`.

The `case $stack` dispatch becomes the **union** of all existing arms (`n8n`, `tools`, `ga4-mcp`,
`gsc-mcp`). This is safe because an arm only executes for a stack actually being deployed, and a
secret absent from an Environment resolves to an empty string rather than failing the job — so
VPS2 carrying unused `GA4_*` references is inert.

### 4. Per-environment variables

`VPS1_TAILSCALE_HOST` / `VPS2_TAILSCALE_HOST` / `VPS3_TAILSCALE_HOST` collapse to a single
`TAILSCALE_HOST` variable defined **inside each Environment**, which is what makes dynamic
resolution possible — GitHub Actions cannot index `vars` by a computed name.

Migration ordering is load-bearing: **add `TAILSCALE_HOST` to each Environment while the old
variables still exist**, merge the new workflow, confirm green, then delete the old variables.
Renaming first breaks the current workflow immediately.

New Environments `bpvps1` and `bpvps2` need: `TAILSCALE_HOST`, `SSH_PRIVATE_KEY`, `BASE_DOMAIN`,
`ACME_EMAIL`, `TRAEFIK_DASHBOARD_AUTH`, `CF_DNS_API_TOKEN`, plus `TS_OAUTH_CLIENT_ID` /
`TS_OAUTH_SECRET` if those are not already org-level.

> **bpvps2's `CF_DNS_API_TOKEN` must be the Teeko account token, not the Blueprint one.**
> bpvps2's Traefik performs DNS-01 for `bookingapi.teeko.ai` and `prodbookingapi.teeko.ai`, which
> live in the Teeko Cloudflare zone. The `blueprintdigital.my` certificate arrives separately via
> the file provider (acme.sh + `KAITEKI_CF_DNS_API_TOKEN` in the stalwart stack). Using the
> Blueprint token here would break booking's certificates.

### 5. n8n convergence

Both hosts adopt the `booking` shape, with `ENV_NAME` supplied by each stack's `.env`:

| | Before (VPS1 / VPS3) | After (both) |
|---|---|---|
| container | `n8n-dev` / `n8n-prod` | `n8n-${ENV_NAME}` |
| env file | `.env.n8n-dev` / `.env.n8n-prod` | `.env.n8n` |
| postgres | `postgres:alpine` / `postgres:18-alpine` | `postgres:18-alpine` on both |
| healthcheck | none | on n8n and db, with `compose up -d --wait` |

`ENV_NAME=dev` on VPS1 and `ENV_NAME=prod` on VPS3 reproduce the existing container names exactly,
so nothing is renamed at the Docker level. `db-waba` remains VPS3-only.

Pinning VPS1's Postgres is a correctness fix, not tidying: with `pull_policy: always` and a
floating `postgres:alpine` tag, a deploy can pull a new major version that refuses to start against
the existing data directory.

Adding healthchecks plus `--wait` changes CI from "reported success because `compose up` returned"
to "reported success because the container is actually healthy".

### 6. bpvps2's one-to-many stack mapping

Every other host maps repo stack dir → host stack dir 1:1, which is what the existing
`rsync vps/<dir>/stacks/ → /root/stacks/` assumes. **bpvps2 does not.** The repo holds a single
`vps/bpvps2/stacks/booking/`, deployed on the host as *two* directories, `/root/stacks/booking-staging`
and `/root/stacks/booking-prod`, distinguished only by `ENV_NAME` in each one's `.env`.

A naive rsync would create `/root/stacks/booking` — a third, unwanted stack — and leave the two
real ones untouched.

Resolution: `hosts.json` gains an optional `fanout` map for this case:

```json
{"key":"bpvps2", "dir":"vps/bpvps2", "fanout": {"booking": ["booking-staging","booking-prod"]}}
```

The sync step rsyncs a `fanout` source into each listed destination instead of its own name. This
keeps the "one compose, deployed twice" property that makes the booking stack the pattern worth
copying, rather than duplicating the file in the repo to satisfy the tooling.

The two booking dirs also stay in `app_stacks`: their `.env.*` files and `docker compose up` are
owned by the booking-system repository's own workflow, so infra CI syncs the compose and stops.

### 7. Data-loss hazard

**Volume names must be read from the hosts, not guessed.** If the converged compose declares a
volume name that differs from what exists on disk, n8n and Postgres start against fresh empty
volumes and the old data is orphaned — a silent, total loss of n8n workflow history.

The first implementation step is therefore `docker volume ls` on VPS1 and VPS3, recording the exact
current names for the n8n data volume, `n8n-db`, and `waba-db`. The compose is then pinned to those
names via explicit `name:` keys. No `${ENV_NAME}` interpolation in volume names unless it
reproduces the existing string exactly.

### 8. Verification

Per host, in this order — staging first, and VPS2/VPS3 only after VPS1 is confirmed:

1. Record `docker ps --format '{{.Names}}'` and `docker volume ls` before.
2. Push a no-op change under the host's stack dir; confirm the matrix job fires for exactly that host.
3. Compare `docker ps` and `docker volume ls` after — container names identical, volume names
   identical, no new anonymous volumes.
4. For n8n specifically: confirm the editor loads and existing workflows are present.

Rollback is `git revert` of the merge commit; the workflow re-runs and restores the previous state.

## Out of scope

- The provision skill itself (Project B).
- Purchasing a new VPS.
- The missing Teeko Hostinger account — VPS1/2/3 firewalls stay hPanel-only.
- The Tailscale auth key needed for unattended host provisioning.
- `vps/vps3-prod/stacks/gsc-mcp;W/`, a repo-only directory absent from the host.

## Success criteria

- `deploy-infra.yml` under ~200 lines with one deploy job.
- All five hosts deploy through CI; bpvps1 and bpvps2 no longer require manual deploys.
- Adding a sixth host is one entry in `vps/hosts.json` plus one GitHub Environment.
- No container or volume renamed; no data lost.
