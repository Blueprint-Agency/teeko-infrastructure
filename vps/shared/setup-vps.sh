#!/bin/bash
# Initial VPS setup script
# Run this once on a fresh VPS to install Docker and create deploy user.
# Usage: ssh root@vps-ip 'bash -s' < setup-vps.sh

set -euo pipefail

DEPLOY_USER="deploy"

echo "==> Updating system..."
apt-get update && apt-get upgrade -y

echo "==> Installing Docker..."
curl -fsSL https://get.docker.com | sh

echo "==> Installing Docker Compose plugin..."
apt-get install -y docker-compose-plugin

echo "==> Creating deploy user..."
if ! id "$DEPLOY_USER" &>/dev/null; then
  useradd -m -s /bin/bash "$DEPLOY_USER"
  usermod -aG docker "$DEPLOY_USER"
  echo "==> Created user: ${DEPLOY_USER}"
else
  echo "==> User ${DEPLOY_USER} already exists"
  usermod -aG docker "$DEPLOY_USER"
fi

echo "==> Setting up SSH for deploy user..."
mkdir -p /home/${DEPLOY_USER}/.ssh
cp /root/.ssh/authorized_keys /home/${DEPLOY_USER}/.ssh/ 2>/dev/null || true
chown -R ${DEPLOY_USER}:${DEPLOY_USER} /home/${DEPLOY_USER}/.ssh
chmod 700 /home/${DEPLOY_USER}/.ssh
chmod 600 /home/${DEPLOY_USER}/.ssh/authorized_keys 2>/dev/null || true

echo "==> Enabling Docker to start on boot..."
systemctl enable docker
systemctl start docker

echo "==> Setup complete!"
echo "    - Docker version: $(docker --version)"
echo "    - Deploy user: ${DEPLOY_USER}"
echo "    - Add your SSH public key to /home/${DEPLOY_USER}/.ssh/authorized_keys"
