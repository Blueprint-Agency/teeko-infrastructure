# Deploy Matrix Refactor + n8n Convergence — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Collapse `.github/workflows/deploy-infra.yml` from three ~120-line per-host jobs into one matrix job driven by `vps/hosts.json`, converge the `n8n` stack onto the `ENV_NAME` pattern, and bring bpvps1 + bpvps2 under CI.

**Architecture:** A `detect` job diffs the push, maps changed paths to host entries in `vps/hosts.json`, and emits a JSON array. One `deploy` job fans out over that array via `strategy.matrix`, resolving per-host values through `matrix.host.*` and through GitHub Environment variables that override org-level ones. Per-stack `.env` generation becomes a single union `case` dispatch, safe because an arm only fires for a stack actually being deployed.

**Tech Stack:** GitHub Actions (matrix, environments, `fromJSON`), Tailscale GitHub Action v4, rsync-over-SSH, Docker Compose v2, Postgres 18, Traefik v3.

## Global Constraints

- **Never rename a Docker volume.** `n8n-data` and `n8n_pgdata` are `external: true` and are named **identically on VPS1 and VPS3**. `waba_pgdata` is compose-managed and resolves to `n8n_waba_pgdata` on VPS3. No `${ENV_NAME}` interpolation in any volume name.
- **Postgres pins to `postgres:18-alpine` on both hosts.** Verified: both `n8n-db` containers run PostgreSQL 18.2 with data dir `/var/lib/postgresql/18`. Pinning to any other major starts incompatible binaries against the existing data dir.
- **Variable precedence is environment > repository > organization.** `BASE_DOMAIN=teeko.ai` and `ACME_EMAIL=teekoaitech@gmail.com` are org-level; per-host differences are expressed as Environment-level overrides, never by editing the org value.
- **`CF_DNS_API_TOKEN` is an org-level secret holding the *Teeko* Cloudflare token.** bpvps2 must keep it (its Traefik does DNS-01 for `bookingapi.teeko.ai`). bpvps1 must override it with the Blueprint token (`kaiteki.my`).
- **`deploy` is the SSH user on all five hosts** and has no sudo. Commands needing root are out of scope for CI.
- Repo is `Blueprint-Agency/teeko-infrastructure`. Commits must not include `Co-Authored-By` lines.
- Work happens on branch `infra/deploy-matrix-refactor`.

## Discovered state (do not re-derive)

Org variables: `ACME_EMAIL`, `BASE_DOMAIN`, `DOCKERHUB_USERNAME`, `VPS{1,2,3}_HOST`, `VPS{1,2,3}_TAILSCALE_HOST`, `BPVPS1`, `BPVPS1_TAILSCALE_HOST=100.94.77.65`, `BPVPS2`, `BPVPS2_TAILSCALE_HOST=100.78.5.2`.

Org secrets: `CF_DNS_API_TOKEN`, `DOCKERHUB_TOKEN`, `SSH_PRIVATE_KEY`, `TS_OAUTH_CLIENT_ID`, `TS_OAUTH_SECRET`.

Environment variables today:
- `vps1-staging`: `N8N_DB_NAME`, `N8N_DB_USER`, `N8N_EDITOR_BASE_URL`, `N8N_WEBHOOK_URL`, `PGADMIN_DEFAULT_EMAIL` (dead)
- `vps2-prod`: `PGADMIN_DEFAULT_EMAIL` (dead)
- `vps3-prod`: `GA4_MCP_PROJECT_ID`, `GSC_DEX_ADMIN_EMAIL`, `MCP_DEX_ADMIN_EMAIL`, `N8N_DB_NAME`, `N8N_DB_USER`, `N8N_EDITOR_BASE_URL`, `N8N_WEBHOOK_URL`

Tailnet IPs: vps1 `100.102.147.30`, vps2 `100.94.86.35`, vps3 `100.73.39.82`, bpvps1 `100.94.77.65`, bpvps2 `100.78.5.2`.

## File Structure

| File | Responsibility |
|---|---|
| `vps/hosts.json` | **Create.** Single source of truth: host key, repo dir, `env_name`, `exclude`, `app_stacks`, optional `fanout`. Read by the workflow and later by the provision skill. |
| `vps/shared/snapshot-host.sh` | **Create.** Prints a stable, diffable snapshot of one host's containers and volumes. This is the test harness for every deploy task. |
| `.github/workflows/deploy-infra.yml` | **Rewrite.** `detect` emits JSON; one matrix `deploy` job replaces three. |
| `vps/vps1-staging/stacks/n8n/docker-compose.yml` | **Modify.** `ENV_NAME` keying, pin Postgres, healthchecks. |
| `vps/vps3-prod/stacks/n8n/docker-compose.yml` | **Modify.** Same shape; keeps `db-waba`. |
| `CLAUDE.md` | **Modify.** Document `hosts.json`, the CI-covers-all-hosts change, and the bpvps1 CF-token override. |

---

### Task 1: Host state snapshot script

The safety net for every later task. Without it, "did anything change?" is eyeballed.

**Files:**
- Create: `vps/shared/snapshot-host.sh`

**Interfaces:**
- Produces: `vps/shared/snapshot-host.sh <ssh-alias>` → stdout, deterministic sorted text. Later tasks diff two invocations.

- [ ] **Step 1: Write the script**

```bash
#!/usr/bin/env bash
# Prints a deterministic snapshot of a host's docker state, for before/after diffing
# around deploys. Sorted so `diff` output means something.
set -euo pipefail
HOST="${1:?usage: snapshot-host.sh <ssh-alias>}"
ssh -o ConnectTimeout=15 -o BatchMode=yes "$HOST" '
  echo "== containers"
  docker ps --format "{{.Names}}\t{{.Image}}\t{{.State}}" | sort
  echo "== volumes"
  docker volume ls --format "{{.Name}}" | sort
  echo "== stacks"
  ls -1 /root/stacks | sort
'
```

- [ ] **Step 2: Make it executable and verify it runs against staging**

Run: `chmod +x vps/shared/snapshot-host.sh && ./vps/shared/snapshot-host.sh bp-vps1-staging`
Expected: three sections; `== containers` lists 7 rows including `n8n-dev`, `n8n-db`, `traefik`; `== volumes` includes `n8n-data` and `n8n_pgdata`.

- [ ] **Step 3: Capture baselines for all five hosts**

```bash
mkdir -p /tmp/snap
for h in bp-vps1-staging bp-vps2-prod bp-vps3-prod bp-bpvps1 bp-bpvps2; do
  ./vps/shared/snapshot-host.sh "$h" > "/tmp/snap/$h.before"
done
wc -l /tmp/snap/*.before
```

Expected: five non-empty files. **Keep `/tmp/snap` for the rest of the plan.**

- [ ] **Step 4: Commit**

```bash
git add vps/shared/snapshot-host.sh
git commit -m "chore: add host snapshot script for deploy verification"
```

---

### Task 2: Pin Postgres on VPS1 and land the pending VPS3 pin

Smallest possible change that exercises the *existing* deploy path end-to-end. Do this before touching the workflow, so a failure here is unambiguously about the stack and not the refactor.

**Files:**
- Modify: `vps/vps1-staging/stacks/n8n/docker-compose.yml:25`
- Modify: `vps/vps3-prod/stacks/n8n/docker-compose.yml` (already edited in the working tree — commit as-is)

**Interfaces:**
- Consumes: nothing.
- Produces: both `db-n8n` services on `postgres:18-alpine`.

- [ ] **Step 1: Pin VPS1's `db-n8n`, matching VPS3's comment**

Replace lines 23-25 of `vps/vps1-staging/stacks/n8n/docker-compose.yml`:

```yaml
  # NOTE: service named 'db-n8n' so n8n-dev can reach it as DB_POSTGRESDB_HOST=db-n8n
  # ⚠️ PIN THE MAJOR. This volume holds a PG18 data dir (PGDATA=/var/lib/postgresql/18/docker
  # — the volume is mounted at the PARENT of PGDATA). `postgres:alpine` floats to the newest
  # stable major, so leaving it unpinned means the day 19 goes stable a `compose up` starts
  # PG19 binaries against a PG18 data dir and the container dies with "database files are
  # incompatible with server". Bumping the major is a deliberate pg_upgrade/dump-restore job.
  db-n8n:
    image: postgres:18-alpine
```

- [ ] **Step 2: Verify the pin matches reality before deploying**

Run: `ssh bp-vps1-staging 'docker exec n8n-db postgres --version'`
Expected: `postgres (PostgreSQL) 18.2`. If this prints any other major, **stop** — the pin must match the running data dir.

- [ ] **Step 3: Commit and push, letting current CI deploy it**

```bash
git add vps/vps1-staging/stacks/n8n/docker-compose.yml vps/vps3-prod/stacks/n8n/docker-compose.yml
git commit -m "fix(n8n): pin postgres to 18-alpine on VPS1 and VPS3

Both data dirs are PG18. A floating postgres:alpine with pull_policy: always
starts PG19 binaries against a PG18 data dir the day 19 goes stable."
git push -u origin infra/deploy-matrix-refactor
```

Note: the workflow triggers on `push` to `main` only, so this push does **not** deploy. Merge to `main` when ready, or run the deploy manually in Step 4.

- [ ] **Step 4: Confirm no drift**

```bash
./vps/shared/snapshot-host.sh bp-vps1-staging > /tmp/snap/bp-vps1-staging.after
diff /tmp/snap/bp-vps1-staging.before /tmp/snap/bp-vps1-staging.after
```

Expected: no output (image column changes only after the stack is actually redeployed).

---

### Task 3: Create `vps/hosts.json`

**Files:**
- Create: `vps/hosts.json`

**Interfaces:**
- Produces: the array consumed by `detect` in Task 4 and by the provision skill later. Field contract: `key` (string, doubles as GitHub Environment name), `dir` (repo path, no trailing slash), `env_name` (`dev`|`prod`, becomes `ENV_NAME`), `exclude` (space-separated stack names skipped entirely), `app_stacks` (space-separated stacks that are rsynced but never `docker compose up`ed by this workflow), `fanout` (optional object mapping one repo stack dir to many host stack dirs).

- [ ] **Step 1: Write the file**

```json
[
  { "key": "vps1-staging", "dir": "vps/vps1-staging", "env_name": "dev",  "exclude": "website", "app_stacks": "" },
  { "key": "vps2-prod",    "dir": "vps/vps2-prod",    "env_name": "prod", "exclude": "website", "app_stacks": "" },
  { "key": "vps3-prod",    "dir": "vps/vps3-prod",    "env_name": "prod", "exclude": "",        "app_stacks": "booking-system ehailing" },
  { "key": "bpvps1",       "dir": "vps/bpvps1",       "env_name": "prod", "exclude": "",        "app_stacks": "" },
  { "key": "bpvps2",       "dir": "vps/bpvps2",       "env_name": "prod", "exclude": "",        "app_stacks": "booking-staging booking-prod",
    "fanout": { "booking": ["booking-staging", "booking-prod"] } }
]
```

- [ ] **Step 2: Validate it parses and every `dir` exists**

```bash
python -c "
import json,os,sys
hosts=json.load(open('vps/hosts.json'))
assert len(hosts)==5, hosts
for h in hosts:
    assert os.path.isdir(h['dir']), f\"missing dir: {h['dir']}\"
    assert os.path.isdir(h['dir']+'/stacks'), f\"missing stacks: {h['dir']}\"
    for src in (h.get('fanout') or {}):
        assert os.path.isdir(f\"{h['dir']}/stacks/{src}\"), f\"fanout source missing: {src}\"
print('hosts.json OK:', ', '.join(h['key'] for h in hosts))
"
```

Expected: `hosts.json OK: vps1-staging, vps2-prod, vps3-prod, bpvps1, bpvps2`

- [ ] **Step 3: Commit**

```bash
git add vps/hosts.json
git commit -m "feat: add vps/hosts.json as the single source of truth for deploy targets"
```

---

### Task 4: Rewrite `detect` to emit a JSON host array

**Files:**
- Modify: `.github/workflows/deploy-infra.yml:16-47` (the `on.push.paths` block and the whole `detect` job)

**Interfaces:**
- Consumes: `vps/hosts.json` from Task 3.
- Produces: `needs.detect.outputs.hosts` — a JSON array of host objects, `[]` when nothing matched. Task 5 consumes it via `fromJSON`.

- [ ] **Step 1: Replace the trigger paths**

```yaml
on:
  push:
    branches: [main]
    paths:
      - 'vps/**'
      - '.github/workflows/deploy-infra.yml'
```

`vps/**` covers all five hosts and future ones without another edit.

- [ ] **Step 2: Replace the `detect` job**

```yaml
jobs:
  detect:
    runs-on: ubuntu-latest
    outputs:
      hosts: ${{ steps.out.outputs.hosts }}
    steps:
      - uses: actions/checkout@v5
        with:
          fetch-depth: 0
      - id: out
        run: |
          BEFORE="${{ github.event.before }}"
          SHA="${{ github.sha }}"
          if [ "$BEFORE" = "0000000000000000000000000000000000000000" ]; then
            DIFF=$(git diff --name-only HEAD~1 HEAD 2>/dev/null || echo "")
          else
            DIFF=$(git diff --name-only "$BEFORE" "$SHA")
          fi
          printf '%s\n' "$DIFF" > /tmp/diff.txt
          HOSTS=$(python3 - <<'PY'
import json
hosts = json.load(open('vps/hosts.json'))
changed = {l.strip() for l in open('/tmp/diff.txt') if l.strip()}
sel = [h for h in hosts if any(c.startswith(h['dir'] + '/') for c in changed)]
print(json.dumps(sel, separators=(',', ':')))
PY
)
          echo "hosts=$HOSTS" >> $GITHUB_OUTPUT
          echo "Selected: $HOSTS"
```

- [ ] **Step 3: Test the selection logic locally before pushing**

```bash
mkdir -p /tmp/dt && cd "$(git rev-parse --show-toplevel)"
printf '%s\n' "vps/vps3-prod/stacks/n8n/docker-compose.yml" "README.md" > /tmp/diff.txt
python3 -c "
import json
hosts=json.load(open('vps/hosts.json'))
changed={l.strip() for l in open('/tmp/diff.txt') if l.strip()}
sel=[h for h in hosts if any(c.startswith(h['dir']+'/') for c in changed)]
assert [h['key'] for h in sel]==['vps3-prod'], sel
print('single-host selection OK')
"
printf '%s\n' "vps/vps1-staging/stacks/n8n/x" "vps/bpvps2/stacks/booking/y" > /tmp/diff.txt
python3 -c "
import json
hosts=json.load(open('vps/hosts.json'))
changed={l.strip() for l in open('/tmp/diff.txt') if l.strip()}
sel=[h for h in hosts if any(c.startswith(h['dir']+'/') for c in changed)]
assert [h['key'] for h in sel]==['vps1-staging','bpvps2'], sel
print('multi-host selection OK')
"
printf '%s\n' "README.md" > /tmp/diff.txt
python3 -c "
import json
hosts=json.load(open('vps/hosts.json'))
changed={l.strip() for l in open('/tmp/diff.txt') if l.strip()}
sel=[h for h in hosts if any(c.startswith(h['dir']+'/') for c in changed)]
assert sel==[], sel
print('no-match selection OK')
"
```

Expected: three OK lines. The `vps/bpvps1` vs `vps/bpvps2` prefix case is why matching requires the trailing `/`.

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/deploy-infra.yml
git commit -m "refactor(ci): detect emits a JSON host array from vps/hosts.json"
```

---

### Task 5: Collapse the three deploy jobs into one matrix job

**Files:**
- Modify: `.github/workflows/deploy-infra.yml` — delete `deploy-vps1`, `deploy-vps2`, `deploy-vps3`; add one `deploy` job.

**Interfaces:**
- Consumes: `needs.detect.outputs.hosts` (Task 4); `vars.TAILSCALE_HOST` (created in Task 6).
- Produces: nothing downstream.

> **Ordering note:** this task writes `vars.TAILSCALE_HOST`, which does not exist yet. Task 6 creates it. Do **not** merge to `main` until Task 6 is done; pushing to the feature branch is safe because the workflow only triggers on `main`.

- [ ] **Step 1: Add the matrix job**

```yaml
  deploy:
    needs: detect
    if: needs.detect.outputs.hosts != '[]'
    runs-on: ubuntu-latest
    environment: ${{ matrix.host.key }}
    strategy:
      fail-fast: false
      matrix:
        host: ${{ fromJSON(needs.detect.outputs.hosts) }}
    steps:
      - uses: actions/checkout@v5
        with:
          fetch-depth: 0

      - name: Connect to Tailscale
        uses: tailscale/github-action@v4
        with:
          oauth-client-id: ${{ secrets.TS_OAUTH_CLIENT_ID }}
          oauth-secret: ${{ secrets.TS_OAUTH_SECRET }}
          tags: tag:ci
          ping: ${{ vars.TAILSCALE_HOST }}

      - name: Setup SSH
        run: |
          mkdir -p ~/.ssh
          echo "${{ secrets.SSH_PRIVATE_KEY }}" | tr -d '\r' > ~/.ssh/id_deploy
          chmod 600 ~/.ssh/id_deploy
          ssh-keyscan -H "${{ vars.TAILSCALE_HOST }}" >> ~/.ssh/known_hosts 2>/dev/null || true

      - name: Detect stacks to deploy and remove
        id: stacks
        env:
          DIR: ${{ matrix.host.dir }}
          EXCLUDE: ${{ matrix.host.exclude }}
        run: |
          BEFORE="${{ github.event.before }}"
          SHA="${{ github.sha }}"
          if [ "$BEFORE" = "0000000000000000000000000000000000000000" ]; then
            DIFF=$(git diff --name-only HEAD~1 HEAD 2>/dev/null || echo "")
          else
            DIFF=$(git diff --name-only "$BEFORE" "$SHA")
          fi
          EXPR=$(echo "$EXCLUDE" | tr ' ' '|')
          [ -z "$EXPR" ] && EXPR='^$'
          ALL_TOUCHED=$(echo "$DIFF" | grep "^$DIR/stacks/" \
            | sed "s|$DIR/stacks/||;s|/.*||" | sort -u \
            | grep -vxE "$EXPR" || true)
          DEPLOY="" REMOVE=""
          for stack in $ALL_TOUCHED; do
            if [ -d "$DIR/stacks/$stack" ]; then DEPLOY="$DEPLOY $stack"; else REMOVE="$REMOVE $stack"; fi
          done
          echo "deploy=$(echo $DEPLOY | xargs)" >> $GITHUB_OUTPUT
          echo "remove=$(echo $REMOVE | xargs)" >> $GITHUB_OUTPUT
          echo "Deploy: $DEPLOY | Remove: $REMOVE"

      - name: Sync compose files
        if: steps.stacks.outputs.deploy != ''
        env:
          DIR: ${{ matrix.host.dir }}
          SSH_HOST: ${{ vars.TAILSCALE_HOST }}
          FANOUT: ${{ toJSON(matrix.host.fanout) }}
          DEPLOY: ${{ steps.stacks.outputs.deploy }}
        run: |
          RSH="ssh -i ~/.ssh/id_deploy -o StrictHostKeyChecking=no"
          for stack in $DEPLOY; do
            DESTS=$(STACK="$stack" python3 -c '
import json, os, sys
raw = os.environ.get("FANOUT") or "null"
fan = json.loads(raw) or {}
stack = os.environ["STACK"]
print(" ".join(fan.get(stack, [stack])))
')
            for d in $DESTS; do
              echo "=== syncing $stack -> /root/stacks/$d"
              rsync -rltz --exclude='.env' --exclude='.env.*' -e "$RSH" \
                "$DIR/stacks/$stack/" "deploy@$SSH_HOST:/root/stacks/$d/"
            done
          done
```

The stack name reaches Python through the `STACK` environment variable, never through shell
interpolation — a stack named with a quote or space cannot break out. `FANOUT` is `null` for the
four hosts without a fanout map, which `json.loads` handles and `or {}` normalises.

The `Deploy and remove stacks` step is carried over unchanged from the current `deploy-vps3` job (lines 357-498), which already contains the **superset** of every `case` arm. Two edits to it:

1. `SSH_HOST: ${{ vars.TAILSCALE_HOST }}` instead of `vars.VPS3_TAILSCALE_HOST`.
2. `APP_STACKS='${{ matrix.host.app_stacks }}'` instead of the hardcoded `'booking-system ehailing'`.
3. The `n8n)` arm writes `.env.n8n` (see Task 7) instead of `.env.n8n-prod`.

- [ ] **Step 2: Delete the three old jobs**

Remove `deploy-vps1`, `deploy-vps2`, `deploy-vps3` in their entirety.

- [ ] **Step 3: Verify the workflow parses**

```bash
python3 -c "
import sys
try: import yaml
except ImportError: print('SKIP: pyyaml not installed'); sys.exit(0)
d=yaml.safe_load(open('.github/workflows/deploy-infra.yml'))
jobs=list(d['jobs'])
assert jobs==['detect','deploy'], jobs
assert d['jobs']['deploy']['strategy']['matrix']['host'].startswith('\${{ fromJSON')
print('workflow shape OK:', jobs)
"
wc -l .github/workflows/deploy-infra.yml
```

Expected: `workflow shape OK: ['detect', 'deploy']` and a line count under 200 (from 498).

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/deploy-infra.yml
git commit -m "refactor(ci): one matrix deploy job replaces three per-host jobs"
```

---

### Task 6: Create `TAILSCALE_HOST` in each Environment, retire the dead vars

Uses the GitHub REST API with the PAT in `.env`. Environment variables override org-level ones, which is what makes a single name resolve to five values.

**Files:** none — GitHub configuration only.

**Interfaces:**
- Produces: `vars.TAILSCALE_HOST` resolvable inside every `deploy` matrix job.

- [ ] **Step 1: Add `TAILSCALE_HOST` to the three existing Environments**

```bash
cd "$(git rev-parse --show-toplevel)"
TOK=$(grep -E '^GITHUB_PERSONAL_ACCESS_TOKEN=' .env | cut -d= -f2-)
REPO=Blueprint-Agency/teeko-infrastructure
add_var() {  # $1=env $2=name $3=value
  curl -s -X POST -H "Authorization: Bearer $TOK" -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/$REPO/environments/$1/variables" \
    -d "{\"name\":\"$2\",\"value\":\"$3\"}" -o /dev/null -w "$1/$2 -> %{http_code}\n"
}
add_var vps1-staging TAILSCALE_HOST 100.102.147.30
add_var vps2-prod    TAILSCALE_HOST 100.94.86.35
add_var vps3-prod    TAILSCALE_HOST 100.73.39.82
```

Expected: three lines ending `-> 201`. A `409` means it already exists — switch that call to `-X PATCH .../variables/TAILSCALE_HOST`.

- [ ] **Step 2: Verify resolution**

```bash
for e in vps1-staging vps2-prod vps3-prod; do
  printf "%-14s " "$e"
  curl -s -H "Authorization: Bearer $TOK" \
    "https://api.github.com/repos/$REPO/environments/$e/variables/TAILSCALE_HOST" \
    | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('value', d.get('message')))"
done
```

Expected: `100.102.147.30`, `100.94.86.35`, `100.73.39.82`.

- [ ] **Step 3: Delete the dead pgAdmin variables**

pgAdmin was removed on 2026-07-21; these reference nothing.

```bash
for e in vps1-staging vps2-prod; do
  curl -s -X DELETE -H "Authorization: Bearer $TOK" \
    "https://api.github.com/repos/$REPO/environments/$e/variables/PGADMIN_DEFAULT_EMAIL" \
    -o /dev/null -w "$e delete -> %{http_code}\n"
done
```

Expected: `-> 204` twice.

- [ ] **Step 4: Leave the org-level `VPS{1,2,3}_TAILSCALE_HOST` in place for now**

They are referenced by `.github/workflows/build-ga4-mcp.yml` and `build-gsc-mcp.yml`. Deleting them is a separate cleanup once those are checked. Record it as follow-up; do not delete here.

---

### Task 7: Converge n8n onto `ENV_NAME`

**Files:**
- Modify: `vps/vps1-staging/stacks/n8n/docker-compose.yml`
- Modify: `vps/vps3-prod/stacks/n8n/docker-compose.yml`
- Modify: `.github/workflows/deploy-infra.yml` — the `n8n)` case arm

**Interfaces:**
- Consumes: `ENV_NAME` from each stack's `.env`, written by the workflow's `BASE_ENV` step.
- Produces: `.env.n8n` as the single n8n env filename on every host.

> **Volume names are frozen.** `n8n-data` and `n8n_pgdata` stay `external: true` with those exact names on both hosts. `waba_pgdata` stays compose-managed (real name `n8n_waba_pgdata`).

- [ ] **Step 1: Add `ENV_NAME` to the workflow's `BASE_ENV`**

In the `Deploy and remove stacks` step, add `ENV_NAME` to the printf:

```bash
          BASE_ENV=$(printf 'BASE_DOMAIN=%s\nACME_EMAIL=%s\nCF_DNS_API_TOKEN=%s\nTRAEFIK_DASHBOARD_AUTH=%s\nGA4_MCP_PATH_TOKEN=%s\nENV_NAME=%s\n' \
            "$BASE_DOMAIN" "$ACME_EMAIL" "$CF_DNS_API_TOKEN" "$ESCAPED_AUTH" "$GA4_MCP_PATH_TOKEN" "$ENV_NAME" | base64 -w0)
```

and add to that step's `env:` block:

```yaml
          ENV_NAME: ${{ matrix.host.env_name }}
```

- [ ] **Step 2: Change the `n8n)` case arm to the stable filename**

```bash
              n8n)
                echo \"\$N8N_APP_ENV\" | base64 -d > /root/stacks/n8n/.env.n8n
                echo \"\$N8N_DB_ENV\"  | base64 -d > /root/stacks/n8n/.env.db-n8n ;;
```

- [ ] **Step 3: Rewrite VPS1's compose**

```yaml
# n8n — one shape shared with VPS3; ENV_NAME (from .env) keys everything that
# would otherwise differ per host. Volumes are external and NOT keyed: they are
# named identically on both hosts and renaming them orphans the data.
services:
  n8n:
    image: n8nio/n8n:latest
    pull_policy: always
    container_name: n8n-${ENV_NAME}
    restart: unless-stopped
    env_file: .env.n8n
    depends_on:
      db-n8n:
        condition: service_healthy
    volumes:
      - n8n-data:/home/node/.n8n
    healthcheck:
      test: ["CMD-SHELL", "wget -qO- http://localhost:5678/healthz >/dev/null 2>&1 || exit 1"]
      interval: 15s
      timeout: 5s
      retries: 5
      start_period: 60s
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.n8n-${ENV_NAME}.rule=Host(`stagingn8n.${BASE_DOMAIN}`)"
      - "traefik.http.routers.n8n-${ENV_NAME}.entrypoints=websecure"
      - "traefik.http.routers.n8n-${ENV_NAME}.tls.certresolver=letsencrypt"
      - "traefik.http.services.n8n-${ENV_NAME}.loadbalancer.server.port=5678"
    networks:
      - proxy

  # NOTE: service named 'db-n8n' so n8n can reach it as DB_POSTGRESDB_HOST=db-n8n
  # ⚠️ PIN THE MAJOR — see the VPS3 copy of this file for the full reasoning.
  db-n8n:
    image: postgres:18-alpine
    container_name: n8n-db
    restart: unless-stopped
    env_file: .env.db-n8n
    volumes:
      - n8n_pgdata:/var/lib/postgresql
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U $${POSTGRES_USER} -d $${POSTGRES_DB}"]
      interval: 5s
      timeout: 5s
      retries: 10
    networks:
      - proxy

volumes:
  n8n-data:
    external: true
  n8n_pgdata:
    external: true

networks:
  proxy:
    external: true
```

- [ ] **Step 4: Rewrite VPS3's compose**

Identical to Step 3 except the Traefik host rule is `Host(\`n8n.${BASE_DOMAIN}\`)`, the full pinning comment is retained on `db-n8n`, and `db-waba` is appended:

```yaml
  # Postgres for WABA workflow data (users + flight_reminder tables)
  db-waba:
    image: postgres:18-alpine   # pinned for the same reason as db-n8n above
    container_name: waba-db
    restart: unless-stopped
    env_file: .env.db-waba
    volumes:
      - waba_pgdata:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U $${POSTGRES_USER} -d $${POSTGRES_DB}"]
      interval: 5s
      timeout: 5s
      retries: 10
    networks:
      - proxy
```

with `waba_pgdata:` added under `volumes:` (no `external`, no `name:` — it must keep resolving to `n8n_waba_pgdata`).

- [ ] **Step 5: Verify compose renders with the real volume names — do not deploy yet**

```bash
cd vps/vps1-staging/stacks/n8n
ENV_NAME=dev BASE_DOMAIN=teeko.ai docker compose config --volumes
```

Expected: exactly `n8n-data` and `n8n_pgdata`. Then:

```bash
ENV_NAME=dev BASE_DOMAIN=teeko.ai docker compose config | grep -E "container_name|external"
```

Expected: `container_name: n8n-dev`, `container_name: n8n-db`, and `external: true` on both volumes. **If `container_name` is not `n8n-dev`, stop** — the container would be recreated under a new name.

Repeat for VPS3 with `ENV_NAME=prod`, expecting `n8n-prod`, `n8n-db`, `waba-db`, and volumes `n8n-data`, `n8n_pgdata`, `waba_pgdata`.

- [ ] **Step 6: Commit**

```bash
git add vps/vps1-staging/stacks/n8n/docker-compose.yml vps/vps3-prod/stacks/n8n/docker-compose.yml .github/workflows/deploy-infra.yml
git commit -m "refactor(n8n): key container and router names off ENV_NAME, add healthchecks

Volume names are deliberately NOT keyed — n8n-data and n8n_pgdata are external
and identically named on both hosts; renaming them would orphan the data."
```

---

### Task 8: First live run against staging only

**Files:** none — verification only.

- [ ] **Step 1: Merge to `main` and watch the run**

```bash
git checkout main && git merge --no-ff infra/deploy-matrix-refactor && git push
```

- [ ] **Step 2: Confirm the matrix selected only the expected hosts**

In the Actions run, `detect` logs `Selected: [...]`. Expected: entries for `vps1-staging` and `vps3-prod` only (the n8n composes changed), **not** `vps2-prod`.

- [ ] **Step 3: Diff the snapshots**

```bash
for h in bp-vps1-staging bp-vps3-prod; do
  ./vps/shared/snapshot-host.sh "$h" > "/tmp/snap/$h.after"
  echo "=== $h"; diff "/tmp/snap/$h.before" "/tmp/snap/$h.after" || true
done
```

Expected: the only differences are `postgres:alpine` → `postgres:18-alpine` in the image column. **Any volume appearing or disappearing is a failure — roll back immediately.**

- [ ] **Step 4: Confirm n8n kept its data**

```bash
ssh bp-vps1-staging 'docker exec n8n-db psql -U "$(grep POSTGRES_USER /root/stacks/n8n/.env.db-n8n | cut -d= -f2)" -d "$(grep POSTGRES_DB /root/stacks/n8n/.env.db-n8n | cut -d= -f2)" -tAc "select count(*) from workflow_entity"'
```

Expected: the same non-zero count as before the deploy. Record the pre-deploy count by running this command **before** Step 1.

- [ ] **Step 5: Rollback procedure if any check fails**

```bash
git revert --no-edit -m 1 HEAD && git push
```

Then re-run Step 3 and confirm the snapshot matches `.before`.

- [ ] **Step 6: Remove the orphaned n8n env files**

Only after Steps 3 and 4 pass. These held real DB credentials and are now unreferenced.

```bash
ssh bp-vps1-staging 'ls -1 /root/stacks/n8n/.env.n8n /root/stacks/n8n/.env.n8n-dev 2>&1'
ssh bp-vps3-prod    'ls -1 /root/stacks/n8n/.env.n8n /root/stacks/n8n/.env.n8n-prod 2>&1'
```

Expected: on each host, `.env.n8n` exists **and** the old file exists. If `.env.n8n` is missing,
stop — the case arm did not run and the stack is still using the old file.

```bash
ssh bp-vps1-staging 'rm -f /root/stacks/n8n/.env.n8n-dev'
ssh bp-vps3-prod    'rm -f /root/stacks/n8n/.env.n8n-prod'
```

Then confirm n8n is still healthy on both:

```bash
ssh bp-vps1-staging 'docker inspect n8n-dev  --format "{{.State.Health.Status}}"'
ssh bp-vps3-prod    'docker inspect n8n-prod --format "{{.State.Health.Status}}"'
```

Expected: `healthy` on both.

---

### Task 9: Onboard bpvps1

**Files:** none in-repo — GitHub configuration, then a no-op commit to trigger.

**Interfaces:**
- Consumes: `vps/hosts.json` entry `bpvps1` (Task 3), the matrix job (Task 5).

> bpvps1 serves **kaiteki.my**, not teeko.ai, and its Traefik needs the **Blueprint** Cloudflare token. Both must be Environment-level overrides of the org values.

- [ ] **Step 1: Create the Environment and its overrides**

```bash
TOK=$(grep -E '^GITHUB_PERSONAL_ACCESS_TOKEN=' .env | cut -d= -f2-)
REPO=Blueprint-Agency/teeko-infrastructure
curl -s -X PUT -H "Authorization: Bearer $TOK" \
  "https://api.github.com/repos/$REPO/environments/bpvps1" -d '{}' \
  -o /dev/null -w "create env -> %{http_code}\n"
for kv in TAILSCALE_HOST=100.94.77.65 BASE_DOMAIN=kaiteki.my ACME_EMAIL=askblueprintagency@gmail.com; do
  curl -s -X POST -H "Authorization: Bearer $TOK" \
    "https://api.github.com/repos/$REPO/environments/bpvps1/variables" \
    -d "{\"name\":\"${kv%%=*}\",\"value\":\"${kv#*=}\"}" -o /dev/null -w "${kv%%=*} -> %{http_code}\n"
done
```

Expected: `create env -> 201`, then three `-> 201`.

- [ ] **Step 2: Set the Blueprint Cloudflare token as an Environment secret**

Environment secrets need the environment's public key to encrypt against. Read the current on-host value rather than inventing one:

```bash
ssh bp-bpvps1 'grep -E "^CF_DNS_API_TOKEN=" /root/stacks/traefik/.env | cut -d= -f2-'
```

Set it via the GitHub UI (Settings → Environments → bpvps1 → Add secret → `CF_DNS_API_TOKEN`) — encrypting via curl requires libsodium and is not worth scripting for one value.

- [ ] **Step 3: Verify the on-host `.env` values the workflow will overwrite**

```bash
ssh bp-bpvps1 'sed -E "s/=.{6,}/=<set>/" /root/stacks/traefik/.env'
```

Expected: `BASE_DOMAIN=<set>`, `ACME_EMAIL=<set>`, `CF_DNS_API_TOKEN=<set>`, `TRAEFIK_DASHBOARD_AUTH=<set>`. Confirm `BASE_DOMAIN` really is `kaiteki.my` — if it is not, correct Step 1 before triggering.

- [ ] **Step 4: Trigger with the safest possible change**

```bash
./vps/shared/snapshot-host.sh bp-bpvps1 > /tmp/snap/bp-bpvps1.before2
echo "# ci: bpvps1 onboarding $(date -u +%FT%TZ)" >> vps/bpvps1/stacks/traefik/docker-compose.yml
git add vps/bpvps1/stacks/traefik/docker-compose.yml
git commit -m "ci: bring bpvps1 under matrix deploy"
git push
```

- [ ] **Step 5: Verify**

```bash
./vps/shared/snapshot-host.sh bp-bpvps1 > /tmp/snap/bp-bpvps1.after
diff /tmp/snap/bp-bpvps1.before2 /tmp/snap/bp-bpvps1.after || true
curl -sI https://kaiteki.my | head -1
curl -sI https://mail.kaiteki.my | head -1
```

Expected: no volume or container-name changes; both curls return `HTTP/2 200` or a `30x`. A TLS error means the wrong CF token — revert and fix Step 2.

---

### Task 10: Onboard bpvps2 and exercise `fanout`

**Files:** none in-repo beyond the trigger commit.

> bpvps2 keeps the **org-level** `BASE_DOMAIN=teeko.ai` and the **org-level** `CF_DNS_API_TOKEN` (Teeko), because its Traefik resolves certs for `bookingapi.teeko.ai`. Do **not** add overrides here. `blueprintdigital.my` certs arrive independently via acme.sh in the stalwart stack.

- [ ] **Step 1: Create the Environment with only `TAILSCALE_HOST`**

```bash
TOK=$(grep -E '^GITHUB_PERSONAL_ACCESS_TOKEN=' .env | cut -d= -f2-)
REPO=Blueprint-Agency/teeko-infrastructure
curl -s -X PUT -H "Authorization: Bearer $TOK" \
  "https://api.github.com/repos/$REPO/environments/bpvps2" -d '{}' \
  -o /dev/null -w "create env -> %{http_code}\n"
curl -s -X POST -H "Authorization: Bearer $TOK" \
  "https://api.github.com/repos/$REPO/environments/bpvps2/variables" \
  -d '{"name":"TAILSCALE_HOST","value":"100.78.5.2"}' -o /dev/null -w "TAILSCALE_HOST -> %{http_code}\n"
```

- [ ] **Step 2: Snapshot, then trigger via the traefik stack (not booking)**

booking is in `app_stacks`, so the workflow syncs its compose but never runs `docker compose up`. Trigger on traefik first so `fanout` is not exercised on the first run.

```bash
./vps/shared/snapshot-host.sh bp-bpvps2 > /tmp/snap/bp-bpvps2.before2
echo "# ci: bpvps2 onboarding $(date -u +%FT%TZ)" >> vps/bpvps2/stacks/traefik/docker-compose.yml
git add vps/bpvps2/stacks/traefik/docker-compose.yml
git commit -m "ci: bring bpvps2 under matrix deploy"
git push
```

- [ ] **Step 3: Verify both booking endpoints survived the Traefik restart**

Traefik restarts on this host briefly interrupt booking-prod.

```bash
./vps/shared/snapshot-host.sh bp-bpvps2 > /tmp/snap/bp-bpvps2.after
diff /tmp/snap/bp-bpvps2.before2 /tmp/snap/bp-bpvps2.after || true
curl -s -o /dev/null -w "staging %{http_code}\n" https://bookingapi.teeko.ai/health
curl -s -o /dev/null -w "prod    %{http_code}\n" https://prodbookingapi.teeko.ai/health
```

Expected: no snapshot differences; both return `200`.

- [ ] **Step 4: Exercise `fanout` with a comment-only booking change**

```bash
echo "# fanout check $(date -u +%FT%TZ)" >> vps/bpvps2/stacks/booking/docker-compose.yml
git add vps/bpvps2/stacks/booking/docker-compose.yml
git commit -m "ci: verify booking fanout to both host dirs"
git push
```

- [ ] **Step 5: Confirm the fanout landed in two directories and created no third**

```bash
ssh bp-bpvps2 'ls -1 /root/stacks; echo "--- staging:"; tail -1 /root/stacks/booking-staging/docker-compose.yml; echo "--- prod:"; tail -1 /root/stacks/booking-prod/docker-compose.yml'
```

Expected: `/root/stacks` lists `booking-prod`, `booking-staging`, `stalwart`, `traefik` — and **no** bare `booking` directory. Both tails show the `# fanout check` line. Containers unchanged, because booking is in `app_stacks`.

---

### Task 11: Update CLAUDE.md

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 1: Replace the CI/CD section**

```markdown
## CI/CD

`.github/workflows/deploy-infra.yml` deploys **all five hosts** from one matrix job.
`vps/hosts.json` is the source of truth: `key` (also the GitHub Environment name), `dir`,
`env_name`, `exclude`, `app_stacks`, and optional `fanout`.

Adding a host: one entry in `vps/hosts.json` + a GitHub Environment named after its `key`
containing at minimum `TAILSCALE_HOST`.

| Branch | Target | Flow |
|--------|--------|------|
| `staging` | VPS1 | GHA builds image → triggers deploy workflow → SSH deploy |
| `main` | VPS2 or VPS3 | Same, production tags |

> `BASE_DOMAIN=teeko.ai`, `ACME_EMAIL` and `CF_DNS_API_TOKEN` are **org-level**. Per-host
> differences are Environment-level overrides — never edit the org value.
> **bpvps1** overrides `BASE_DOMAIN=kaiteki.my` and `CF_DNS_API_TOKEN` (Blueprint account).
> **bpvps2** deliberately does not: its Traefik resolves `bookingapi.teeko.ai`, so it needs
> the Teeko token even though the host lives in the Blueprint Hostinger account.
```

- [ ] **Step 2: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: document hosts.json, matrix CI, and the per-host variable overrides"
```

---

## Follow-ups (not in this plan)

- Delete org-level `VPS{1,2,3}_TAILSCALE_HOST` after confirming `build-ga4-mcp.yml` and `build-gsc-mcp.yml` no longer reference them.
- Remove `vps/vps3-prod/stacks/gsc-mcp;W/` — present in the repo, absent on the host.
- Project B: the provision skill, which reads `vps/hosts.json`.
