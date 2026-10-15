/**
 * The Effect seam for the sync slice.
 *
 * Two things live here:
 *
 *  1. `syncStoreLayer` — the local cache as a `Layer`, for code that composes
 *     a whole Effect program and wants the service in context.
 *  2. `runSyncEffect*` — the Effect seam for Vue `<script setup>` callers.
 *     The engines return `Effect`s; the components consuming them are
 *     ordinary script blocks. Effect's rule is that you never `await`
 *     without a plan for the failure, and the plan for a local-first cache
 *     is "degrade, but say why". These helpers encode that policy once, so
 *     each call site stays a one-liner and the *reason* is no longer
 *     discarded.
 *
 * `runSyncEffect` returns `null` on failure, the shape the old
 * `catch { return null }` produced, so call sites that already branched on
 * `if (delta)` keep their shape. `runSyncEffectOr` covers operations whose
 * "nothing there" value is not `null` (an empty row list, an absent cursor).
 */
import { Cause, Effect, Exit } from 'effect'
import { describeSyncError, type SyncError } from './SyncError'
import { IndexedDbStoreLive } from './IndexedDbStore'

/** The same cache as a `Layer`, for code that composes a whole Effect program
 * and wants the service in context:
 * ```ts
 * Effect.provide(program, syncStoreLayer)
 * ``` */
export const syncStoreLayer = IndexedDbStoreLive

const report = (op: string, error: SyncError): void => {
  if (import.meta.env?.DEV) console.warn(`[sync] ${op}: ${describeSyncError(error)}`)
}

/** Run a fallible sync Effect for its value, degrading to `null` on failure.
 * @param op Short label used in the dev-mode warning, e.g. `'sessions.loadDelta'`. */
export async function runSyncEffect<A>(
  effect: Effect.Effect<A, SyncError>,
  op: string,
): Promise<A | null> {
  const exit = await Effect.runPromise(Effect.exit(effect))
  if (Exit.isSuccess(exit)) return exit.value
  report(op, Cause.squash(exit.cause) as SyncError)
  return null
}

/** Run a fallible sync Effect for its value, degrading to `fallback` on
 * failure. Use when the "empty" answer is not `null` (e.g. `[]` for rows). */
export async function runSyncEffectOr<A>(
  effect: Effect.Effect<A, SyncError>,
  fallback: A,
  op: string,
): Promise<A> {
  const exit = await Effect.runPromise(Effect.exit(effect))
  if (Exit.isSuccess(exit)) return exit.value
  report(op, Cause.squash(exit.cause) as SyncError)
  return fallback
}

/** Run a best-effort sync Effect for its side effects, e.g. `putLocal`. These
 * are typed `Effect<void, never>` by the engine, but the error channel is
 * accepted anyway so a caller cannot accidentally turn an advisory write into
 * a rejected promise. */
export async function runSyncVoid(
  effect: Effect.Effect<void, SyncError>,
  op: string,
): Promise<void> {
  const exit = await Effect.runPromise(Effect.exit(effect))
  if (Exit.isFailure(exit)) report(op, Cause.squash(exit.cause) as SyncError)
}

/**
 * Run a fallible sync Effect and keep BOTH outcomes distinguishable.
 *
 * `runSyncEffect` degrades to `null`, which is right when "nothing there"
 * and "could not check" lead to the same correct action. It is WRONG when
 * the UI has to render the difference — a documents sidebar that shows
 * "No documents yet" because the backend was down is the exact
 * empty-vs-unavailable confusion this subsystem was ported to end, and the
 * sidebar's "a failed fetch is not emptiness" contract depends on the
 * message surviving. This variant hands back the reason so the caller can
 * record it; use it wherever an `error` ref is rendered.
 */
export async function runSyncResult<A>(
  effect: Effect.Effect<A, SyncError>,
  op: string,
): Promise<{ ok: true; value: A } | { ok: false; reason: string }> {
  const exit = await Effect.runPromise(Effect.exit(effect))
  if (Exit.isSuccess(exit)) return { ok: true, value: exit.value }
  const error = Cause.squash(exit.cause) as SyncError
  report(op, error)
  return { ok: false, reason: describeSyncError(error) }
}

// Re-exported so specs and future slices can build a program with the store
// in context without importing three modules.
export { SyncStore, memorySyncStoreLayer, makeMemorySyncStore } from './SyncStore'
