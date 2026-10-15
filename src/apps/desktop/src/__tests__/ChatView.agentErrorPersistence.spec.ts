/**
 * Tests for the **persistence contract** of the agent-error card.
 *
 * The bug we're guarding against: ChatView used to hold
 * `agentError = ref<...>(null)` as a local component ref. Every time the
 * user clicked another session in the sidebar, AppLayout's
 * `:key="activeChatId"` forced a fresh ChatView mount, the local ref was
 * GC'd, and the user lost the most recent retry diagnostic until they
 * caused another error. The fix (Task 2 of
 * `docs/superpowers/plans/2026-08-29-chatview-agent-error-persistent.md`)
 * moves the slot into a Pinia store keyed by `session_id` so the card
 * survives a remount.
 *
 * These three tests exercise the EXACT user-visible scenarios that
 * prove the fix:
 *
 *   A — persistence across remount. Mount ChatView with chat-s1, fire an
 *       `is_error` `full` SSE event, assert the card renders. Unmount.
 *       Mount a fresh ChatView with the same chatId. Fire NO new events.
 *       Assert the card is STILL there. Pre-fix this failed: the
 *       remounted ChatView started with `agentError.value === null` and
 *       the card was gone.
 *
 *   B — auto-clear on recovery. Mount → fire `is_error` event → card
 *       appears. Fire a non-error renderable `full` event → card
 *       disappears (agent recovered). Unmount. Mount a fresh ChatView.
 *       Assert the card STAYS gone (the recovery clear is persistent
 *       too — the user's chat has a clean state even after a remount).
 *
 *   C — key isolation. Two ChatViews mounted simultaneously: chat-s1 and
 *       chat-s2. Fire an error for s1. Assert s1's wrapper shows the
 *       card and s2's wrapper does NOT. Fire an error for s2 with
 *       different content. Assert both wrappers show their respective
 *       errors independently (no cross-talk between sessions).
 *
 * Mounts a real ChatView with the standard SSE-bus harness pattern from
 * ChatView.stopSession.spec.ts / chatViewWorktree.spec.ts /
 * ChatView.updatePlan.spec.ts: `installSseBus` + `__setSseBusGlobalClient`
 * with a stub client + `__dispatchSseBus('llm', ...)` to inject events.
 *
 * The wait-for-`isStreaming === true` loop in `mountChatView` is the
 * contract that `connectSse()` has registered its bus listener — the
 * earliest observable signal that a subsequent `__dispatchSseBus('llm',
 * …)` call will reach the listener. Same loop as the sibling specs.
 */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { createApp, nextTick, type App as VueApp, type Ref, ref } from 'vue'
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

// jsdom 29 dropped `Element.prototype.scrollTo`; the VirtualScroller calls
// `containerRef.value.scrollTo({top, behavior})` on every render and would log
// "containerRef.value.scrollTo is not a function" without the polyfill.

// Mirrors chatViewWorktree.spec.ts:62-71 + ChatView.stopSession.spec.ts:38-47.
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

// ─── shared SSE stub ─────────────────────────────────────────────────────── Inert SseClient that
// satisfies the bus's interface (close / reconnect / getState / onStateChange) without opening a
// real EventSource.

// Same shape as ChatView.stopSession.spec.ts:50-63 and chatViewWorktree.spec.ts:82-95.
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

// ─── default mocks ───────────────────────────────────────────────────────── Wire up the api.*
// calls ChatView makes in onMounted (getChatHistory, getQueuedMessages, getSession, getGitStatus,
// getPabrikConfig).

// The fields don't matter for these tests — only the SSE handler branches we're exercising — but
// the calls themselves must resolve so onMounted's async chain doesn't hang the mount loop.
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
  vi.spyOn(api, 'getQueuedMessages').mockResolvedValue({ messages: [], count: 0 } as any)
  vi.spyOn(api, 'getSession').mockResolvedValue({
    sessionId: 'placeholder',
    sessionName: '',
    createdAt: '',
    agent: '',
    selectedProfile: '',
    cwd: '',
    git_worktree_cwd: '',
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
  } as any)
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  vi.spyOn(api, 'getGitStatus').mockResolvedValue({ is_git_repo: false } as any)
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  vi.spyOn(api, 'getPabrikConfig').mockResolvedValue({ profiles: {} } as any)
}

// ─── mount helper ──────────────────────────────────────────────────────────
// Mounts ChatView with `:chat-id="<chatId>"` and waits for the SSE bus
// listener to register (`isStreaming === true` is flipped at the end of
// `connectSse()` — ChatView.vue:2322 — after `bus.on('llm', ...)` has
// been called). Returns the wrapper. Each test owns its own wrapper;
// tests that need a "remount" call `wrapper.unmount()` and call this
// again — the store persists across mounts.
async function mountChatView(chatId: string, processingState: Ref<Record<string, boolean>>) {
  const wrapper = mount(ChatView, {
    props: { chatId, chatName: 'Test Chat' },
    attachTo: document.body,
    global: {
      provide: { processingState },
    },
  })
  for (let i = 0; i < 30; i++) {
    await new Promise((r) => setTimeout(r, 0))
    await nextTick()
    const streaming = (wrapper.vm as unknown as { isStreaming?: boolean }).isStreaming
    if (streaming) break
  }
  await nextTick()
  return wrapper
}

describe('ChatView agent-error card — persistence across remounts', () => {
  let wrapper: VueWrapper | null = null
  let app: VueApp | null = null
  let processingState: Ref<Record<string, boolean>> | null = null

  beforeEach(() => {
    // jsdom 29 in this project's Vitest does not provide localStorage;
    // navigation.ts reads it at store init so we stub a minimal in-memory
    // implementation. Same pattern as chatViewWorktree.spec.ts:194-206.
    if (typeof localStorage === 'undefined' || typeof localStorage.getItem !== 'function') {
      Object.defineProperty(globalThis, 'localStorage', {
        value: makeLocalStorageStub(),
        writable: true,
        configurable: true,
      })
    } else {
      localStorage.clear()
    }

    // ChatView reads useNavigationStore() in setup(); Pinia must be
    // active for any useXxxStore() call.
    setActivePinia(createPinia())

    // Install the bus BEFORE mounting so ChatView's `useSseBus()` in `connectSse()` finds an
    // installed bus. Replace the global client so we never touch jsdom's EventSource — the stub
    // satisfies the SseClient interface. We drive `llm` events via `__dispatchSseBus`.
    __resetSseBus()
    app = createApp({})
    installSseBus(app)
    __setSseBusGlobalClient(makeStubClient('open'))

    processingState = ref<Record<string, boolean>>({})
  })

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    __resetSseBus()
    app = null
    processingState = null
    vi.restoreAllMocks()
  })

  // ─────────────────────────────────────────────────────────────────────────
  // A — persistence across remount (the bug being fixed)
  // ─────────────────────────────────────────────────────────────────────────
  it('A: error card persists across ChatView remount for the same session', async () => {
    installChatViewMocks()

    // First mount: fire an `is_error` `full` event for session s1.
    wrapper = await mountChatView('chat-s1', processingState!)
    __dispatchSseBus('llm', {
      session_id: 's1',
      type: 'full',
      is_error: true,
      content:
        '[Retry 3/10] StreamInterrupted (callDynamicAgentNew). Retrying in 5000ms.\nServer said: connection reset',
      id: 'evt-1',
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
    } as any)
    await flushPromises()
    await nextTick()

    // Card must render after the first mount.
    expect(wrapper!.find('[data-testid="agent-error-card"]').exists()).toBe(true)

    // Remount: unmount the old ChatView (AppLayout's `:key="activeChatId"`
    // forces this on every sidebar click) and mount a fresh ChatView
    // for the SAME chatId. Fire NO new SSE events.
    wrapper.unmount()
    wrapper = await mountChatView('chat-s1', processingState!)
    await flushPromises()
    await nextTick()

    // The card must STILL be there — the Pinia store outlives the component, so the error
    // diagnostic survives the remount. Pre-fix this assertion failed because the local `agentError`
    // ref was GC'd between mounts.
    const card = wrapper.find('[data-testid="agent-error-card"]')
    expect(card.exists()).toBe(true)
    // The headline / detail parsed from the original content must
    // match — confirms the store's `setError(sessionId, content, id)`
    // round-trips the content verbatim into the second mount.
    expect(card.text()).toContain('StreamInterrupted')
    expect(card.text()).toContain('connection reset')
  })

  // ─────────────────────────────────────────────────────────────────────────
  // B — auto-clear on recovery persists across remount
  // ─────────────────────────────────────────────────────────────────────────
  it('B: a non-error full event clears the card, and the clear survives a remount', async () => {
    installChatViewMocks()

    wrapper = await mountChatView('chat-s1', processingState!)

    // Error fires → card appears.
    __dispatchSseBus('llm', {
      session_id: 's1',
      type: 'full',
      is_error: true,
      content: '[Retry 2/10] StreamInterrupted (callDynamicAgentNew). Retrying in 5000ms.',
      id: 'evt-err-1',
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
    } as any)
    await flushPromises()
    await nextTick()
    expect(wrapper.find('[data-testid="agent-error-card"]').exists()).toBe(true)

    // Recovery fires (non-error renderable full) → card disappears. Mirrors the
    // ChatView.vue:2155-2163 branch: any `full` event with `finish_reason` + at least one
    // renderable field triggers `agentErrorStore.clearForSession(sid)`.
    __dispatchSseBus('llm', {
      session_id: 's1',
      type: 'full',
      is_error: false,
      role: 'assistant',
      content: 'hi',
      finish_reason: 'stop',
      id: 'evt-recover-1',
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
    } as any)
    await flushPromises()
    await nextTick()
    expect(wrapper.find('[data-testid="agent-error-card"]').exists()).toBe(false)

    // Remount — the recovery clear must persist too. A fresh ChatView
    // for chat-s1 must NOT show a stale error card.
    wrapper.unmount()
    wrapper = await mountChatView('chat-s1', processingState!)
    await flushPromises()
    await nextTick()
    expect(wrapper.find('[data-testid="agent-error-card"]').exists()).toBe(false)
  })

  // ─────────────────────────────────────────────────────────────────────────
  // D — auto-clear on chunk_final run-end marker (2026-09-10 option 1)
  // ─────────────────────────────────────────────────────────────────────────
  it('D: a non-error chunk_final event clears the card, and the clear survives a remount', async () => {
    installChatViewMocks()

    wrapper = await mountChatView('chat-s1', processingState!)

    // Error fires → card appears.
    __dispatchSseBus('llm', {
      session_id: 's1',
      type: 'full',
      is_error: true,
      content: '[Retry 4/10] StreamInterrupted (callDynamicAgentNew). Retrying in 5000ms.',
      id: 'evt-err-chunk-final',
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
    } as any)
    await flushPromises()
    await nextTick()
    expect(wrapper.find('[data-testid="agent-error-card"]').exists()).toBe(true)

    // Run-end marker fires (non-error chunk_final, no finish_reason, no renderable payload
    // required) → card disappears.

    // This covers the stuck-card case where the terminal `full` lacks finish_reason / renderable
    // fields and skips the `full` clear gate — the token stream completing is itself proof of
    // recovery.
    __dispatchSseBus('llm', {
      session_id: 's1',
      type: 'chunk_final',
      total_tokens: 42,
      id: 'evt-chunk-final-1',
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
    } as any)
    await flushPromises()
    await nextTick()
    expect(wrapper.find('[data-testid="agent-error-card"]').exists()).toBe(false)

    // Remount — the chunk_final clear must persist too.
    wrapper.unmount()
    wrapper = await mountChatView('chat-s1', processingState!)
    await flushPromises()
    await nextTick()
    expect(wrapper.find('[data-testid="agent-error-card"]').exists()).toBe(false)
  })

  // ─────────────────────────────────────────────────────────────────────────
  // C — key isolation (two ChatViews simultaneously)
  // ─────────────────────────────────────────────────────────────────────────
  it('C: errors are isolated per session_id across simultaneous ChatViews', async () => {
    installChatViewMocks()

    // Mount TWO ChatViews in parallel. Each owns its own `processingState` map (separate `ref`
    // instances). The Pinia store is the shared state — both mounts read from / write to the same
    // `useAgentErrorStore()` instance keyed by session_id.
    const ps1 = ref<Record<string, boolean>>({})
    const ps2 = ref<Record<string, boolean>>({})

    const wrapperS1 = await mountChatView('chat-s1', ps1)
    const wrapperS2 = await mountChatView('chat-s2', ps2)
    // Use the FIRST wrapper as the `wrapper` slot so the afterEach
    // unmount cleans up; explicitly unmount the second one in a
    // finally block below to avoid leaving it mounted.
    wrapper = wrapperS1

    // Fire an error for s1 ONLY.
    __dispatchSseBus('llm', {
      session_id: 's1',
      type: 'full',
      is_error: true,
      content: '[Retry 1/10] StreamInterrupted (callDynamicAgentNew). Retrying in 5000ms.',
      id: 'evt-s1-err',
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
    } as any)
    await flushPromises()
    await nextTick()

    // s1 shows its card; s2 does NOT.
    expect(wrapperS1.find('[data-testid="agent-error-card"]').exists()).toBe(true)
    expect(wrapperS2.find('[data-testid="agent-error-card"]').exists()).toBe(false)

    // Fire a DIFFERENT error for s2 (different content so we can
    // assert each wrapper shows its OWN error and not the other's).
    __dispatchSseBus('llm', {
      session_id: 's2',
      type: 'full',
      is_error: true,
      content: '[Retry 2/10] OverloadedError (callDynamicAgentNew). Retrying in 10000ms.',
      id: 'evt-s2-err',
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
    } as any)
    await flushPromises()
    await nextTick()

    // Both wrappers now show their own errors independently — the
    // store key isolation guarantee. s1's card text is the s1
    // content; s2's card text is the s2 content. No cross-talk.
    const cardS1 = wrapperS1.find('[data-testid="agent-error-card"]')
    const cardS2 = wrapperS2.find('[data-testid="agent-error-card"]')
    expect(cardS1.exists()).toBe(true)
    expect(cardS2.exists()).toBe(true)
    expect(cardS1.text()).toContain('StreamInterrupted')
    expect(cardS1.text()).not.toContain('OverloadedError')
    expect(cardS2.text()).toContain('OverloadedError')
    expect(cardS2.text()).not.toContain('StreamInterrupted')

    // Cleanup the second wrapper explicitly so the afterEach doesn't
    // leak it (afterEach only knows about the `wrapper` slot).
    wrapperS2.unmount()
  })
})
