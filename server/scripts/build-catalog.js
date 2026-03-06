#!/usr/bin/env node
/**
 * Build token catalog standalone
 * Run: node scripts/build-catalog.js
 * Or: TOKEN_CATALOG_ENABLED=true npm start (runs in background)
 */

import dotenv from 'dotenv';
import path from 'path';
import { fileURLToPath } from 'url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
dotenv.config({ path: path.join(__dirname, '../.env') });

import { buildCatalog, saveCatalogToRedis } from '../token-catalog.js';

const apiKey = (process.env.BIRDEYE_API_KEY || '').trim();

async function main() {
  console.log('[BUILD] Starting token catalog build...');
  const stats = await buildCatalog(apiKey);
  console.log('[BUILD] Done:', stats.total, 'tokens');
  console.log('[BUILD] By source:', stats.bySource);
  if (stats.error) console.warn('[BUILD] Error:', stats.error);
  console.log('[BUILD] Duration:', Math.round(stats.durationMs / 1000), 's');
  if (process.env.REDIS_URL) {
    await saveCatalogToRedis();
  } else {
    console.log('[BUILD] Set REDIS_URL to persist catalog for chain-only mode');
  }
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
