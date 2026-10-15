/**
 * sseClient.ts
 *
 * Auto-reconnecting wrapper around the browser-native `EventSource`.
 *
 * Why this exists
 * ───────────────
 * The previous pattern in the desktop app (e.g. `App.vue` worker
 * stream, `ChatsList.vue` session stream, `ChatView.vue` chat + queue
 * streams) was a raw `new EventSource(url)` plus a hand-rolled
 * `onerror` callback. Three things went wrong:
 *
 *   1. **No reconnect on 3 of the 4 streams.** The browser's native
 *      `EventSource` does auto-retry on network-level failures with
 *      a 3 s default — but only if the server sends the SSE spec's
 *      `retry:` field, and ONLY for some failure modes (4xx/5xx are
 *      not retried by the spec). On a `pabrik` server restart, the new
 *      process serves the new connection, but the old `EventSource`
 *      is permanently dead and never reconnects.
 *
 *   2. **Naive retry in `App.vue` had two bugs.** A 5 s
 *      `setTimeout(reconnect)` was not stored, so it could fire
 *      after the component unmounted (timer leak) and could fire
 *      after a *second* transient error had already reconnected
 *      successfully, killing the working connection. See §10 of
 *      `docs/sse-reconnect-plan.md`.
 *
 *   3. **No lifecycle awareness.** Laptops that suspend, tabs
 *      that get backgrounded, and Wi-Fi that drops then reappears
 *      are common — and the previous code did not pause retries
 *      while the tab was hidden, nor fast-path on the browser's
 *      `online` event.
 *
 * This module is the single source of truth for SSE reconnection in
 * the desktop app. It is consumed by `api/index.ts` (the 4 factory
 * functions there are thin adapters) and can be consumed directly
 * for new streams.
 *
 * Public surface
 * ──────────────
 *   - `createSseClient(opts) → SseClient`
 *       Owns one `EventSource`, one retry timer, and the
 *       `visibilitychange` / `online` listeners. All cleaned up in
 *       `.close()`. **The constructor is fully async** — the
 *       initial `start()` is deferred to the next macrotask
 *       (`setTimeout(start, 0)`) so the HTTP request does not
 *       fire synchronously inside the caller. Tests that interact
 *       with `instances[0]` immediately after construction must
 *       call `vi.advanceTimersByTime(0)` to flush the deferred
 *       start.
 *   - `SseClient.close()` — terminal, no further reconnects.
 *   - `SseClient.reconnect()` — force a reconnect, resets attempt
 *       counter. Use it for a user-driven "Retry" button.
 *   - `SseClient.getState()` — synchronous read of the current
 *       state. Use it in templates / ref-bound UI.
 *   - `SseClient.onStateChange(cb)` — subscribe to state
 *       transitions. Returns an unsubscribe function. Use it to
 *       drive reactive UI (e.g. a "Reconnecting…" badge).
 *
 * State machine
 * ─────────────
 *
 *        construct
 *            │
 *            ▼
 *      ┌──────────┐
 *      │connecting│◄────────────────────────┐
 *      └────┬─────┘                         │
 *           │ 'connected' server event      │
 *           ▼                               │
 *       ┌──────┐ onerror                    │
 *       │ open │──────────────────┐         │
 *       └──┬───┘                  │         │
 *          │ .close()             │         │
 *          ▼                      ▼         │
 *      ┌────────┐  timer     ┌────────────┐ │
 *      │ closed │  fires     │reconnecting│─┘
 *      └────────┘            └─────┬──────┘
 *                                 │ too many errors
 *                                 │ OR non-recoverable 4xx/5xx
 *                                 │ on FIRST attempt
 *                                 ▼
 *                              ┌────────┐
 *                              │ failed │
 *                              └────────┘
 *
 * Notes:
 *   - `reconnecting → connecting` is the timer-or-event fast path
 *     (a fresh `EventSource` is constructed).
 *   - `failed` is terminal. The only way out is `.reconnect()` or
 *     constructing a new client.
 *   - `visibilitychange → visible` AND `online` event both
 *     fast-path `reconnecting → connecting` (cancel the timer,
 *     start a fresh attempt).
 *   - `pagehide` AND `beforeunload` (added in the 2026-01-15 fix)
 *     call `close()` synchronously. Without this, the browser only
 *     eventually tears down the underlying socket on page unload,
 *     and the SSE connection lingers in the network panel as
 *     "open" / "pending" until the server-side timeout fires. The
 *     browser's `EventSource` close method is also needed to make
 *     the browser drop the stream from the network panel
 *     immediately on refresh / tab close / navigation. Set
 *     `closeOnUnload: false` to opt out (tests, SSR).
 */
/**
 * State emitted by `SseClient`. See the state machine in the file
 * header for transitions.
 *
 * - `connecting`:   An `EventSource` was just opened; waiting for the
 *                   first byte / the server's `connected` named event.
 * - `open`:         Server sent a `connected` named event. We are
 *                   live; data events are flowing.
 * - `reconnecting`: Stream was open, then `onerror` fired, and a
 *                   retry timer is pending (or we are paused waiting
 *                   for visibility / online).
 * - `closed`:       Consumer called `.close()`. Terminal.
 * - `failed`:       Terminal. Either the first attempt errored (4xx /
 *                   5xx) before any `open` fired, or
 *                   `maxAttempts` was reached.
 */
export type SseState = 'connecting' | 'open' | 'reconnecting' | 'closed' | 'failed'

/**  * Side-channel info attached to every state emission. Lets UI (and tests) distinguish "first error
 * before open" from "Nth error after open" without re-implementing the logic. */
export interface SseStateInfo {
  /** 1 = first try, 2 = first retry, … */
  attempt: number
  /**    * Set on `reconnecting`. The actual delay until the next attempt (after jitter), in ms. Tests use
   * this to assert the backoff schedule deterministically. */
  nextDelayMs?: number
  /** Set on `reconnecting` / `failed`. The `error` event from the ES. */
  lastError?: Event
  /**
   * What triggered this transition. Useful for log/UX messages:
   *   - `error`            — the EventSource fired onerror
   *   - `stall`            — stall detector fired (no events for stallThresholdMs while open)
   *   - `closed`           — the EventSource fired a clean close (rare)
   *   - `online`           — the browser's `online` event fast-pathed us
   *   - `visible`          — the tab became visible while we were paused
   *   - `manual`           — the consumer called .close() or .reconnect()
   *   - `exhausted`        — `maxAttempts` reached (only on `failed`)
   *   - `non-recoverable`  — first-attempt failure (4xx/5xx) (only on `failed`)
   */
  reason?:
    | 'error'
    | 'stall'
    | 'closed'
    | 'online'
    | 'visible'
    | 'manual'
    | 'exhausted'
    | 'non-recoverable'
}

export interface SseClientOptions {
  /** URL to subscribe to. Required. */
  url: string
  /**
   * Event dispatcher. Called once per `data:` line the server sent.
   *
   * - `raw` is the unparsed payload string. The SseClient does
   *   NOT do JSON parsing — the adapter owns that. JSON
   *   buffering (multi-line payloads) is the adapter's
   *   responsibility, since the SseClient has no idea what
   *   payload format the server uses.
   * - `eventType` is the SSE `event:` name (`'message'` for the
   *   unnamed default, or the named event name like
   *   `'connected'` / `'queue_message'`). For custom named
   *   events to be routed here, list them in
   *   `additionalEventTypes` — the SseClient does NOT
   *   auto-discover server-sent event names, it must be told
   *   which ones to listen for. The `'connected'` event is
   *   always registered automatically.
   *
   * Throwing inside this callback is caught and logged — a
   * malformed event does NOT close the connection.
   */
  onEvent: (raw: string, eventType: string) => void
  /**
   * Additional named SSE event types to route to `onEvent`.
   * The reserved names `'connected'` (handled internally:
   * fires `onConnected` and transitions to `'open'`) and
   * `'message'` (the unnamed default) are always registered;
   * duplicates in this list are silently de-duplicated.
   *
   * Why this option exists
   * ──────────────────────
   * The browser's `EventSource` fires each server-side
   * `event: <name>` to listeners registered for THAT specific
   * name. The SseClient can only register listeners it knows
   * about up front, so consumers must declare which custom
   * event types they care about. Without this, named events
   * like `queue_message` are silently dropped on the floor
   * — they reach the network but never reach the JS handler.
   *
   * Example — the queue-messages stream:
   *   createSseClient({
   *     url: '/api/.../queue_messages/stream',
   *     additionalEventTypes: ['queue_message'],
   *     onEvent: (raw, type) => {
   *       if (type === 'queue_message') { ... }
   *     },
   *   })
   *
   * Unknown / never-fired names are harmless (the listener
   * simply never fires).
   */
  additionalEventTypes?: string[]
  /**
   * Heartbeat data to drop silently from the default
   * `'message'` event stream. The backend SSE manager sends
   * `data: ping\n\n` every ~15 s to keep the connection alive
   * through proxies / NATs; surfacing that to consumers
   * leaks the protocol detail and (in consumers that
   * JSON-buffer the data, like the queue-messages stream)
   * grows an ever-larger buffer that never flushes, because
   * `'ping'` contains no `{` or `}` to anchor a JSON slice.
   *
   * Default: `'ping'` (matches `sse_manager.sendHeartbeat`).
   * Set to `null` to disable the filter (every default
   * `'message'` event reaches `onEvent`, including
   * heartbeats).
   *
   * Only applies to the default `'message'` event. Heartbeats
   * sent as custom named events (e.g. `event: heartbeat`) are
   * not affected — declare and ignore them in the consumer
   * instead.
   */
  heartbeatData?: string | null
  /** Fires once, after the server's first `connected` named event. This is the canonical "we are
   * live" signal. Do NOT treat the raw `open` event (HTTP 200 + headers) as live — the connection
   * can still be rejected at the protocol level by the server. */
  /** The 'connected' event is ALSO passed to `onEvent` with `eventType === 'connected'`, so
   * adapters that want the payload can read it from there. */
  onConnected?: () => void
  /** Fires on every state transition. Use it to drive a Vue ref
   * for reactive UI (e.g. the `SseStatusBadge`). */
  onStateChange?: (state: SseState, info: SseStateInfo) => void
  /** Initial backoff for the *first* retry. Doubles each subsequent
   * retry, capped at `maxDelayMs`. Default: 1 000 ms. */
  baseDelayMs?: number
  /**    * Upper bound on the backoff delay (after jitter). Default: 30 000 ms. The "Reconnecting…" badge
   * can use this to give the user a sense of how long the next attempt will take. */
  maxDelayMs?: number
  /** Hard cap on reconnect attempts. After this many failed retries (post-open), state becomes
   * `failed` and no further retries are scheduled. The first attempt does NOT count against this
   * cap (a 4xx on the first try already goes to `failed` immediately). */
  /** Default: `Infinity` (an SSE stream is expected to live the lifetime of the page). */
  maxAttempts?: number
  /**    * Random source for jitter. Override in tests to make the backoff schedule deterministic.
   * Default: `Math.random`. Jitter formula: `delay = exp * (0.5 + 0.5 * random())` (full-jitter
   * pattern, AWS-style). */
  random?: () => number
  /**    * Pause the retry timer while `document.hidden === true`. The retry fires immediately on
   * `visibilitychange → visible`. Default: `true`. Set `false` for headless contexts or tests. */
  pauseWhenHidden?: boolean
  /**    * Reconnect immediately on the browser's `online` event. Default: `true`. The event target is
   * `window` (override with `onlineTarget` for tests). */
  reconnectOnOnline?: boolean
  /**    * Override the `EventSource` constructor. Default: `globalThis.EventSource`. Tests pass a mock
   * factory here so they can fire synthetic `open` / `error` / `message` events without a real
   * network. */
  EventSourceCtor?: typeof EventSource
  /** Override the `visibilitychange` target. Default: `document`.
   * Tests may pass a mock to control visibility. */
  visibilityTarget?: Pick<Document, 'addEventListener' | 'removeEventListener' | 'hidden'>
  /** Override the `online` event target. Default: `window`. Tests
   * may pass a mock to fire synthetic `online` events. */
  onlineTarget?: Pick<Window, 'addEventListener' | 'removeEventListener'>
  /** Override `setTimeout` / `clearTimeout` for fake-timer tests.
   * Default: the global `setTimeout` / `clearTimeout`. */
  setTimeoutFn?: typeof setTimeout
  clearTimeoutFn?: typeof clearTimeout
  /**
   * Close the connection automatically on `pagehide` (modern,
   * covers bfcache) and `beforeunload` (legacy fallback). When
   * the user refreshes the page, closes the tab, or navigates
   * away, the browser will eventually tear down the underlying
   * socket — but the SSE connection lingers in the network
   * panel as "open" / "pending" and the server does not know
   * the client is gone until the server-side timeout fires.
   * Listening for `pagehide` + `beforeunload` and calling
   * `close()` synchronously makes the browser drop the stream
   * from the network panel immediately.
   *
   * Default: `true`. Set `false` in tests (to avoid extra
   * listeners) or in headless contexts that have no `window`.
   */
  closeOnUnload?: boolean
  /**    * Override the `pagehide` / `beforeunload` event target. Default: `window`. Tests may pass a mock
   * to fire synthetic unload events. */
  unloadTarget?: Pick<Window, 'addEventListener' | 'removeEventListener'>
  /**    * The SSE event name that signals "the stream is live". The default `'connected'` matches the
   * backend's convention; expose it for symmetry / future flexibility. */
  connectedEventName?: string
  /** Stall threshold in ms. While `state === 'open'`, if no event (message / heartbeat / connected)
   * arrives within this window, the client treats the stream as silently dead and reconnects (see
   * `stallRecovery`). */
  /** Default: 30_000 — well ABOVE the ~15s backend keep-alive (`sse_manager.sendHeartbeat`), with
   * margin for timer jitter. A threshold below the heartbeat interval guarantees false-positive
   * reconnects on every idle window. Tests may pass a smaller value for determinism. */
  stallThresholdMs?: number
  /**    * When true (default), a stall triggers `es.close()` + `scheduleRetry({ reason: 'stall' })`
   * instead of only logging. Set false to restore log-only behaviour (e.g. for diagnosis). */
  stallRecovery?: boolean
  /** Max time in ms to wait for the server's `connected` handshake after (re)starting the
   * EventSource before treating the stream as dead. */
  /** Guards against streams that return HTTP 200 + valid SSE framing but never emit the handshake
   * (e.g. a backend rejection path that cannot change the already-sent status code) — without this
   * the client sits in 'connecting' forever. */
  /** Heartbeats do NOT reset this timer; only the handshake does. Default: 15_000. Firing routes
   * through the normal error path (`failed` on first attempt, backoff retry once ever open). */
  connectedTimeoutMs?: number
}

export interface SseClient {
  /**
   * Close the connection. Terminal — no further state changes, no
   * further retries, all listeners removed. Safe to call multiple
   * times.
   *
   * @param reason Optional human-readable string identifying the
   * call site. Surfaced in every subsequent diagnostic log
   * (STALL DETECTED, DISCONNECT DIAGNOSIS) so the operator can
   * answer "who closed this connection?" by reading the console.
   * Defaults to `'unspecified'` when omitted.
   */
  close(reason?: string): void
  /**
   * Force a reconnect attempt right now. Resets the attempt
   * counter to 0. If the connection is currently `open`, the
   * existing `EventSource` is closed and a new one is opened.
   * Intended for a user-driven "Retry" button on the `failed`
   * badge.
   *
   * @param reason Optional human-readable string identifying the
   * call site. Surfaced in every subsequent diagnostic log so the
   * operator can correlate a manual reconnect with any subsequent
   * stall/error.
   */
  reconnect(reason?: string): void
  /**
   * Synchronous read of the current state. Returns the most recently emitted state. /
   */
  getState(): SseState
  /**    * Subscribe to state transitions. Returns an unsubscribe function. Subscribers are NOT called for
   * the state that was current at the time of subscription — only for transitions that happen AFTER
   * subscribing. (If you need the current state at subscription time, call `getState()` too.) */
  onStateChange(cb: (s: SseState, info: SseStateInfo) => void): () => void
}

/**
 * Create a self-managing SSE client with exponential backoff and
 * full jitter. See the file header for the state machine and the
 * public surface.
 *
 * @example
 *   const client = createSseClient({
 *     url: '/api/sessions/stream',
 *     onEvent: (raw, type) => console.log(type, raw),
 *     onConnected: () => console.log('live'),
 *     onStateChange: (s) => (sseState.value = s),
 *   })
 *   // later
 *   client.close()
 */
export function createSseClient(opts: SseClientOptions): SseClient {
  // =====================================================================
  // Diagnostic logger — DEEP v2
  //
  // Tracks every received byte at millisecond resolution so we can
  // tell exactly WHEN data stopped flowing before a disconnect.
  // Critical for the "drops at 15s" bug — without per-message
  // timestamps we can't tell if onerror fired:
  //   (a) RIGHT after the last message (server crashed mid-send)
  //   (b) 15s after the last message (keep-alive timeout fired)
  //   (c) BEFORE any messages arrived (connection never established)
  //
  // Toggle off by setting `globalThis.__sseDebug = false` in DevTools.
  // =====================================================================
  const debugOn: boolean = (globalThis as { __sseDebug?: boolean }).__sseDebug !== false
  const t0: number = performance.now()
  // High-resolution clock for delta-time measurements. performance.now()
  // is monotonic (immune to wall-clock adjustments) and gives
  // sub-millisecond precision in every modern browser.
  const now = (): number => performance.now() - t0
  const iso = (): string => new Date().toISOString()
  const fmtMs = (ms: number): string => (ms / 1000).toFixed(3) + 's'
  // navigator.connection is the NetworkInformation API. It's non-standard (Chromium-only), so we
  // type-erase Navigator with a cast. Reports effectiveType ('4g' / '3g' / '2g' / 'slow-2g'),
  // downlink (Mbps estimate), rtt (ms estimate), and saveData (user has data-saver enabled).
  // All fields are nullable.
  const readNetworkInfo = (): Record<string, unknown> | null => {
    if (typeof navigator === 'undefined') return null
    const conn = (navigator as Navigator & { connection?: unknown }).connection
    if (conn === null || conn === undefined) return null
    const c = conn as {
      effectiveType?: string
      downlink?: number
      rtt?: number
      saveData?: boolean
    }
    return {
      effectiveType: c.effectiveType,
      downlink: c.downlink,
      rtt: c.rtt,
      saveData: c.saveData,
    }
  }
  const log = (msg: string, extra?: Record<string, unknown>): void => {
    if (!debugOn) return
    const t = now()
    const extra_ = extra ? ' ' + JSON.stringify(extra) : ''

    console.log(`[sse-client ${iso()} t=${fmtMs(t)}] ${msg}${extra_}`)
  }
  // Track timing of last received event. Initially null = no event yet.
  let lastEventAt: number | null = null
  let lastEventKind: string | null = null
  let lastEventBytes: number = 0
  let heartbeatCount: number = 0
  let eventCount: number = 0
  // Stall detector: while state='open', if no event arrives within `stallThresholdMs` of the
  // previous one, emit a warning so the operator can see "data stopped 10s ago" before the eventual
  // onerror fires. Disabled by default; activated via the global toggle below.
  const stallDetectorOn: boolean =
    (globalThis as { __sseStallDetector?: boolean }).__sseStallDetector !== false
  const stallThresholdMs: number = opts.stallThresholdMs ?? 30_000 // 30s — well above the ~15s backend heartbeat
  const stallRecovery: boolean = opts.stallRecovery ?? true
  let stallTimer: ReturnType<typeof setTimeout> | null = null
  // Connected-handshake timeout: armed in start(), cleared on the
  // first `connected` event (or any terminal path). Fires when the
  // server holds the stream open without ever handshaking.
  let connectedTimer: ReturnType<typeof setTimeout> | null = null
  // Set to `now()` the first time the stall detector fires during a given open window. Reset on
  // every 'connected' event (so the gap between stall-detected and browser-error is the delta of
  // two timestamps, not the cumulative stall count).
  // Surfaced in the EventSource 'error' log + the DISCONNECT DIAGNOSIS log so the operator can see
  // "stall detector saw it 12s before the browser did" — a key diagnostic for backend vs
  // browser-initiated drops.
  let stallFiredAt: number | null = null
  // Readiness at the time the stall detector fired.
  // Captured because by the time the browser fires the actual `error` event, readyState has usually
  // transitioned from OPEN to CONNECTING (the browser's internal retry state) — losing the smoking
  // gun for "TCP was alive during the silence". Reset on every 'connected' event.
  let stallFiredAtReadiness: string | null = null
  // Tracks when the tab became hidden (and when it became visible again). Set in
  // `onVisibilityChange`.
  // Surfaced in every diagnostic log so the operator can rule out "browser paused the connection
  // because the user backgrounded the tab" — a common cause of EventSource silence that is NOT a
  // disconnect.
  let tabHiddenAtMs: number | null = null
  // Tracks when the browser last fired the `offline` event. Cleared on `online`. Surfaced in the
  // same diagnostic logs for the same reason — `navigator.onLine === false` is a stronger signal
  // than "we haven't seen bytes in 19s" because it points squarely at the network layer.
  let navigatorOfflineAtMs: number | null = null
  // Capture the stack frame at the time the consumer called `.close(reason?)` and
  // `.reconnect(reason?)`. Surfaced in every diagnostic log so the operator can answer "who asked
  // for this disconnect?" — was it App.vue on unmount? pagehide/beforeunload?
  // Or did nobody ask, and the browser fired onerror by itself?
  let lastCloseReason: string | null = null
  let _lastCloseCaller: string | null = null
  let lastCloseAtMs: number | null = null
  let lastReconnectReason: string | null = null
  let _lastReconnectCaller: string | null = null
  let lastReconnectAtMs: number | null = null
  // Capture the constructor's caller frame so we can answer "who instantiated this SseClient?" —
  // useful when several components share the bus and you want to know which one owns the long-lived
  // stream.
  const constructedAtCaller = (() => {
    const stack = new Error('sseClient::captureCaller').stack
    if (!stack) return '(no stack)'
    // Skip the first 2 frames (Error ctor + our IIFE) and grab up to
    // 3 caller frames. Picked up by STALL DETECTED and DISCONNECT
    // DIAGNOSIS to answer "where was this client created?".
    return stack
      .split('\n')
      .slice(2, 5)
      .map((line) => line.trim().replace(/^at\s+/, ''))
      .filter((line) => line.length > 0)
      .join(' | ')
  })()

  // Classify the cause of an SSE disconnect into one of five buckets.
  // The DISCONNECT DIAGNOSIS log + the STALL DETECTED log include
  // this field so the operator can answer the user's question —
  // "was it the backend, the frontend, or the network?" — by
  // reading a single line of console output. Buckets:
  //
  //   - 'backend'   Server stopped sending data but the TCP socket
  //                 is still alive (EventSource.readyState === OPEN
  //                 during a sustained silence). Last event was
  //                 typically a heartbeat, which means the server
  //                 process is still running but its heartbeat
  //                 sender stalled (zombie loop, panic'd worker
  //                 thread, etc.) or the server killed the SSE
  //                 connection without RST/FIN.
  //   - 'network'   Browser reported offline (navigator.onLine ===
  //                 false via the 'offline' event or the property
  //                 check). TCP socket almost certainly dead.
  //   - 'browser'   Tab is hidden AND silence started after the
  //                 hide transition. Browsers throttle / pause
  //                 EventSource when the tab is backgrounded, which
  //                 LOOKS like a stall in the logs but is actually
  //                 expected behavior.
  //   - 'user-code' User code called .close() or .reconnect()
  //                 recently. Disconnect is intentional — not a bug.
  //   - 'unknown'   Could not classify (the signals conflict — e.g.
  //                 readyState=OPEN AND tab hidden AND network
  //                 online). Surfaced so the operator knows to dig
  //                 deeper.
  type Suspect = 'backend' | 'network' | 'browser' | 'user-code' | 'unknown'
  function classifyDisconnectSuspect(snapshot: {
    readiness: string
    networkOnline: boolean | null
    tabHiddenAtMs: number | null
    sinceLastCloseMs: number | null
    sinceLastReconnectMs: number | null
    sinceLastEventMs: number
  }): Suspect {
    const {
      readiness,
      networkOnline,
      tabHiddenAtMs: hidden,
      sinceLastCloseMs,
      sinceLastReconnectMs,
      sinceLastEventMs,
    } = snapshot
    // User-code close is the strongest signal — if close() was called within the last few seconds,
    // the disconnect is by definition intentional. We give this priority over network/ backend so
    // the operator doesn't see a confusing "backend/network" diagnosis for a deliberate close.
    if (sinceLastCloseMs !== null && sinceLastCloseMs < 5_000) {
      return 'user-code'
    }
    // Network reported offline — TCP is almost certainly dead.
    if (networkOnline === false) {
      return 'network'
    }
    // Tab hidden AND the stall started AFTER the hide transition — browser throttled the
    // connection. Excludes the case where the tab was hidden for hours before the stall started,
    // which is unlikely in practice but flagged as 'unknown' below if it does happen.
    if (hidden !== null && now() - hidden < sinceLastEventMs + 5_000) {
      return 'browser'
    }
    // readiness === OPEN during sustained silence → server stopped
    // sending data while the socket was alive. Strong backend
    // signal.
    if (readiness === 'OPEN' && sinceLastEventMs > 5_000) {
      return 'backend'
    }
    // User-code reconnect was called recently — the disconnect is
    // a side effect of a manual reset, not a real outage.
    if (sinceLastReconnectMs !== null && sinceLastReconnectMs < 5_000) {
      return 'user-code'
    }
    return 'unknown'
  }

  // Render the suspect classification + the supporting signals into a single human-readable
  // sentence. The DISCONNECT DIAGNOSIS log attaches this so the operator can read one line and know
  // what happened — no need to cross-reference multiple log lines.
  // Each sentence includes the suspect token verbatim ('backend', 'network', 'browser',
  // 'user-code') so the operator can grep for `conclusion: ...backend...` to find every disconnect
  // we attributed to the server.
  // Tests pin this contract; do not reword the suspect label without updating
  // `sseClient.deeplog.spec.ts`.
  function formatConclusion(
    suspect: Suspect,
    snapshot: {
      readiness: string
      networkOnline: boolean | null
      tabHiddenAtMs: number | null
      sinceLastEventMs: number
      lastEventKind: string | null
      lastCloseReason: string | null
      lastReconnectReason: string | null
    },
  ): string {
    const silentFor = Math.round(snapshot.sinceLastEventMs / 100) / 10
    const silentForStr = `${silentFor}s`
    switch (suspect) {
      case 'backend':
        return `Suspect=backend: server stopped sending events ${silentForStr} ago (last was ${snapshot.lastEventKind ?? 'unknown'}); TCP socket was ${snapshot.readiness.toLowerCase()} so backend is the prime suspect`
      case 'network':
        return `Suspect=network: browser reports navigator.onLine === false; TCP socket likely dead after ${silentForStr} of silence`
      case 'browser':
        return `Suspect=browser: tab became hidden during the silence window — browser paused the EventSource; not a real disconnect`
      case 'user-code': {
        const r = snapshot.lastCloseReason ?? snapshot.lastReconnectReason ?? '(no reason)'
        return `Suspect=user-code: user code called close()/reconnect() (reason="${r}") within the last 5s — disconnect is intentional`
      }
      case 'unknown':
      default:
        return `Suspect=unknown: could not classify — readiness=${snapshot.readiness}, online=${snapshot.networkOnline}, hidden=${snapshot.tabHiddenAtMs !== null}, silentFor=${silentForStr}`
    }
  }

  function resetStallDetector(): void {
    if (stallTimer !== null) {
      clearTimeoutFn(stallTimer)
      stallTimer = null
    }
    if (!stallDetectorOn) return
    if (state !== 'open') return
    stallTimer = setTimeoutFn(() => {
      // No event in stallThresholdMs while we should be open. Log it.
      const sinceLast = lastEventAt !== null ? now() - lastEventAt : -1
      const readiness = ['CONNECTING', 'OPEN', 'CLOSED'][es?.readyState ?? 0] ?? 'UNKNOWN'
      // `navigator.onLine` may be missing (jsdom without the polyfill, SSR without a Navigator) —
      // fall back to a boolean rather than letting `undefined` propagate, which JSON.stringify
      // would strip out of the log payload and confuse the operator.
      const networkOnline: boolean | null =
        typeof navigator === 'undefined'
          ? null
          : typeof navigator.onLine === 'boolean'
            ? navigator.onLine
            : null
      // Mark the wall-clock instant the stall detector fired so the downstream 'error' listener can
      // compute "stall-to-error ms" and the DISCONNECT DIAGNOSIS can show how long the operator had
      // to wait between "we know it's dead" and "the browser agrees".
      // Also capture the readiness AT STALL TIME so the DISCONNECT DIAGNOSIS doesn't lose the
      // smoking gun when the browser transitions readyState to CONNECTING before firing its onerror
      // event.
      stallFiredAt = now()
      stallFiredAtReadiness = readiness
      const suspect = classifyDisconnectSuspect({
        readiness,
        networkOnline,
        tabHiddenAtMs,
        sinceLastCloseMs: lastCloseAtMs !== null ? now() - lastCloseAtMs : null,
        sinceLastReconnectMs: lastReconnectAtMs !== null ? now() - lastReconnectAtMs : null,
        sinceLastEventMs: Math.round(sinceLast),
      })
      log('STALL DETECTED', {
        sinceLastEventMs: Math.round(sinceLast),
        lastEventKind,
        lastEventBytes,
        heartbeatCount,
        eventCount,
        readyState: es?.readyState,
        readyStateLabel: readiness,
        // navigator.connection tells us what kind of network the browser thinks we're on. If the
        // effectiveType says "2g" or "slow-2g", that's the smoking gun.
        // The NetworkInformation API is non-standard, so we type-erase Navigator with a cast —
        // guards against TS complaining in jsdom too.
        navConn: readNetworkInfo(),
        // Disconnect classification — answers "is this the backend's fault, the browser's fault, or
        // the network's fault?" in a single field. See `classifyDisconnectSuspect` for the rules.
        // Operator can grep for `SUSPECT: backend` to find every stall the desktop app attributed
        // to the server.
        suspect,
        navigatorOnline: networkOnline,
        tabHiddenAtMs,
        // `sinceLastUserActionMs` makes it easy to correlate this stall with a route change, a
        // click, a navigation, etc. The operator can cross-reference the value with browser
        // DevTools timeline.
        sinceLastCloseMs: lastCloseAtMs !== null ? Math.round(now() - lastCloseAtMs) : null,
        sinceLastReconnectMs:
          lastReconnectAtMs !== null ? Math.round(now() - lastReconnectAtMs) : null,
        lastCloseReason,
        lastReconnectReason,
        constructedBy: constructedAtCaller,
        // `conclusion` is the operator's TL;DR — one sentence that tells them what we think
        // happened. Composed from the same snapshot via `formatConclusion` so the STALL DETECTED
        // and DISCONNECT DIAGNOSIS conclusions are consistent.
        conclusion: formatConclusion(suspect, {
          readiness,
          networkOnline,
          tabHiddenAtMs,
          sinceLastEventMs: Math.round(sinceLast),
          lastEventKind,
          lastCloseReason,
          lastReconnectReason,
        }),
      })
      // Stall recovery (idle-freeze fix): the stream is silently dead (TCP open, zero bytes). The
      // browser will NOT fire onerror on its own, so close the dead EventSource and schedule a
      // retry.
      // Guarded by `stallRecovery` (default true) so diagnosis builds can restore log-only
      // behaviour.
      if (stallRecovery && !closed && state === 'open') {
        log('STALL RECOVERY reconnect', { sinceLastEventMs: Math.round(sinceLast), suspect })
        if (es) {
          try {
            es.close()
          } catch {
            // Some polyfills throw on close; ignore.
          }
          es = null
        }
        logDisconnectDiagnosis('error-event')
        scheduleRetry({ reason: 'stall' })
      }
    }, stallThresholdMs)
  }

  // Fires from `handleError` (the 'onerror' path) and from `onPageHide` (the page-unload path) —
  // but ONLY on the onerror path. Synthesizes every signal we have into one log so the operator can
  // answer "was this the backend, the frontend, or the network?" by reading a single line.
  function logDisconnectDiagnosis(reason: 'error-event' | 'page-unload' | 'non-recoverable'): void {
    const sinceLast = lastEventAt !== null ? now() - lastEventAt : -1
    // Use the readiness captured at stall-time if available — that's the smoking gun. The current
    // readiness is typically CONNECTING (browser is in its internal retry state) which would
    // mislead the classifier. Falls back to current readiness if no stall ever fired.
    const readiness =
      stallFiredAtReadiness ?? ['CONNECTING', 'OPEN', 'CLOSED'][es?.readyState ?? 0] ?? 'UNKNOWN'
    const networkOnline =
      typeof navigator === 'undefined'
        ? null
        : typeof navigator.onLine === 'boolean'
          ? navigator.onLine
          : null
    const sinceStall = stallFiredAt !== null ? Math.round(now() - stallFiredAt) : null
    const sinceLastCloseMs = lastCloseAtMs !== null ? Math.round(now() - lastCloseAtMs) : null
    const sinceLastReconnectMs =
      lastReconnectAtMs !== null ? Math.round(now() - lastReconnectAtMs) : null
    const suspect = classifyDisconnectSuspect({
      readiness,
      networkOnline,
      tabHiddenAtMs,
      sinceLastCloseMs,
      sinceLastReconnectMs,
      sinceLastEventMs: Math.round(sinceLast),
    })
    log('DISCONNECT DIAGNOSIS', {
      // Top-level signal — what we think caused this.
      suspect,
      // Why we're logging the diagnosis. 'error-event' = the browser fired EventSource.onerror.
      // 'page-unload' = we're tearing down because the user is leaving. 'non-recoverable' = the
      // server returned a 4xx/5xx on the first attempt.
      reason,
      // EventSource lifecycle state at the moment of diagnosis.
      readiness,
      // Network state at diagnosis time. `null` means the API
      // isn't available (e.g. SSR, jsdom without the polyfill).
      navigatorOnline: networkOnline,
      effectiveType: readNetworkInfo()?.effectiveType ?? null,
      // Visibility — `null` means the tab has been visible the
      // whole session; a number means it became hidden that many ms
      // ago.
      tabHiddenAtMs,
      // Time since the last received event. -1 = we never got one.
      sinceLastEventMs: Math.round(sinceLast),
      lastEventKind,
      lastEventBytes,
      // Heartbeats and named events counted separately so the
      // operator can tell "we never got ANY data" from "we got
      // heartbeats but no named events".
      heartbeatCount,
      eventCount,
      // Did the stall detector fire BEFORE the browser's onerror?
      // If so, by how many ms? This is the "you had warning X
      // seconds before the browser caught up" signal.
      wasStalledBefore: stallFiredAt !== null,
      stallToErrorMs: sinceStall,
      // Attempt counter — `attempt` was incremented by start() when
      // the current EventSource was constructed. If we never
      // connected successfully, this is the first attempt.
      attempt,
      // Most recent user-code actions. Surfaced so the operator
      // can correlate the disconnect with a route change, an App
      // unmount, a user-driven "retry" click, etc.
      sinceLastCloseMs,
      sinceLastReconnectMs,
      lastCloseReason,
      lastReconnectReason,
      // Where was this SseClient instantiated? Captured at
      // construction time (see `constructedAtCaller`). Helps when
      // several components share the bus.
      constructedBy: constructedAtCaller,
      // Human-readable TL;DR. Same shape as the STALL DETECTED
      // `conclusion` so the operator can read either log line and
      // get the same answer.
      conclusion: formatConclusion(suspect, {
        readiness,
        networkOnline,
        tabHiddenAtMs,
        sinceLastEventMs: Math.round(sinceLast),
        lastEventKind,
        lastCloseReason,
        lastReconnectReason,
      }),
    })
  }

  log('createSseClient', { url: opts.url })

  const baseDelayMs = opts.baseDelayMs ?? 1_000
  const maxDelayMs = opts.maxDelayMs ?? 30_000
  const maxAttempts = opts.maxAttempts ?? Infinity
  const random = opts.random ?? Math.random
  const pauseWhenHidden = opts.pauseWhenHidden ?? true
  const reconnectOnOnline = opts.reconnectOnOnline ?? true
  const setTimeoutFn = opts.setTimeoutFn ?? setTimeout
  const clearTimeoutFn = opts.clearTimeoutFn ?? clearTimeout
  const connectedEventName = opts.connectedEventName ?? 'connected'
  // Connected-handshake deadline (see the option doc). Heartbeats
  // must NOT reset this — a stream that pings without handshaking
  // is exactly the hang this guards against.
  const connectedTimeoutMs: number = opts.connectedTimeoutMs ?? 15_000
  // Heartbeat data to silently drop from the default 'message' event. Default: 'ping' (matches
  // sse_manager.sendHeartbeat's literal `data: ping\n\n`). `null` disables the filter entirely —
  // see the `heartbeatData` option doc for why this exists.
  const heartbeatData: string | null =
    opts.heartbeatData === undefined ? 'ping' : opts.heartbeatData
  // Deduplicated list of custom named event types the consumer wants routed to `onEvent`. Reserved
  // names (`'connected'`, `'message'`) are always handled by the SseClient's own listeners, so
  // including them here is a no-op.
  // We filter them out below to avoid double-registration (which would fire `onEvent` twice per
  // event).
  const reservedEventNames = new Set<string>(['connected', 'message'])
  const additionalEventTypes: string[] = (opts.additionalEventTypes ?? []).filter(
    (name) => !reservedEventNames.has(name),
  )
  // Cast is safe: in browsers EventSource is a global, in jsdom the
  // setup.ts polyfill assigns it. Tests override via opts.
  const EventSourceCtor =
    opts.EventSourceCtor ??
    ((globalThis as { EventSource?: typeof EventSource }).EventSource as typeof EventSource)
  const visibilityTarget = (opts.visibilityTarget ??
    (typeof document !== 'undefined' ? document : null)) as Pick<
    Document,
    'addEventListener' | 'removeEventListener' | 'hidden'
  > | null
  const onlineTarget = (opts.onlineTarget ??
    (typeof window !== 'undefined' ? window : null)) as Pick<
    Window,
    'addEventListener' | 'removeEventListener'
  > | null
  const closeOnUnload = opts.closeOnUnload ?? true
  const unloadTarget = (opts.unloadTarget ??
    (typeof window !== 'undefined' ? window : null)) as Pick<
    Window,
    'addEventListener' | 'removeEventListener'
  > | null

  // Mutable connection state
  let es: EventSource | null = null
  let retryTimer: ReturnType<typeof setTimeout> | null = null
  let attempt = 0
  let hasBeenOpen = false
  let state: SseState = 'connecting'
  const subscribers = new Set<(s: SseState, info: SseStateInfo) => void>()
  let closed = false

  function emitState(next: SseState, info: SseStateInfo): void {
    state = next
    if (next !== 'open') {
      // Clear the stall detector when leaving 'open' — otherwise its setTimeout keeps the timer
      // count non-zero in tests and could fire a misleading STALL warning while we're already in
      // 'reconnecting' / 'failed' / 'closed'.
      if (stallTimer !== null) {
        clearTimeoutFn(stallTimer)
        stallTimer = null
      }
      // 'open' is logged by the 'connected' event listener at the exact moment we receive the
      // server handshake (more diagnostic value than logging every state transition once the
      // connection is stable).
      log('state', {
        next,
        attempt: info.attempt,
        reason: info.reason,
        nextDelayMs: info.nextDelayMs,
      })
    }
    for (const cb of subscribers) {
      try {
        cb(next, info)
      } catch (err) {
        // A buggy subscriber must not poison the others or the connection. Log to console.error
        // (not throw) so the surface stays usable in dev. Production code is expected to be
        // careful; this is just defense-in-depth.
        console.error('[SseClient] onStateChange subscriber threw:', err)
      }
    }
  }

  function clearRetry(): void {
    if (retryTimer !== null) {
      clearTimeoutFn(retryTimer)
      retryTimer = null
    }
  }

  function clearConnectedTimer(): void {
    if (connectedTimer !== null) {
      clearTimeoutFn(connectedTimer)
      connectedTimer = null
    }
  }

  function armConnectedTimer(): void {
    clearConnectedTimer()
    connectedTimer = setTimeoutFn(() => {
      connectedTimer = null
      if (closed) return
      // The stream is alive enough to hold the socket but never handshook (or died before
      // handshaking). Route through the normal error path so first-attempt hangs land in 'failed'
      // (badge shows Retry) and post-open hangs back off.
      log('connected timeout', { attempt, connectedTimeoutMs })
      handleError({ reason: 'error' })
    }, connectedTimeoutMs)
  }

  function start(): void {
    if (closed) return
    clearRetry()

    attempt += 1
    log('start', { attempt, url: opts.url })
    emitState('connecting', { attempt, reason: 'manual' })

    let instance: EventSource
    try {
      instance = new EventSourceCtor(opts.url)
    } catch (err) {
      log('EventSource ctor THREW', { err: String(err) })
      // The constructor itself threw synchronously (e.g. invalid
      // URL). Treat as a first-attempt fatal error.
      handleError(
        err instanceof Event
          ? { reason: 'non-recoverable', lastError: err }
          : { reason: 'non-recoverable', lastError: new Event('error') },
      )
      return
    }
    es = instance
    log('EventSource constructed', { readyState: instance.readyState })
    // Deadline for the server handshake. Without this, a stream
    // that never emits `connected` (rejected-but-200, hung proxy)
    // sits in 'connecting' forever.
    armConnectedTimer()

    instance.addEventListener(connectedEventName, (e: Event) => {
      // Server explicitly confirmed the stream is live. This is the "open for business" signal —
      // distinct from the raw TCP/HTTP `open` event which only means the headers came back OK.
      // We mark the connection as "ever open" (so a 4xx/5xx on the *next* attempt is still treated
      // as recoverable and goes through the backoff loop) but we DO NOT reset `attempt` here.
      // `attempt` tracks "how many start() calls have we made" — the backoff formula `2 ** (attempt
      // - 1)` depends on it monotonically increasing across retries.
      // Resetting it in `connected` would cause the first retry after a successful open to compute
      // `2 ** -1 = 0.5` of the base delay, halving the backoff and breaking the exponential
      // schedule.
      // The right place to reset `attempt` is `reconnect()` (a user-driven retry) and construction
      // (a fresh client).
      // NEW (sse-disconnect-diagnosis): also reset `stallFiredAt` so the next stall-to-error gap is
      // computed against the fresh connection, not the previous (possibly long-dead) one. Same
      // reasoning as `eventCount` — the counter is per-open-window, not per-client-lifetime.
      const me = e as MessageEvent
      const raw = typeof me.data === 'string' ? me.data : String(me.data ?? '')
      lastEventAt = now()
      lastEventKind = connectedEventName
      lastEventBytes = raw.length
      eventCount += 1
      hasBeenOpen = true
      clearConnectedTimer()
      stallFiredAt = null
      stallFiredAtReadiness = null
      log('connected', {
        sinceLastEventMs: -1,
        bytes: raw.length,
        eventCount,
        heartbeatCount,
        // NEW (sse-disconnect-diagnosis): include the time since the last close/reconnect so the
        // operator can see the duration of the gap. Useful for diagnosing "the app was closed for X
        // minutes — was the reconnect prompt?".
        sinceLastCloseMs: lastCloseAtMs !== null ? Math.round(now() - lastCloseAtMs) : null,
        sinceLastReconnectMs:
          lastReconnectAtMs !== null ? Math.round(now() - lastReconnectAtMs) : null,
      })
      emitState('open', { attempt, reason: 'manual' })
      // Arm the stall detector AFTER emitState so `state === 'open'`
      // is true. (resetStallDetector early-returns otherwise — bug
      // introduced by reordering.)
      resetStallDetector()
      // Throw-isolation: a throwing onConnected must never break the handshake — the stream is
      // already open and subsequent data events must still dispatch.
      // Previously this call sat outside the try below, so a throw skipped the onEvent passthrough
      // for this handshake (and surfaced as an uncaught exception).
      try {
        opts.onConnected?.()
      } catch (err) {
        console.error('[SseClient] onConnected subscriber threw:', err)
      }
      // Also pass through to onEvent so adapters that want the
      // payload (e.g. `createSseConnection` adds it to the message
      // stream with `type: 'connected'`) can read it.
      try {
        opts.onEvent(raw, connectedEventName)
      } catch (err) {
        console.error('[SseClient] onEvent subscriber threw on connected:', err)
      }
    })

    instance.addEventListener('message', (e: Event) => {
      const me = e as MessageEvent
      try {
        const raw = typeof me.data === 'string' ? me.data : String(me.data ?? '')
        const isHeartbeat = heartbeatData !== null && raw === heartbeatData
        const sinceLast = lastEventAt !== null ? now() - lastEventAt : -1
        lastEventAt = now()
        lastEventKind = isHeartbeat ? 'heartbeat' : 'message'
        lastEventBytes = raw.length
        if (isHeartbeat) {
          heartbeatCount += 1
        } else {
          eventCount += 1
        }
        log(isHeartbeat ? 'heartbeat' : 'message', {
          sinceLastEventMs: Math.round(sinceLast),
          eventCount,
          heartbeatCount,
          bytes: raw.length,
          preview: raw.slice(0, 80),
        })
        resetStallDetector()
        // Drop heartbeats before they reach the consumer. The backend sends `data: ping\n\n` as a
        // keepalive; in consumers that JSON-buffer incoming data (e.g. the queue-messages stream),
        // every heartbeat appends to the buffer and the buffer never drains (no `{`/`}`).
        // This is a generic SseClient concern — the heartbeat exists to keep the connection alive,
        // which is the SseClient's job, not the consumer's.
        if (isHeartbeat) {
          return
        }
        opts.onEvent(raw, 'message')
      } catch (err) {
        console.error('[SseClient] onEvent subscriber threw on message:', err)
      }
    })

    // Raw EventSource lifecycle hooks — separate from the SSE 'connected' named event above. Logged
    // so the dev console can distinguish a) the HTTP/TLS 'open' (200 + headers) from b) the SSE
    // 'connected' (protocol handshake) from c) 'error' (the browser fired onerror).
    // Without this, all three fire through a single onerror callback and we can't tell them apart.
    instance.addEventListener('open', () => {
      log('EventSource raw open', { readyState: instance.readyState })
    })
    instance.addEventListener('error', () => {
      const sinceLastEventMs = lastEventAt !== null ? Math.round(now() - lastEventAt) : -1
      // Coerce undefined → null so JSON.stringify doesn't strip the
      // key from the log payload. See the STALL DETECTED path for
      // the same dance with the reason inline.
      const networkOnline: boolean | null =
        typeof navigator === 'undefined'
          ? null
          : typeof navigator.onLine === 'boolean'
            ? navigator.onLine
            : null
      const stallToErrorMs = stallFiredAt !== null ? Math.round(now() - stallFiredAt) : null
      log('EventSource raw error', {
        readyState: instance.readyState,
        // readyState 0 = CONNECTING, 1 = OPEN, 2 = CLOSED. CLOSED
        // here is the smoking gun: the browser thinks the SSE
        // endpoint is gone.
        readyStateLabel: ['CONNECTING', 'OPEN', 'CLOSED'][instance.readyState] ?? 'UNKNOWN',
        // Time since the last received event — the most important diagnostic field. If this is
        // ~0ms, the connection died mid-stream. If it's ~5000ms, the heartbeat just stopped
        // arriving. If it's ~15000ms or larger, an idle/keep-alive timeout fired.
        sinceLastEventMs,
        lastEventKind,
        heartbeatCount,
        eventCount,
        // NEW (sse-disconnect-diagnosis): network state at error
        // time. `false` here is the smoking gun for "OS-level
        // network drop" — TCP socket is almost certainly dead.
        navigatorOnline: networkOnline,
        // NEW (sse-disconnect-diagnosis): if the stall detector already fired during this open
        // window, `stallToErrorMs` tells the operator "the desktop app saw this coming N seconds
        // before the browser did".
        // For the user's reported symptom (heartbeat stops → 19s later browser errors), this is
        // typically ~12s.
        wasStalledBefore: stallFiredAt !== null,
        stallToErrorMs,
        // NEW (sse-disconnect-diagnosis): tab visibility at error time. Browsers throttle
        // backgrounded tabs, so a hidden tab + silence is much less alarming than a visible tab +
        // silence.
        tabHiddenAtMs,
      })
    })

    // Register listeners for any additional named event types the consumer declared (e.g.
    // 'queue_message'). Each one is dispatched to `onEvent` with the event name as the type
    // argument, matching the contract documented on `onEvent` and on `createSseConnection`.
    // We register inside `start()` (not once, at construction) so the listeners are re-attached on
    // reconnect — the EventSource is rebuilt on every retry, so any listeners on the previous
    // instance are gone.
    for (const eventName of additionalEventTypes) {
      instance.addEventListener(eventName, (e: Event) => {
        const me = e as MessageEvent
        try {
          const raw = typeof me.data === 'string' ? me.data : String(me.data ?? '')
          opts.onEvent(raw, eventName)
        } catch (err) {
          console.error(`[SseClient] onEvent subscriber threw on ${eventName}:`, err)
        }
      })
    }

    instance.onerror = (e: Event) => {
      handleError({ reason: 'error', lastError: e })
    }
  }

  function handleError(info: { reason: SseStateInfo['reason']; lastError?: Event }): void {
    if (closed) return
    clearConnectedTimer()

    // Close the dead EventSource so it cannot fire onerror again. Browsers fire onerror both on the
    // initial error AND on every internal retry attempt — we want exactly one error → one attempt
    // counter increment.
    if (es) {
      log('es.close() before handleError path', { attempt, infoReason: info.reason })
      try {
        es.close()
      } catch {
        // Some polyfills throw on close; ignore.
      }
      es = null
    }

    // First-attempt failure (4xx/5xx, DNS error, etc.) is NOT recoverable by retrying. The server
    // actively rejected us (or the URL is wrong). Going into a backoff loop here would just hammer
    // the server.
    log('handleError branch', { hasBeenOpen, attempt, infoReason: info.reason })
    if (!hasBeenOpen) {
      // NEW (sse-disconnect-diagnosis): fire the comprehensive diagnosis log on the terminal
      // 'failed' path too, so the operator sees one log line answering "why did the very first
      // attempt fail?". Uses reason 'non-recoverable' so downstream tooling can branch on it.
      logDisconnectDiagnosis(info.reason === 'non-recoverable' ? 'non-recoverable' : 'error-event')
      emitState('failed', {
        attempt,
        lastError: info.lastError,
        reason: info.reason === 'non-recoverable' ? 'non-recoverable' : 'error',
      })
      return
    }

    // We've been connected before, so a transient error is
    // worth retrying. Bump the attempt counter (already done in
    // start()) and decide whether to schedule or to give up.
    if (attempt > maxAttempts) {
      logDisconnectDiagnosis('error-event')
      emitState('failed', {
        attempt,
        lastError: info.lastError,
        reason: 'exhausted',
      })
      return
    }

    // NEW (sse-disconnect-diagnosis): fire the comprehensive diagnosis log BEFORE scheduleRetry so
    // the operator can read it as a single log entry (after 'EventSource raw error' and before
    // 'scheduleRetry set').
    // The log aggregates every signal we have so the operator can answer "was this the backend, the
    // frontend, or the network?" with one log line.
    logDisconnectDiagnosis('error-event')
    scheduleRetry({ reason: 'error' })
  }

  function scheduleRetry(reasonInfo: { reason: 'error' | 'stall' | 'visible' | 'online' }): void {
    if (closed) return
    clearRetry()

    // While the tab is hidden, do not burn battery or hit the server with retries. Wait for
    // visibilitychange → visible to fire `start()` instead. Tests that need to bypass this can set
    // `pauseWhenHidden: false` and pre-set `visibilityTarget.hidden = false` (jsdom default).
    if (pauseWhenHidden && visibilityTarget && visibilityTarget.hidden) {
      log('scheduleRetry paused (tab hidden)', { reason: reasonInfo.reason })
      emitState('reconnecting', {
        attempt,
        reason: 'error', // we are paused, but the cause was still the error
      })
      return
    }

    // Exponential backoff, full jitter (AWS pattern). exp = min(base * 2^(n-1), max) jitter = 0.5 +
    // 0.5 * random() // range [0.5, 1.0) delay = exp * jitter With base=1s, max=30s, attempt=1,
    // random=0.5: exp = 1000, jitter = 0.75, delay = 750 ms
    const exp = Math.min(baseDelayMs * 2 ** (attempt - 1), maxDelayMs)
    const jitter = 0.5 + 0.5 * random()
    const delay = exp * jitter

    log('scheduleRetry set', { attempt, delayMs: Math.round(delay), reason: reasonInfo.reason })
    emitState('reconnecting', {
      attempt,
      nextDelayMs: delay,
      reason: reasonInfo.reason,
    })
    retryTimer = setTimeoutFn(() => {
      log('retryTimer fired', { attempt })
      retryTimer = null
      start()
    }, delay)
  }

  // ── DOM listeners ─────────────────────────────────────────────────────
  // Only attach when the target is available. In tests, callers
  // can pass mock targets or set `pauseWhenHidden: false`.

  function onVisibilityChange(): void {
    if (closed) return
    if (!visibilityTarget) return
    if (visibilityTarget.hidden) {
      // NEW (sse-disconnect-diagnosis): track when the tab became hidden.
      // Surfaced in every diagnostic log so the operator can rule out "browser paused the
      // connection because the user backgrounded the tab" — a common cause of EventSource silence
      // that is NOT a real disconnect.
      tabHiddenAtMs = now()
      log('tab hidden', { atMs: Math.round(tabHiddenAtMs) })
      return
    }
    // We just became visible. If we were waiting to retry, do it
    // now.
    log('tab visible', {
      wasHiddenForMs: tabHiddenAtMs !== null ? Math.round(now() - tabHiddenAtMs) : null,
    })
    tabHiddenAtMs = null
    if (state === 'reconnecting') {
      clearRetry()
      // Fast-path on visibility: open immediately, do not wait
      // for the timer. Mark the reason so logs / UI can show
      // "resumed on visibility" if they want to.
      emitState('reconnecting', { attempt, reason: 'visible' })
      start()
    }
  }

  function onOnline(): void {
    if (closed) return
    // NEW (sse-disconnect-diagnosis): track network restoration.
    // Surfaced in the next diagnostic log so the operator can
    // correlate "network came back" with subsequent reconnects.
    const wasOfflineForMs =
      navigatorOfflineAtMs !== null ? Math.round(now() - navigatorOfflineAtMs) : null
    navigatorOfflineAtMs = null
    log('network online', { wasOfflineForMs })
    // Same fast-path: if we were in `reconnecting` because the
    // network died, retry immediately on `online`.
    if (state === 'reconnecting') {
      clearRetry()
      emitState('reconnecting', { attempt, reason: 'online' })
      start()
    }
  }

  // NEW (sse-disconnect-diagnosis): 'offline' listener. Tracks when the browser reported the
  // network as down. Surfaced in every diagnostic log as `navigatorOfflineAtMs` (and surfaced
  // inline as `navigatorOnline: false` for direct read).
  function onOffline(): void {
    if (closed) return
    navigatorOfflineAtMs = now()
    log('network offline', { atMs: Math.round(navigatorOfflineAtMs) })
  }

  function onPageHide(): void {
    // `pagehide` / `beforeunload` are the "user is leaving the page" signal (refresh, tab close,
    // navigation). The unload handler MUST be synchronous — the browser will not await a Promise.
    // Just call `teardown()` and let the browser close the socket.
    // Without this, the SSE connection lingers in the network panel as "open" / "pending" and the
    // server does not know the client is gone until the server-side timeout fires.
    // Track the close reason + caller BEFORE teardown so the next log line ("state closed {reason:
    // manual}") and any in-flight DISCONNECT DIAGNOSIS log both know who asked.
    lastCloseReason = 'page-unload'
    _lastCloseCaller = 'pagehide|beforeunload'
    lastCloseAtMs = now()
    log('close() called', { reason: 'page-unload', caller: 'pagehide|beforeunload' })
    teardown()
  }

  if (visibilityTarget && typeof visibilityTarget.addEventListener === 'function') {
    visibilityTarget.addEventListener('visibilitychange', onVisibilityChange)
  }
  if (reconnectOnOnline && onlineTarget && typeof onlineTarget.addEventListener === 'function') {
    onlineTarget.addEventListener('online', onOnline)
    // NEW (sse-disconnect-diagnosis): also listen for 'offline' so we can attribute silence to a
    // network drop. The browser fires 'offline' on `navigator.onLine === false`.
    // Without this listener the diagnostic log would only see `navigatorOnline: false` at error
    // time — by then the browser has already started its own internal reconnect, which masks the
    // cause.
    onlineTarget.addEventListener('offline', onOffline)
  }
  if (closeOnUnload && unloadTarget && typeof unloadTarget.addEventListener === 'function') {
    unloadTarget.addEventListener('pagehide', onPageHide)
    unloadTarget.addEventListener('beforeunload', onPageHide)
  }

  // Wire the optional `opts.onStateChange` into the same subscriber set the `.onStateChange(cb)`
  // method uses. This way the two entry points are equivalent and a throwing opts.onStateChange is
  // caught by the same try/catch in `emitState` (it cannot break the connection).
  if (opts.onStateChange) {
    subscribers.add(opts.onStateChange)
  }

  // ── Kick off the first attempt ──────────────────────────────────────── We do this AFTER the
  // listeners are attached so a synchronous success / failure does not race the listener
  // registration.
  // Defer the start() call to the next macrotask (setTimeout 0) so the SseClient constructor
  // returns immediately without initiating the HTTP request synchronously.
  // This makes the SSE setup "fully async" — callers (e.g. `kanbanSseStore.initKanbanSse`) can be
  // `await`ed, and other in-flight fetch API calls (workspace data, chat history, etc.) can proceed
  // before the EventSource connection is established.
  // Without this defer, the SSE HTTP request would race with the same-tick fetches and saturate the
  // browser's per-origin connection pool (6 in HTTP/1.1).
  // The `onError` synchronous-constructor-throw path still works: the throw happens inside
  // `start()` after the deferral, so the first-attempt fatal error is reported on the next tick
  // (slightly later than before, but still before any reconnect could fire).
  setTimeout(start, 0)

  // Shared cleanup path. Called by both the public `.close()` method and the `pagehide` /
  // `beforeunload` listener. Idempotent (the `closed` guard at the top makes repeat calls a no-op),
  // so it is safe to call from a stale unload handler after `.close()` has already been invoked.
  function teardown(): void {
    if (closed) return
    closed = true
    clearRetry()
    clearConnectedTimer()
    if (es) {
      try {
        es.close()
      } catch {
        // ignore
      }
      es = null
    }
    if (visibilityTarget && typeof visibilityTarget.removeEventListener === 'function') {
      visibilityTarget.removeEventListener('visibilitychange', onVisibilityChange)
    }
    if (
      reconnectOnOnline &&
      onlineTarget &&
      typeof onlineTarget.removeEventListener === 'function'
    ) {
      onlineTarget.removeEventListener('online', onOnline)
    }
    if (onlineTarget && typeof onlineTarget.removeEventListener === 'function') {
      onlineTarget.removeEventListener('offline', onOffline)
    }
    if (closeOnUnload && unloadTarget && typeof unloadTarget.removeEventListener === 'function') {
      unloadTarget.removeEventListener('pagehide', onPageHide)
      unloadTarget.removeEventListener('beforeunload', onPageHide)
    }
    emitState('closed', { attempt, reason: 'manual' })
    subscribers.clear()
  }

  return {
    /**
     * Close the connection. Terminal — no further state changes, no
     * further retries, all listeners removed. Safe to call multiple
     * times.
     *
     * @param reason Optional human-readable string identifying the
     * call site. Surfaced in every subsequent diagnostic log
     * (STALL DETECTED, DISCONNECT DIAGNOSIS) so the operator can
     * answer "who closed this connection?" by reading the console.
     * Defaults to `'unspecified'` when omitted.
     */
    close(reason?: string): void {
      const r = reason ?? 'unspecified'
      const caller = getCallerStack()
      // Track so the next STALL DETECTED or DISCONNECT DIAGNOSIS can
      // answer "did user code just close this?".
      lastCloseReason = r
      _lastCloseCaller = caller
      lastCloseAtMs = now()
      log('close() called', { reason: r, caller })
      teardown()
    },

    /**
     * Force a reconnect attempt right now. Resets the attempt
     * counter to 0. If the connection is currently `open`, the
     * existing `EventSource` is closed and a new one is opened.
     * Intended for a user-driven "Retry" button on the `failed`
     * badge.
     *
     * @param reason Optional human-readable string identifying the
     * call site. Surfaced in every subsequent diagnostic log so
     * the operator can correlate a manual reconnect with any
     * subsequent stall/error.
     */
    reconnect(reason?: string): void {
      if (closed) return
      const r = reason ?? 'unspecified'
      const caller = getCallerStack()
      lastReconnectReason = r
      _lastReconnectCaller = caller
      lastReconnectAtMs = now()
      log('reconnect() called', { reason: r, caller, attempt })
      if (es) {
        try {
          es.close()
        } catch {
          // ignore
        }
        es = null
      }
      clearRetry()
      attempt = 0
      hasBeenOpen = false
      start()
    },

    getState(): SseState {
      return state
    },

    onStateChange(cb: (s: SseState, info: SseStateInfo) => void): () => void {
      subscribers.add(cb)
      return () => {
        subscribers.delete(cb)
      }
    },
  }
}

// Module-level helper: grab up to 3 caller frames from the JS stack. Used by SseClient.close() and
// .reconnect() so the operator can see "which component asked for this disconnect?". Strips leading
// 'at ' prefixes (V8 convention) and discards empty lines.
// Returns '(no stack)' when the runtime doesn't expose Error.stack (some embedded JS engines).
// Frame count is bounded so a deep recursion doesn't blow up the log payload.
function getCallerStack(): string {
  const stack = new Error('sseClient::captureCaller').stack
  if (!stack) return '(no stack)'
  return (
    stack
      .split('\n')
      .slice(2, 5)
      .map((line) => line.trim().replace(/^at\s+/, ''))
      .filter((line) => line.length > 0)
      .join(' | ') || '(empty stack)'
  )
}
