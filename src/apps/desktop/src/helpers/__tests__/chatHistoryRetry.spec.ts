import { Effect, Exit } from 'effect'
import { describe, expect, it, vi } from 'vitest'

import {
  fetchInitialHistoryWithRetry,
  historyRetrySchedule,
  INITIAL_HISTORY_RETRY_DELAYS_MS,
  INITIAL_HISTORY_TIMEOUT_MS,
} from '../chatHistoryRetry'

/** Run an Effect to an Exit without the test ever having to catch anything. */
const runExit = <A, E>(effect: Effect.Effect<A, E>): Promise<Exit.Exit<A, E>> =>
  Effect.runPromise(Effect.exit(effect))

/** The success value, or undefined — lets us assert without a conditional expect. */
const valueOf = <A, E>(exit: Exit.Exit<A, E>): A | undefined =>
  Exit.isSuccess(exit) ? exit.value : undefined

/** The failure cause, or undefined. */
const causeOf = <A, E>(exit: Exit.Exit<A, E>): unknown =>
  Exit.isFailure(exit) ? exit.cause : undefined

/** Collapse the backoff to zero so the retry tests do not wait it out. */
const NO_WAIT = [0, 0, 0, 0]

describe('INITIAL_HISTORY_TIMEOUT_MS', () => {
  it("outlives apiFetch's 15 s default — that abort is what faked an empty session", () => {
    // apiFetch: `timeoutMs = 15_000`.
    expect(INITIAL_HISTORY_TIMEOUT_MS).toBeGreaterThan(15_000)
  })

  it('is still finite, so a hung backend cannot park the skeleton forever', () => {
    expect(INITIAL_HISTORY_TIMEOUT_MS).toBeGreaterThan(0)
    expect(INITIAL_HISTORY_TIMEOUT_MS).toBeLessThan(120_000)
  })
})

describe('INITIAL_HISTORY_RETRY_DELAYS_MS', () => {
  it('starts at 0 — the first load must not wait', () => {
    expect(INITIAL_HISTORY_RETRY_DELAYS_MS[0]).toBe(0)
  })

  it('backs off monotonically from the second entry on', () => {
    const backoff = INITIAL_HISTORY_RETRY_DELAYS_MS.slice(1)
    expect(backoff.length).toBeGreaterThan(0)
    for (let i = 1; i < backoff.length; i++) {
      expect(backoff[i]!).toBeGreaterThan(backoff[i - 1]!)
    }
  })
})

describe('historyRetrySchedule', () => {
  it('stops immediately when there is no backoff entry', async () => {
    // A single delay means "try once, never retry" — the schedule must not keep the effect alive.
    const attempt = vi.fn().mockRejectedValue(new Error('nope'))
    const exit = await runExit(
      fetchInitialHistoryWithRetry(() => Effect.tryPromise({ try: () => attempt(), catch: (e) => e as Error }), {
        delaysMs: [0],
      }),
    )
    expect(Exit.isFailure(exit)).toBe(true)
    expect(attempt).toHaveBeenCalledTimes(1)
  })

  it('is exported so the policy can be inspected without running it', () => {
    expect(historyRetrySchedule).toBeTypeOf('function')
    expect(historyRetrySchedule([0])).toBeDefined()
    expect(historyRetrySchedule(INITIAL_HISTORY_RETRY_DELAYS_MS)).toBeDefined()
  })
})

describe('fetchInitialHistoryWithRetry', () => {
  it('returns the first success without a single retry', async () => {
    const attempt = vi.fn().mockResolvedValue('transcript')

    const exit = await runExit(
      fetchInitialHistoryWithRetry(() => Effect.tryPromise({ try: () => attempt(), catch: (e) => e as Error }), { delaysMs: NO_WAIT }),
    )

    expect(Exit.isSuccess(exit)).toBe(true)
    expect(valueOf(exit)).toBe('transcript')
    expect(attempt).toHaveBeenCalledTimes(1)
  })

  it('keeps going after failures and returns the eventual success', async () => {
    const attempt = vi
      .fn()
      .mockRejectedValueOnce(new Error('503'))
      .mockRejectedValueOnce(new Error('timeout'))
      .mockResolvedValue('transcript')

    const exit = await runExit(
      fetchInitialHistoryWithRetry(() => Effect.tryPromise({ try: () => attempt(), catch: (e) => e as Error }), { delaysMs: NO_WAIT }),
    )

    expect(Exit.isSuccess(exit)).toBe(true)
    expect(valueOf(exit)).toBe('transcript')
    expect(attempt).toHaveBeenCalledTimes(3)
  })

  it('fails on the error channel with the LAST error once the schedule is exhausted', async () => {
    const last = new Error('still down')
    const attempt = vi.fn().mockRejectedValueOnce(new Error('a')).mockRejectedValue(last)

    const exit = await runExit(
      fetchInitialHistoryWithRetry(() => Effect.tryPromise({ try: () => attempt(), catch: (e) => e as Error }), { delaysMs: NO_WAIT }),
    )

    // The failure must survive as a FAILURE, not degrade into a value — that is the whole point (AGENTS.md: never let a failure become an "empty").
    expect(Exit.isFailure(exit)).toBe(true)
    expect(causeOf(exit)).toBeDefined()
    expect(attempt).toHaveBeenCalledTimes(NO_WAIT.length)
  })

  it('reports every failure to onRetry so a reader can tell retrying from giving up', async () => {
    const attempt = vi.fn().mockRejectedValue(new Error('boom'))
    const onRetry = vi.fn()

    await runExit(
      fetchInitialHistoryWithRetry(() => Effect.tryPromise({ try: () => attempt(), catch: (e) => e as Error }), {
        delaysMs: NO_WAIT,
        onRetry,
      }),
    )

    // Once per failed attempt, including the last.
    expect(onRetry).toHaveBeenCalledTimes(NO_WAIT.length)
    expect(onRetry).toHaveBeenCalledWith(expect.any(Error))
  })

  it('does not call onRetry when the first attempt succeeds', async () => {
    const onRetry = vi.fn()
    await runExit(
      fetchInitialHistoryWithRetry(() => Effect.succeed('transcript'), {
        delaysMs: NO_WAIT,
        onRetry,
      }),
    )
    expect(onRetry).not.toHaveBeenCalled()
  })

  it('honours a custom schedule length', async () => {
    const attempt = vi.fn().mockRejectedValue(new Error('nope'))

    const exit = await runExit(
      fetchInitialHistoryWithRetry(() => Effect.tryPromise({ try: () => attempt(), catch: (e) => e as Error }), { delaysMs: [0, 0] }),
    )

    expect(Exit.isFailure(exit)).toBe(true)
    expect(attempt).toHaveBeenCalledTimes(2)
  })
})
