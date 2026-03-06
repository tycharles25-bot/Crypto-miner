#!/usr/bin/env node
/**
 * Run multiple workers on one machine, each with a different proxy = different IP
 * Path to 1M samples/min on a single computer.
 *
 * Create workers.json:
 *   [
 *     { "HTTP_PROXY": "http://proxy1.example.com:8080" },
 *     { "HTTP_PROXY": "http://proxy2.example.com:8080" },
 *     {}
 *   ]
 * Last one has no proxy (uses your direct IP).
 *
 * Usage: node scripts/run-workers.js
 * HUB_URL from .env or: HUB_URL=https://hub.com node scripts/run-workers.js
 */

import dotenv from 'dotenv';
import { spawn } from 'child_process';
import path from 'path';
import { fileURLToPath } from 'url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const rootDir = path.join(__dirname, '..');

dotenv.config({ path: path.join(rootDir, '.env') });
const HUB_URL = (process.env.HUB_URL || '').trim().replace(/\/$/, '');
const WORKERS_JSON = process.env.WORKERS_JSON || path.join(rootDir, 'workers.json');

if (!HUB_URL) {
  console.error('HUB_URL required. Set in .env or: HUB_URL=https://hub.com node scripts/run-workers.js');
  process.exit(1);
}

let configs;
try {
  const fs = await import('fs');
  const raw = fs.readFileSync(WORKERS_JSON, 'utf8');
  configs = JSON.parse(raw);
  if (!Array.isArray(configs) || configs.length === 0) {
    throw new Error('workers.json must be a non-empty array');
  }
} catch (e) {
  if (e.code === 'ENOENT') {
    console.error('workers.json not found. Create it with:');
    console.error(JSON.stringify([
      { HTTP_PROXY: 'http://proxy1:8080' },
      { HTTP_PROXY: 'http://proxy2:8080' },
      {},
    ], null, 2));
  } else {
    console.error('workers.json:', e.message);
  }
  process.exit(1);
}

const workers = [];

function spawnWorker(env, id) {
  const child = spawn('node', ['worker.js'], {
    cwd: rootDir,
    env: { ...process.env, ...env, HUB_URL },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  child.stdout.on('data', (d) => process.stdout.write(`[W${id}] ${d}`));
  child.stderr.on('data', (d) => process.stderr.write(`[W${id}] ${d}`));
  child.on('exit', (code) => {
    console.error(`[W${id}] exited ${code}, restarting in 5s...`);
    setTimeout(() => spawnWorker(env, id), 5000);
  });
  workers.push(child);
  console.log(`[W${id}] started`, env.HTTP_PROXY ? `proxy: ${env.HTTP_PROXY}` : 'no proxy');
}

configs.forEach((env, i) => spawnWorker(env, i));

process.on('SIGINT', () => {
  console.log('\nShutting down workers...');
  workers.forEach((w) => w.kill());
  process.exit(0);
});
