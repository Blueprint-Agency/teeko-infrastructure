/**
 * One-time script: creates GitHub environments, secrets, and variables
 * for the teeko-infrastructure repo.
 * Run: node mcp/setup-github-secrets.mjs
 * Requires: GITHUB_TOKEN env var (or reads from ../.env)
 */
import { readFileSync, existsSync } from 'fs';
import { createRequire } from 'module';

const require = createRequire(import.meta.url);
const sodium = require('tweetsodium');

// Load .env if GITHUB_TOKEN not set
let TOKEN = process.env.GITHUB_TOKEN;
let SSH_KEY = process.env.SSH_PRIVATE_KEY;

if (!TOKEN) {
  const envPath = new URL('../.env', import.meta.url).pathname.replace(/^\/([A-Z]:)/, '$1');
  if (existsSync(envPath)) {
    const lines = readFileSync(envPath, 'utf8').split('\n');
    for (const line of lines) {
      const m = line.match(/^GITHUB_PERSONAL_ACCESS_TOKEN=(.+)$/);
      if (m) TOKEN = m[1].trim();
    }
  }
}

if (!TOKEN) throw new Error('No GITHUB_TOKEN found');

// Read SSH private key
const sshKeyPath = process.env.HOME + '/.ssh/infra_ed25519';
SSH_KEY = readFileSync(sshKeyPath, 'utf8').trim();

const REPO_OWNER = 'Blueprint-Agency';
const REPO_NAME = 'teeko-infrastructure';
const BASE = 'https://api.github.com';

const headers = {
  Authorization: `Bearer ${TOKEN}`,
  Accept: 'application/vnd.github+json',
  'X-GitHub-Api-Version': '2022-11-28',
  'Content-Type': 'application/json',
};

async function api(method, path, body) {
  const res = await fetch(`${BASE}${path}`, {
    method,
    headers,
    body: body ? JSON.stringify(body) : undefined,
  });
  const text = await res.text();
  if (!res.ok && res.status !== 204) {
    console.error(`  ERROR ${res.status} ${method} ${path}: ${text.slice(0, 200)}`);
    return null;
  }
  return text ? JSON.parse(text) : null;
}

// Get public key for secret encryption
async function getPublicKey(envName) {
  const path = envName
    ? `/repos/${REPO_OWNER}/${REPO_NAME}/environments/${envName}/secrets/public-key`
    : `/repos/${REPO_OWNER}/${REPO_NAME}/actions/secrets/public-key`;
  return api('GET', path);
}

function encryptSecret(publicKeyB64, secretValue) {
  const key = Buffer.from(publicKeyB64, 'base64');
  const value = Buffer.from(secretValue);
  const encrypted = sodium.seal(value, key);
  return Buffer.from(encrypted).toString('base64');
}

async function setSecret(name, value, envName) {
  const pk = await getPublicKey(envName);
  if (!pk) return;
  const encrypted = encryptSecret(pk.key, value);
  const path = envName
    ? `/repos/${REPO_OWNER}/${REPO_NAME}/environments/${envName}/secrets/${name}`
    : `/repos/${REPO_OWNER}/${REPO_NAME}/actions/secrets/${name}`;
  await api('PUT', path, { encrypted_value: encrypted, key_id: pk.key_id });
  console.log(`  secret: ${name} → ${envName || 'repo'}`);
}

async function setVariable(name, value, envName) {
  const basePath = envName
    ? `/repos/${REPO_OWNER}/${REPO_NAME}/environments/${envName}/variables`
    : `/repos/${REPO_OWNER}/${REPO_NAME}/actions/variables`;

  // Try PATCH first (update), then POST (create)
  const patchRes = await fetch(`${BASE}${basePath}/${name}`, {
    method: 'PATCH',
    headers,
    body: JSON.stringify({ name, value }),
  });
  if (!patchRes.ok) {
    await api('POST', basePath, { name, value });
  }
  console.log(`  var:    ${name} → ${envName || 'repo'}`);
}

async function createEnvironment(envName) {
  await api('PUT', `/repos/${REPO_OWNER}/${REPO_NAME}/environments/${envName}`, {});
  console.log(`  env:    ${envName} created`);
}

async function main() {
  // ── Environments ───────────────────────────────────────────────────────────
  console.log('\n=== Creating environments ===');
  await createEnvironment('vps1-staging');
  await createEnvironment('vps2-prod');
  await createEnvironment('vps3-prod');

  // ── Repository-level secrets ────────────────────────────────────────────────
  console.log('\n=== Repo secrets ===');
  await setSecret('CF_DNS_API_TOKEN',        'cfut_BEiZE1lcl1nvpA2FlRUH7ANywfdJa4dyfSo7xKcO2b9076c3');
  await setSecret('TRAEFIK_DASHBOARD_AUTH',  'admin:$2y$05$Ym5VG2.e0zPwg9OfdCMQguqRbJW093uraEOQRwiP2BZ04ZIOFRZcq');
  await setSecret('GRAFANA_ADMIN_PASSWORD',  'Teekoadmin123!');
  await setSecret('PGADMIN_DEFAULT_PASSWORD','Teekoadmin123!');
  await setSecret('SSH_PRIVATE_KEY',         SSH_KEY);

  // ── Repository-level variables ──────────────────────────────────────────────
  console.log('\n=== Repo variables ===');
  await setVariable('BASE_DOMAIN',          'teeko.ai');
  await setVariable('ACME_EMAIL',           'teekoaitech@gmail.com');
  await setVariable('PGADMIN_DEFAULT_EMAIL','teekoaitech@gmail.com');

  // ── vps1-staging secrets ────────────────────────────────────────────────────
  console.log('\n=== vps1-staging secrets ===');
  await setSecret('SSH_HOST',         '72.61.114.7',                   'vps1-staging');
  await setSecret('SSH_USER',         'root',                          'vps1-staging');
  await setSecret('N8N_DB_PASSWORD',  'eBNsn92#pq8',                   'vps1-staging');
  await setSecret('N8N_ENCRYPTION_KEY','KO8GSvzjgzbagmGG1R4mQitrqNuVZ/4t', 'vps1-staging');

  console.log('\n=== vps1-staging variables ===');
  await setVariable('N8N_DB_USER',        'postgres',                  'vps1-staging');
  await setVariable('N8N_DB_NAME',        'n8n-dev',                   'vps1-staging');
  await setVariable('N8N_EDITOR_BASE_URL','https://stagingn8n.teeko.ai','vps1-staging');
  await setVariable('N8N_WEBHOOK_URL',    'https://stagingn8n.teeko.ai','vps1-staging');

  // ── vps2-prod secrets ───────────────────────────────────────────────────────
  console.log('\n=== vps2-prod secrets ===');
  await setSecret('SSH_HOST', '72.60.235.226', 'vps2-prod');
  await setSecret('SSH_USER', 'root',          'vps2-prod');

  // ── vps3-prod secrets ───────────────────────────────────────────────────────
  console.log('\n=== vps3-prod secrets ===');
  await setSecret('SSH_HOST',          '72.62.74.77',                   'vps3-prod');
  await setSecret('SSH_USER',          'root',                          'vps3-prod');
  await setSecret('N8N_DB_PASSWORD',   'Sjdju2Jsif902si',               'vps3-prod');
  await setSecret('N8N_ENCRYPTION_KEY','KO8GSvzjgzbagmGG1R4mQitrqNuVZ/4t', 'vps3-prod');

  console.log('\n=== vps3-prod variables ===');
  await setVariable('N8N_DB_USER',        'Suyg78Ksp990',          'vps3-prod');
  await setVariable('N8N_DB_NAME',        'n8n-prod',              'vps3-prod');
  await setVariable('N8N_EDITOR_BASE_URL','https://n8n.teeko.ai',  'vps3-prod');
  await setVariable('N8N_WEBHOOK_URL',    'https://n8n.teeko.ai',  'vps3-prod');

  console.log('\n✓ Done');
}

main().catch(console.error);
