/**
 * Retry policy for the INITIAL transcript fetch in ChatView.
 *
 * Why this exists: the chatview used to abort a slow `/messages` round-trip
 * on `apiFetch`'s 15 s default and — because the loader swallowed the
 * failure into an empty transcript — render the empty state ("How can I help
 * you?") for a session that is full of messages. Two things had to change:
 * the failure must travel in the error channel, and the caller must WAIT
 * rather than surrender. This module owns the "how long do we wait" half.
 *
 * The composer is already disabled by `isInitializing` for the duration, so a
 * long wait costs the user nothing but a skeleton — which is exactly the
 * honest representation of "we asked the server and it hasn't answered yet".
 *
 * Effect-TS, not try/catch: the attempt is an `Effect`, so "it failed" is in
 * the return type and `Effect.retry` handles the policy. A `try`/`catch`
 * here would put the failure back in a position where a caller can quietly
 * drop it. See AGENTS.md, "Frontend — No `try`/`catch` in the desktop app".
 */
import { Effect, Schedule } from 'effect'

/**
 * Per-attempt budget. Deliberately far above `apiFetch`'s 15 s default:
 * the transcript page is `PAGE_SIZE = 1000` rows and routinely carries
 * base64 `image_urls` plus tool JSON, for which the constant's own comment
 * warns about "slow TTFB". Not `0` (unbounded) — a genuinely hung backend
 * would then park the skeleton forever, which is the failure mode the
 * default timeout exists to prevent.
 */
export const INITIAL_HISTORY_TIMEOUT_MS = 45_000

/**
 * Delay BEFORE each attempt, in order. The first entry is `0` — the initial
 * load must not wait. Each later entry is the backoff after that attempt
 * failed, so the full schedule is 4 attempts spanning ~7.75 s of waiting plus
 * however long each attempt itself takes.
 */
export const INITIAL_HISTORY_RETRY_DELAYS_MS: readonly number[] = [0, 750, 2000, 5000]

/** The `Schedule` half of the policy: `len(delaysMs) - 1` retries, separated
 * by `delaysMs[1..]`. The leading `0` is the "don't wait before the first
 * try" entry and is consumed by the caller, not scheduled. */
export const historyRetrySchedule = (delaysMs: readonly number[]): Schedule.Schedule<unknown> => {
  const backoffs = delaysMs.slice(1)
  if (backoffs.length === 0) return Schedule.stop
  // `fromDelays` is unbounded; intersecting with `recurs` bounds it to exactly
  // one retry per backoff entry, so `len(delaysMs)` is the attempt count.
  return Schedule.fromDelays(backoffs[0]!, ...backoffs.slice(1)).pipe(
    Schedule.intersect(Schedule.recurs(backoffs.length)),
  )
}

/**
 * Run `attempt` until it succeeds, waiting `delaysMs[attempt]` before each
 * try. Fails with the LAST error once the schedule is exhausted — the caller
 * decides what an exhausted schedule means (for ChatView: the inline error
 * state plus its Retry button, never "this session is empty").
 *
 * `onRetry` fires on EVERY failure, including the last one, so a reader can
 * tell "still retrying" from "gave up" by comparing it against the schedule
 * length. `delaysMs` is injectable so specs can collapse the backoff to zero
 * instead of waiting out the real schedule.
 */
export const fetchInitialHistoryWithRetry = <A, E>(
  attempt: () => Effect.Effect<A, E>,
  options: {
    delaysMs?: readonly number[]
    onRetry?: (error: E) => void
  } = {},
): Effect.Effect<A, E> => {
  const delaysMs = options.delaysMs ?? INITIAL_HISTORY_RETRY_DELAYS_MS
  const once = options.onRetry
    ? Effect.tapError(attempt(), (error) => Effect.sync(() => options.onRetry?.(error)))
    : attempt()
  return Effect.retry(once, historyRetrySchedule(delaysMs))
}
