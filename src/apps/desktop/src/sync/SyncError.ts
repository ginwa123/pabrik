/** The sync engine's error channel. Before Effect, every failure in this subsystem was funnelled
 * into a bare `catch {}` that returned a fallback value, so a backend outage, a corrupt IndexedDB
 * database and a legitimately empty result all reached the UI as the same value. */
import { Data } from 'effect'

/** The local cache (IndexedDB or its in-memory fallback) failed. */
export class SyncStorageError extends Data.TaggedError('SyncStorageError')<{
  /** Store operation that failed, e.g. `getAll`, `setCursor`. */
  readonly op: string
  /** Object store involved, e.g. `sessions`. */
  readonly store: string
  /** Underlying message, for logging. Never parsed for control flow. */
  readonly reason: string
}> {}

/** The remote delta fetch failed (network, non-2xx, or malformed payload). */
export class SyncRemoteError extends Data.TaggedError('SyncRemoteError')<{
  /** Engine operation that triggered the fetch, e.g. `fetchDelta`. */
  readonly op: string
  readonly reason: string
}> {}

export type SyncError = SyncStorageError | SyncRemoteError

/** Short, log-safe one-liner for an error on the sync error channel. */
export function describeSyncError(error: SyncError): string {
  return error._tag === 'SyncStorageError'
    ? `sync storage ${error.op} failed on store "${error.store}": ${error.reason}`
    : `sync remote ${error.op} failed: ${error.reason}`
}
