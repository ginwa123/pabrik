/** A warm IndexedDB cache must not cost the reader their place: the cached-mount branch painted
 * stored rows and then jumped to the bottom, discarding the saved position on every later open.
 */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { nextTick } from 'vue'
import { mount, type VueWrapper } from '@vue/test-utils'
import { Effect } from 'effect'

import * as api from '../../api'
import ChatView from '../../components/views/ChatView.vue'

const VIEWPORT = 800
const ROW_HEIGHT = 200
const ROW_COUNT = 100
const REAL_TOTAL = ROW_HEIGHT * ROW_COUNT
const REAL_BOTTOM = REAL_TOTAL - VIEWPORT
const SAVED_POSITION = 9000
const BASE_NANO = 1794000000000000000

const ctl = vi.hoisted(() => ({ cached: [] as ReturnType<typeof cachedRow>[] }))

const wireRow = (id: string, content: string, nano: number, role: string) => ({
  id,
  role,
  content,
  created_at: Math.floor(nano / 1e9),
  created_at_nano: nano,
  finish_reason: '',
})

const cachedRow = (id: string, content: string, nano: number, role: string) => ({
  id,
  sortKey: nano,
  created_at_nano: nano,
  session_id: 's_cached_restore',
  created_at: Math.floor(nano / 1e9),
  role,
  content,
  raw: wireRow(id, content, nano, role),
})

vi.mock('../../sync/ChatEngineDb', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../../sync/ChatEngineDb')>()
  return {
    ...actual,
    chatEngineDb: {
      primeFromCache: () => Effect.succeed(ctl.cached),
      getCursor: () => Effect.succeed(String(BASE_NANO + ROW_COUNT)),
      loadDelta: () => Effect.succeed({ items: [], nextCursor: null, hasMore: false, extra: {} }),
      loadOlderFromCache: () => Effect.succeed([]),
      putLocal: () => Effect.void,
      setCursor: () => Effect.void,
    },
  }
})

vi.mock('../../api', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../../api')>()
  const empty = {
    messages: [],
    has_more: false,
    next_cursor: null,
    cwd: '/tmp',
    git_worktree_cwd: '',
    max_total_tokens: 0,
    max_capacity_total_tokens: 0,
    skills: [],
  }
  return {
    ...actual,
    getChatHistory: () => Promise.resolve(empty),
    fetchChatHistoryEffect: () => Effect.succeed(empty),
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

Object.defineProperty(HTMLElement.prototype, 'clientHeight', {
  configurable: true,
  get(): number {
    return VIEWPORT
  },
})

Object.defineProperty(HTMLElement.prototype, 'scrollHeight', {
  configurable: true,
  get(): number {
    const sizer = (this as HTMLElement).querySelector?.('.virtual-scroller-sizer')
    return sizer ? parseFloat((sizer as HTMLElement).style.height) || 0 : 0
  },
})

Object.defineProperty(HTMLElement.prototype, 'offsetHeight', {
  configurable: true,
  get(): number {
    const parent = (this as HTMLElement).parentElement
    return parent?.classList.contains('virtual-scroller-content') ? ROW_HEIGHT : 0
  },
})

async function mountChatView(chatId: string): Promise<VueWrapper> {
  const wrapper = mount(ChatView, {
    props: { chatId, chatName: 'Cached restore' },
    attachTo: document.body,
  })
  for (let i = 0; i < 60; i++) {
    await new Promise((r) => setTimeout(r, 40))
    await nextTick()
    if (wrapper.find('.virtual-scroller').exists()) break
  }
  return wrapper
}

function findScrollerContainer(wrapper: VueWrapper): HTMLElement {
  const el = wrapper.find('.virtual-scroller')
  if (!el.exists()) {
    throw new Error('.virtual-scroller not mounted — the cached load never settled')
  }
  return el.element as HTMLElement
}

async function settleScroller(): Promise<void> {
  for (let i = 0; i < 8; i++) {
    await new Promise((r) => setTimeout(r, 60))
    await nextTick()
  }
}

describe('ChatView — a cached mount lands where the reader left it', () => {
  let wrapper: VueWrapper | null = null

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

    ctl.cached = Array.from({ length: ROW_COUNT }, (_, i) => {
      const index = ROW_COUNT - 1 - i
      return cachedRow(
        `msg_${index}`,
        `Message ${index}`,
        BASE_NANO + i,
        index % 2 === 0 ? 'user' : 'assistant',
      )
    })

    vi.spyOn(api, 'getQueuedMessages').mockResolvedValue({ messages: [] } as never)
    vi.spyOn(api, 'getSession').mockResolvedValue({
      session_id: 's_cached_restore',
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
  })

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    vi.restoreAllMocks()
  })

  it('restores the saved position instead of jumping to the bottom', async () => {
    localStorage.setItem('chat-scroll-s_cached_restore', String(SAVED_POSITION))

    wrapper = await mountChatView('s_cached_restore')
    const container = findScrollerContainer(wrapper)
    await settleScroller()

    expect(container.scrollHeight).toBe(REAL_TOTAL)
    expect(container.scrollTop).toBe(SAVED_POSITION)
  })

  it('a reader with nothing saved still lands at the bottom of the cached rows', async () => {
    wrapper = await mountChatView('s_cached_restore')
    const container = findScrollerContainer(wrapper)
    await settleScroller()

    expect(container.scrollTop).toBe(REAL_BOTTOM)
  })
})
