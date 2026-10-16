// elapsedDuration.ts — one formatter for every "how long has this been running" label in the app.
/** Seconds of silence after which a running worker reads as stale. */
export const WORKER_STALE_SECONDS = 300

/** Format a duration in milliseconds as a compact elapsed label. < 60s        → "42s" < 60m
 * → "4m 12s" < 24h        → "1h 04m" everything   → "2d 3h" Returns '' for non-finite or negative
 * input so callers can guard with `v-if` rather than render "NaNs" or "-1s". */
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
