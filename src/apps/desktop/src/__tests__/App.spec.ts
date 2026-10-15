import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest'

import { mount } from '@vue/test-utils'
import { createApp, type App as VueApp, nextTick } from 'vue'
import { setActivePinia, createPinia } from 'pinia'

import App from '../App.vue'
import * as api from '../api'
import {
  installSseBus,
  useSseBus,
  __resetSseBus,
  __dispatchSseBus,
  __setSseBusGlobalClient,
  __getSseBusGlobalClient,
} from '../helpers/sseBus'
import type { SseClient, SseState, SseStateInfo } from '../helpers/sseClient'
import { useTabsStore } from '../stores/tabs'
import { makeLocalStorageStub } from './helpers'

/** Test-only stub SseClient. Mirrors the helper in `sseBus.spec.ts` (kept inline rather than shared
 * to avoid coupling between the two spec files). */
/** Tracks state-listener callbacks on a non-public `__stateListeners` array so `emitStubState` can
 * fan out a transition to all subscribers — the production `SseClient` keeps the listener list in a
 * closure; tests reach it via `as any`. */
function makeStubClient(initial: SseState): SseClient {
   
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const stub: any = {
    close: vi.fn(),
    reconnect: vi.fn(),
    getState: () => stub._state,
    onStateChange: (cb: (s: SseState, info: SseStateInfo) => void) => {
      stub.__stateListeners.push(cb)
      return () => {
        const i = stub.__stateListeners.indexOf(cb)
        if (i >= 0) stub.__stateListeners.splice(i, 1)
      }
    },
  }
  stub._state = initial
  stub.__stateListeners = [] as Array<(s: SseState, info: SseStateInfo) => void>
  return stub as SseClient
}

 
function emitStubState(c: SseClient, s: SseState): void {
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const listeners = (c as any).__stateListeners as
    | Array<(s: SseState, info: SseStateInfo) => void>
    | undefined
  if (listeners) {
    for (const cb of listeners) cb(s, {} as SseStateInfo)
  }
}

describe('App', () => {
  let app: VueApp
  let stub: SseClient

  beforeEach(() => {
    __resetSseBus()
    // App.vue's onMounted calls `useNavigationStore()` (to wire the frontend-log-client context).
    // Without an active Pinia the call throws (`getActivePinia()` was called but there was no
    // active Pinia).
    // The existing AppLayout.* tests already use this `setActivePinia(createPinia())` pattern (see
    // AppLayout.chatview .spec.ts:112). One fresh Pinia per test keeps stores isolated.
    setActivePinia(createPinia())
    // jsdom 29 dropped localStorage from its default globals; the navigation store reads from
    // localStorage during setup (`loadSidebarCollapsed()`). Install a Map-backed stub for the
    // duration of each test. Same pattern as AppLayout.chatview.spec .ts:114.
    Object.defineProperty(globalThis, 'localStorage', {
      value: makeLocalStorageStub(),
      writable: true,
      configurable: true,
    })
    app = createApp({})
    // Install the bus BEFORE mounting App.vue so the singleton exists
    // when App.vue's `useSseBus().close()` runs in onUnmounted. Plan's
    // gotcha #6: `useSseBus` throws if not installed.
    installSseBus(app)
    // Replace the underlying global SseClient (otherwise it would call `new EventSource(...)` and
    // silently idle in jsdom) with a deterministic fake we drive through 'open' in the
    // reconnect-resync test.
    stub = makeStubClient('connecting')
    __setSseBusGlobalClient(stub)
    // fetchInitialWorkers hits the network — stub it so the tests
    // don't try to fetch. Tests that need to assert call counts use
    // `vi.mocked(api.getWorkers).mockClear()` after mount.
    vi.spyOn(api, 'getWorkers').mockResolvedValue({
      workers: [],
      count: 0,
    })
  })

  it('mounts without throwing', () => {
    // Smoke test: App.vue should mount cleanly. EventSource is polyfilled in src/__tests__/setup.ts
    // so the SSE connection opened in onMounted does not crash. The template is a <router-view />,
    // so we only assert that the component instance exists — no router is provided here.
    const wrapper = mount(App)
    expect(wrapper.exists()).toBe(true)
  })

  it("App.vue wires the tab title feed: a session rename lands on the tab", async () => {
    // Regression: the feed used to be subscribed from AppLayout's onMounted, which runs BEFORE
    // App.vue's (children mount first) — so `useSseBus()` threw and the subscription silently never
    // happened, leaving chat tabs labelled with the generic "Chat" after every auto-rename.
    const tabs = useTabsStore()
    const tab = tabs.open({ query: { view: 'chat', session: 'sess_w1' } })
    expect(tab.title).toBe('Chat')

    mount(App)
    __dispatchSseBus('session', {
      action: 'updated',
      id: 'sess_w1',
      name: 'renamed-live',
    } as unknown as api.SessionEvent)
    await nextTick()

    expect(tabs.tabs.find((t) => t.key === 'chat:sess_w1')?.title).toBe('renamed-live')
  })

  it("App.vue unsubscribes the tab title feed on unmount", async () => {
    const tabs = useTabsStore()
    tabs.open({ query: { view: 'chat', session: 'sess_w2' } })
    const wrapper = mount(App)
    wrapper.unmount()

    __dispatchSseBus('session', {
      action: 'updated',
      id: 'sess_w2',
      name: 'after-unmount',
    } as unknown as api.SessionEvent)
    await nextTick()

    expect(tabs.tabs.find((t) => t.key === 'chat:sess_w2')?.title).toBe('Chat')
  })

  it("App.vue subscribes to bus.on('worker'); handleWorkerEvent fires when the bus dispatches", async () => {
    const wrapper = mount(App)
    // Read the provided `processingState` ref. When `mount(App)` is
    // used (root mount with no outer app), provides go to the root
    // component instance under `vm.$.provides` (NOT `vm.$.appContext
    // .provides` — that's only for nested-app ancestors).
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const provides = (wrapper.vm as any).$.provides as Record<string, unknown>
    const processingState = provides['processingState'] as {
      value: Record<string, boolean>
    }
    expect(processingState).toBeDefined()

    // Dispatch a synthetic 'created' worker event for 'sess_w1'.
    __dispatchSseBus('worker', {
      action: 'created',
      id: 'w_1',
      session_id: 'sess_w1',
      working_directory: '/tmp',
      last_activity: 0,
      last_activity_description: '',
      created_at: '',
    } as unknown as api.WorkerEvent)
    await nextTick()
    expect(processingState.value['sess_w1']).toBe(true)

    // Dispatch a 'deleted' for the same session and verify removal.
    __dispatchSseBus('worker', {
      action: 'deleted',
      id: 'w_1',
      session_id: 'sess_w1',
      working_directory: '/tmp',
      last_activity: 0,
      last_activity_description: '',
      created_at: '',
    } as unknown as api.WorkerEvent)
    await nextTick()
    expect(processingState.value['sess_w1']).toBeUndefined()
  })

  it("App.vue calls fetchInitialWorkers when bus.state transitions to 'open' (reconnect-resync)", async () => {
    mount(App)
    // Clear any calls that may have happened during mount. The { immediate: true } watcher fires
    // synchronously during setup but the stub was 'connecting' at that point, so getWorkers should
    // not have been called yet — mockClear() is defensive.
    const getWorkersSpy = vi.mocked(api.getWorkers).mockClear()
    expect(getWorkersSpy).not.toHaveBeenCalled()

    // Flip the stub to 'open' — the watcher must call
    // fetchInitialWorkers in response.
    emitStubState(stub, 'open')
    // The watcher is async by default; drain a microtask.
    await nextTick()
    expect(getWorkersSpy).toHaveBeenCalled()
  })

  it('unmounting App.vue calls bus.close() on the bus singleton', () => {
    const wrapper = mount(App)
    // `bus.close()` should clear the singleton — verify by checking that a subsequent `useSseBus()`
    // throws.
    // We don't spy on any specific SseClient's close() because App.vue's onUnmounted delegates to
    // `useSseBus().close()`, which delegates to the bus's internal global client (the
    // closure-scoped one from installSseBus).
    // Spying on it would couple the test to bus internals; checking the singleton-cleared invariant
    // is a stronger behavioral contract anyway.
    expect(() => useSseBus()).not.toThrow()

    wrapper.unmount()

    // bus.close() was called → singleton is null → useSseBus() throws.
    expect(() => useSseBus()).toThrow(/installSseBus/)
    // The test handle also goes to null.
    expect(__getSseBusGlobalClient()).toBeNull()
  })

  describe('no app-level zoom suppression (desktop-app only)', () => {
    // The desktop app uses the host webview's native page-zoom (Ctrl+wheel / multi-finger pinch).
    // The previous global wheel-zoom suppressor in App.vue was removed — letting the native
    // behaviour run.
    // The design canvas has its own `@wheel="handleCanvasWheel"` handler in `DesignView.vue` that
    // calls `preventDefault()` and performs cursor-anchored zoom on the canvas only.
    // These tests lock in the NEW contract: App.vue must NOT install any capture-phase wheel
    // listener that calls `preventDefault()`.
    // The host webview is now free to apply its native page-zoom on Ctrl+wheel / metaKey+wheel /
    // double-tap / pinch anywhere in the desktop app shell.
    // Shared wrapper — every test in this block mounts via this and unmounts in afterEach so
    // listeners from previous tests don't bleed into later ones.
    let wrapper: ReturnType<typeof mount> | null = null

    afterEach(() => {
      wrapper?.unmount()
      wrapper = null
    })

    function dispatchWheel(init: WheelEventInit): WheelEvent {
      // jsdom honours `cancelable: true` and reflects `defaultPrevented`
      // after `preventDefault()` is called. Dispatch on `window` so it
      // matches the target App.vue would have used.
      const event = new WheelEvent('wheel', { bubbles: true, cancelable: true, ...init })
      window.dispatchEvent(event)
      return event
    }

    it('Ctrl+wheel is NOT preventDefaulted by App.vue (host webview handles page-zoom)', () => {
      wrapper = mount(App)
      const event = dispatchWheel({ ctrlKey: true, deltaY: -100 })
      expect(event.defaultPrevented).toBe(false)
    })

    it('metaKey+wheel (mac trackpad pinch) is NOT preventDefaulted by App.vue', () => {
      wrapper = mount(App)
      const event = dispatchWheel({ metaKey: true, deltaY: 100 })
      expect(event.defaultPrevented).toBe(false)
    })

    it('plain wheel without modifier does NOT call preventDefault (normal scroll preserved)', () => {
      wrapper = mount(App)
      const event = dispatchWheel({ deltaY: 100 })
      expect(event.defaultPrevented).toBe(false)
    })

    it('Ctrl+wheel with shiftKey is NOT preventDefaulted by App.vue', () => {
      // DesignView treats shiftKey as a 4× speed multiplier for its
      // own zoom. Outside the canvas, the host webview's native
      // page-zoom should run freely.
      wrapper = mount(App)
      const event = dispatchWheel({ ctrlKey: true, shiftKey: true, deltaY: -100 })
      expect(event.defaultPrevented).toBe(false)
    })

    it('App.vue does NOT register a capture-phase wheel listener on mount', () => {
      // Spy on addEventListener BEFORE mounting so the spy captures
      // the registration (or in this case, the ABSENCE of it).
      const addSpy = vi.spyOn(window, 'addEventListener')

      wrapper = mount(App)

      const wheelAdditions = addSpy.mock.calls.filter((c) => c[0] === 'wheel')
      const captureWheelAdditions = wheelAdditions.filter((c) => {
        const opts = c[2]
        return (
          typeof opts === 'object' &&
          opts !== null &&
          (opts as AddEventListenerOptions).capture === true
        )
      })
      // App.vue's onMounted must NOT have installed a capture-phase wheel listener. (Other
      // listeners in the same test e.g. the SSE bus may register unrelated events — we only assert
      // on the capture-phase wheel case.)
      expect(captureWheelAdditions.length).toBe(0)

      addSpy.mockRestore()
    })
  })
})

// ────────────────────────────────────────────────────────────────────────
// workerActivity — the additive second provide key
// ────────────────────────────────────────────────────────────────────────

describe('App workerActivity', () => {
  let app: VueApp
  let stub: SseClient

  /** Read a provided ref off a root-mounted App instance. */
  const readProvide = (wrapper: ReturnType<typeof mount>, key: string) => {
    // With `mount(App)` (root mount, no outer app) provides land on `vm.$.provides`, NOT
    // `vm.$.appContext.provides` — that is only for nested-app ancestors. eslint-disable-next-line
    // @typescript-eslint/no-explicit-any -- test-only reach into Vue internals.
    const provides = (wrapper.vm as any).$.provides as Record<string, unknown>
    return provides[key] as { value: unknown } | undefined
  }

  beforeEach(() => {
    __resetSseBus()
    setActivePinia(createPinia())
    Object.defineProperty(globalThis, 'localStorage', {
      value: makeLocalStorageStub(),
      writable: true,
      configurable: true,
    })
    app = createApp({})
    installSseBus(app)
    stub = makeStubClient('connecting')
    __setSseBusGlobalClient(stub)
    vi.spyOn(api, 'getWorkers').mockResolvedValue({ workers: [], count: 0 })
    // The worker ticker is a real interval; fake timers let the lifecycle
    // tests count it and advance it deterministically.
    vi.useFakeTimers()
  })

  afterEach(() => {
    vi.useRealTimers()
  })

  it('provides workerActivity alongside processingState', () => {
    const wrapper = mount(App)
    // The boolean map is untouched — eight components still read it.
    expect(readProvide(wrapper, 'processingState')).toBeDefined()
    expect(readProvide(wrapper, 'workerActivity')).toBeDefined()
  })

  it('a worker_created event seeds startedAt and lastActivityAt', async () => {
    const wrapper = mount(App)
    const activity = readProvide(wrapper, 'workerActivity') as {
      value: Record<string, { startedAt: number; lastActivityAt: number }>
    }

    __dispatchSseBus('worker', {
      action: 'created',
      id: 'w_1',
      session_id: 'sess_a',
      working_directory: '/tmp',
      // SSE carries a bare unix-SECONDS number.
      last_activity: 1_800_000_000,
      last_activity_description: '',
      created_at: '2026-10-09 12:00:00',
    } as unknown as api.WorkerEvent)
    await nextTick()

    const row = activity.value['sess_a']
    expect(row).toBeDefined()
    // Seconds normalised to milliseconds.
    expect(row?.lastActivityAt).toBe(1_800_000_000_000)
    expect(row?.startedAt).toBe(Date.parse('2026-10-09T12:00:00Z'))
  })

  it('a worker_updated event moves the heartbeat but NOT the start time', async () => {
    const wrapper = mount(App)
    const activity = readProvide(wrapper, 'workerActivity') as {
      value: Record<string, { startedAt: number; lastActivityAt: number }>
    }

    __dispatchSseBus('worker', {
      action: 'created',
      id: 'w_1',
      session_id: 'sess_b',
      working_directory: '/tmp',
      last_activity: 1_800_000_000,
      last_activity_description: '',
      created_at: '2026-10-09 12:00:00',
    } as unknown as api.WorkerEvent)
    await nextTick()
    const startedAt = activity.value['sess_b']?.startedAt

    // A heartbeat must not reset the elapsed clock to zero.
    __dispatchSseBus('worker', {
      action: 'updated',
      id: 'w_1',
      session_id: 'sess_b',
      working_directory: '/tmp',
      last_activity: 1_800_000_060,
      last_activity_description: 'Tool call: bash',
      created_at: '',
    } as unknown as api.WorkerEvent)
    await nextTick()

    expect(activity.value['sess_b']?.startedAt).toBe(startedAt)
    expect(activity.value['sess_b']?.lastActivityAt).toBe(1_800_000_060_000)
  })

  it('a worker_deleted event clears the activity entry', async () => {
    const wrapper = mount(App)
    const activity = readProvide(wrapper, 'workerActivity') as {
      value: Record<string, unknown>
    }

    __dispatchSseBus('worker', {
      action: 'created',
      id: 'w_1',
      session_id: 'sess_c',
      working_directory: '/tmp',
      last_activity: 1_800_000_000,
      last_activity_description: '',
      created_at: '2026-10-09 12:00:00',
    } as unknown as api.WorkerEvent)
    await nextTick()
    expect(activity.value['sess_c']).toBeDefined()

    __dispatchSseBus('worker', {
      action: 'deleted',
      id: 'w_1',
      session_id: 'sess_c',
      working_directory: '/tmp',
      last_activity: 0,
      last_activity_description: '',
      created_at: '',
    } as unknown as api.WorkerEvent)
    await nextTick()

    expect(activity.value['sess_c']).toBeUndefined()
  })

  it('starts the shared ticker when a worker appears and stops it when the last one goes', async () => {
    const wrapper = mount(App)
    // No worker yet → no interval anywhere in the app.
    expect(vi.getTimerCount()).toBe(0)

    __dispatchSseBus('worker', {
      action: 'created',
      id: 'w_1',
      session_id: 'sess_t',
      working_directory: '/tmp',
      last_activity: 1_800_000_000,
      last_activity_description: '',
      created_at: '2026-10-09 12:00:00',
    } as unknown as api.WorkerEvent)
    await nextTick()
    expect(vi.getTimerCount()).toBe(1)

    __dispatchSseBus('worker', {
      action: 'deleted',
      id: 'w_1',
      session_id: 'sess_t',
      working_directory: '/tmp',
      last_activity: 0,
      last_activity_description: '',
      created_at: '',
    } as unknown as api.WorkerEvent)
    await nextTick()
    // The last worker leaving must release the timer, not leave it idling.
    expect(vi.getTimerCount()).toBe(0)
    wrapper.unmount()
  })

  it('the shared ticker advances workerNow so chips count without polling', async () => {
    const wrapper = mount(App)
    const now = readProvide(wrapper, 'workerNow') as { value: number }

    __dispatchSseBus('worker', {
      action: 'created',
      id: 'w_1',
      session_id: 'sess_t2',
      working_directory: '/tmp',
      last_activity: 1_800_000_000,
      last_activity_description: '',
      created_at: '2026-10-09 12:00:00',
    } as unknown as api.WorkerEvent)
    await nextTick()

    const before = now.value
    vi.advanceTimersByTime(3_000)
    await nextTick()
    expect(now.value).toBeGreaterThan(before)
    wrapper.unmount()
  })

  it('the bootstrap refetch normalises the REST string shape of last_activity', async () => {
    // The REST wire types `last_activity` as a numeric STRING (every Zig
    // `Row.values` entry is a `[]u8`), while the SSE event sends a bare
    // number. Both must land as milliseconds.
    vi.mocked(api.getWorkers).mockResolvedValue({
      workers: [
        {
          id: 'w_rest',
          session_id: 'sess_rest',
          working_directory: '/tmp',
          last_activity: '1800000000',
          last_activity_description: 'Tool call: read_file',
          created_at: '2026-10-09 11:55:00',
          status: 'running',
          is_running: true,
          queue_count: 0,
        },
      ],
      count: 1,
    })

    const wrapper = mount(App)
    const activity = readProvide(wrapper, 'workerActivity') as {
      value: Record<string, { startedAt: number; lastActivityAt: number; description: string }>
    }

    // Drive the reconnect path that triggers fetchInitialWorkers.
    emitStubState(stub, 'open')
    await vi.waitFor(() => expect(activity.value['sess_rest']).toBeDefined())

    expect(activity.value['sess_rest']?.lastActivityAt).toBe(1_800_000_000_000)
    expect(activity.value['sess_rest']?.startedAt).toBe(Date.parse('2026-10-09T11:55:00Z'))
    expect(activity.value['sess_rest']?.description).toBe('Tool call: read_file')
  })
})
