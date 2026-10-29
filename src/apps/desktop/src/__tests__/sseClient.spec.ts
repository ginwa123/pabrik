/** sseClient.spec.ts Unit tests for `helpers/sseClient.ts`. Uses a controllable mock `EventSource`
 * (no real network) and vitest fake timers for deterministic backoff assertions. Coverage (matches
 * the 9 tests): 1. */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

import { createSseClient, type SseState } from '../helpers/sseClient'
import {
  createMockCtor,
  createMockTarget,
  createMockOnlineTarget,
} from './_helpers/sseClientHarness'

describe('createSseClient', () => {
  beforeEach(() => {
    vi.useFakeTimers()
  })
  afterEach(() => {
    vi.useRealTimers()
  })

  // 1. Backoff schedule
  it('uses exponential backoff with full jitter on consecutive errors', () => {
    const { ctor, instances } = createMockCtor()
    const { target: visTarget } = createMockTarget(false)
    const { target: onlineTarget } = createMockOnlineTarget()

    const client = createSseClient({
      url: '/test',
      EventSourceCtor: ctor,
      visibilityTarget: visTarget,
      onlineTarget: onlineTarget,
      // Deterministic random: returns the midpoint (0.5) so jitter
      // is always 0.75 of the exponential value.
      random: () => 0.5,
      pauseWhenHidden: false,
      baseDelayMs: 1_000,
      maxDelayMs: 30_000,
      onEvent: () => {},
    })

    // Flush the deferred start() — createSseClient schedules start() on the next
    // macrotask so the SSE setup is fully async (see helpers/sseClient.ts).
    vi.advanceTimersByTime(0)
    // First instance: open it, then error it 5 times.
    instances[0]!.simulateOpen()
    instances[0]!.emit('error')
    // Attempt 1 failed; exp = 1000 * 2^0 = 1000, delay = 750
    expect(client.getState()).toBe('reconnecting')

    // Advance 750ms → next attempt
    vi.advanceTimersByTime(750)
    expect(instances.length).toBe(2)
    instances[1]!.simulateOpen()
    instances[1]!.emit('error')
    // Attempt 2 failed; exp = 1000 * 2^1 = 2000, delay = 1500
    expect(client.getState()).toBe('reconnecting')

    vi.advanceTimersByTime(1_500)
    expect(instances.length).toBe(3)
    instances[2]!.simulateOpen()
    instances[2]!.emit('error')
    // Attempt 3 failed; exp = 1000 * 2^2 = 4000, delay = 3000
    expect(client.getState()).toBe('reconnecting')

    vi.advanceTimersByTime(3_000)
    expect(instances.length).toBe(4)
    instances[3]!.simulateOpen()
    instances[3]!.emit('error')
    // Attempt 4 failed; exp = 1000 * 2^3 = 8000, delay = 6000
    expect(client.getState()).toBe('reconnecting')

    vi.advanceTimersByTime(6_000)
    expect(instances.length).toBe(5)
    instances[4]!.simulateOpen()
    instances[4]!.emit('error')
    // Attempt 5 failed; exp = 1000 * 2^4 = 16000, delay = 12000
    expect(client.getState()).toBe('reconnecting')

    client.close()
  })

  // 2. Jitter range
  it('jitter scales delay between 0.5×exp and 1.0×exp', () => {
    // With random=0, the actual delay is exp * 0.5. We assert by checking that the timer is
    // scheduled with the expected delay using `vi.getTimerCount()` / next fire time.
    const seenDelays: number[] = []

    // ── random=0: min jitter ──
    {
      const { ctor, instances } = createMockCtor()
      const { target: visTarget } = createMockTarget(false)
      const { target: onlineTarget } = createMockOnlineTarget()
      const client = createSseClient({
        url: '/test',
        EventSourceCtor: ctor,
        visibilityTarget: visTarget,
        onlineTarget: onlineTarget,
        random: () => 0,
        pauseWhenHidden: false,
        baseDelayMs: 1_000,
        maxDelayMs: 30_000,
        onEvent: () => {},
        onStateChange: (state, info) => {
          if (state === 'reconnecting' && info.nextDelayMs !== undefined) {
            seenDelays.push(info.nextDelayMs)
          }
        },
      })

      // Flush the deferred start() — createSseClient schedules start() on the next
      // macrotask so the SSE setup is fully async (see helpers/sseClient.ts).
      vi.advanceTimersByTime(0)
      instances[0]!.simulateOpen()
      instances[0]!.emit('error')
      // exp = 1000, jitter = 0.5, delay = 500
      expect(seenDelays[0]).toBe(500)
      client.close()
    }

    // ── random=1: max jitter (1.0) ──
    {
      const seenDelays2: number[] = []
      const { ctor, instances } = createMockCtor()
      const { target: visTarget } = createMockTarget(false)
      const { target: onlineTarget } = createMockOnlineTarget()
      const client = createSseClient({
        url: '/test',
        EventSourceCtor: ctor,
        visibilityTarget: visTarget,
        onlineTarget: onlineTarget,
        random: () => 1,
        pauseWhenHidden: false,
        baseDelayMs: 1_000,
        maxDelayMs: 30_000,
        onEvent: () => {},
        onStateChange: (state, info) => {
          if (state === 'reconnecting' && info.nextDelayMs !== undefined) {
            seenDelays2.push(info.nextDelayMs)
          }
        },
      })

      // Flush the deferred start() — createSseClient schedules start() on the next
      // macrotask so the SSE setup is fully async (see helpers/sseClient.ts).
      vi.advanceTimersByTime(0)
      instances[0]!.simulateOpen()
      instances[0]!.emit('error')
      // exp = 1000, jitter = 1.0, delay = 1000
      expect(seenDelays2[0]).toBe(1_000)
      client.close()
    }
  })

  // 3. Open cancels retry
  it('an `open` event cancels a pending retry', () => {
    const { ctor, instances } = createMockCtor()
    const { target: visTarget } = createMockTarget(false)
    const { target: onlineTarget } = createMockOnlineTarget()

    const client = createSseClient({
      url: '/test',
      EventSourceCtor: ctor,
      visibilityTarget: visTarget,
      onlineTarget: onlineTarget,
      random: () => 0.5,
      pauseWhenHidden: false,
      // Stall recovery would fire during the 10s idle below and create
      // a 4th instance — disable it so this test isolates the
      // "open cancels retry" path (stall covered in sseStallRecovery.spec).
      stallRecovery: false,
      onEvent: () => {},
    })

    // Flush the deferred start() — createSseClient schedules start() on the next
    // macrotask so the SSE setup is fully async (see helpers/sseClient.ts).
    vi.advanceTimersByTime(0)
    instances[0]!.simulateOpen()
    instances[0]!.emit('error')
    // We are now in 'reconnecting' with a 750ms timer.
    expect(client.getState()).toBe('reconnecting')
    expect(instances.length).toBe(1)

    // Now open a second instance (simulating the SseClient's internal start() during retry) and
    // emit 'open' for it. We need to advance the timer for start() to fire, then open the new
    // instance.
    vi.advanceTimersByTime(750)
    expect(instances.length).toBe(2)
    // Even though the retry fired, no new error yet — the open
    // event will reset the attempt counter and put us in 'open'.
    instances[1]!.simulateOpen()
    expect(client.getState()).toBe('open')

    // Trigger another error, then call open again before the
    // retry timer fires. The new open should cancel the timer.
    instances[1]!.emit('error')
    expect(client.getState()).toBe('reconnecting')
    // Force the next attempt manually via the public API to
    // simulate "open arrives first". This is the "open cancels
    // retry" case.
    client.reconnect()
    // reconnect() closes the dead ES, so emit 'open' on the
    // freshly-created third instance.
    expect(instances.length).toBe(3)
    instances[2]!.simulateOpen()
    expect(client.getState()).toBe('open')
    // Advance well past the original retry window — no extra
    // instance should be created.
    vi.advanceTimersByTime(10_000)
    expect(instances.length).toBe(3)

    client.close()
  })

  // 4. First error is fatal (no retry)
  it('fails immediately on error before the first open', () => {
    const { ctor, instances } = createMockCtor()
    const { target: visTarget } = createMockTarget(false)
    const { target: onlineTarget } = createMockOnlineTarget()

    const client = createSseClient({
      url: '/test',
      EventSourceCtor: ctor,
      visibilityTarget: visTarget,
      onlineTarget: onlineTarget,
      pauseWhenHidden: false,
      onEvent: () => {},
    })

    // Flush the deferred start() — createSseClient schedules start() on the next
    // macrotask so the SSE setup is fully async (see helpers/sseClient.ts).
    vi.advanceTimersByTime(0)
    // No 'open' — emit error straight away.
    instances[0]!.emit('error')
    expect(client.getState()).toBe('failed')

    // Advance time — no new attempts should be scheduled.
    vi.advanceTimersByTime(60_000)
    expect(instances.length).toBe(1)

    client.close()
  })

  // 4b. Non-recoverable when EventSource constructor throws
  it('fails immediately when the EventSource constructor throws', () => {
    const { target: visTarget } = createMockTarget(false)
    const { target: onlineTarget } = createMockOnlineTarget()

    const ThrowingCtor = function (): never {
      throw new Error('Invalid URL')
    } as unknown as typeof EventSource

    const client = createSseClient({
      url: '/test',
      EventSourceCtor: ThrowingCtor,
      visibilityTarget: visTarget,
      onlineTarget: onlineTarget,
      pauseWhenHidden: false,
      onEvent: () => {},
    })

    // Flush the deferred start() — createSseClient schedules start() on the next
    // macrotask so the SSE setup is fully async (see helpers/sseClient.ts).
    vi.advanceTimersByTime(0)
    expect(client.getState()).toBe('failed')
    client.close()
  })

  // 5. Mid-stream retry
  it('reconnects after an error following a successful open', () => {
    const { ctor, instances } = createMockCtor()
    const { target: visTarget } = createMockTarget(false)
    const { target: onlineTarget } = createMockOnlineTarget()

    const client = createSseClient({
      url: '/test',
      EventSourceCtor: ctor,
      visibilityTarget: visTarget,
      onlineTarget: onlineTarget,
      random: () => 0.5,
      pauseWhenHidden: false,
      onEvent: () => {},
    })

    // Flush the deferred start() — createSseClient schedules start() on the next
    // macrotask so the SSE setup is fully async (see helpers/sseClient.ts).
    vi.advanceTimersByTime(0)
    instances[0]!.simulateOpen()
    expect(client.getState()).toBe('open')
    instances[0]!.emit('error')
    expect(client.getState()).toBe('reconnecting')
    // Advance the backoff — new instance appears.
    vi.advanceTimersByTime(750)
    expect(instances.length).toBe(2)

    client.close()
  })

  // 5b. maxAttempts is honored
  it('transitions to `failed` after maxAttempts retries are exhausted', () => {
    const { ctor, instances } = createMockCtor()
    const { target: visTarget } = createMockTarget(false)
    const { target: onlineTarget } = createMockOnlineTarget()

    const client = createSseClient({
      url: '/test',
      EventSourceCtor: ctor,
      visibilityTarget: visTarget,
      onlineTarget: onlineTarget,
      pauseWhenHidden: false,
      maxAttempts: 2,
      onEvent: () => {},
    })

    // Flush the deferred start() — createSseClient schedules start() on the next
    // macrotask so the SSE setup is fully async (see helpers/sseClient.ts).
    vi.advanceTimersByTime(0)
    // attempt 1: open then error → reconnecting (attempt 1)
    instances[0]!.simulateOpen()
    instances[0]!.emit('error')
    // Advance to fire retry.
    vi.advanceTimersByTime(60_000)
    // attempt 2: open then error → reconnecting (attempt 2)
    instances[1]!.simulateOpen()
    instances[1]!.emit('error')
    // Advance to fire retry. The retry creates a third EventSource and bumps `attempt` to 3, but
    // the connection is not yet `failed` — `failed` is only emitted by `handleError` when the new
    // instance errors and `attempt > maxAttempts`.
    vi.advanceTimersByTime(60_000)
    expect(instances.length).toBe(3)
    // Open + error the 3rd instance. attempt=3 > maxAttempts=2
    // → state goes to 'failed' (terminal).
    instances[2]!.simulateOpen()
    instances[2]!.emit('error')
    expect(client.getState()).toBe('failed')

    client.close()
  })

  // 6. Visibility pause
  it('pauses the retry timer while the tab is hidden and fires on visible', () => {
    const { ctor, instances } = createMockCtor()
    const { target: visTarget } = createMockTarget(true) // start hidden
    const { target: onlineTarget } = createMockOnlineTarget()

    const client = createSseClient({
      url: '/test',
      EventSourceCtor: ctor,
      visibilityTarget: visTarget,
      onlineTarget: onlineTarget,
      pauseWhenHidden: true,
      onEvent: () => {},
    })

    // Flush the deferred start() — createSseClient schedules start() on the next
    // macrotask so the SSE setup is fully async (see helpers/sseClient.ts).
    vi.advanceTimersByTime(0)
    // Open then error while hidden.
    instances[0]!.simulateOpen()
    instances[0]!.emit('error')
    expect(client.getState()).toBe('reconnecting')
    // No timer should be scheduled — we are paused.
    expect(vi.getTimerCount()).toBe(0)

    // Advance time — still no new instance.
    vi.advanceTimersByTime(120_000)
    expect(instances.length).toBe(1)

    // Become visible.
    visTarget.setHidden(false)
    visTarget.fire('visibilitychange')
    // Now a fresh instance is created.
    expect(instances.length).toBe(2)

    client.close()
  })

  // 7. Online fast-path
  it('reconnects immediately on the browser `online` event', () => {
    const { ctor, instances } = createMockCtor()
    const { target: visTarget } = createMockTarget(false)
    const { target: onlineTarget } = createMockOnlineTarget()

    const client = createSseClient({
      url: '/test',
      EventSourceCtor: ctor,
      visibilityTarget: visTarget,
      onlineTarget: onlineTarget,
      pauseWhenHidden: false,
      onEvent: () => {},
    })

    // Flush the deferred start() — createSseClient schedules start() on the next
    // macrotask so the SSE setup is fully async (see helpers/sseClient.ts).
    vi.advanceTimersByTime(0)
    instances[0]!.simulateOpen()
    instances[0]!.emit('error')
    expect(client.getState()).toBe('reconnecting')
    expect(instances.length).toBe(1)

    // `online` event fires — should fast-path to a new instance.
    onlineTarget.fire('online')
    expect(instances.length).toBe(2)

    client.close()
  })

  // 8. Close is terminal
  it('close() is terminal — no further state changes or attempts', () => {
    const { ctor, instances } = createMockCtor()
    const { target: visTarget } = createMockTarget(false)
    const { target: onlineTarget } = createMockOnlineTarget()

    const states: SseState[] = []
    const client = createSseClient({
      url: '/test',
      EventSourceCtor: ctor,
      visibilityTarget: visTarget,
      onlineTarget: onlineTarget,
      pauseWhenHidden: false,
      onEvent: () => {},
      onStateChange: (s) => states.push(s),
    })

    // Flush the deferred start() — createSseClient schedules start() on the next
    // macrotask so the SSE setup is fully async (see helpers/sseClient.ts).
    vi.advanceTimersByTime(0)
    instances[0]!.simulateOpen()
    client.close()
    expect(client.getState()).toBe('closed')
    // After close, more events on the dead instance must not
    // change state.
    instances[0]!.emit('error')
    expect(client.getState()).toBe('closed')
    // online + visibility must not retry.
    onlineTarget.fire('online')
    visTarget.fire('visibilitychange')
    expect(instances.length).toBe(1)
    // We saw at least ['connecting', 'open', 'closed'].
    expect(states).toEqual(['connecting', 'open', 'closed'])
  })

  // 8b. close() is idempotent
  it('close() is safe to call multiple times', () => {
    const { ctor, instances } = createMockCtor()
    const { target: visTarget } = createMockTarget(false)
    const { target: onlineTarget } = createMockOnlineTarget()

    const client = createSseClient({
      url: '/test',
      EventSourceCtor: ctor,
      visibilityTarget: visTarget,
      onlineTarget: onlineTarget,
      onEvent: () => {},
    })

    // Flush the deferred start() — createSseClient schedules start() on the next
    // macrotask so the SSE setup is fully async (see helpers/sseClient.ts).
    vi.advanceTimersByTime(0)
    client.close()
    client.close()
    client.close()
    expect(client.getState()).toBe('closed')
    // Should not have re-attached listeners or created instances.
    expect(instances.length).toBe(1)
  })

  // 9. State emission order
  it('emits the expected state sequence on connect → error → reconnect → open', () => {
    const { ctor, instances } = createMockCtor()
    const { target: visTarget } = createMockTarget(false)
    const { target: onlineTarget } = createMockOnlineTarget()

    const states: SseState[] = []
    const client = createSseClient({
      url: '/test',
      EventSourceCtor: ctor,
      visibilityTarget: visTarget,
      onlineTarget: onlineTarget,
      pauseWhenHidden: false,
      onEvent: () => {},
      onStateChange: (s) => states.push(s),
      stallThresholdMs: 120_000,
      connectedTimeoutMs: 120_000,
    })

    // Flush the deferred start() — createSseClient schedules start() on the next
    // macrotask so the SSE setup is fully async (see helpers/sseClient.ts).
    vi.advanceTimersByTime(0)
    // Walk: construct → connecting, then open → open, then error
    // → reconnecting, then retry fires → connecting, then open
    // → open.
    expect(states[0]).toBe('connecting')
    instances[0]!.simulateOpen()
    expect(states[1]).toBe('open')
    instances[0]!.emit('error')
    expect(states[2]).toBe('reconnecting')
    vi.advanceTimersByTime(2_000)
    // A new instance was created → 'connecting' emitted.
    expect(states[3]).toBe('connecting')
    instances[1]!.simulateOpen()
    expect(states[4]).toBe('open')

    client.close()
    // close adds 'closed' at the end.
    expect(states[5]).toBe('closed')
    expect(states).toEqual(['connecting', 'open', 'reconnecting', 'connecting', 'open', 'closed'])
  })
})
