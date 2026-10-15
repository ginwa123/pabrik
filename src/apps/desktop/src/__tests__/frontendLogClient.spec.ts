/**
 * frontendLogClient.spec.ts
 *
 * Unit tests for `helpers/frontendLogClient.ts`. Covers the 10
 * behaviours required by plan Chunk 6 of
 * `docs/superpowers/plans/2026-07-17-frontend-error-logs.md`:
 *
 *   1.  `window.error`            → POST `kind=window_error`
 *                                    with `stack` / `source` / `line`
 *   2.  `window.unhandledrejection` → POST `kind=unhandled_rejection`
 *   3.  Patched `console.error`    → POST `kind=console_error`
 *                                    (original still called)
 *   4.  Patched `console.warn`     → POST `kind=console_warn`
 *   5.  `console.log/info/debug`   → NOT POSTed
 *   6.  100 fast `console.error`   → exactly 1 POST (debounce coalesces)
 *   7.  `pagehide`                 → uses `navigator.sendBeacon`, not fetch
 *   8.  Failed POST (rejected)     → batch dropped, no retry
 *   9.  Queue overflow             → drops oldest 25 + 1 overflow warn
 *  10.  `getContext()` is invoked per-flush (fresh route / session)
 *
 * Tests inject a fake `Window`, `fetchFn`, and `sendBeaconFn` via the
 * `FrontendLogClientOptions` seams so the queue can be observed end-
 * to-end without a real network. `vi.useFakeTimers()` controls the
 * 250 ms debounce window so flushes fire deterministically.
 *
 * Style mirrors `sseClient.spec.ts` (separate fakes per concern,
 * `vi.useFakeTimers()` in `beforeEach`, `vi.useRealTimers()` in
 * `afterEach`, `handle.close()` in `afterEach` so listeners and
 * console patches don't leak across tests).
 */

import { afterEach, beforeEach, describe, expect, test, vi } from 'vitest'

import {
  installFrontendLogClient,
  type FrontendLogClientHandle,
} from '../helpers/frontendLogClient'

// ─── Minimal FakeWindow ──────────────────────────────────────────────────
// Mirrors what `installFrontendLogClient` actually reads from the target:
// `addEventListener` (3 event types), `removeEventListener` (3 types),
// `console.{error,warn,log,info,debug}` (only `error` + `warn` are
// patched, but the helper accepts the whole console). We do NOT need
// `dispatchEvent` for these tests (we fire listeners directly), but the
// type includes it so the helper can be cast as `Window` cleanly.
interface FakeWindow {
  addEventListener: (type: string, cb: EventListenerOrEventListenerObject) => void
  removeEventListener: (type: string, cb: EventListenerOrEventListenerObject) => void
  console: {
    error: (...args: unknown[]) => void
    warn: (...args: unknown[]) => void
    log: (...args: unknown[]) => void
    info: (...args: unknown[]) => void
    debug: (...args: unknown[]) => void
  }
  dispatchEvent: (event: Event) => boolean
}

interface FakeWindowBundle {
  window: FakeWindow
  errorListeners: Set<EventListenerOrEventListenerObject>
  rejectionListeners: Set<EventListenerOrEventListenerObject>
  unloadListeners: Set<EventListenerOrEventListenerObject>
  // Captured references to the ORIGINAL vi.fn() spies for console.error and console.warn.
  // After `installFrontendLogClient` runs, the module REPLACES `window.console.error` /
  // `window.console.warn` with a closure that internally calls these originals (bound at install
  // time).
  // Asserting on the (post-install) `window.console.*` reference would fail with "not a spy" — the
  // spies have moved. The assertions need to use `originalErrorSpy` / `originalWarnSpy`.
  originalErrorSpy: ReturnType<typeof vi.fn>
  originalWarnSpy: ReturnType<typeof vi.fn>
}

function makeFakeWindow(): FakeWindowBundle {
  const errorListeners = new Set<EventListenerOrEventListenerObject>()
  const rejectionListeners = new Set<EventListenerOrEventListenerObject>()
  const unloadListeners = new Set<EventListenerOrEventListenerObject>()
  const originalErrorSpy = vi.fn()
  const originalWarnSpy = vi.fn()
  const console_ = {
    error: originalErrorSpy,
    warn: originalWarnSpy,
    log: vi.fn(),
    info: vi.fn(),
    debug: vi.fn(),
  }
  const window: FakeWindow = {
    addEventListener(type, cb) {
      if (type === 'error') errorListeners.add(cb)
      else if (type === 'unhandledrejection') rejectionListeners.add(cb)
      else if (type === 'pagehide' || type === 'beforeunload') unloadListeners.add(cb)
    },
    removeEventListener(type, cb) {
      if (type === 'error') errorListeners.delete(cb)
      else if (type === 'unhandledrejection') rejectionListeners.delete(cb)
      else if (type === 'pagehide' || type === 'beforeunload') unloadListeners.delete(cb)
    },
    console: console_,
    dispatchEvent: () => true,
  }
  return {
    window,
    errorListeners,
    rejectionListeners,
    unloadListeners,
    originalErrorSpy,
    originalWarnSpy,
  }
}

function fireListeners(
  listeners: Set<EventListenerOrEventListenerObject>,
  event: Event,
): void {
  for (const cb of listeners) {
    if (typeof cb === 'function') cb(event)
    else cb.handleEvent(event)
  }
}

// ─── Test suite ──────────────────────────────────────────────────────────

describe('frontendLogClient', () => {
  let fetchMock: ReturnType<typeof vi.fn>
  let beaconMock: ReturnType<typeof vi.fn>
  // Mutable context sources so test 10 can prove getContext() is called
  // per-flush (the closures capture the variables, not the values).
  let routePath: string | null
  let sessionId: string | null
  let handle: FrontendLogClientHandle | null = null

  beforeEach(() => {
    vi.useFakeTimers()
    fetchMock = vi.fn().mockResolvedValue({ ok: true, status: 204 })
    beaconMock = vi.fn().mockReturnValue(true)
    routePath = '/app'
    sessionId = 'session_xyz'
  })

  afterEach(() => {
    handle?.close()
    handle = null
    vi.useRealTimers()
    vi.restoreAllMocks()
  })

  function makeHandle(window: FakeWindow): FrontendLogClientHandle {
    handle = installFrontendLogClient({
      endpoint: '/api/logs',
      getContext: () => ({
        getRoutePath: () => routePath,
        getSessionId: () => sessionId,
      }),
      target: window as unknown as Window,
      fetchFn: fetchMock as unknown as typeof fetch,
      sendBeaconFn: beaconMock as unknown as (url: string, data: BodyInit) => boolean,
    })
    return handle
  }

  // 1. window.error
  test('window.error → POST with kind=window_error, stack/source/line populated', async () => {
    const { window, errorListeners } = makeFakeWindow()
    makeHandle(window)

    const err = new Error('boom')
    const event = new ErrorEvent('error', {
      message: 'boom',
      error: err,
      filename: 'app.js',
      lineno: 42,
    })
    fireListeners(errorListeners, event)

    await vi.runAllTimersAsync()

    expect(fetchMock).toHaveBeenCalledTimes(1)
    const [url, init] = fetchMock.mock.calls[0] as [string, RequestInit]
    expect(url).toBe('/api/logs')
    expect(init.method).toBe('POST')
    const body = JSON.parse(init.body as string)
    expect(body.events).toHaveLength(1)
    expect(body.events[0].kind).toBe('window_error')
    expect(body.events[0].level).toBe('error')
    expect(body.events[0].message).toBe('boom')
    expect(body.events[0].stack).toContain('boom')
    expect(body.events[0].source).toBe('app.js')
    expect(body.events[0].line).toBe(42)
  })

  // 2. unhandledrejection
  test('window.unhandledrejection → POST with kind=unhandled_rejection', async () => {
    const { window, rejectionListeners } = makeFakeWindow()
    makeHandle(window)

    const err = new Error('rejected')
    // jsdom's PromiseRejectionEvent constructor requires `reason` and
    // `promise`. Use Promise.reject so the test doesn't leak an
    // unhandled rejection after the assertion.
    const promise = Promise.reject(err)
    promise.catch(() => {}) // mark the rejection as handled for jsdom
    const event = new PromiseRejectionEvent('unhandledrejection', {
      reason: err,
      promise,
    })
    fireListeners(rejectionListeners, event)

    await vi.runAllTimersAsync()

    expect(fetchMock).toHaveBeenCalledTimes(1)
    const [, init] = fetchMock.mock.calls[0] as [string, RequestInit]
    const body = JSON.parse(init.body as string)
    expect(body.events).toHaveLength(1)
    expect(body.events[0].kind).toBe('unhandled_rejection')
    expect(body.events[0].level).toBe('error')
    expect(body.events[0].message).toBe('rejected')
    expect(body.events[0].stack).toBeDefined()
    expect(body.events[0].stack).toContain('rejected')
  })

  // 3. console.error patch
  test('patched console.error → POST kind=console_error, original still called', async () => {
    const { window, originalErrorSpy } = makeFakeWindow()
    makeHandle(window)

    // The fake window's console.error is a vi.fn() (originalErrorSpy) that the install function
    // captured as `originalError` (bound to console). Calling the (now-patched)
    // window.console.error should: (a) enqueue a console_error event, (b) call the original spy.
    // We assert on the captured spy reference — `window.console.error` itself has been REPLACED by
    // the patch function, so it's no longer a vi.fn().
    window.console.error('boom')

    await vi.runAllTimersAsync()

    expect(fetchMock).toHaveBeenCalledTimes(1)
    const [, init] = fetchMock.mock.calls[0] as [string, RequestInit]
    const body = JSON.parse(init.body as string)
    expect(body.events).toHaveLength(1)
    expect(body.events[0].kind).toBe('console_error')
    expect(body.events[0].level).toBe('error')
    expect(body.events[0].message).toBe('boom')
    // Original console.error was called once with 'boom'.
    expect(originalErrorSpy).toHaveBeenCalledTimes(1)
    expect(originalErrorSpy).toHaveBeenCalledWith('boom')
  })

  // 4. console.warn patch
  test('patched console.warn → POST kind=console_warn', async () => {
    const { window, originalWarnSpy } = makeFakeWindow()
    makeHandle(window)

    window.console.warn('heads up')

    await vi.runAllTimersAsync()

    expect(fetchMock).toHaveBeenCalledTimes(1)
    const [, init] = fetchMock.mock.calls[0] as [string, RequestInit]
    const body = JSON.parse(init.body as string)
    expect(body.events).toHaveLength(1)
    expect(body.events[0].kind).toBe('console_warn')
    expect(body.events[0].level).toBe('warn')
    expect(body.events[0].message).toBe('heads up')
    expect(originalWarnSpy).toHaveBeenCalledTimes(1)
    expect(originalWarnSpy).toHaveBeenCalledWith('heads up')
  })

  // 5. log / info / debug are NOT intercepted
  test('console.log / .info / .debug are NOT POSTed', async () => {
    const { window } = makeFakeWindow()
    makeHandle(window)

    window.console.log('x')
    window.console.info('y')
    window.console.debug('z')

    await vi.runAllTimersAsync()

    expect(fetchMock).toHaveBeenCalledTimes(0)
  })

  // 6. debounce coalesces N fast console.error into 1 POST
  test('100 fast console.error calls → exactly 1 POST (debounce coalesces)', async () => {
    const { window } = makeFakeWindow()
    makeHandle(window)

    for (let i = 0; i < 100; i++) {
      window.console.error('x')
    }

    await vi.runAllTimersAsync()

    expect(fetchMock).toHaveBeenCalledTimes(1)
    const [, init] = fetchMock.mock.calls[0] as [string, RequestInit]
    const body = JSON.parse(init.body as string)
    // 100 events trigger queue overflow at MAX_QUEUE_SIZE=50 — the module drops the oldest 25 and
    // enqueues a `console_warn` overflow marker on each overflow.
    // We don't assert an exact count (the overflow math is intricate and tested separately in #9);
    // we DO assert that: (a) coalescing produced exactly one POST (the debounce claim), (b) the
    // batch is non-empty, (c) every event has kind ∈ {console_error, console_warn}.
    expect(body.events.length).toBeGreaterThan(0)
    expect(body.events.length).toBeLessThanOrEqual(100)
    for (const ev of body.events) {
      expect(['console_error', 'console_warn']).toContain(ev.kind)
    }
  })

  // 7. pagehide → sendBeacon, NOT fetch
  test('pagehide → uses navigator.sendBeacon, NOT fetch', () => {
    const { window, unloadListeners } = makeFakeWindow()
    makeHandle(window)

    // Fire a real event (sendBeacon gets a Blob built from JSON.stringify
    // of the batch; the Blob constructor takes the JSON string).
    window.console.error('before-unload')
    fireListeners(unloadListeners, new Event('pagehide'))

    expect(beaconMock).toHaveBeenCalledTimes(1)
    expect(fetchMock).toHaveBeenCalledTimes(0)

    const [beaconUrl, beaconData] = beaconMock.mock.calls[0] as [string, BodyInit]
    expect(beaconUrl).toBe('/api/logs')
    expect(beaconData).toBeInstanceOf(Blob)
    // The Blob's type should be application/json (per module code).
    const blob = beaconData as Blob
    expect(blob.type).toBe('application/json')
  })

  // 8. failed POST → batch dropped, no retry
  test('failed POST → batch is dropped, no retry', async () => {
    fetchMock = vi.fn().mockRejectedValue(new Error('network down'))
    const { window } = makeFakeWindow()
    makeHandle(window)

    window.console.error('boom')

    await vi.runAllTimersAsync()

    // fetchFn was invoked exactly once; the rejection is caught inside flush() and the batch is
    // silently dropped (no retry, no second POST).
    // The module also calls originalWarn with a diagnostic — we don't assert that here because
    // originalWarn is captured BEFORE the patch (so it's NOT the spy on window.console.warn).
    expect(fetchMock).toHaveBeenCalledTimes(1)
  })

  // 9. queue overflow → drops oldest 25 + 1 overflow warn per overflow
  test('queue overflow → drops oldest 25 + emits overflow warning', async () => {
    const { window } = makeFakeWindow()
    makeHandle(window)

    // 60 console.error calls. - Calls 1..50 fill the queue to 50. - Call 51 overflows: drop 25 →
    // 25, +1 warn → 26, +1 event → 27. - Calls 52..60 fill queue from 27 → 36. Final queue size
    // after 60 calls = 36 (35 console_error + 1 console_warn).
    for (let i = 0; i < 60; i++) {
      window.console.error('x')
    }

    await vi.runAllTimersAsync()

    expect(fetchMock).toHaveBeenCalledTimes(1)
    const [, init] = fetchMock.mock.calls[0] as [string, RequestInit]
    const body = JSON.parse(init.body as string)
    expect(body.events).toHaveLength(36)
    const overflow = body.events.find(
      (ev: { kind: string; message: string }) =>
        ev.message === '[frontendLog] queue overflow, dropped 25 events',
    )
    expect(overflow).toBeDefined()
    expect(overflow.kind).toBe('console_warn')
    expect(overflow.level).toBe('warn')
  })

  // 10. getContext() is called per-flush (fresh route / session)
  test('getContext() is called per-flush → fresh route_path and session_id each time', async () => {
    const { window } = makeFakeWindow()
    makeHandle(window)

    // Flush 1: routePath='/app', sessionId='session_xyz'
    window.console.error('first')
    await vi.runAllTimersAsync()

    expect(fetchMock).toHaveBeenCalledTimes(1)
    let [, init] = fetchMock.mock.calls[0] as [string, RequestInit]
    let body = JSON.parse(init.body as string)
    expect(body.events).toHaveLength(1)
    expect(body.events[0].route_path).toBe('/app')
    expect(body.events[0].session_id).toBe('session_xyz')

    // Mutate the captured variables; subsequent getContext() calls
    // must see the new values.
    routePath = '/app/changed'
    sessionId = 'session_def'

    // Flush 2: new routePath + sessionId
    window.console.error('second')
    await vi.runAllTimersAsync()

    expect(fetchMock).toHaveBeenCalledTimes(2)
    ;[, init] = fetchMock.mock.calls[1] as [string, RequestInit]
    body = JSON.parse(init.body as string)
    expect(body.events).toHaveLength(1)
    expect(body.events[0].route_path).toBe('/app/changed')
    expect(body.events[0].session_id).toBe('session_def')
  })
})
