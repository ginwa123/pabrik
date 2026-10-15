// elapsedDuration.ts — one formatter for every "how long has this been
// running" label in the app.
//
// The worker-running surfaces (sidebar rows, kanban card, kanban row,
// task-detail dialog, chat app bar) all need the same string, and a
// "4m 12s" that disagrees with the card's "4m 12s" is a bug report
// waiting to happen. `SpawnSubAgent.vue` already had a private
// `formatElapsed` for sub-agent rows; this is that function promoted to
// a shared, tested helper so both surfaces render identically.
//
// Deliberately NOT `formatRelativeTime` (helpers/relativeTime.ts): that
// one buckets into "5m" / "2h" / "3d" and collapses everything under a
// minute to "now", which is useless for a run that has been going for
// 40 seconds. A running worker needs second-level resolution.
/** Seconds of silence after which a running worker reads as stale. */
export const WORKER_STALE_SECONDS = 300

/**
 * Format a duration in milliseconds as a compact elapsed label.
 *
 *   < 60s        → "42s"
 *   < 60m        → "4m 12s"
 *   < 24h        → "1h 04m"
 *   everything   → "2d 3h"
 *
 * Returns '' for non-finite or negative input so callers can guard with
 * `v-if` rather than render "NaNs" or "-1s". Clock skew between the
 * backend's stamp and the browser's clock is the realistic source of a
 * negative value, and an empty chip is the honest rendering of it.
 */
export function formatElapsedDuration(ms: number): string {
  if (!Number.isFinite(ms) || ms < 0) return ''
  const totalSec = Math.floor(ms / 1000)
  if (totalSec < 60) return `${totalSec}s`
  const min = Math.floor(totalSec / 60)
  if (min < 60) return `${min}m ${(totalSec % 60).toString().padStart(2, '0')}s`
  const hour = Math.floor(min / 60)
  if (hour < 24) return `${hour}h ${(min % 60).toString().padStart(2, '0')}m`
  return `${Math.floor(hour / 24)}d ${(hour % 24).toString().padStart(2, '0')}h`
}

/**  * True when a worker's last heartbeat is old enough to read as stalled. The threshold sits below
 * the 600s the backend's `cleanup_stale_worker` cron uses to delete the row, so the UI can warn
 * before the run is reaped rather than reporting a disappearance after the fact. */
export function isWorkerStale(lastActivityMs: number, nowMs: number): boolean {
  if (!Number.isFinite(lastActivityMs) || !Number.isFinite(nowMs)) return false
  return nowMs - lastActivityMs >= WORKER_STALE_SECONDS * 1000
}
