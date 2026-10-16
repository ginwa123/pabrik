/** Retry policy for the INITIAL transcript fetch in ChatView. */
import { Effect, Schedule } from 'effect'

/** Per-attempt budget. Deliberately far above `apiFetch`'s 15 s default: the transcript page is
 * `PAGE_SIZE = 1000` rows and routinely carries base64 `image_urls` plus tool JSON, for which the
 * constant's own comment warns about "slow TTFB". */
export const INITIAL_HISTORY_TIMEOUT_MS = 45_000

/**  * Delay BEFORE each attempt, in order. The first entry is `0` — the initial load must not wait.
 * Each later entry is the backoff after that attempt failed, so the full schedule is 4 attempts
 * spanning ~7.75 s of waiting plus however long each attempt itself takes. */
export const INITIAL_HISTORY_RETRY_DELAYS_MS: readonly number[] = [0, 750, 2000, 5000]

/**  * The `Schedule` half of the policy: `len(delaysMs) - 1` retries, separated by `delaysMs[1..]`. The
 * leading `0` is the "don't wait before the first try" entry and is consumed by the caller, not
 * scheduled. */
export const historyRetrySchedule = (delaysMs: readonly number[]): Schedule.Schedule<unknown> => {
  const backoffs = delaysMs.slice(1)
  if (backoffs.length === 0) return Schedule.stop
  // `fromDelays` is unbounded; intersecting with `recurs` bounds it to exactly
  // one retry per backoff entry, so `len(delaysMs)` is the attempt count.
  return Schedule.fromDelays(backoffs[0]!, ...backoffs.slice(1)).pipe(
    Schedule.intersect(Schedule.recurs(backoffs.length)),
  )
}

/** Run `attempt` until it succeeds, waiting `delaysMs[attempt]` before each try. Fails with the
 * LAST error once the schedule is exhausted — the caller decides what an exhausted schedule means
 * (for ChatView: the inline error state plus its Retry button, never "this session is empty"). */
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
