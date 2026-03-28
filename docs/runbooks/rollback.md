# Rollback Runbook

## When to Rollback
- Deployment causes errors (500s, crashes, health check failures)
- New version has a critical bug discovered after deploy

## Via Claude Code (MCP)
Ask Claude Code:
- "Rollback my-app on VPS2 to the previous version"
- "Stop my-app on staging and restart with the previous image"

## Via Script
```bash
./scripts/rollback.sh prod-vps2 my-app
```

## Manual Rollback
```bash
ssh deploy@<vps-ip>
cd /opt/infrastructure/vps/<vps-alias>

# Option 1: Pin to a known-good tag in docker-compose.yml, then:
docker compose pull <service-name>
docker compose up -d <service-name>

# Option 2: If previous image is still cached locally:
docker compose stop <service-name>
docker compose rm -f <service-name>
docker compose up -d <service-name>
```

## Post-Rollback
1. Verify the service is healthy: `docker compose ps`
2. Check logs: `docker compose logs -f <service-name>`
3. Investigate the root cause before re-deploying
