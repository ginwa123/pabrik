/** sseClient.spec.ts Unit tests for `helpers/sseClient.ts`. Uses a controllable mock `EventSource`
 * (no real network) and vitest fake timers for deterministic backoff assertions. Coverage (matches
 * the 9 tests): 1. */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

import { createSseClient, type SseState } from '../helpers/sseClient'

// ─── Mock EventSource ──────────────────────────────────────────────────── A controllable
// replacement for the browser-native EventSource. Captures every listener registered, every close()
// call, and lets tests fire synthetic events.
interface MockEventSource {
  url: string
  readyState: number
  onerror: ((e: Event) => void) | null
  close: () => void
  addEventListener: (type: string, listener: EventListenerOrEventListenerObject) => void
  removeEventListener: (type: string, listener: EventListenerOrEventListenerObject) => void
  emit(type: 'open' | 'error' | 'message' | string, data?: string): void
  /** Simulate the server's `connected` named event. This is what the SseClient uses as the
   * canonical "stream is live" signal (per the backend convention). */
  simulateOpen(payload?: string): void
  /** All listeners, by type. */
  _listeners: Map<string, Set<EventListenerOrEventListenerObject>>
  _closed: boolean
}

function createMockCtor(): {
  ctor: typeof EventSource
  instances: MockEventSource[]
} {
  const instances: MockEventSource[] = []
  const ctor = function MockEventSource(this: unknown, url: string): MockEventSource {
    const inst: MockEventSource = {
      url,
      readyState: 0,
      onerror: null,
      _listeners: new Map(),
      _closed: false,
      close() {
        this._closed = true
        this.readyState = 2
      },
      addEventListener(type: string, listener: EventListenerOrEventListenerObject) {
        let set = this._listeners.get(type)
        if (!set) {
          set = new Set()
          this._listeners.set(type, set)
        }
        set.add(listener)
      },
      removeEventListener(type: string, listener: EventListenerOrEventListenerObject) {
        const set = this._listeners.get(type)
        if (set) set.delete(listener)
      },
      emit(type: string, data?: string) {
        // Build a real MessageEvent if the type is message-like.
        // Using `new MessageEvent` requires a real DOM env; jsdom
        // provides one, so this works.
        const ev = data !== undefined ? new MessageEvent(type, { data }) : new Event(type)
        // Fire addEventListener-style listeners, if any. The native EventSource fires BOTH
        // addEventListener listeners AND the `onerror` property — they are independent — so we must
        // do the same.
        const set = this._listeners.get(type)
        if (set) {
          for (const listener of set) {
            if (typeof listener === 'function') listener(ev)
            else listener.handleEvent(ev)
          }
        }
        // Also fire onerror (the property, not the listener) for
        // parity with the native EventSource behavior.
        if (type === 'error' && this.onerror) {
          this.onerror(ev)
        }
      },
      simulateOpen(payload: string = '{"ok":true}') {
        this.emit('connected', payload)
      },
    }
    instances.push(inst)
    return inst
  } as unknown as typeof EventSource
  return { ctor: ctor as unknown as typeof EventSource, instances }
}

// ─── Mock visibility / online targets ───────────────────────────────────
function createMockTarget(hidden = false): {
  target: Pick<Document, 'addEventListener' | 'removeEventListener' | 'hidden'> & {
    _listeners: Map<string, Set<EventListenerOrEventListenerObject>>
    setHidden(v: boolean): void
    fire(type: string): void
  }
} {
  const target = {
    hidden,
    _listeners: new Map<string, Set<EventListenerOrEventListenerObject>>(),
    addEventListener(type: string, listener: EventListenerOrEventListenerObject) {
      let set = this._listeners.get(type)
      if (!set) {
        set = new Set()
        this._listeners.set(type, set)
      }
      set.add(listener)
    },
    removeEventListener(type: string, listener: EventListenerOrEventListenerObject) {
      const set = this._listeners.get(type)
      if (set) set.delete(listener)
    },
    setHidden(v: boolean) {
      this.hidden = v
    },
    fire(type: string) {
      const set = this._listeners.get(type)
      if (!set) return
      for (const listener of set) {
        if (typeof listener === 'function') listener(new Event(type))
        else listener.handleEvent(new Event(type))
      }
    },
  }
  return { target }
}

function createMockOnlineTarget(): {
  target: Pick<Window, 'addEventListener' | 'removeEventListener'> & {
    _listeners: Map<string, Set<EventListenerOrEventListenerObject>>
    fire(type: string): void
  }
} {
  return {
    target: {
      _listeners: new Map<string, Set<EventListenerOrEventListenerObject>>(),
      addEventListener(type: string, listener: EventListenerOrEventListenerObject) {
        let set = this._listeners.get(type)
        if (!set) {
          set = new Set()
          this._listeners.set(type, set)
        }
        set.add(listener)
      },
      removeEventListener(type: string, listener: EventListenerOrEventListenerObject) {
        const set = this._listeners.get(type)
        if (set) set.delete(listener)
      },
      fire(type: string) {
        const set = this._listeners.get(type)
        if (!set) return
        for (const listener of set) {
          if (typeof listener === 'function') listener(new Event(type))
          else listener.handleEvent(new Event(type))
        }
      },
    },
  }
}

// Mock `window` for the `pagehide` / `beforeunload` listeners. Same shape as the online target —
// both `addEventListener` and `removeEventListener` accounting, plus a `fire(type)` helper to
// simulate the browser firing the unload event.
function createMockUnloadTarget(): {
  target: Pick<Window, 'addEventListener' | 'removeEventListener'> & {
    _listeners: Map<string, Set<EventListenerOrEventListenerObject>>
    fire(type: string): void
  }
} {
  return {
    target: {
      _listeners: new Map<string, Set<EventListenerOrEventListenerObject>>(),
      addEventListener(type: string, listener: EventListenerOrEventListenerObject) {
        let set = this._listeners.get(type)
        if (!set) {
          set = new Set()
          this._listeners.set(type, set)
        }
        set.add(listener)
      },
      removeEventListener(type: string, listener: EventListenerOrEventListenerObject) {
        const set = this._listeners.get(type)
        if (set) set.delete(listener)
      },
      fire(type: string) {
        const set = this._listeners.get(type)
        if (!set) return
        for (const listener of set) {
          if (typeof listener === 'function') listener(new Event(type))
          else listener.handleEvent(new Event(type))
        }
      },
    },
  }
}

// ─── Tests ──────────────────────────────────────────────────────────────
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

  // 9b. 'connected' server event fires onConnected
  it('fires onConnected and passes the payload to onEvent on the `connected` event', () => {
    const { ctor, instances } = createMockCtor()
    const { target: visTarget } = createMockTarget(false)
    const { target: onlineTarget } = createMockOnlineTarget()

    const onConnected = vi.fn()
    const onEvent = vi.fn()

    const client = createSseClient({
      url: '/test',
      EventSourceCtor: ctor,
      visibilityTarget: visTarget,
      onlineTarget: onlineTarget,
      pauseWhenHidden: false,
      onConnected,
      onEvent,
    })

    // Flush the deferred start() — createSseClient schedules start() on the next
    // macrotask so the SSE setup is fully async (see helpers/sseClient.ts).
    vi.advanceTimersByTime(0)
    // Emit the 'connected' named event with a JSON payload.
    instances[0]!.emit('connected', JSON.stringify({ session_id: 'abc' }))
    expect(onConnected).toHaveBeenCalledTimes(1)
    expect(onEvent).toHaveBeenCalledWith(JSON.stringify({ session_id: 'abc' }), 'connected')
    expect(client.getState()).toBe('open')

    client.close()
  })

  // 9c. 'message' events go to onEvent
  it('routes `message` events to onEvent with the raw payload and type "message"', () => {
    const { ctor, instances } = createMockCtor()
    const { target: visTarget } = createMockTarget(false)
    const { target: onlineTarget } = createMockOnlineTarget()

    const onEvent = vi.fn()
    const client = createSseClient({
      url: '/test',
      EventSourceCtor: ctor,
      visibilityTarget: visTarget,
      onlineTarget: onlineTarget,
      pauseWhenHidden: false,
      onEvent,
    })

    // Flush the deferred start() — createSseClient schedules start() on the next
    // macrotask so the SSE setup is fully async (see helpers/sseClient.ts).
    vi.advanceTimersByTime(0)
    instances[0]!.emit('connected', '{"ok":true}')
    onEvent.mockClear() // drop the 'connected' call
    instances[0]!.emit('message', '{"chunk":"hello"}')
    expect(onEvent).toHaveBeenCalledWith('{"chunk":"hello"}', 'message')

    client.close()
  })

  // 9d. additionalEventTypes registers listeners for custom named events (e.g. `queue_message`) and
  // routes them to onEvent.
  it('routes `additionalEventTypes` named events to onEvent with the event name as the type', () => {
    const { ctor, instances } = createMockCtor()
    const { target: visTarget } = createMockTarget(false)
    const { target: onlineTarget } = createMockOnlineTarget()

    const onEvent = vi.fn()
    const client = createSseClient({
      url: '/test',
      EventSourceCtor: ctor,
      visibilityTarget: visTarget,
      onlineTarget: onlineTarget,
      pauseWhenHidden: false,
      additionalEventTypes: ['queue_message', 'worker_event'],
      onEvent,
    })

    // Flush the deferred start() — createSseClient schedules start() on the next
    // macrotask so the SSE setup is fully async (see helpers/sseClient.ts).
    vi.advanceTimersByTime(0)
    // Confirm the SseClient actually registered the listeners on
    // the EventSource instance. Without these, the mock's `emit`
    // would have no listener to call.
    expect(instances[0]!._listeners.get('queue_message')?.size ?? 0).toBe(1)
    expect(instances[0]!._listeners.get('worker_event')?.size ?? 0).toBe(1)

    instances[0]!.emit('connected', '{"ok":true}')
    onEvent.mockClear()
    instances[0]!.emit('queue_message', '{"action":"queued","message":"hi"}')
    expect(onEvent).toHaveBeenCalledWith('{"action":"queued","message":"hi"}', 'queue_message')

    // A second declared type also routes through.
    onEvent.mockClear()
    instances[0]!.emit('worker_event', '{"id":"w1"}')
    expect(onEvent).toHaveBeenCalledWith('{"id":"w1"}', 'worker_event')

    client.close()
  })

  // 9e. additionalEventTypes dedupes reserved names. Passing `connected` or `message` in the list
  // must NOT register a second listener (which would cause onEvent to fire twice per event,
  // doubling the consumer's parse work).
  it('silently de-duplicates reserved names (`connected`, `message`) in additionalEventTypes', () => {
    const { ctor, instances } = createMockCtor()
    const { target: visTarget } = createMockTarget(false)
    const { target: onlineTarget } = createMockOnlineTarget()

    const onEvent = vi.fn()
    const client = createSseClient({
      url: '/test',
      EventSourceCtor: ctor,
      visibilityTarget: visTarget,
      onlineTarget: onlineTarget,
      pauseWhenHidden: false,
      additionalEventTypes: ['connected', 'message', 'queue_message'],
      onEvent,
    })

    // Flush the deferred start() — createSseClient schedules start() on the next
    // macrotask so the SSE setup is fully async (see helpers/sseClient.ts).
    vi.advanceTimersByTime(0)
    // 'connected' is registered by the SseClient itself (1
    // listener); the dedupe must NOT add a second.
    expect(instances[0]!._listeners.get('connected')?.size ?? 0).toBe(1)
    // 'message' is also registered by the SseClient itself.
    expect(instances[0]!._listeners.get('message')?.size ?? 0).toBe(1)
    // 'queue_message' is a custom name and gets one listener.
    expect(instances[0]!._listeners.get('queue_message')?.size ?? 0).toBe(1)

    // Confirm a 'message' event fires onEvent exactly once
    // (not twice from the dedup-bug).
    instances[0]!.emit('connected', '{"ok":true}')
    onEvent.mockClear()
    instances[0]!.emit('message', 'real-data')
    expect(onEvent).toHaveBeenCalledTimes(1)
    expect(onEvent).toHaveBeenCalledWith('real-data', 'message')

    client.close()
  })

  // 9f. additionalEventTypes listeners are re-registered on reconnect. When a retry fires `start()`
  // again, a fresh EventSource is built and the previous instance's listeners are gone — the new
  // instance must get the same named-event listeners.
  it('re-registers additionalEventTypes listeners after a reconnect', () => {
    const { ctor, instances } = createMockCtor()
    const { target: visTarget } = createMockTarget(false)
    const { target: onlineTarget } = createMockOnlineTarget()

    const onEvent = vi.fn()
    const client = createSseClient({
      url: '/test',
      EventSourceCtor: ctor,
      visibilityTarget: visTarget,
      onlineTarget: onlineTarget,
      // Deterministic random: returns the midpoint (0.5) so jitter is always 0.75 of the
      // exponential value. With baseDelayMs=1000, the first retry's exp = 1000 * 2^0 = 1000 and
      // delay = 750ms — easy to advance past.
      random: () => 0.5,
      pauseWhenHidden: false,
      baseDelayMs: 1_000,
      maxDelayMs: 30_000,
      additionalEventTypes: ['queue_message'],
      onEvent,
    })

    // Flush the deferred start() — createSseClient schedules start() on the next
    // macrotask so the SSE setup is fully async (see helpers/sseClient.ts).
    vi.advanceTimersByTime(0)
    // First instance: listener registered.
    expect(instances[0]!._listeners.get('queue_message')?.size ?? 0).toBe(1)

    // Simulate a connect → error → reconnect cycle. The error calls es.close() (releasing listeners
    // on the dead ES) and schedules a retry; advancing the timer fires the retry and constructs a
    // new EventSource.
    instances[0]!.emit('connected', '{"ok":true}')
    instances[0]!.emit('error')

    // Advance past the 750ms backoff to trigger the retry.
    vi.advanceTimersByTime(750)
    expect(instances.length).toBeGreaterThanOrEqual(2)

    // The new instance has the `queue_message` listener
    // re-attached.
    expect(instances[1]!._listeners.get('queue_message')?.size ?? 0).toBe(1)

    // And the listener actually fires when the server sends the
    // named event on the new connection.
    instances[1]!.emit('queue_message', '{"action":"deleted"}')
    expect(onEvent).toHaveBeenCalledWith('{"action":"deleted"}', 'queue_message')

    client.close()
  })

  // 9g. Default 'message' events whose payload equals `'ping'` (the backend's keepalive) are
  // silently dropped. The consumer never sees them, so JSON-buffering adapters don't grow an
  // unbounded buffer of "ping\nping\n..." between real events.
  it('silently drops `ping` heartbeat messages from the default `message` event', () => {
    const { ctor, instances } = createMockCtor()
    const { target: visTarget } = createMockTarget(false)
    const { target: onlineTarget } = createMockOnlineTarget()

    const onEvent = vi.fn()
    const client = createSseClient({
      url: '/test',
      EventSourceCtor: ctor,
      visibilityTarget: visTarget,
      onlineTarget: onlineTarget,
      pauseWhenHidden: false,
      onEvent,
    })

    // Flush the deferred start() — createSseClient schedules start() on the next
    // macrotask so the SSE setup is fully async (see helpers/sseClient.ts).
    vi.advanceTimersByTime(0)
    instances[0]!.emit('connected', '{"ok":true}')
    onEvent.mockClear()

    // 100 heartbeats in a row should result in ZERO onEvent
    // calls. (If the filter were broken, the consumer would see
    // 100 calls with raw === 'ping'.)
    for (let i = 0; i < 100; i++) {
      instances[0]!.emit('message', 'ping')
    }
    expect(onEvent).not.toHaveBeenCalled()

    // A real message still passes through.
    instances[0]!.emit('message', '{"real":"data"}')
    expect(onEvent).toHaveBeenCalledWith('{"real":"data"}', 'message')
    expect(onEvent).toHaveBeenCalledTimes(1)

    client.close()
  })

  // 9h. Setting `heartbeatData: null` disables the heartbeat filter — every default `message` event
  // reaches `onEvent`, including the `'ping'` keepalive. Useful for tests, or for consumers that
  // want to count heartbeats.
  it('disables the heartbeat filter when heartbeatData is null', () => {
    const { ctor, instances } = createMockCtor()
    const { target: visTarget } = createMockTarget(false)
    const { target: onlineTarget } = createMockOnlineTarget()

    const onEvent = vi.fn()
    const client = createSseClient({
      url: '/test',
      EventSourceCtor: ctor,
      visibilityTarget: visTarget,
      onlineTarget: onlineTarget,
      pauseWhenHidden: false,
      heartbeatData: null,
      onEvent,
    })

    // Flush the deferred start() — createSseClient schedules start() on the next
    // macrotask so the SSE setup is fully async (see helpers/sseClient.ts).
    vi.advanceTimersByTime(0)
    instances[0]!.emit('connected', '{"ok":true}')
    onEvent.mockClear()

    instances[0]!.emit('message', 'ping')
    expect(onEvent).toHaveBeenCalledWith('ping', 'message')
    expect(onEvent).toHaveBeenCalledTimes(1)

    client.close()
  })

  // 9i. Setting `heartbeatData` to a custom string filters that
  // exact payload (rather than always 'ping'). Tests / servers
  // that use a different keepalive token can plug it in.
  it('uses a custom heartbeatData string when provided', () => {
    const { ctor, instances } = createMockCtor()
    const { target: visTarget } = createMockTarget(false)
    const { target: onlineTarget } = createMockOnlineTarget()

    const onEvent = vi.fn()
    const client = createSseClient({
      url: '/test',
      EventSourceCtor: ctor,
      visibilityTarget: visTarget,
      onlineTarget: onlineTarget,
      pauseWhenHidden: false,
      heartbeatData: ':keepalive',
      onEvent,
    })

    // Flush the deferred start() — createSseClient schedules start() on the next
    // macrotask so the SSE setup is fully async (see helpers/sseClient.ts).
    vi.advanceTimersByTime(0)
    instances[0]!.emit('connected', '{"ok":true}')
    onEvent.mockClear()

    // The custom keepalive is filtered.
    instances[0]!.emit('message', ':keepalive')
    expect(onEvent).not.toHaveBeenCalled()

    // The default 'ping' is NOT filtered anymore — the
    // consumer now sees it as a regular event.
    instances[0]!.emit('message', 'ping')
    expect(onEvent).toHaveBeenCalledWith('ping', 'message')
    expect(onEvent).toHaveBeenCalledTimes(1)

    client.close()
  })

  // Listener cleanup
  it('removes DOM listeners on close()', () => {
    const { ctor, instances } = createMockCtor()
    const { target: visTarget } = createMockTarget(false)
    const { target: onlineTarget } = createMockOnlineTarget()
    const { target: unloadTarget } = createMockUnloadTarget()

    const client = createSseClient({
      url: '/test',
      EventSourceCtor: ctor,
      visibilityTarget: visTarget,
      onlineTarget: onlineTarget,
      unloadTarget: unloadTarget,
      pauseWhenHidden: false,
      onEvent: () => {},
    })

    // Flush the deferred start() — createSseClient schedules start() on the next
    // macrotask so the SSE setup is fully async (see helpers/sseClient.ts).
    vi.advanceTimersByTime(0)
    // Before close: 1 visibility listener, 1 online listener,
    // 1 pagehide listener, 1 beforeunload listener.
    expect(visTarget._listeners.get('visibilitychange')?.size ?? 0).toBe(1)
    expect(onlineTarget._listeners.get('online')?.size ?? 0).toBe(1)
    expect(unloadTarget._listeners.get('pagehide')?.size ?? 0).toBe(1)
    expect(unloadTarget._listeners.get('beforeunload')?.size ?? 0).toBe(1)

    client.close()

    // After close: 0 listeners of each kind. This is the
    // defense against the App.vue-style timer-leak bug — a
    // closed client must not retain DOM references.
    expect(visTarget._listeners.get('visibilitychange')?.size ?? 0).toBe(0)
    expect(onlineTarget._listeners.get('online')?.size ?? 0).toBe(0)
    expect(unloadTarget._listeners.get('pagehide')?.size ?? 0).toBe(0)
    expect(unloadTarget._listeners.get('beforeunload')?.size ?? 0).toBe(0)

    // The underlying EventSource was also closed.
    expect(instances[0]!._closed).toBe(true)
  })

  // 10. pagehide / beforeunload cleanly tear down the connection (the 2026-01-15 fix for "SSE still
  // open after refresh").
  it('closes the connection on pagehide so it is not still "open" after refresh', () => {
    const { ctor, instances } = createMockCtor()
    const { target: visTarget } = createMockTarget(false)
    const { target: onlineTarget } = createMockOnlineTarget()
    const { target: unloadTarget } = createMockUnloadTarget()

    const states: SseState[] = []
    const client = createSseClient({
      url: '/test',
      EventSourceCtor: ctor,
      visibilityTarget: visTarget,
      onlineTarget: onlineTarget,
      unloadTarget: unloadTarget,
      pauseWhenHidden: false,
      onStateChange: (s) => states.push(s),
      onEvent: () => {},
    })

    // Flush the deferred start() — createSseClient schedules start() on the next
    // macrotask so the SSE setup is fully async (see helpers/sseClient.ts).
    vi.advanceTimersByTime(0)
    // Simulate a normal open: server sent the `connected` event.
    instances[0]!.simulateOpen()
    expect(client.getState()).toBe('open')

    // User hits refresh — the browser fires `pagehide` on window.
    unloadTarget.fire('pagehide')

    // The client must be in 'closed' state, the EventSource must
    // be closed, and all DOM listeners (pagehide, beforeunload,
    // visibility, online) must be removed.
    expect(client.getState()).toBe('closed')
    expect(instances[0]!._closed).toBe(true)
    expect(unloadTarget._listeners.get('pagehide')?.size ?? 0).toBe(0)
    expect(unloadTarget._listeners.get('beforeunload')?.size ?? 0).toBe(0)
    expect(visTarget._listeners.get('visibilitychange')?.size ?? 0).toBe(0)
    expect(onlineTarget._listeners.get('online')?.size ?? 0).toBe(0)
    // The state emission sequence includes 'closed' as the final
    // entry, same shape as the manual close() path.
    expect(states).toEqual(['connecting', 'open', 'closed'])
  })

  // 10b. beforeunload does the same thing (legacy fallback for
  // browsers without pagehide support).
  it('closes the connection on beforeunload (legacy fallback)', () => {
    const { ctor, instances } = createMockCtor()
    const { target: visTarget } = createMockTarget(false)
    const { target: onlineTarget } = createMockOnlineTarget()
    const { target: unloadTarget } = createMockUnloadTarget()

    const client = createSseClient({
      url: '/test',
      EventSourceCtor: ctor,
      visibilityTarget: visTarget,
      onlineTarget: onlineTarget,
      unloadTarget: unloadTarget,
      pauseWhenHidden: false,
      onEvent: () => {},
    })

    // Flush the deferred start() — createSseClient schedules start() on the next
    // macrotask so the SSE setup is fully async (see helpers/sseClient.ts).
    vi.advanceTimersByTime(0)
    instances[0]!.simulateOpen()
    expect(client.getState()).toBe('open')

    unloadTarget.fire('beforeunload')
    expect(client.getState()).toBe('closed')
    expect(instances[0]!._closed).toBe(true)
  })

  // 10c. Stale pagehide handler after explicit close() is a no-op
  // (teardown is idempotent via the `closed` guard).
  it('a stale pagehide handler after close() is a no-op', () => {
    const { ctor, instances } = createMockCtor()
    const { target: visTarget } = createMockTarget(false)
    const { target: onlineTarget } = createMockOnlineTarget()
    const { target: unloadTarget } = createMockUnloadTarget()

    const client = createSseClient({
      url: '/test',
      EventSourceCtor: ctor,
      visibilityTarget: visTarget,
      onlineTarget: onlineTarget,
      unloadTarget: unloadTarget,
      pauseWhenHidden: false,
      onEvent: () => {},
    })

    // Flush the deferred start() — createSseClient schedules start() on the next
    // macrotask so the SSE setup is fully async (see helpers/sseClient.ts).
    vi.advanceTimersByTime(0)
    client.close()
    expect(client.getState()).toBe('closed')

    // Stale pagehide (e.g. browser fires it after Vue's onUnmounted called .close() and the page
    // finally unloads). Must not throw, must not create a new instance, must not change state.
    unloadTarget.fire('pagehide')
    expect(client.getState()).toBe('closed')
    expect(instances.length).toBe(1)
  })

  // 10d. closeOnUnload: false skips the unload listeners. Useful
  // for SSR / tests / contexts without a real `window`.
  it('does not attach unload listeners when closeOnUnload is false', () => {
    const { ctor } = createMockCtor()
    const { target: visTarget } = createMockTarget(false)
    const { target: onlineTarget } = createMockOnlineTarget()
    const { target: unloadTarget } = createMockUnloadTarget()

    const client = createSseClient({
      url: '/test',
      EventSourceCtor: ctor,
      visibilityTarget: visTarget,
      onlineTarget: onlineTarget,
      unloadTarget: unloadTarget,
      pauseWhenHidden: false,
      closeOnUnload: false,
      onEvent: () => {},
    })

    // Flush the deferred start() — createSseClient schedules start() on the next
    // macrotask so the SSE setup is fully async (see helpers/sseClient.ts).
    vi.advanceTimersByTime(0)
    expect(unloadTarget._listeners.get('pagehide')?.size ?? 0).toBe(0)
    expect(unloadTarget._listeners.get('beforeunload')?.size ?? 0).toBe(0)

    client.close()
  })

  // getState is synchronous
  it('getState() returns the current state synchronously', () => {
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
    expect(client.getState()).toBe('connecting')
    instances[0]!.simulateOpen()
    expect(client.getState()).toBe('open')
    instances[0]!.emit('error')
    expect(client.getState()).toBe('reconnecting')

    client.close()
  })

  // reconnect() resets the attempt counter
  it('reconnect() resets the attempt counter and opens a new connection', () => {
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
      onStateChange: (s) => states.push(s),
      onEvent: () => {},
      stallThresholdMs: 120_000,
      connectedTimeoutMs: 120_000,
    })

    // Flush the deferred start() — createSseClient schedules start() on the next
    // macrotask so the SSE setup is fully async (see helpers/sseClient.ts).
    vi.advanceTimersByTime(0)
    // Burn through 2 retries so attempt=3.
    instances[0]!.simulateOpen()
    instances[0]!.emit('error')
    vi.advanceTimersByTime(2_000)
    instances[1]!.simulateOpen()
    instances[1]!.emit('error')
    vi.advanceTimersByTime(2_000)
    expect(instances.length).toBe(3)

    // Manual reconnect — should close the current instance and
    // create a fresh one. Attempt counter resets to 0, then
    // start() bumps to 1.
    client.reconnect()
    expect(instances.length).toBe(4)
    // The previous instance was closed.
    expect(instances[2]!._closed).toBe(true)
    // State is now 'connecting' for the fresh attempt.
    expect(client.getState()).toBe('connecting')

    client.close()
  })

  // Subscriber errors do not break the connection
  it('a throwing onStateChange subscriber does not break the connection', () => {
    const { ctor, instances } = createMockCtor()
    const { target: visTarget } = createMockTarget(false)
    const { target: onlineTarget } = createMockOnlineTarget()

    const errorSpy = vi.spyOn(console, 'error').mockImplementation(() => {})

    const client = createSseClient({
      url: '/test',
      EventSourceCtor: ctor,
      visibilityTarget: visTarget,
      onlineTarget: onlineTarget,
      pauseWhenHidden: false,
      onEvent: () => {},
      onStateChange: () => {
        throw new Error('subscriber bug')
      },
    })

    // Flush the deferred start() — createSseClient schedules start() on the next
    // macrotask so the SSE setup is fully async (see helpers/sseClient.ts).
    vi.advanceTimersByTime(0)
    // Despite the throw, the connection should reach 'open'.
    instances[0]!.simulateOpen()
    expect(client.getState()).toBe('open')
    expect(errorSpy).toHaveBeenCalled()

    errorSpy.mockRestore()
    client.close()
  })

  // onStateChange returns an unsubscribe function
  it('onStateChange returns an unsubscribe function', () => {
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
    const cb = vi.fn()
    const unsub = client.onStateChange(cb)
    instances[0]!.simulateOpen()
    expect(cb).toHaveBeenCalledWith('open', expect.any(Object))

    cb.mockClear()
    unsub()
    client.reconnect()
    // After unsub, the new attempt's 'connecting' should not be
    // observed.
    expect(cb).not.toHaveBeenCalled()

    client.close()
  })

  // message handler is robust to non-string data
  it('handles message events whose `data` is not a string', () => {
    const { ctor, instances } = createMockCtor()
    const { target: visTarget } = createMockTarget(false)
    const { target: onlineTarget } = createMockOnlineTarget()

    const onEvent = vi.fn()
    const client = createSseClient({
      url: '/test',
      EventSourceCtor: ctor,
      visibilityTarget: visTarget,
      onlineTarget: onlineTarget,
      pauseWhenHidden: false,
      onEvent,
    })

    // Flush the deferred start() — createSseClient schedules start() on the next
    // macrotask so the SSE setup is fully async (see helpers/sseClient.ts).
    vi.advanceTimersByTime(0)
    instances[0]!.emit('connected', 'ok')
    onEvent.mockClear()
    // Manually fire a message event with non-string data via the
    // mock's addEventListener path. We use a custom shape.
    const set = instances[0]!._listeners.get('message')!
    for (const listener of set) {
      const ev = { data: 42 } as unknown as MessageEvent
      if (typeof listener === 'function') listener(ev)
      else listener.handleEvent(ev)
    }
    expect(onEvent).toHaveBeenCalledWith('42', 'message')

    client.close()
  })

  // Throw-isolation: a throwing onConnected must not break the handshake —
  // onEvent still fires for `connected` and later data events dispatch.
  it('a throwing onConnected still passes connected to onEvent and keeps the stream open', () => {
    const { ctor, instances } = createMockCtor()
    const { target: visTarget } = createMockTarget(false)
    const { target: onlineTarget } = createMockOnlineTarget()

    const errorSpy = vi.spyOn(console, 'error').mockImplementation(() => {})
    const onEvent = vi.fn()
    const client = createSseClient({
      url: '/test',
      EventSourceCtor: ctor,
      visibilityTarget: visTarget,
      onlineTarget: onlineTarget,
      pauseWhenHidden: false,
      additionalEventTypes: ['llm_chunk'],
      onConnected: () => {
        throw new Error('onConnected bug')
      },
      onEvent,
    })

    vi.advanceTimersByTime(0)
    // Must not throw out of the listener — handshake completes.
    expect(() => instances[0]!.emit('connected', '{"connected":true}')).not.toThrow()
    expect(client.getState()).toBe('open')
    expect(onEvent).toHaveBeenCalledWith('{"connected":true}', 'connected')
    expect(errorSpy).toHaveBeenCalledWith(
      '[SseClient] onConnected subscriber threw:',
      expect.any(Error),
    )

    // Stream stays alive: a later named event still dispatches.
    onEvent.mockClear()
    instances[0]!.emit('llm_chunk', '{"type":"chunk"}')
    expect(onEvent).toHaveBeenCalledWith('{"type":"chunk"}', 'llm_chunk')

    errorSpy.mockRestore()
    client.close()
  })

  // Throw-isolation: a throwing onEvent on one event must not silence the next.
  it('a throwing onEvent on message does not silence the next event', () => {
    const { ctor, instances } = createMockCtor()
    const { target: visTarget } = createMockTarget(false)
    const { target: onlineTarget } = createMockOnlineTarget()

    const errorSpy = vi.spyOn(console, 'error').mockImplementation(() => {})
    let calls = 0
    const throwOnCall = 2 // simulateOpen (connected) = call 1 (ok), message = call 2 (throws)
    const client = createSseClient({
      url: '/test',
      EventSourceCtor: ctor,
      visibilityTarget: visTarget,
      onlineTarget: onlineTarget,
      pauseWhenHidden: false,
      additionalEventTypes: ['llm_chunk'],
      onEvent: () => {
        calls += 1
        if (calls === throwOnCall) throw new Error('consumer bug')
      },
    })

    vi.advanceTimersByTime(0)
    instances[0]!.simulateOpen()
    expect(calls).toBe(1)
    expect(() => instances[0]!.emit('message', '{"a":1}')).not.toThrow()
    expect(calls).toBe(2)
    // Second event still dispatches despite the first throw.
    expect(() => instances[0]!.emit('llm_chunk', '{"type":"chunk"}')).not.toThrow()
    expect(calls).toBe(3)
    expect(client.getState()).toBe('open')

    errorSpy.mockRestore()
    client.close()
  })
})
