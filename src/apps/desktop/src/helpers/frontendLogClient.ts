/** frontendLogClient.ts Captures browser-side errors and ships them to the backend `POST /api/logs`
 * endpoint for the frontend-error-logs feature. */
export type LogLevel = 'error' | 'warn' | 'info' | 'debug'
export type LogKind =
  | 'window_error'
  | 'unhandled_rejection'
  | 'console_error'
  | 'console_warn'

export interface LogEvent {
  level: LogLevel
  kind: LogKind
  message: string
  stack?: string
  source?: string
  line?: number
  route_path?: string
  session_id?: string
}

export interface FrontendLogContext {
  getRoutePath: () => string | null
  getSessionId: () => string | null
}

export interface FrontendLogClientOptions {
  endpoint: string
  getContext: () => FrontendLogContext
  target?: Window
  fetchFn?: typeof fetch
  sendBeaconFn?: (url: string, data: BodyInit) => boolean
}

export interface FrontendLogClientHandle {
  close(): void
}

const MAX_QUEUE_SIZE = 50
const MAX_QUEUE_DROP = 25
const DEBOUNCE_MS = 250

// `Window` in the DOM lib does NOT expose `console` (it's a separate global). The install function
// accesses `target.console.*` to patch and restore it, so widen the local `target` type to include
// `console`. Zero runtime cost — pure compile-time widening.
type TargetWithConsole = Window & { console: Console }

export function installFrontendLogClient(
  opts: FrontendLogClientOptions,
): FrontendLogClientHandle {
  const target = (opts.target ?? window) as TargetWithConsole
  const fetchFn = opts.fetchFn ?? globalThis.fetch.bind(globalThis)
  const sendBeaconFn = opts.sendBeaconFn ?? target.navigator.sendBeacon.bind(target.navigator)

  const queue: LogEvent[] = []
  let debounceTimer: ReturnType<typeof setTimeout> | null = null
  let closed = false

  const originalError = target.console.error.bind(target.console)
  const originalWarn = target.console.warn.bind(target.console)

  function formatArgs(args: unknown[]): string {
    return args.map((a) =>
      typeof a === 'string'
        ? a
        : (() => {
            try {
              return JSON.stringify(a)
            } catch {
              return String(a)
            }
          })(),
    ).join(' ')
  }

  function enrichEvent(event: LogEvent): LogEvent {
    if (event.route_path || event.session_id) return event
    const ctx = opts.getContext()
    return {
      ...event,
      route_path: ctx.getRoutePath() ?? undefined,
      session_id: ctx.getSessionId() ?? undefined,
    }
  }

  function scheduleFlush(): void {
    if (debounceTimer !== null) clearTimeout(debounceTimer)
    debounceTimer = setTimeout(() => {
      debounceTimer = null
      void flush()
    }, DEBOUNCE_MS)
  }

  async function flush(): Promise<void> {
    if (closed || queue.length === 0) return
    const batch = queue.splice(0, queue.length)
    const enriched = batch.map(enrichEvent)
    try {
      const resp = await fetchFn(opts.endpoint, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ events: enriched }),
      })
      if (!resp.ok) {
        originalWarn('[frontendLog] POST returned non-2xx, dropping batch', resp.status)
      }
    } catch (err) {
      originalWarn('[frontendLog] POST failed, dropping batch', err)
    }
  }

  function beaconFlush(): void {
    if (closed || queue.length === 0) return
    const batch = queue.splice(0, queue.length)
    const enriched = batch.map(enrichEvent)
    const blob = new Blob([JSON.stringify({ events: enriched })], {
      type: 'application/json',
    })
    sendBeaconFn(opts.endpoint, blob)
  }

  function enqueue(event: LogEvent): void {
    if (closed) return
    if (queue.length >= MAX_QUEUE_SIZE) {
      queue.splice(0, MAX_QUEUE_DROP)
      enqueue({
        level: 'warn',
        kind: 'console_warn',
        message: '[frontendLog] queue overflow, dropped 25 events',
      })
    }
    queue.push(event)
    scheduleFlush()
  }

  const onError = (e: ErrorEvent): void => {
    const event: LogEvent = {
      level: 'error',
      kind: 'window_error',
      message: e.message || String(e.error || 'unknown error'),
    }
    if (e.error instanceof Error && e.error.stack) event.stack = e.error.stack
    if (e.filename) event.source = e.filename
    if (e.lineno) event.line = e.lineno
    enqueue(event)
  }

  const onUnhandledRejection = (e: PromiseRejectionEvent): void => {
    const reason = e.reason
    const event: LogEvent = {
      level: 'error',
      kind: 'unhandled_rejection',
      message:
        reason instanceof Error
          ? reason.message || String(reason)
          : String(reason),
    }
    if (reason instanceof Error && reason.stack) event.stack = reason.stack
    enqueue(event)
  }

  target.addEventListener('error', onError)
  target.addEventListener('unhandledrejection', onUnhandledRejection)
  target.addEventListener('pagehide', beaconFlush)
  target.addEventListener('beforeunload', beaconFlush)

  target.console.error = (...args: unknown[]): void => {
    enqueue({ level: 'error', kind: 'console_error', message: formatArgs(args) })
    originalError(...args)
  }
  target.console.warn = (...args: unknown[]): void => {
    enqueue({ level: 'warn', kind: 'console_warn', message: formatArgs(args) })
    originalWarn(...args)
  }

  return {
    close(): void {
      if (closed) return
      closed = true
      target.removeEventListener('error', onError)
      target.removeEventListener('unhandledrejection', onUnhandledRejection)
      target.removeEventListener('pagehide', beaconFlush)
      target.removeEventListener('beforeunload', beaconFlush)
      target.console.error = originalError
      target.console.warn = originalWarn
      if (debounceTimer !== null) {
        clearTimeout(debounceTimer)
        debounceTimer = null
      }
      queue.length = 0
    },
  }
}
