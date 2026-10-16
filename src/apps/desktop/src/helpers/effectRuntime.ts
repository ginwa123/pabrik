/** The generic Effect seam for Vue `<script setup>` callers. `sync/runtime.ts` is the same idea
 * specialised to the sync slice (it degrades to `null`/a fallback and reports a `SyncError`). */
import { Cause, Effect, Exit, Option } from 'effect'

/** Best-effort one-liner for anything on an Effect's error channel. */
export function describeCause(cause: Cause.Cause<unknown>): string {
  const failure = Option.getOrUndefined(Cause.failureOption(cause))
  if (failure !== undefined) {
    return failure instanceof Error ? failure.message : String(failure)
  }
  // A defect (a thrown non-Error, a bug) rather than a declared failure.
  return Cause.pretty(cause)
}

/**  * Run `effect` and hand back its `Exit` — never a fallback value, never a throw. The caller matches
 * on it, so "failed" stays visible in the type. Failures are logged in dev; the `Exit` is still
 * returned so the caller can surface them in the UI. */
export async function runEffectExit<A, E>(
  effect: Effect.Effect<A, E>,
  op: string,
): Promise<Exit.Exit<A, E>> {
  const exit = await Effect.runPromise(Effect.exit(effect))
  if (Exit.isFailure(exit) && import.meta.env?.DEV) {
    console.warn(`[${op}] ${describeCause(exit.cause)}`)
  }
  return exit
}

/**  * Run `effect` for its value, degrading to `fallback` on failure. Use ONLY when the fallback is a
 * genuinely equivalent answer. "The cache had no new rows" is fine; "the server is unreachable" is
 * not — that one needs `runEffectExit` so the reason can reach the UI. */
export async function runEffectOr<A, E>(
  effect: Effect.Effect<A, E>,
  fallback: A,
  op: string,
): Promise<A> {
  const exit = await runEffectExit(effect, op)
  return Exit.isSuccess(exit) ? exit.value : fallback
}
