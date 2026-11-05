/** ChatView's CACHED mount and older-history pagination: the tail refresh (`cursor + asc`) describes
 * the NEWER direction, so its `has_more` / `next_cursor` must never reach the older-direction state.
 */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { createApp, nextTick, type App as VueApp } from 'vue'
import { mount, type VueWrapper } from '@vue/test-utils'
import { Effect } from 'effect'

import * as api from '../../api'
import ChatView from '../../components/views/ChatView.vue'
import { AUTO_STICK_GATE_MS, VirtualScroller } from '../../helpers'

const OLDEST_CACHED_NANO = 1794000000000000000
const MIDDLE_CACHED_NANO = 1794000000000000256
const NEWEST_CACHED_NANO = 1794000000000000512

const row = (id: string, content: string, created_at_nano: number, role = 'user') => ({
  id,
  role,
  content,
  created_at: Math.floor(created_at_nano / 1e9),
  created_at_nano,
  finish_reason: '',
})

const page = (messages: unknown[], has_more = false, next_cursor: string | null = null) => ({
  messages,
  has_more,
  next_cursor,
  cwd: '/tmp',
  git_worktree_cwd: '',
  max_total_tokens: 0,
  max_capacity_total_tokens: 0,
  skills: [],
})

/** One cached row as `primeFromCache` hands it over: the engine's ChatMessage, not the wire row. */
const cachedRow = (id: string, content: string, created_at_nano: number) => ({
  id,
  sortKey: created_at_nano,
  created_at_nano,
  session_id: 's_scrollback',
  created_at: Math.floor(created_at_nano / 1e9),
  role: 'user',
  content,
  raw: row(id, content, created_at_nano),
})

const ctl = vi.hoisted(() => ({
  cached: [] as unknown[],
  /** The page the older-history request answers with. */
  olderRows: [] as unknown[],
  /** 'empty' = the tail is already cached (the server's normal asc answer). */
  delta: {
    items: [] as unknown[],
    nextCursor: null as string | null,
    hasMore: false,
    extra: {},
  },
  /** Every `getChatHistory` call: `null` = the initial page, otherwise the pagination cursor. */
  historyCursors: [] as (string | null)[],
  /** One page per `loadOlderFromCache` call; an exhausted list = a cache miss. */
  olderCachedPages: [] as unknown[][],
}))

vi.mock('../../sync/ChatEngineDb', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../../sync/ChatEngineDb')>()
  return {
    ...actual,
    chatEngineDb: {
      primeFromCache: () => Effect.succeed(ctl.cached),
      getCursor: () => Effect.succeed(String(NEWEST_CACHED_NANO)),
      loadDelta: () => Effect.succeed(ctl.delta),
      loadOlderFromCache: () => Effect.succeed(ctl.olderCachedPages.shift() ?? []),
      putLocal: () => Effect.void,
      setCursor: () => Effect.void,
    },
  }
})

vi.mock('../../api', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../../api')>()
  return {
    ...actual,
    getChatHistory: (_sessionId: string, _limit: number, cursor?: string) => {
      ctl.historyCursors.push(cursor ?? null)
      return Promise.resolve(page(ctl.olderRows))
    },
    fetchChatHistoryEffect: () => Effect.succeed(page([])),
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
  const stub = {
    close: vi.fn(),
    reconnect: vi.fn(),
    getState: () => 'connecting' as SseState,
    onStateChange: (_cb: (s: SseState, _info: SseStateInfo) => void) => () => {},
  }
  return stub as unknown as SseClient
}

async function tick(ms = 10): Promise<void> {
  await new Promise((r) => setTimeout(r, ms))
  await nextTick()
}

async function waitFor(predicate: () => boolean, tries = 80): Promise<void> {
  for (let i = 0; i < tries; i++) {
    if (predicate()) return
    await tick()
  }
}

describe('ChatView cached mount — scroll-back stays armed', () => {
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
    ctl.cached = [
      cachedRow('c3', 'cached newest', NEWEST_CACHED_NANO),
      cachedRow('c2', 'cached middle', MIDDLE_CACHED_NANO),
      cachedRow('c1', 'cached oldest', OLDEST_CACHED_NANO),
    ]
    ctl.olderRows = [row('o1', 'fetched from the server', 1793999999000000000)]
    ctl.delta = { items: [], nextCursor: null, hasMore: false, extra: {} }
    ctl.historyCursors = []
    ctl.olderCachedPages = []

    vi.spyOn(api, 'getQueuedMessages').mockResolvedValue({ messages: [] } as never)
    vi.spyOn(api, 'getSession').mockResolvedValue({
      session_id: 's_scrollback',
      session_name: '',
      selectedAgent: null,
      cwd: '',
      git_worktree_cwd: '',
    } as never)
    vi.spyOn(api, 'getGitStatus').mockResolvedValue({
      is_git_repo: false,
      branch: '',
      has_changes: false,
      is_clean: true,
      current: '',
      status: 'clean',
    } as never)
    vi.spyOn(api, 'getPabrikConfig').mockResolvedValue({ profiles: {} } as never)
    vi.spyOn(api, 'getStreamSnapshot').mockResolvedValue({ active: false, content: '' } as never)

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
    return mount(ChatView, {
      props: { chatId: 's_scrollback', chatName: 'Scroll-back Chat' },
      attachTo: document.body,
    })
  }

  /** What the VirtualScroller does when the reader arrives at the top of the transcript. The open
   * auto-sticks to the bottom, and that stick suppresses scroll-back for `AUTO_STICK_GATE_MS`; a
   * reader travelling to the top takes longer than the gate, so wait it out first. */
  async function readerReachesTop(w: VueWrapper): Promise<void> {
    await new Promise((r) => setTimeout(r, AUTO_STICK_GATE_MS + 100))
    const scroller = w.findComponent(VirtualScroller)
    expect(scroller.exists()).toBe(true)
    scroller.vm.$emit('load-more')
  }

  it('fetches the page older than the OLDEST cached row when the reader reaches the top', async () => {
    wrapper = mountView()
    await waitFor(() => wrapper!.text().includes('cached oldest'))
    expect(wrapper.text()).toContain('cached newest')

    await readerReachesTop(wrapper)
    await waitFor(() => ctl.historyCursors.length > 0)

    expect(ctl.historyCursors).toHaveLength(1)
    expect(Number(ctl.historyCursors[0])).toBe(OLDEST_CACHED_NANO)
    await waitFor(() => wrapper!.text().includes('fetched from the server'))
    expect(wrapper.text()).toContain('fetched from the server')
    expect(wrapper.text().indexOf('fetched from the server')).toBeLessThan(
      wrapper.text().indexOf('cached oldest'),
    )
  })

  it('serves the older page from IndexedDB, then asks the network past the rows it served', async () => {
    ctl.olderCachedPages = [
      [
        cachedRow('o2', 'cached older newer', OLDEST_CACHED_NANO - 1024),
        cachedRow('o1', 'cached older oldest', OLDEST_CACHED_NANO - 2048),
      ],
      [],
    ]

    wrapper = mountView()
    await waitFor(() => wrapper!.text().includes('cached oldest'))

    await readerReachesTop(wrapper)
    await waitFor(() => wrapper!.text().includes('cached older oldest'))

    expect(wrapper.text()).toContain('cached older newer')
    expect(ctl.historyCursors).toEqual([])

    await readerReachesTop(wrapper)
    await waitFor(() => ctl.historyCursors.length > 0)
    expect(Number(ctl.historyCursors[0])).toBe(OLDEST_CACHED_NANO - 2048)
  })

  it('keeps the older cursor at the oldest row when the tail delta brought NEWER rows', async () => {
    ctl.delta = {
      items: [cachedRow('n1', 'arrived since the cache', 1794000000000000768)],
      nextCursor: '1794000000000000768',
      hasMore: true,
      extra: {},
    }

    wrapper = mountView()
    await waitFor(() => wrapper!.text().includes('arrived since the cache'))

    await readerReachesTop(wrapper)
    await waitFor(() => ctl.historyCursors.length > 0)

    expect(ctl.historyCursors).toHaveLength(1)
    expect(Number(ctl.historyCursors[0])).toBe(OLDEST_CACHED_NANO)
  })
})
