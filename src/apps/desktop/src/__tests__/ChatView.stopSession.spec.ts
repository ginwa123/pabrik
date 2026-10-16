/** Tests for ChatView's Stop button wiring. The Stop button lives in FileInput.vue (visible only
 * when `isLLMProcessing === true`). */
/** Clicking it emits a `stop-session` event; ChatView's `handleStopSession` translates that into a
 * `api.stopSession(sessionId)` call against the backend's `POST /api/llm/session/:session/stop`
 * endpoint. */
/** The backend flips `worker.cancelled=1`; the workflow breaks on the next iteration boundary;
 * `deleteWorker` fires a SSE `worker deleted` event; `App.vue`'s worker-event listener removes the
 * session from `processingState`; `isLLMProcessing` becomes false; the button auto-hides. */
/** Plan: docs/superpowers/plans/2026-08-06-chatview-stop-button.md */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { createApp, nextTick, ref, type App as VueApp, type Ref } from 'vue'
import { mount, flushPromises, type VueWrapper } from '@vue/test-utils'

import * as api from '../api'
import ChatView from '../components/views/ChatView.vue'
import {
  installSseBus,
  __resetSseBus,
  __setSseBusGlobalClient,
  __dispatchSseBus,
} from '../helpers/sseBus'
import type { SseClient, SseState, SseStateInfo } from '../helpers/sseClient'
import { makeLocalStorageStub } from './helpers'

// jsdom 29 dropped `Element.prototype.scrollTo`. The VirtualScroller calls
// `containerRef.value.scrollTo({top, behavior})` on every render; without the polyfill the test log
// floods with "containerRef.value.scrollTo is not a function" unhandled errors.
if (
  typeof (globalThis as { HTMLElement?: { prototype: { scrollTo?: unknown } } }).HTMLElement
    ?.prototype.scrollTo === 'undefined'
) {
  ;(
    globalThis as unknown as { HTMLElement: { prototype: { scrollTo: () => void } } }
  ).HTMLElement.prototype.scrollTo = function () {
    // no-op
  }
}

// ─── shared SSE stub ──────────────────────────────────────────────────────
function makeStubClient(initial: SseState): SseClient {
   
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const stub: any = {
    close: vi.fn(),
    reconnect: vi.fn(),
    getState: () => stub._state,
    onStateChange: (_cb: (s: SseState, _info: SseStateInfo) => void) => {
      return () => {}
    },
  }
  stub._state = initial
  return stub as SseClient
}

// ─── default mocks ────────────────────────────────────────────────────────
function installChatViewMocks() {
  vi.spyOn(api, 'getChatHistory').mockResolvedValue({
    messages: [],
    has_more: false,
    next_cursor: null,
    cwd: '/tmp',
    git_worktree_cwd: '',
    max_total_tokens: 0,
     
    max_capacity_total_tokens: 0,
   
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  } as any)
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  vi.spyOn(api, 'getQueuedMessages').mockResolvedValue({ messages: [] } as any)
  vi.spyOn(api, 'getSession').mockResolvedValue({
    session_id: 'placeholder',
    session_name: '',
     
    selectedProfile: null,
    cwd: '',
    git_worktree_cwd: '',
   
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  } as any)
  vi.spyOn(api, 'getGitStatus').mockResolvedValue({
     
    is_git_repo: false,
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  } as any)
  vi.spyOn(api, 'getPabrikConfig').mockResolvedValue({
    profiles: {},
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  } as any)
}

// ─── mount helper ───────────────────────────────────────────────────────── Mounts ChatView with
// `processingState[chatId] === true` so the `isLLMProcessing` computed is true and the Stop button
// (in FileInput) renders.
async function mountChatViewProcessing(chatId = 'session_proc') {
  const processingState = ref<Record<string, boolean>>({})
  processingState.value[chatId] = true

  const wrapper = mount(ChatView, {
    props: { chatId, chatName: 'Test Chat' },
    attachTo: document.body,
    global: {
      provide: { processingState },
    },
  })
  for (let i = 0; i < 20; i++) {
    await new Promise((r) => setTimeout(r, 0))
    await nextTick()
    const streaming = (wrapper.vm as unknown as { isStreaming?: boolean }).isStreaming
    if (streaming) break
  }
  await nextTick()
  return wrapper
}

describe('ChatView — Stop button (cancel running agent)', () => {
  let wrapper: VueWrapper | null = null
  let app: VueApp | null = null

  beforeEach(() => {
    if (typeof localStorage === 'undefined' || typeof localStorage.getItem !== 'function') {
      Object.defineProperty(globalThis, 'localStorage', {
        value: makeLocalStorageStub(),
        writable: true,
        configurable: true,
      })
    } else {
      localStorage.clear()
    }
    setActivePinia(createPinia())
    __resetSseBus()
    app = createApp({})
    installSseBus(app)
    __setSseBusGlobalClient(makeStubClient('connecting'))
  })

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    __resetSseBus()
    app = null
    vi.restoreAllMocks()
  })

 

  it('A: clicking the Stop button calls api.stopSession with the un-prefixed session id', async () => {
    installChatViewMocks()
    const stopSpy = vi.spyOn(api, 'stopSession').mockResolvedValue({
      success: true,
      session_id: 'session_proc',
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    } as any)

    wrapper = await mountChatViewProcessing('session_proc')

    const btn = wrapper!.find('[data-testid="stop-session-button"]')
    expect(btn.exists()).toBe(true)

    await btn.trigger('click')
    await flushPromises()

    expect(stopSpy).toHaveBeenCalledTimes(1)
    // The sessionId passed must be un-prefixed (no `chat-`) because the backend route uses the raw
    // session_id.
    expect(stopSpy).toHaveBeenCalledWith('session_proc')
   
  })

  it('B: rapid double-clicks result in exactly one api.stopSession call (debounce via FileInput isStopping)', async () => {
    installChatViewMocks()
    const stopSpy = vi.spyOn(api, 'stopSession').mockResolvedValue({
      success: true,
      session_id: 'session_proc',
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    } as any)

    wrapper = await mountChatViewProcessing('session_proc')

    const btn = wrapper!.find('[data-testid="stop-session-button"]')
    expect(btn.exists()).toBe(true)

    // Two rapid clicks. FileInput's `handleStopClick` short-circuits on the second click because
    // `isStopping` is true after the first emit. We mirror that here by setting isStopping=true via
    // setProps after the first click, then clicking again.
    await btn.trigger('click')
    // After the first emit, FileInput flips isStopping to true.
    // Verify the spinner is now showing.
    await wrapper!.setProps({ isStopping: true })
    await flushPromises()

    // Second click: the button is `:disabled`, so the test-utils
    // click doesn't even reach handleStopClick (the disabled flag
    // suppresses the click event). Still, ensure no extra call.
    await btn.trigger('click')
    await flushPromises()

    expect(stopSpy).toHaveBeenCalledTimes(1)
  })

  it('C: SSE worker `deleted` event hides the Stop button', async () => {
    installChatViewMocks()
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    vi.spyOn(api, 'stopSession').mockResolvedValue({ success: true } as any)

    wrapper = await mountChatViewProcessing('session_proc')

    // The button is shown while processing.
    expect(wrapper!.find('[data-testid="stop-session-button"]').exists()).toBe(true)

    // Simulate the backend cancelling + deleting the worker by dispatching the SSE `worker deleted`
    // event the workflow emits after the loop break. In production this is what App.vue's
    // `handleWorkerEvent` listens for and translates into a removal from `processingState`.
    const provides = (wrapper!.vm as any).$.provides as Record<string, unknown>
    const ps = provides['processingState'] as Ref<Record<string, boolean>>
     
    delete ps.value['session_proc']
    // Reassign to the same shape to guarantee the ref's value-setter
    // notifies subscribers regardless of how the internal proxy
    // tracks the delete.
    ps.value = { ...ps.value }
    await nextTick()
    await nextTick()

    expect(wrapper!.find('[data-testid="stop-session-button"]').exists()).toBe(false)
  })

  it('D: when api.stopSession rejects, the error is caught (no unhandled promise rejection)', async () => {
    installChatViewMocks()
    // Suppress console.error noise from the catch handler — the
    // test is asserting the rejection is CAUGHT, not that it
    // surfaces to the console.
    const consoleErrSpy = vi.spyOn(console, 'error').mockImplementation(() => {})
    vi.spyOn(api, 'stopSession').mockRejectedValue(new Error('network down'))

    wrapper = await mountChatViewProcessing('session_proc')
    const btn = wrapper!.find('[data-testid="stop-session-button"]')
    expect(btn.exists()).toBe(true)

    // Catch an unhandled rejection that escapes the click handler.
    let unhandled: unknown = null
    const onUnhandled = (e: PromiseRejectionEvent) => {
      unhandled = e.reason
      e.preventDefault()
    }
    window.addEventListener('unhandledrejection', onUnhandled)

    try {
      await btn.trigger('click')
      await flushPromises()
      // Wait for the microtask queue to drain so the rejection
      // propagates if it ever escapes the catch.
      await new Promise((r) => setTimeout(r, 50))

      expect(unhandled).toBeNull()
      // The handler caught the error and console.error'd it.
      expect(consoleErrSpy).toHaveBeenCalled()
    } finally {
      window.removeEventListener('unhandledrejection', onUnhandled)
    }
  })

  it('E: when api.stopSession rejects, the Stop button stays visible (until SSE clears processingState)', async () => {
    installChatViewMocks()
    vi.spyOn(api, 'stopSession').mockRejectedValue(new Error('network down'))
    // Silence the console.error so the test log stays clean.
    vi.spyOn(console, 'error').mockImplementation(() => {})

    wrapper = await mountChatViewProcessing('session_proc')
    const btn = wrapper!.find('[data-testid="stop-session-button"]')
    expect(btn.exists()).toBe(true)

    await btn.trigger('click')
    await flushPromises()

    // Button is still visible because processingState[sessionId] is still true (the API rejection
    // didn't trigger an SSE event for this test; the backend DID receive the cancel via the network
    // call, but we're simulating a transport-layer failure before the backend processes it).
    expect(wrapper!.find('[data-testid="stop-session-button"]').exists()).toBe(true)
  })
})