#!/usr/bin/env node
/**
 * Generate render.yaml with PumpApi ingest workers in different regions
 * Render shares IPs per region - 1 worker per region = 1 IP = 1 PumpApi connection
 * 5 regions = 5 connections = ~95k samples/min
 *
 * Run: node scripts/generate-render-pumpapi.js
 * Output to render-pumpapi-ingest.yaml
 */

const REGIONS = ['oregon', 'frankfurt', 'singapore', 'ohio', 'virginia'];
const services = [];

for (let i = 0; i < REGIONS.length; i++) {
  const region = REGIONS[i];
  services.push(`  - type: worker
    name: pumpapi-ingest-${region}
    runtime: node
    region: ${region}
    rootDir: server
    buildCommand: npm install
    startCommand: node pumpapi-ingest-worker.js
    envVars:
      - key: HUB_URL
        sync: false
      - key: PUMPAPI_BATCH_SIZE
        value: "1000"
      - key: PUMPAPI_BATCH_INTERVAL_MS
        value: "5000"`);
}

const total = REGIONS.length * 19000;
const yaml = `# PumpApi Ingest Workers - 5 regions = 5 unique IPs = ~${total.toLocaleString()} samples/min
# Render shares IPs per region, so 1 worker per region = 1 PumpApi connection each
# Deploy: Connect repo to Render → New Blueprint → Select render-pumpapi-ingest.yaml
# Set HUB_URL when prompted (your hub must be reachable from the internet)

services:
${services.join('\n\n')}
`;

const fs = await import('fs');
const path = await import('path');
const rootDir = path.join(process.cwd(), '..');
const outPath = path.join(rootDir, 'render-pumpapi-ingest.yaml');
fs.writeFileSync(outPath, yaml);
console.log('Wrote', outPath, `(${REGIONS.length} workers, ${REGIONS.length} regions)`);
