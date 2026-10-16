/** Vitest test setup. Runs before every test file. Polyfills browser APIs that jsdom does not
 * implement so module-level code in `src/api/index.ts` (which calls `new EventSource(...)` at
 * function entry) can be imported without crashing during unit tests. */
/** The stub is intentionally inert: it accepts a URL, exposes the same `addEventListener` /
 * `onmessage` / `close` surface, but never fires events. Tests that need real SSE behavior should
 * mock the api module instead of relying on this stub. */
class EventSourceStub {
  static readonly CONNECTING = 0
  static readonly OPEN = 1
  static readonly CLOSED = 2
  readonly readyState: number = EventSourceStub.CLOSED
  onopen: ((ev: Event) => void) | null = null
  onmessage: ((ev: MessageEvent) => void) | null = null
  onerror: ((ev: Event) => void) | null = null
  url: string = ''
  withCredentials: boolean = false

  constructor(url?: string) {
    this.url = url ?? ''
  }

  addEventListener(_type: string, _listener: EventListenerOrEventListenerObject): void {}
  removeEventListener(_type: string, _listener: EventListenerOrEventListenerObject): void {}
  dispatchEvent(_event: Event): boolean {
    return true
  }
  close(): void {}
}

if (typeof (globalThis as { EventSource?: unknown }).EventSource === 'undefined') {
  ;(globalThis as { EventSource: unknown }).EventSource = EventSourceStub
}

// jsdom does not ship ResizeObserver, but VirtualScroller.vue instantiates one in onMounted. The
// stub matches the EventSource polyfill above: inert, accepts the calls, never fires — tests that
// need real resize behavior should mock the component instead of relying on this stub.
if (typeof (globalThis as { ResizeObserver?: unknown }).ResizeObserver === 'undefined') {
  ;(globalThis as { ResizeObserver: unknown }).ResizeObserver = class {
    observe(): void {}
    unobserve(): void {}
    disconnect(): void {}
  }
}

// jsdom does not implement `Element.prototype.scrollTo`.
if (typeof Element !== 'undefined' && !Element.prototype.scrollTo) {
  Element.prototype.scrollTo = function scrollToPolyfill(
    this: Element,
    x?: number | ScrollToOptions,
    y?: number,
  ): void {
    const el = this as Element & { scrollTop?: number; scrollLeft?: number }
    let top: number | undefined
    let left: number | undefined
    if (typeof x === 'number') {
      top = x
      left = y ?? el.scrollLeft ?? 0
    } else if (x && typeof x === 'object') {
      top = x.top
      left = x.left
    }
    if (top !== undefined) el.scrollTop = top
    if (left !== undefined) el.scrollLeft = left
  }
}

// Stub global fetch so relative-URL API calls in tests don't throw "Failed to parse URL from
// /api/..." TypeErrors. Tests that need real API behavior should mock the api module (vi.spyOn(api,
// ...)) instead of letting this stub fire.
const stubFetch: typeof fetch = async () =>
  new Response(JSON.stringify({ error: 'fetch stubbed in test env' }), {
    status: 404,
    headers: { 'Content-Type': 'application/json' },
  })
;(globalThis as { fetch: typeof fetch }).fetch = stubFetch

// Install the SSE bus ONCE for the whole test file. Why this is in setup.ts (not in every test's
// beforeEach): 1. ChatView's onMounted calls connectSse() which calls useSseBus().
import { createApp } from 'vue'
import { installSseBus, __setSseBusGlobalClient } from '../helpers/sseBus'

installSseBus(createApp({}))
__setSseBusGlobalClient({
  // `state` is a private field on the real SseClient class; the cast is fine because the stub is
  // never type-checked against the interface contract (no test asserts on it directly).
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  state: 'open' as any,
  lastError: null,
  getState: () => 'open',
  isConnected: () => false,
  onEvent: () => {},
  onError: () => {},
  onStateChange: () => () => {},
  reconnect: () => {},
  close: () => {},
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
} as any)
