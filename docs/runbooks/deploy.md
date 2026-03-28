# Deploy Runbook

## Automated Deploy (Normal Flow)

1. Push to `staging` branch → GHA builds image → deploys to VPS1
2. Push to `main` branch → GHA builds image → deploys to VPS2 or VPS3

No manual action needed.

## Manual Deploy (Emergency / Testing)

### Via Claude Code (MCP)
Ask Claude Code:
- "Deploy my-app to staging"
- "Pull the latest image for my-app on VPS2 and restart it"

### Via SSH
```bash
ssh deploy@<vps-ip>
cd /opt/infrastructure/vps/<vps-alias>
docker compose pull <service-name>
docker compose up -d <service-name>
```

### Via Script
```bash
./vps/shared/deploy.sh staging my-app
./vps/shared/deploy.sh prod-vps2 my-app
```

## Adding a New App

1. Add entry to `apps/registry.yml`
2. Add service to the target VPS `docker-compose.yml`
3. Add env vars to `.env` on the VPS
4. Push to trigger deploy, or deploy manually

## Secrets Required in GitHub Actions

| Secret | Description |
|--------|-------------|
| `STAGING_VPS_HOST` | VPS1 IP address |
| `STAGING_SSH_PRIVATE_KEY` | SSH key for deploy@VPS1 |
| `PROD_VPS2_HOST` | VPS2 IP address |
| `PROD_VPS2_SSH_PRIVATE_KEY` | SSH key for deploy@VPS2 |
| `PROD_VPS3_HOST` | VPS3 IP address |
| `PROD_VPS3_SSH_PRIVATE_KEY` | SSH key for deploy@VPS3 |
