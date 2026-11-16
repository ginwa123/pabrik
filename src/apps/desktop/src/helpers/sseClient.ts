/** sseClient.ts Auto-reconnecting wrapper around the browser-native `EventSource`. */
export type SseState = 'connecting' | 'open' | 'reconnecting' | 'closed' | 'failed'

/** Side-channel info attached to every state emission. */
export interface SseStateInfo {
  /** 1 = first try, 2 = first retry, … */
  attempt: number
  /** Set on `reconnecting`. */
  nextDelayMs?: number
  /** Set on `reconnecting` / `failed`. The `error` event from the ES. */
  lastError?: Event
  /** What triggered this transition. */
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
  /** Event dispatcher. */
  onEvent: (raw: string, eventType: string) => void
  /** Additional named SSE event types to route to `onEvent`. */
  additionalEventTypes?: string[]
  /** Heartbeat data to drop silently from the default `'message'` event stream. */
  heartbeatData?: string | null
  /** Fires once, after the server's first `connected` named event. */
  onConnected?: () => void
  /** Fires on every state transition. */
  onStateChange?: (state: SseState, info: SseStateInfo) => void
  /** Initial backoff for the *first* retry. */
  baseDelayMs?: number
  /** Upper bound on the backoff delay (after jitter). */
  maxDelayMs?: number
  /** Hard cap on reconnect attempts. */
  maxAttempts?: number
  /** Random source for jitter. */
  random?: () => number
  /** Pause the retry timer while `document.hidden === true`. */
  pauseWhenHidden?: boolean
  /** Reconnect immediately on the browser's `online` event. */
  reconnectOnOnline?: boolean
  /** Override the `EventSource` constructor. */
  EventSourceCtor?: typeof EventSource
  /** Override the `visibilitychange` target. */
  visibilityTarget?: Pick<Document, 'addEventListener' | 'removeEventListener' | 'hidden'>
  /** Override the `online` event target. */
  onlineTarget?: Pick<Window, 'addEventListener' | 'removeEventListener'>
  /** Override `setTimeout` / `clearTimeout` for fake-timer tests. */
  setTimeoutFn?: typeof setTimeout
  clearTimeoutFn?: typeof clearTimeout
  /** Close the connection automatically on `pagehide` (modern, covers bfcache) and `beforeunload` (legacy fallback). */
  closeOnUnload?: boolean
  /** Override the `pagehide` / `beforeunload` event target. */
  unloadTarget?: Pick<Window, 'addEventListener' | 'removeEventListener'>
  /** The SSE event name that signals "the stream is live". */
  connectedEventName?: string
  /** Stall threshold in ms. */
  stallThresholdMs?: number
  /** When true (default), a stall triggers `es.close()` + `scheduleRetry({ reason: 'stall' })` instead of only logging. */
  stallRecovery?: boolean
  /** Max time in ms to wait for the server's `connected` handshake after (re)starting the EventSource before treating the stream as dead. */
  connectedTimeoutMs?: number
}

export interface SseClient {
  /** Close the connection. */
  close(reason?: string): void
  /** Force a reconnect attempt right now. */
  reconnect(reason?: string): void
  /** Synchronous read of the current state. */
  getState(): SseState
  /** Subscribe to state transitions. */
  onStateChange(cb: (s: SseState, info: SseStateInfo) => void): () => void
}

/** Create a self-managing SSE client with exponential backoff and full jitter. */
export function createSseClient(opts: SseClientOptions): SseClient {
  // ===================================================================== Diagnostic logger — DEEP v2 Tracks every received byte at millisecond resolution so we …
  const debugOn: boolean = (globalThis as { __sseDebug?: boolean }).__sseDebug !== false
  const t0: number = performance.now()
  // High-resolution clock for delta-time measurements. performance.now() is monotonic (immune to wall-clock adjustments) and gives sub-millisecond precision in …
  const now = (): number => performance.now() - t0
  const iso = (): string => new Date().toISOString()
  const fmtMs = (ms: number): string => (ms / 1000).toFixed(3) + 's'
  // navigator.connection is the NetworkInformation API.
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
  // Stall detector: while state='open', if no event arrives within `stallThresholdMs` of the previous one, emit a warning so the operator can see "data stopped 10s …
  const stallDetectorOn: boolean =
    (globalThis as { __sseStallDetector?: boolean }).__sseStallDetector !== false
  const stallThresholdMs: number = opts.stallThresholdMs ?? 30_000 // 30s — well above the ~15s backend heartbeat
  const stallRecovery: boolean = opts.stallRecovery ?? true
  let stallTimer: ReturnType<typeof setTimeout> | null = null
  // Connected-handshake timeout: armed in start(), cleared on the first `connected` event (or any terminal path).
  let connectedTimer: ReturnType<typeof setTimeout> | null = null
  // Set to `now()` the first time the stall detector fires during a given open window.
  let stallFiredAt: number | null = null
  // Readiness at the time the stall detector fired.
  let stallFiredAtReadiness: string | null = null
  // Tracks when the tab became hidden (and when it became visible again).
  let tabHiddenAtMs: number | null = null
  // Tracks when the browser last fired the `offline` event.
  let navigatorOfflineAtMs: number | null = null
  // Capture the stack frame at the time the consumer called `.close(reason?)` and `.reconnect(reason?)`.
  let lastCloseReason: string | null = null
  let _lastCloseCaller: string | null = null
  let lastCloseAtMs: number | null = null
  let lastReconnectReason: string | null = null
  let _lastReconnectCaller: string | null = null
  let lastReconnectAtMs: number | null = null
  // Capture the constructor's caller frame so we can answer "who instantiated this SseClient?" — useful when several components share the bus and you want to know …
  const constructedAtCaller = (() => {
    const stack = new Error('sseClient::captureCaller').stack
    if (!stack) return '(no stack)'
    // Skip the first 2 frames (Error ctor + our IIFE) and grab up to 3 caller frames.
    return stack
      .split('\n')
      .slice(2, 5)
      .map((line) => line.trim().replace(/^at\s+/, ''))
      .filter((line) => line.length > 0)
      .join(' | ')
  })()

  // Classify the cause of an SSE disconnect into one of five buckets.
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
    // User-code close is the strongest signal — if close() was called within the last few seconds, the disconnect is by definition intentional.
    if (sinceLastCloseMs !== null && sinceLastCloseMs < 5_000) {
      return 'user-code'
    }
    // Network reported offline — TCP is almost certainly dead.
    if (networkOnline === false) {
      return 'network'
    }
    // Tab hidden AND the stall started AFTER the hide transition — browser throttled the connection.
    if (hidden !== null && now() - hidden < sinceLastEventMs + 5_000) {
      return 'browser'
    }
    // readiness === OPEN during sustained silence → server stopped sending data while the socket was alive.
    if (readiness === 'OPEN' && sinceLastEventMs > 5_000) {
      return 'backend'
    }
    // User-code reconnect was called recently — the disconnect is a side effect of a manual reset, not a real outage.
    if (sinceLastReconnectMs !== null && sinceLastReconnectMs < 5_000) {
      return 'user-code'
    }
    return 'unknown'
  }

  // Render the suspect classification + the supporting signals into a single human-readable sentence.
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
      // `navigator.onLine` may be missing (jsdom without the polyfill, SSR without a Navigator) — fall back to a boolean rather than letting `undefined` propagate …
      const networkOnline: boolean | null =
        typeof navigator === 'undefined'
          ? null
          : typeof navigator.onLine === 'boolean'
            ? navigator.onLine
            : null
      // Mark the wall-clock instant the stall detector fired so the downstream 'error' listener can compute "stall-to-error ms" and the DISCONNECT DIAGNOSIS can show …
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
        // navigator.connection tells us what kind of network the browser thinks we're on.
        navConn: readNetworkInfo(),
        // Disconnect classification — answers "is this the backend's fault, the browser's fault, or the network's fault?" in a single field.
        suspect,
        navigatorOnline: networkOnline,
        tabHiddenAtMs,
        // `sinceLastUserActionMs` makes it easy to correlate this stall with a route change, a click, a navigation, etc. The operator can cross-reference the value with …
        sinceLastCloseMs: lastCloseAtMs !== null ? Math.round(now() - lastCloseAtMs) : null,
        sinceLastReconnectMs:
          lastReconnectAtMs !== null ? Math.round(now() - lastReconnectAtMs) : null,
        lastCloseReason,
        lastReconnectReason,
        constructedBy: constructedAtCaller,
        // `conclusion` is the operator's TL;DR — one sentence that tells them what we think happened.
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
      // Stall recovery (idle-freeze fix): the stream is silently dead (TCP open, zero bytes).
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

  // Fires from `handleError` (the 'onerror' path) and from `onPageHide` (the page-unload path) — but ONLY on the onerror path.
  function logDisconnectDiagnosis(reason: 'error-event' | 'page-unload' | 'non-recoverable'): void {
    const sinceLast = lastEventAt !== null ? now() - lastEventAt : -1
    // Use the readiness captured at stall-time if available — that's the smoking gun.
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
      // Why we're logging the diagnosis.
      reason,
      // EventSource lifecycle state at the moment of diagnosis.
      readiness,
      // Network state at diagnosis time.
      navigatorOnline: networkOnline,
      effectiveType: readNetworkInfo()?.effectiveType ?? null,
      // Visibility — `null` means the tab has been visible the whole session; a number means it became hidden that many ms ago.
      tabHiddenAtMs,
      // Time since the last received event. -1 = we never got one.
      sinceLastEventMs: Math.round(sinceLast),
      lastEventKind,
      lastEventBytes,
      // Heartbeats and named events counted separately so the operator can tell "we never got ANY data" from "we got heartbeats but no named events".
      heartbeatCount,
      eventCount,
      // Did the stall detector fire BEFORE the browser's onerror?
      wasStalledBefore: stallFiredAt !== null,
      stallToErrorMs: sinceStall,
      // Attempt counter — `attempt` was incremented by start() when the current EventSource was constructed.
      attempt,
      // Most recent user-code actions.
      sinceLastCloseMs,
      sinceLastReconnectMs,
      lastCloseReason,
      lastReconnectReason,
      // Where was this SseClient instantiated?
      constructedBy: constructedAtCaller,
      // Human-readable TL;DR.
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
  // Connected-handshake deadline (see the option doc).
  const connectedTimeoutMs: number = opts.connectedTimeoutMs ?? 15_000
  // Heartbeat data to silently drop from the default 'message' event.
  const heartbeatData: string | null =
    opts.heartbeatData === undefined ? 'ping' : opts.heartbeatData
  // Deduplicated list of custom named event types the consumer wants routed to `onEvent`.
  const reservedEventNames = new Set<string>(['connected', 'message'])
  const additionalEventTypes: string[] = (opts.additionalEventTypes ?? []).filter(
    (name) => !reservedEventNames.has(name),
  )
  // Cast is safe: in browsers EventSource is a global, in jsdom the setup.ts polyfill assigns it.
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
      // Clear the stall detector when leaving 'open' — otherwise its setTimeout keeps the timer count non-zero in tests and could fire a misleading STALL warning while …
      if (stallTimer !== null) {
        clearTimeoutFn(stallTimer)
        stallTimer = null
      }
      // 'open' is logged by the 'connected' event listener at the exact moment we receive the server handshake (more diagnostic value than logging every state …
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
        // A buggy subscriber must not poison the others or the connection.
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
      // The stream is alive enough to hold the socket but never handshook (or died before handshaking).
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
      // The constructor itself threw synchronously (e.g. invalid URL).
      handleError(
        err instanceof Event
          ? { reason: 'non-recoverable', lastError: err }
          : { reason: 'non-recoverable', lastError: new Event('error') },
      )
      return
    }
    es = instance
    log('EventSource constructed', { readyState: instance.readyState })
    // Deadline for the server handshake.
    armConnectedTimer()

    instance.addEventListener(connectedEventName, (e: Event) => {
      // Server explicitly confirmed the stream is live.
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
        // NEW (sse-disconnect-diagnosis): include the time since the last close/reconnect so the operator can see the duration of the gap.
        sinceLastCloseMs: lastCloseAtMs !== null ? Math.round(now() - lastCloseAtMs) : null,
        sinceLastReconnectMs:
          lastReconnectAtMs !== null ? Math.round(now() - lastReconnectAtMs) : null,
      })
      emitState('open', { attempt, reason: 'manual' })
      // Arm the stall detector AFTER emitState so `state === 'open'` is true.
      resetStallDetector()
      // Throw-isolation: a throwing onConnected must never break the handshake — the stream is already open and subsequent data events must still dispatch.
      try {
        opts.onConnected?.()
      } catch (err) {
        console.error('[SseClient] onConnected subscriber threw:', err)
      }
      // Also pass through to onEvent so adapters that want the payload (e.g.
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
        // Drop heartbeats before they reach the consumer.
        if (isHeartbeat) {
          return
        }
        opts.onEvent(raw, 'message')
      } catch (err) {
        console.error('[SseClient] onEvent subscriber threw on message:', err)
      }
    })

    // Raw EventSource lifecycle hooks — separate from the SSE 'connected' named event above.
    instance.addEventListener('open', () => {
      log('EventSource raw open', { readyState: instance.readyState })
    })
    instance.addEventListener('error', () => {
      const sinceLastEventMs = lastEventAt !== null ? Math.round(now() - lastEventAt) : -1
      // Coerce undefined → null so JSON.stringify doesn't strip the key from the log payload.
      const networkOnline: boolean | null =
        typeof navigator === 'undefined'
          ? null
          : typeof navigator.onLine === 'boolean'
            ? navigator.onLine
            : null
      const stallToErrorMs = stallFiredAt !== null ? Math.round(now() - stallFiredAt) : null
      log('EventSource raw error', {
        readyState: instance.readyState,
        // readyState 0 = CONNECTING, 1 = OPEN, 2 = CLOSED.
        readyStateLabel: ['CONNECTING', 'OPEN', 'CLOSED'][instance.readyState] ?? 'UNKNOWN',
        // Time since the last received event — the most important diagnostic field.
        sinceLastEventMs,
        lastEventKind,
        heartbeatCount,
        eventCount,
        // NEW (sse-disconnect-diagnosis): network state at error time.
        navigatorOnline: networkOnline,
        // NEW (sse-disconnect-diagnosis): if the stall detector already fired during this open window, `stallToErrorMs` tells the operator "the desktop app saw this …
        wasStalledBefore: stallFiredAt !== null,
        stallToErrorMs,
        // NEW (sse-disconnect-diagnosis): tab visibility at error time.
        tabHiddenAtMs,
      })
    })

    // Register listeners for any additional named event types the consumer declared (e.g.
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

    // Close the dead EventSource so it cannot fire onerror again.
    if (es) {
      log('es.close() before handleError path', { attempt, infoReason: info.reason })
      try {
        es.close()
      } catch {
        // Some polyfills throw on close; ignore.
      }
      es = null
    }

    // First-attempt failure (4xx/5xx, DNS error, etc.) is NOT recoverable by retrying.
    log('handleError branch', { hasBeenOpen, attempt, infoReason: info.reason })
    if (!hasBeenOpen) {
      // NEW (sse-disconnect-diagnosis): fire the comprehensive diagnosis log on the terminal 'failed' path too, so the operator sees one log line answering "why did …
      logDisconnectDiagnosis(info.reason === 'non-recoverable' ? 'non-recoverable' : 'error-event')
      emitState('failed', {
        attempt,
        lastError: info.lastError,
        reason: info.reason === 'non-recoverable' ? 'non-recoverable' : 'error',
      })
      return
    }

    // We've been connected before, so a transient error is worth retrying.
    if (attempt > maxAttempts) {
      logDisconnectDiagnosis('error-event')
      emitState('failed', {
        attempt,
        lastError: info.lastError,
        reason: 'exhausted',
      })
      return
    }

    // NEW (sse-disconnect-diagnosis): fire the comprehensive diagnosis log BEFORE scheduleRetry so the operator can read it as a single log entry (after 'EventSource …
    logDisconnectDiagnosis('error-event')
    scheduleRetry({ reason: 'error' })
  }

  function scheduleRetry(reasonInfo: { reason: 'error' | 'stall' | 'visible' | 'online' }): void {
    if (closed) return
    clearRetry()

    // While the tab is hidden, do not burn battery or hit the server with retries.
    if (pauseWhenHidden && visibilityTarget && visibilityTarget.hidden) {
      log('scheduleRetry paused (tab hidden)', { reason: reasonInfo.reason })
      emitState('reconnecting', {
        attempt,
        reason: 'error', // we are paused, but the cause was still the error
      })
      return
    }

    // Exponential backoff, full jitter (AWS pattern). exp = min(base * 2^(n-1), max) jitter = 0.5 + 0.5 * random() // range [0.5, 1.0) delay = exp * jitter With …
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
  function onVisibilityChange(): void {
    if (closed) return
    if (!visibilityTarget) return
    if (visibilityTarget.hidden) {
      // NEW (sse-disconnect-diagnosis): track when the tab became hidden.
      tabHiddenAtMs = now()
      log('tab hidden', { atMs: Math.round(tabHiddenAtMs) })
      return
    }
    // We just became visible.
    log('tab visible', {
      wasHiddenForMs: tabHiddenAtMs !== null ? Math.round(now() - tabHiddenAtMs) : null,
    })
    tabHiddenAtMs = null
    if (state === 'reconnecting') {
      clearRetry()
      // Fast-path on visibility: open immediately, do not wait for the timer.
      emitState('reconnecting', { attempt, reason: 'visible' })
      start()
    }
  }

  function onOnline(): void {
    if (closed) return
    // NEW (sse-disconnect-diagnosis): track network restoration.
    const wasOfflineForMs =
      navigatorOfflineAtMs !== null ? Math.round(now() - navigatorOfflineAtMs) : null
    navigatorOfflineAtMs = null
    log('network online', { wasOfflineForMs })
    // Same fast-path: if we were in `reconnecting` because the network died, retry immediately on `online`.
    if (state === 'reconnecting') {
      clearRetry()
      emitState('reconnecting', { attempt, reason: 'online' })
      start()
    }
  }

  // NEW (sse-disconnect-diagnosis): 'offline' listener.
  function onOffline(): void {
    if (closed) return
    navigatorOfflineAtMs = now()
    log('network offline', { atMs: Math.round(navigatorOfflineAtMs) })
  }

  function onPageHide(): void {
    // `pagehide` / `beforeunload` are the "user is leaving the page" signal (refresh, tab close, navigation).
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
    // NEW (sse-disconnect-diagnosis): also listen for 'offline' so we can attribute silence to a network drop.
    onlineTarget.addEventListener('offline', onOffline)
  }
  if (closeOnUnload && unloadTarget && typeof unloadTarget.addEventListener === 'function') {
    unloadTarget.addEventListener('pagehide', onPageHide)
    unloadTarget.addEventListener('beforeunload', onPageHide)
  }

  // Wire the optional `opts.onStateChange` into the same subscriber set the `.onStateChange(cb)` method uses.
  if (opts.onStateChange) {
    subscribers.add(opts.onStateChange)
  }

  // ── Kick off the first attempt ────────────────────────────────────────
  setTimeout(start, 0)

  // Shared cleanup path.
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
    /** Close the connection. */
    close(reason?: string): void {
      const r = reason ?? 'unspecified'
      const caller = getCallerStack()
      // Track so the next STALL DETECTED or DISCONNECT DIAGNOSIS can answer "did user code just close this?".
      lastCloseReason = r
      _lastCloseCaller = caller
      lastCloseAtMs = now()
      log('close() called', { reason: r, caller })
      teardown()
    },

    /** Force a reconnect attempt right now. */
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

// Module-level helper: grab up to 3 caller frames from the JS stack.
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
