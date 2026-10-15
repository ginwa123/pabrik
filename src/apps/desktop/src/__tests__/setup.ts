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

// jsdom does not implement `Element.prototype.scrollTo`. VirtualScroller.vue
// calls `containerRef.value.scrollTo(...)` in scrollToBottom, scrollToTop,
// and scrollToPosition — and ChatView's scrollToBottom is invoked from
// setTimeout / nextTick after the test's assertions have completed. Without
// this polyfill, those post-test async callbacks throw
// `TypeError: containerRef.value.scrollTo is not a function` and surface
// as unhandled rejections in the vitest output (vitest reports them as "caught unhandled errors"
// but `dangerouslyIgnoreUnhandledErrors` lets the suite exit 0 — the warnings still pollute CI logs
// and obscure real regressions).
// Implementation: parse the ScrollToOptions (or the two-arg form ScrollToOptions-like), and assign
// scrollTop + scrollLeft on the element.
// Tests that rely on `container.scrollTop === N` to assert scroll-restore behavior (see
// ChatView.scrollRestore.spec.ts) require a real assignment — a no-op polyfill would break those
// tests.
// `behavior: 'smooth'` is silently ignored (jsdom doesn't run animation frames; tests that need to
// assert on smooth-scroll easing should mock the component instead).
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
// Without this stub, store actions like `fetchKanbanColumns` and `loadFoldersForCwdPicker` produce
// unhandled rejections during test cleanup and vitest counts them as errors (exit 1) even when the
// test itself passes.
// The stub resolves with a generic 404 JSON response — every apiFetch call goes through `silent`
// checks before notifyError, so callers can observe the rejection normally; the stub just avoids
// the URL-parse TypeError that would otherwise escape the test.
// Replace global fetch with a stub that returns 404 for any URL. jsdom env may already provide its
// own fetch, so we always overwrite.
// Without this stub, unmocked api calls in tests hit `new URL(/api/...)` which fails to parse (no
// base URL set up) and produces unhandled rejections that vitest counts as errors (exit 1).
const stubFetch: typeof fetch = async () =>
  new Response(JSON.stringify({ error: 'fetch stubbed in test env' }), {
    status: 404,
    headers: { 'Content-Type': 'application/json' },
  })
;(globalThis as { fetch: typeof fetch }).fetch = stubFetch

// Install the SSE bus ONCE for the whole test file. Why this is in
// setup.ts (not in every test's beforeEach):
//
//   1. ChatView's onMounted calls connectSse() which calls useSseBus().
//      If a test mounts AppLayout (which renders ChatView) and the bus
//      is torn down between mount and connectSse, useSseBus throws.
//
//   2. ChatView also schedules scrollToBottom via setTimeout / nextTick
//      AFTER the test body has returned and afterEach has run. If the
//      bus was reset by afterEach, the post-test async chain throws
//      `useSseBus called before installSseBus` and surfaces as an
//      unhandled rejection in the vitest output.
//
// The pre-existing per-spec beforeEach that calls
// `__resetSseBus() → installSseBus(createApp({})) → __setSseBusGlobalClient(stub)`
// is still safe — installSseBus() is idempotent (`if (_instance) return
// _instance`), and our global installSseBus() here just re-asserts the
// invariant the spec expects.
//
// App.spec.ts's "unmounting App.vue calls bus.close() on the bus
// singleton" test still works because it relies on App.vue's own
// onUnmounted → useSseBus().close() (which nulls the singleton), not
// on __resetSseBus. The global install here doesn't prevent close()
// from nulling _instance.
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
