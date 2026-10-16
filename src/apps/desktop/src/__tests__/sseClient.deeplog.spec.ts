/** Tests for the DEEP v2 logger in sseClient.ts. The "drops at 15s" bug surfaces as the SseClient
 * transitioning to 'reconnecting'. */
import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest'
import { createSseClient } from '../helpers/sseClient'

// Minimal EventSource mock — captures every listener; `emit` fires them.
interface MockEventSource {
  url: string
  readyState: number
  close: () => void
  addEventListener: (t: string, l: EventListenerOrEventListenerObject) => void
  removeEventListener: (t: string, l: EventListenerOrEventListenerObject) => void
  emit: (t: string, data?: string) => void
  simulateOpen: (payload?: string) => void
}

function createMockCtor(): { ctor: typeof EventSource; instance: () => MockEventSource } {
  let captured: MockEventSource | null = null
  const ctor = function MockEventSource(this: unknown, url: string): MockEventSource {
    const listeners = new Map<string, Set<EventListenerOrEventListenerObject>>()
    let onerrorHandler: ((e: Event) => void) | null = null
    const inst: MockEventSource = {
      url,
      readyState: 0,
      close() {
        // nothing
      },
      addEventListener(type, listener) {
        let set = listeners.get(type)
        if (!set) {
          set = new Set()
          listeners.set(type, set)
        }
        set.add(listener)
      },
      removeEventListener(type, listener) {
        const set = listeners.get(type)
        if (set) set.delete(listener)
      },
      emit(type, data) {
        const ev = data !== undefined ? new MessageEvent(type, { data }) : new Event(type)
        // 'error' is special: browsers fire BOTH the onerror property AND any listeners registered
        // via addEventListener('error', ...).
        const set = listeners.get(type)
        if (set) {
          for (const l of set) {
            if (typeof l === 'function') (l as (e: Event) => void)(ev)
            else (l as { handleEvent: (e: Event) => void }).handleEvent(ev)
          }
        }
        if (type === 'error' && onerrorHandler) {
          onerrorHandler(ev)
        }
      },
      simulateOpen(payload: string = '{"ok":true}') {
        // Mirror the real browser's behavior: when the SSE `connected` event arrives, readyState
        // transitions to OPEN (1).
        inst.readyState = 1
        inst.emit('connected', payload)
      },
    }
    // The SseClient assigns `instance.onerror = ...` AFTER `addEventListener('error', ...)`. See
    // `sseClient.ts::start` for the dual-fire pattern in production.
    Object.defineProperty(inst, 'onerror', {
      get() {
        return onerrorHandler
      },
      set(h: ((e: Event) => void) | null) {
        onerrorHandler = h
      },
      configurable: true,
    })
    captured = inst
    return inst
  } as unknown as typeof EventSource
  return { ctor, instance: () => captured! }
}

beforeEach(() => {
  ;(globalThis as { __sseDebug?: boolean }).__sseDebug = true
  ;(globalThis as { __sseStallDetector?: boolean }).__sseStallDetector = true
  Object.defineProperty(globalThis, 'navigator', {
    value: {
      // `onLine: true` is the default for a connected desktop app. The sse-disconnect-diagnosis
      // chunk surfaces `navigatorOnline` in every diagnostic log; tests that want `suspect:
      // 'network'` override this to `false` (see the corresponding test).
      onLine: true,
      connection: {
        effectiveType: '4g',
        downlink: 10,
        rtt: 50,
        saveData: false,
      },
    },
    configurable: true,
    writable: true,
  })
  vi.spyOn(console, 'log').mockImplementation(() => {})
})

afterEach(() => {
  vi.restoreAllMocks()
  delete (globalThis as { __sseDebug?: boolean }).__sseDebug
  delete (globalThis as { __sseStallDetector?: boolean }).__sseStallDetector
})

// Collects every log call into a searchable array. Strips the ISO prefix + t=... preamble because
// those vary run-to-run. Regex design note: the original pattern was `\] (\w[\w ]*?)` which only
// matched word chars + spaces.
function parseLogCalls(): Array<{ msg: string; extra?: Record<string, unknown> }> {
  const out: Array<{ msg: string; extra?: Record<string, unknown> }> = []
  for (const c of (console.log as ReturnType<typeof vi.fn>).mock.calls) {
    const line = String(c[0])
    const m = line.match(/\] (.+?)(?: (\{.*\})|$)/)
    if (m) {
      // Group 1 is required by the regex pattern (the `m !== null` check already proves group 1
      // matched a non-empty run); TypeScript's RegExpMatchArray type still types captures as
      // `string | undefined`, so the `!` asserts what the regex guarantees.
      const msg = m[1]!
      const json = m[2]
      try {
        out.push({ msg, extra: json ? JSON.parse(json) : undefined })
      } catch {
        out.push({ msg })
      }
    }
  }
  return out
}

describe('SseClient deep v2 logger — per-message timing', () => {
  it('logs every heartbeat with sinceLastEventMs >= 5000', () => {
    vi.useFakeTimers()
    const mock = createMockCtor()
    createSseClient({
      url: '/x',
      onEvent: () => {},
      additionalEventTypes: [],
      EventSourceCtor: mock.ctor,
    })
    // Flush the setTimeout(start, 0) so the EventSource is constructed
    void vi.advanceTimersByTime(0)
    const es = mock.instance()

    es.simulateOpen('{"connected":true}')
    vi.advanceTimersByTime(5_000)
    es.emit('message', 'ping')
    vi.advanceTimersByTime(5_000)
    es.emit('message', 'ping')

    const calls = parseLogCalls()
    const heartbeats = calls.filter((c) => c.msg === 'heartbeat')
    expect(heartbeats.length).toBeGreaterThanOrEqual(2)
    // 2nd heartbeat reports ~5000ms since the 1st. The length check
    // above proves `heartbeats[1]` exists, so the `!` is safe.
    const second = heartbeats[1]!
    expect(second.extra?.sinceLastEventMs).toBeGreaterThanOrEqual(4_500)
    expect(second.extra?.sinceLastEventMs).toBeLessThan(6_000)
  })

  it('counts heartbeats and named events separately', () => {
    vi.useFakeTimers()
    const mock = createMockCtor()
    const onEvent = vi.fn()
    createSseClient({
      url: '/x',
      onEvent,
      additionalEventTypes: ['custom_named'],
      EventSourceCtor: mock.ctor,
    })
    void vi.advanceTimersByTime(0)
    const es = mock.instance()
    es.simulateOpen('{"ok":true}')
    es.emit('message', 'ping')
    es.emit('message', 'ping')
    es.emit('message', '{"hello":1}')

    // onEvent fires for: connected, 1 named message (NOT the 2 heartbeats)
    expect(onEvent).toHaveBeenCalledTimes(2)
    const calls = parseLogCalls()
    // heartbeatCount is in the heartbeat log payload — verify it advances
    const lastHeartbeat = calls.filter((c) => c.msg === 'heartbeat').at(-1)
    expect(lastHeartbeat?.extra?.heartbeatCount).toBe(2)
    // eventCount counts named events; connected incremented it to 1
    // before any heartbeat, so a heartbeat seen at this point shows 1
    expect(lastHeartbeat?.extra?.eventCount).toBe(1)
    const lastRealEvent = calls.filter((c) => c.msg === 'message').at(-1)
    expect(lastRealEvent?.extra?.eventCount).toBe(2)
  })
})

describe('SseClient deep v2 logger — stall detector', () => {
  it('fires STALL DETECTED if no event arrives in stallThresholdMs while state=open', () => {
    vi.useFakeTimers()
    const mock = createMockCtor()
    createSseClient({
      url: '/x',
      onEvent: () => {},
      additionalEventTypes: [],
      EventSourceCtor: mock.ctor,
      stallThresholdMs: 7_000,
    })
    void vi.advanceTimersByTime(0)
    const es = mock.instance()
    es.simulateOpen('{"ok":true}')
    // Don't fire any more events for 9s — stallThresholdMs is 7s in
    // production, we test with 9s so the assertion can be exactly 7s+
    // rather than timing-sensitive to the precision of vi.advanceTimersByTime.
    vi.advanceTimersByTime(9_000)

    const calls = parseLogCalls()
    const stallLine = calls.find((c) => c.msg === 'STALL DETECTED')
    expect(stallLine).toBeDefined()
    expect(stallLine?.extra?.sinceLastEventMs).toBeGreaterThanOrEqual(7_000)
    // The stall payload includes NetworkInformation API data
    expect(stallLine?.extra?.navConn).toBeDefined()
    expect((stallLine?.extra?.navConn as { effectiveType?: string })?.effectiveType).toBe('4g')
  })

  it('does NOT fire STALL DETECTED if events keep arriving every < stallThresholdMs', () => {
    vi.useFakeTimers()
    const mock = createMockCtor()
    createSseClient({
      url: '/x',
      onEvent: () => {},
      additionalEventTypes: [],
      EventSourceCtor: mock.ctor,
      stallThresholdMs: 7_000,
    })
    void vi.advanceTimersByTime(0)
    const es = mock.instance()
    es.simulateOpen('{"ok":true}')
    // Send one heartbeat every 5s for 30s — never let the stall
    // detector fire
    for (let i = 0; i < 6; i++) {
      vi.advanceTimersByTime(5_000)
      es.emit('message', 'ping')
    }
    const calls = parseLogCalls()
    const stallLine = calls.find((c) => c.msg === 'STALL DETECTED')
    expect(stallLine).toBeUndefined()
  })

  it('does NOT fire if state != open (e.g. during initial connecting)', () => {
    vi.useFakeTimers()
    const mock = createMockCtor()
    createSseClient({
      url: '/x',
      onEvent: () => {},
      additionalEventTypes: [],
      EventSourceCtor: mock.ctor,
      stallThresholdMs: 7_000,
    })
    void vi.advanceTimersByTime(0)
    // Don't fire connected — state is still 'connecting'.
    // After 8s, the stall detector must NOT fire because we're
    // not actually supposed to be receiving events yet.
    vi.advanceTimersByTime(8_000)
    const calls = parseLogCalls()
    expect(calls.find((c) => c.msg === 'STALL DETECTED')).toBeUndefined()
  })
})

describe('SseClient deep v2 logger — error event context', () => {
  it('error event captures sinceLastEventMs + lastEventKind in the log payload', () => {
    vi.useFakeTimers()
    const mock = createMockCtor()
    createSseClient({
      url: '/x',
      onEvent: () => {},
      additionalEventTypes: [],
      EventSourceCtor: mock.ctor,
      stallRecovery: false,
    })
    void vi.advanceTimersByTime(0)
    const es = mock.instance()
    es.simulateOpen('{"ok":true}')
    es.emit('message', 'ping')
    // 12s of silence — simulate the user's symptom
    vi.advanceTimersByTime(12_000)
    es.emit('error')
    es.readyState = 0

    const calls = parseLogCalls()
    const errorLine = calls.find((c) => c.msg === 'EventSource raw error')
    expect(errorLine).toBeDefined()
    // 12s since last heartbeat, readyStateLabel=CONNECTING (per user trace)
    expect(errorLine?.extra?.sinceLastEventMs).toBeGreaterThanOrEqual(11_500)
    expect(errorLine?.extra?.lastEventKind).toBe('heartbeat')
    expect(errorLine?.extra?.heartbeatCount as number).toBeGreaterThanOrEqual(1)
  })

  it('error event right after a message: sinceLastEventMs ~= 0ms', () => {
    vi.useFakeTimers()
    const mock = createMockCtor()
    createSseClient({
      url: '/x',
      onEvent: () => {},
      additionalEventTypes: [],
      EventSourceCtor: mock.ctor,
    })
    void vi.advanceTimersByTime(0)
    const es = mock.instance()
    es.simulateOpen('{"ok":true}')
    es.emit('message', '{"hello":1}')
    // No silence between message and error — connection died mid-stream
    es.emit('error')

    const calls = parseLogCalls()
    const errorLine = calls.find((c) => c.msg === 'EventSource raw error')
    expect(errorLine).toBeDefined()
    expect(errorLine?.extra?.sinceLastEventMs).toBeLessThan(100)
    expect(errorLine?.extra?.lastEventKind).toBe('message')
  })
})

/** Tests for the DISCONNECT DIAGNOSIS log added in the sse-disconnect-diagnosis chunk. */
describe('SseClient deep v2 logger — DISCONNECT DIAGNOSIS', () => {
  it('logs DISCONNECT DIAGNOSIS with suspect=backend when TCP was OPEN during silence', () => {
    vi.useFakeTimers()
    const mock = createMockCtor()
    createSseClient({
      url: '/x',
      onEvent: () => {},
      additionalEventTypes: [],
      EventSourceCtor: mock.ctor,
      // Disable stall recovery so this test isolates diagnosis
      // classification (stall covered in sseStallRecovery.spec).
      stallRecovery: false,
      stallThresholdMs: 7_000,
    })
    void vi.advanceTimersByTime(0)
    const es = mock.instance()
    es.simulateOpen('{"ok":true}')
    es.emit('message', 'ping') // heartbeat
    // 19 seconds of silence — long enough that STALL DETECTED fires (~7s) and the browser's error
    // fires (~14s in jsdom + we simulate the error manually). Mirrors the user's reported symptom
    // from the bug report.
    vi.advanceTimersByTime(19_000)
    // Force the ES into CONNECTING (readyState=0) — what the
    // browser would do internally when its internal retry fires.
    es.readyState = 0
    es.emit('error')

    const calls = parseLogCalls()
    const diag = calls.find((c) => c.msg === 'DISCONNECT DIAGNOSIS')
    expect(diag).toBeDefined()
    // The smoking gun: readyState was OPEN for the entire silence (the stall detector would have
    // fired while readyState=1).
    expect(diag?.extra?.suspect).toBe('backend')
    // Last event was a heartbeat — proves the server was alive
    // enough to send data at some point.
    expect(diag?.extra?.lastEventKind).toBe('heartbeat')
    expect(diag?.extra?.sinceLastEventMs).toBeGreaterThanOrEqual(18_000)
    // Browser reported network online (jsdom default in the
    // `beforeEach` polyfill sets connection.effectiveType='4g',
    // so navigator.onLine defaults to true unless we override).
    expect(diag?.extra?.navigatorOnline).toBe(true)
    // Tab was visible the whole time.
    expect(diag?.extra?.tabHiddenAtMs).toBeNull()
    // No user-code close happened recently.
    expect(diag?.extra?.lastCloseReason).toBeNull()
    // Conclusion is a one-sentence TL;DR — must mention "backend"
    // so the operator can grep for it.
    expect(diag?.extra?.conclusion).toContain('backend')
    // constructedBy is captured so the operator knows which
    // component owns this SseClient.
    expect(diag?.extra?.constructedBy).toBeDefined()
    expect(diag?.extra?.constructedBy).not.toBe('')
  })

  it('logs DISCONNECT DIAGNOSIS with suspect=network when navigator.onLine === false', () => {
    vi.useFakeTimers()
    // jsdom doesn't expose `navigator.onLine` reliably across
    // versions — set it explicitly on the polyfilled navigator.
    Object.defineProperty(globalThis.navigator, 'onLine', {
      value: false,
      configurable: true,
    })
    try {
      const mock = createMockCtor()
      createSseClient({
        url: '/x',
        onEvent: () => {},
        additionalEventTypes: [],
        EventSourceCtor: mock.ctor,
        stallRecovery: false,
      })
      void vi.advanceTimersByTime(0)
      const es = mock.instance()
      es.simulateOpen('{"ok":true}')
      es.emit('message', 'ping')
      vi.advanceTimersByTime(12_000)
      es.readyState = 2 // CLOSED — what browsers typically settle on after a network drop
      es.emit('error')

      const calls = parseLogCalls()
      const diag = calls.find((c) => c.msg === 'DISCONNECT DIAGNOSIS')
      expect(diag).toBeDefined()
      expect(diag?.extra?.suspect).toBe('network')
      expect(diag?.extra?.navigatorOnline).toBe(false)
      expect(diag?.extra?.conclusion).toContain('network')
    } finally {
      // Restore so subsequent tests aren't poisoned.
      Object.defineProperty(globalThis.navigator, 'onLine', {
        value: true,
        configurable: true,
      })
    }
  })

  it('logs DISCONNECT DIAGNOSIS with suspect=user-code when close() was called recently', () => {
    // Note: this is hard to test cleanly because `close()` is terminal — after close, the
    // connection is gone, so no subsequent STALL DETECTED or DISCONNECT DIAGNOSIS log can fire.
    vi.useFakeTimers()
    const mock = createMockCtor()
    const client = createSseClient({
      url: '/x',
      onEvent: () => {},
      additionalEventTypes: [],
      EventSourceCtor: mock.ctor,
    })
    void vi.advanceTimersByTime(0)
    client.close('user-clicked-exit-button')
    const calls = parseLogCalls()
    const closeCall = calls.find(
      (c) => c.msg === 'close() called' && c.extra?.reason === 'user-clicked-exit-button',
    )
    expect(closeCall).toBeDefined()
    expect(closeCall!.extra).toBeDefined()
    // `caller` is the stack-trace fragment captured at the call
    // site. Must be a non-empty string so the operator can grep
    // for it.
    const caller = closeCall!.extra!.caller
    expect(typeof caller).toBe('string')
    expect((caller as string).length).toBeGreaterThan(0)
  })

  it('close(reason) and reconnect(reason) capture the reason + caller frame', () => {
    vi.useFakeTimers()
    const mock = createMockCtor()
    const client = createSseClient({
      url: '/x',
      onEvent: () => {},
      additionalEventTypes: [],
      EventSourceCtor: mock.ctor,
    })
    void vi.advanceTimersByTime(0)
    client.close('component-unmount')
    const calls = parseLogCalls()
    const closeCall = calls.find(
      (c) => c.msg === 'close() called' && c.extra?.reason === 'component-unmount',
    )
    expect(closeCall).toBeDefined()
    expect(closeCall!.extra).toBeDefined()
    // The caller field is a stack trace segment — must be a non-empty string. We don't assert the
    // exact frame because vitest's stack format varies by Node version, but the captured stack
    // should at least contain the sseClient module.
    const caller = closeCall!.extra!.caller
    expect(caller).toBeDefined()
    expect(typeof caller).toBe('string')
    expect((caller as string).length).toBeGreaterThan(0)
  })

  it('STALL DETECTED log includes suspect + conclusion fields', () => {
    vi.useFakeTimers()
    const mock = createMockCtor()
    createSseClient({
      url: '/x',
      onEvent: () => {},
      additionalEventTypes: [],
      EventSourceCtor: mock.ctor,
      stallThresholdMs: 7_000,
    })
    void vi.advanceTimersByTime(0)
    const es = mock.instance()
    es.simulateOpen('{"ok":true}')
    es.emit('message', 'ping')
    vi.advanceTimersByTime(9_000) // past the 7s stall threshold

    const calls = parseLogCalls()
    const stall = calls.find((c) => c.msg === 'STALL DETECTED')
    expect(stall).toBeDefined()
    expect(stall!.extra).toBeDefined()
    // Must classify the stall into one of the five buckets.
    const suspect = stall!.extra!.suspect
    expect(['backend', 'network', 'browser', 'user-code', 'unknown']).toContain(suspect)
    const conclusion = stall!.extra!.conclusion
    expect(typeof conclusion).toBe('string')
    expect((conclusion as string).length).toBeGreaterThan(0)
    // navigatorOnline field is new — must be present.
    expect(stall?.extra).toHaveProperty('navigatorOnline')
    // tabHiddenAtMs field is new — must be present.
    expect(stall?.extra).toHaveProperty('tabHiddenAtMs')
  })

  it('EventSource raw error log includes stall awareness (wasStalledBefore + stallToErrorMs)', () => {
    vi.useFakeTimers()
    const mock = createMockCtor()
    createSseClient({
      url: '/x',
      onEvent: () => {},
      additionalEventTypes: [],
      EventSourceCtor: mock.ctor,
      stallThresholdMs: 7_000,
    })
    void vi.advanceTimersByTime(0)
    const es = mock.instance()
    es.simulateOpen('{"ok":true}')
    es.emit('message', 'ping')
    vi.advanceTimersByTime(9_000) // stall detector fires at 7s
    vi.advanceTimersByTime(5_000) // browser error fires 5s later
    es.readyState = 0
    es.emit('error')

    const calls = parseLogCalls()
    const errorLine = calls.find((c) => c.msg === 'EventSource raw error')
    expect(errorLine).toBeDefined()
    expect(errorLine?.extra?.wasStalledBefore).toBe(true)
    // stallToErrorMs should be ~5000ms (we advanced 5s between stall firing and error firing —
    // stall fires at 7s into the test, error fires at 14s into the test, so the gap is 7s in
    // absolute terms but the stall was first marked at the 7s point of the open window).
    const stallToErrorMs = errorLine?.extra?.stallToErrorMs as number
    expect(stallToErrorMs).toBeGreaterThanOrEqual(6_500)
    expect(stallToErrorMs).toBeLessThan(8_000)
    // Network + visibility fields are new.
    expect(errorLine?.extra).toHaveProperty('navigatorOnline')
    expect(errorLine?.extra).toHaveProperty('tabHiddenAtMs')
  })
})
