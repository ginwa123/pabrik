/**
 * ChatView's cached mount: what is on screen while the REMOTE half of the
 * transcript load is still in flight.
 *
 * Contract under test (ChatView.vue, `runHistoryLoadAttempt`):
 *
 *   - The load has two halves. The cache prime (`chatEngineDb.primeFromCache`,
 *     IndexedDB) is fast; the network half (`chatEngineDb.loadDelta` on a cache
 *     hit, `api.fetchChatHistoryEffect` on a cache miss) is slow — bound by
 *     `INITIAL_HISTORY_TIMEOUT_MS` (45 s) plus a retry schedule.
 *   - `isLoading` is cleared the instant the cached rows paint, so it cannot
 *     answer "is the transcript known yet". `isInitializing` is the readgate —
 *     the skeleton is up while the remote half is outstanding AND nothing
 *     renderable has painted.
 *   - So: a cached mount whose rows render shows the CACHED TRANSCRIPT with no
 *     skeleton (that is the point of painting the cache); a cold mount, and a
 *     cached mount whose rows do not render, keep the skeleton until the
 *     remote answer lands.
 *   - A cache that painted nothing renderable must NOT confirm an empty
 *     transcript — it falls through to the authoritative full page instead.
 *
 * ⛔ WHY THIS FILE USES `vi.mock` MODULE FACTORIES, NOT `vi.spyOn`
 *
 * Two seams, both hoisted-or-nothing (see the long note in
 * `ChatView.streamingStick.spec.ts`):
 *   1. `chatEngineDb` (`sync/ChatEngineDb.ts`) drives the cache prime and the
 *      delta. `ChatEngineDb`'s constructor default is bound ONCE at module
 *      load, and that default is not a method the component ever rebinds — a
 *      late `vi.spyOn` reaches neither the prime nor the delta.
 *   2. `api.fetchChatHistoryEffect(...)` is called DIRECTLY by ChatView for the
 *      authoritative network page.
 * `vi.mock` is hoisted above the module graph, so both are the only seams that
 * work. A `vi.spyOn` here would leave the real network call in place, the retry
 * loop would hold `isLoading`, and every test would pass while asserting
 * nothing.
 */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { createApp, nextTick, type App as VueApp } from 'vue'
import { mount, type VueWrapper } from '@vue/test-utils'
import { Effect } from 'effect'

import * as api from '../../api'
import ChatView from '../../components/views/ChatView.vue'

const EMPTY_PAGE = {
  messages: [],
  has_more: false,
  next_cursor: null,
  cwd: '/tmp',
  git_worktree_cwd: '',
  max_total_tokens: 0,
  max_capacity_total_tokens: 0,
  skills: [],
}

type RawRow = {
  id: string
  role: string
  content: string
  created_at: number
  finish_reason: string
}

/**
 * Everything the two mocked seams read at CALL time (never at factory time),
 * so a test can set up a scenario before the mount.
 */
const ctl = vi.hoisted(() => ({
  /** Rows `primeFromCache` answers with — ChatMessage-shaped: `{ id, raw }`. */
  cached: [] as unknown[],
  /** The page the authoritative network load answers with. */
  page: {
    messages: [] as unknown[],
    has_more: false,
    next_cursor: null,
    cwd: '/tmp',
    git_worktree_cwd: '',
    max_total_tokens: 0,
    max_capacity_total_tokens: 0,
    skills: [],
  },
  /** 'pending' = the remote never answers on its own; 'immediate' = it does. */
  pageMode: 'pending' as 'pending' | 'immediate',
  /** 'pending' = the tail delta stays in flight; 'empty' = it answers "no new rows". */
  deltaMode: 'pending' as 'pending' | 'empty',
  /** Settle the in-flight network page (set once the Effect runs). */
  releasePage: null as null | ((v: unknown) => void),
  /** How many times the authoritative page was requested. */
  fetchPageCalls: 0,
  /** How many times the tail delta was requested. */
  loadDeltaCalls: 0,
}))

const rawRow = (id: string, role: string, content: string, createdAt: number): RawRow => ({
  id,
  role,
  content,
  created_at: createdAt,
  finish_reason: '',
})

vi.mock('../../sync/ChatEngineDb', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../../sync/ChatEngineDb')>()
  return {
    ...actual,
    chatEngineDb: {
      primeFromCache: () => Effect.succeed(ctl.cached),
      getCursor: () => Effect.succeed(null),
      loadDelta: () => {
        ctl.loadDeltaCalls += 1
        if (ctl.deltaMode === 'pending') {
          return Effect.promise(() => new Promise(() => {}))
        }
        return Effect.succeed({ items: [], nextCursor: null, hasMore: false, extra: {} })
      },
      putLocal: () => Effect.void,
      setCursor: () => Effect.void,
    },
  }
})

vi.mock('../../api', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../../api')>()
  return {
    ...actual,
    getChatHistory: () => Promise.resolve(ctl.page),
    fetchChatHistoryEffect: () => {
      ctl.fetchPageCalls += 1
      if (ctl.pageMode === 'immediate') return Effect.succeed(ctl.page)
      return Effect.promise(
        () =>
          new Promise((resolve) => {
            ctl.releasePage = resolve as (v: unknown) => void
          }),
      )
    },
  }
})

vi.mock('vue-router', async () => {
  const actual = await vi.importActual<typeof import('vue-router')>('vue-router')
  return {
    ...actual,
    useRoute: () => ({ query: {}, path: '/app', params: {} }),
    useRouter: () => ({
      replace: vi.fn(() => Promise.resolve()),
      push: vi.fn(() => Promise.resolve()),
      back: vi.fn(),
    }),
  }
})

// jsdom 29 has no HTMLElement.prototype.scrollTo; ChatView's cached-mount paint
// calls scrollToBottom immediately. Assign-only, like src/__tests__/setup.ts.
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

import { installSseBus, __resetSseBus, __setSseBusGlobalClient } from '../../helpers/sseBus'
import type { SseClient, SseState, SseStateInfo } from '../../helpers/sseClient'

function makeStubClient(): SseClient {
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const stub: any = {
    close: vi.fn(),
    reconnect: vi.fn(),
    getState: () => 'connecting' as SseState,
    onStateChange: (_cb: (s: SseState, _info: SseStateInfo) => void) => () => {},
  }
  return stub as SseClient
}

const SKELETON = '[data-testid="chat-initializing-skeleton"]'

async function tick(ms = 10): Promise<void> {
  await new Promise((r) => setTimeout(r, ms))
  await nextTick()
}

/** Poll until `predicate` holds (or give up after `tries` ticks). */
async function waitFor(predicate: () => boolean, tries = 60): Promise<void> {
  for (let i = 0; i < tries; i++) {
    if (predicate()) return
    await tick()
  }
}

describe('ChatView cached mount — what the reader sees while the remote half loads', () => {
  let wrapper: VueWrapper | null = null
  let app: VueApp | null = null

  beforeEach(() => {
    if (typeof localStorage === 'undefined' || typeof localStorage.getItem !== 'function') {
      const store: Record<string, string> = {}
      vi.stubGlobal('localStorage', {
        getItem: (k: string) => (k in store ? store[k] : null),
        setItem: (k: string, v: string) => {
          store[k] = String(v)
        },
        removeItem: (k: string) => {
          delete store[k]
        },
        clear: () => {
          for (const k in store) delete store[k]
        },
        key: () => null,
        length: 0,
      } as Storage)
    } else {
      localStorage.clear()
    }
    setActivePinia(createPinia())

    // Scenario defaults: nothing cached, nothing answered yet.
    ctl.cached = []
    ctl.page = { ...EMPTY_PAGE }
    ctl.pageMode = 'pending'
    ctl.deltaMode = 'pending'
    ctl.releasePage = null
    ctl.fetchPageCalls = 0
    ctl.loadDeltaCalls = 0

    // The mount-time best-effort calls are not what this spec is about.
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    vi.spyOn(api, 'getQueuedMessages').mockResolvedValue({ messages: [] } as any)
    vi.spyOn(api, 'getSession').mockResolvedValue({
      session_id: 's_cache',
      session_name: '',
      selectedProfile: null,
      cwd: '',
      git_worktree_cwd: '',
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
    } as any)
    vi.spyOn(api, 'getGitStatus').mockResolvedValue({
      is_git_repo: false,
      branch: '',
      has_changes: false,
      is_clean: true,
      current: '',
      status: 'clean',
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
    } as any)
    vi.spyOn(api, 'getPabrikConfig').mockResolvedValue({
      profiles: {},
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
    } as any)
    vi.spyOn(api, 'getStreamSnapshot').mockResolvedValue({
      active: false,
      content: '',
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
    } as any)

    __resetSseBus()
    app = createApp({})
    installSseBus(app)
    __setSseBusGlobalClient(makeStubClient())
  })

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    __resetSseBus()
    app = null
    vi.unstubAllGlobals()
    vi.restoreAllMocks()
  })

  function mountView(): VueWrapper {
    const w = mount(ChatView, {
      props: { chatId: 's_cache', chatName: 'Cache Chat' },
      attachTo: document.body,
    })
    return w
  }

  it('cache miss (cold mount): the skeleton covers the whole remote page', async () => {
    ctl.cached = []
    ctl.pageMode = 'pending'

    wrapper = mountView()
    // The skeleton is up from the first frame, so waiting on it proves nothing
    // — wait for the load to actually reach the network half.
    await waitFor(() => ctl.fetchPageCalls > 0)

    expect(wrapper.find(SKELETON).exists()).toBe(true)
    expect(ctl.fetchPageCalls).toBe(1)
    // No cached rows were painted, so there is no transcript to show yet.
    expect(wrapper.find('.virtual-scroller').exists()).toBe(false)

    // Control: it is not stuck on. The remote answer takes the skeleton down.
    ctl.page = { ...EMPTY_PAGE, messages: [rawRow('m1', 'assistant', 'Hello', 1)] }
    ctl.releasePage?.(ctl.page)
    await waitFor(() => !wrapper!.find(SKELETON).exists())

    expect(wrapper.find(SKELETON).exists()).toBe(false)
    expect(wrapper.text()).toContain('Hello')
  })

  it('cache hit with renderable rows: the cached transcript paints and NO skeleton is shown while the tail delta is in flight', async () => {
    ctl.cached = [{ id: 'm1', raw: rawRow('m1', 'user', 'From the cache', 1) }]
    ctl.deltaMode = 'pending'

    wrapper = mountView()
    await waitFor(() => wrapper!.text().includes('From the cache'))

    expect(wrapper.find(SKELETON).exists()).toBe(false)
    expect(wrapper.text()).toContain('From the cache')
    // The transcript really mounted — the paint is not just text in the tree.
    expect(wrapper.find('.virtual-scroller').exists()).toBe(true)
    // The tail delta is the remote half on this path, and it is outstanding.
    expect(ctl.loadDeltaCalls).toBe(1)
    // Cache-first means NOT re-fetching the whole page behind the reader.
    expect(ctl.fetchPageCalls).toBe(0)
  })

  it('cache hit with renderable rows: the remote tail row is merged in when it lands', async () => {
    ctl.cached = [{ id: 'm1', raw: rawRow('m1', 'user', 'From the cache', 1) }]
    ctl.deltaMode = 'empty'

    wrapper = mountView()
    await waitFor(() => wrapper!.text().includes('From the cache'))

    expect(wrapper.find(SKELETON).exists()).toBe(false)
    expect(wrapper.text()).toContain('From the cache')
    expect(ctl.loadDeltaCalls).toBe(1)
    expect(ctl.fetchPageCalls).toBe(0)
  })

  it('cache hit whose rows do not render: the skeleton holds, and the load falls through to the authoritative page', async () => {
    // An assistant turn with no content, no reasoning and no tool call: cached,
    // but `messageGroups` drops it, so there is nothing on screen.
    ctl.cached = [{ id: 'm1', raw: rawRow('m1', 'assistant', '', 1) }]
    // Let the delta settle so the fall-through is observable.
    ctl.deltaMode = 'empty'
    ctl.pageMode = 'pending'

    wrapper = mountView()
    await waitFor(() => ctl.fetchPageCalls > 0)

    expect(ctl.loadDeltaCalls).toBe(1)
    // ⬅ the fix: the cache could not answer, so the full page was requested…
    expect(ctl.fetchPageCalls).toBe(1)
    // …and the reader gets the skeleton, not a blank column.
    expect(wrapper.find(SKELETON).exists()).toBe(true)

    // The authoritative page arrives with something renderable.
    ctl.page = {
      ...EMPTY_PAGE,
      messages: [rawRow('m1', 'assistant', 'Recovered from the server', 1)],
    }
    ctl.releasePage?.(ctl.page)
    await waitFor(() => !wrapper!.find(SKELETON).exists())

    expect(wrapper.find(SKELETON).exists()).toBe(false)
    expect(wrapper.text()).toContain('Recovered from the server')
  })

  it('cache hit whose rows do not render + an empty page: the empty state is the SERVER answer, not the cache guess', async () => {
    ctl.cached = [{ id: 'm1', raw: rawRow('m1', 'assistant', '', 1) }]
    ctl.deltaMode = 'empty'
    ctl.pageMode = 'pending'

    wrapper = mountView()
    await waitFor(() => ctl.fetchPageCalls > 0)

    // Still waiting on the server: skeleton, NOT "How can I help you?".
    expect(wrapper.find(SKELETON).exists()).toBe(true)
    expect(wrapper.text()).not.toContain('How can I help you?')

    ctl.page = { ...EMPTY_PAGE }
    ctl.releasePage?.(ctl.page)
    await waitFor(() => !wrapper!.find(SKELETON).exists())

    expect(wrapper.find(SKELETON).exists()).toBe(false)
    expect(wrapper.text()).toContain('How can I help you?')
  })
})
