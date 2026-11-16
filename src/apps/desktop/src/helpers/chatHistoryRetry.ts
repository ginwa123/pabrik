/** Retry policy for the INITIAL transcript fetch in ChatView. */
import { Effect, Schedule } from 'effect'

/** Per-attempt budget. */
export const INITIAL_HISTORY_TIMEOUT_MS = 45_000

/** Delay BEFORE each attempt, in order. */
export const INITIAL_HISTORY_RETRY_DELAYS_MS: readonly number[] = [0, 750, 2000, 5000]

/** The `Schedule` half of the policy: `len(delaysMs) - 1` retries, separated by `delaysMs[1..]`. */
export const historyRetrySchedule = (delaysMs: readonly number[]): Schedule.Schedule<unknown> => {
  const backoffs = delaysMs.slice(1)
  if (backoffs.length === 0) return Schedule.stop
  // `fromDelays` is unbounded; intersecting with `recurs` bounds it to exactly one retry per backoff entry, so `len(delaysMs)` is the attempt count.
  return Schedule.fromDelays(backoffs[0]!, ...backoffs.slice(1)).pipe(
    Schedule.intersect(Schedule.recurs(backoffs.length)),
  )
}

/** Run `attempt` until it succeeds, waiting `delaysMs[attempt]` before each try. */
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
