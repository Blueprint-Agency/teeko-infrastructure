#!/usr/bin/env node
// Loads .env and starts the GitHub MCP server (cross-platform, no bash required).
const fs = require('fs');
const path = require('path');
const { spawn } = require('child_process');

const envFile = path.join(__dirname, '..', '.env');
if (!fs.existsSync(envFile)) {
  console.error(`Error: .env not found at ${envFile}`);
  process.exit(1);
}

// Parse .env and inject into environment
const lines = fs.readFileSync(envFile, 'utf8').split('\n');
for (const line of lines) {
  const trimmed = line.trim();
  if (!trimmed || trimmed.startsWith('#')) continue;
  const idx = trimmed.indexOf('=');
  if (idx === -1) continue;
  const key = trimmed.slice(0, idx).trim();
  const value = trimmed.slice(idx + 1).trim().replace(/^["']|["']$/g, '');
  process.env[key] = value;
}

const child = spawn('npx', ['-y', '@github/mcp-server'], {
  stdio: 'inherit',
  env: process.env,
  shell: true,
});

child.on('exit', (code) => process.exit(code ?? 0));
