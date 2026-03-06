/**
 * Event-driven hot mint queue
 * Mints from swap events are added here; chain scanner fetches bonding curves for them only.
 * ~99% RPC reduction vs full 892k scan.
 */

const MAX_QUEUE = 50000;
const queue = new Map(); // mint -> lastAddedAt (dedupe, keep newest)

export function addMintToQueue(mint) {
  if (!mint || mint.length < 32) return;
  if (queue.size >= MAX_QUEUE) return;
  queue.set(mint, Date.now());
}

export function takeBatch(n) {
  const mints = Array.from(queue.keys()).slice(0, n);
  for (const m of mints) queue.delete(m);
  return mints;
}

export function getQueueSize() {
  return queue.size;
}
