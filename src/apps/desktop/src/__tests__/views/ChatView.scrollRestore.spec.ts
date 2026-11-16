/** Tests for ChatView's scroll-position restore behavior on mount. */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { createApp, nextTick, type App as VueApp } from 'vue'
import { mount, type VueWrapper } from '@vue/test-utils'
import { Effect } from 'effect'

import * as api from '../../api'
import ChatView from '../../components/views/ChatView.vue'
import { installSseBus, __resetSseBus, __setSseBusGlobalClient } from '../../helpers/sseBus'
import type { SseClient, SseState, SseStateInfo } from '../../helpers/sseClient'

// ── The history seam, hoisted ───────────────────────────────────────────────
const historyRows: unknown[] = []
const historyResponse = () => ({
  messages: historyRows,
  has_more: false,
  next_cursor: null,
  cwd: '/tmp',
  git_worktree_cwd: '',
  max_total_tokens: 0,
  max_capacity_total_tokens: 0,
  skills: [],
})
vi.mock('../../api', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../../api')>()
  return {
    ...actual,
    getChatHistory: () => Promise.resolve(historyResponse()),
    fetchChatHistoryEffect: () => Effect.succeed(historyResponse()),
  }
})

// ChatView calls useRoute()/useRouter() on mount (URL param sync).
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

// `scrollTo` must ASSIGN the position and FIRE the event a browser fires. setup.ts already installs a polyfill that does the assignment, so the `typeof … === …
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
  el.dispatchEvent(new Event('scroll'))
}

// jsdom does NOT lay out elements. scrollHeight and clientHeight default to 0 on every element, so ChatView's restore would see max=0 and no-op.
Object.defineProperty(HTMLElement.prototype, 'scrollHeight', {
  configurable: true,
  get(): number {
    return 20000
  },
})
Object.defineProperty(HTMLElement.prototype, 'clientHeight', {
  configurable: true,
  get(): number {
    return 800
  },
})

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

function installApiMocks(): void {
  // getChatHistory returns 100 user-role messages so the chat is scrollable.
  historyRows.length = 0
  for (let i = 0; i < 100; i++) {
    historyRows.push({
      id: `msg_${i}`,
      role: 'user',
      content: `Message ${i}`,
      created_at: i,
      image_url: '',
      finish_reason: '',
    })
  }

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  vi.spyOn(api, 'getQueuedMessages').mockResolvedValue({ messages: [] } as any)
  vi.spyOn(api, 'getSession').mockResolvedValue({
    session_id: 'placeholder',

    session_name: '',
    selectedAgent: null,
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
}

async function mountChatView(chatId: string): Promise<VueWrapper> {
  const wrapper = mount(ChatView, {
    props: { chatId, chatName: 'Test Chat' },
    attachTo: document.body,
  })
  // The onMounted chain is async: loadChatHistory → connectSse → startGitStatusPoll → getQueuedMessages → loadProfiles (sync).
  for (let i = 0; i < 20; i++) {
    await new Promise((r) => setTimeout(r, 0))
    await nextTick()
    const streaming = (wrapper.vm as unknown as { isStreaming?: boolean }).isStreaming
    if (streaming) break
  }
  return wrapper
}

/** Configure the VirtualScroller container's scrollHeight and clientHeight to simulate a known geometry. */
function findScrollerContainer(wrapper: VueWrapper): HTMLElement | null {
  // The VirtualScroller renders a `<div class="virtual-scroller">` container.
  const el = wrapper.find('.virtual-scroller')
  return el.exists() ? (el.element as HTMLElement) : null
}

async function waitForInitialLoad(wrapper: VueWrapper): Promise<void> {
  // The initial-load branch awaits rAF × 2 (one inside loadChatHistory, one for VirtualScroller's measureItems).
  for (let i = 0; i < 30; i++) {
    await new Promise((r) => setTimeout(r, 25))
    const container = findScrollerContainer(wrapper)
    if (container && container.scrollHeight > container.clientHeight) return
  }
}

describe('ChatView — scroll position persistence', () => {
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

  it('falls through to scrollToBottom when the saved position is "near bottom"', async () => {
    // scrollHeight - clientHeight = 19200 (the max). saved = 19200 → distance from bottom = 0 → "still at bottom" → restore returns null → ChatView calls …
    localStorage.setItem('chat-scroll-task_nearbottom', '19200')
    installApiMocks()

    wrapper = await mountChatView('task_nearbottom')
    await waitForInitialLoad(wrapper)

    const container = findScrollerContainer(wrapper)
    expect(container).not.toBeNull()
    const max = container!.scrollHeight - container!.clientHeight
    expect(container!.scrollTop).toBe(max)
  })

  it('falls through to scrollToBottom when no saved value exists', async () => {
    installApiMocks()

    wrapper = await mountChatView('task_fresh')
    await waitForInitialLoad(wrapper)

    const container = findScrollerContainer(wrapper)
    expect(container).not.toBeNull()
    const max = container!.scrollHeight - container!.clientHeight
    expect(container!.scrollTop).toBe(max)
  })

  it('falls through to scrollToBottom when the saved value is 0', async () => {
    localStorage.setItem('chat-scroll-task_zero', '0')
    installApiMocks()

    wrapper = await mountChatView('task_zero')
    await waitForInitialLoad(wrapper)

    const container = findScrollerContainer(wrapper)
    expect(container).not.toBeNull()
    const max = container!.scrollHeight - container!.clientHeight
    expect(container!.scrollTop).toBe(max)
  })

  it('persists the scroll position when the user scrolls up before closing', async () => {
    installApiMocks()

    wrapper = await mountChatView('task_save')
    await waitForInitialLoad(wrapper)

    const container = findScrollerContainer(wrapper)
    expect(container).not.toBeNull()

    // Simulate the user scrolling up to the middle.
    container!.scrollTop = 450
    container!.dispatchEvent(new Event('scrollend'))

    // The composable should have persisted 450 synchronously.
    expect(localStorage.getItem('chat-scroll-task_save')).toBe('450')

    wrapper?.unmount()
    wrapper = null
  })

  it('keys the save per task (two chats never share a position)', async () => {
    // The landing position is asserted in ChatView.scrollRestoreLands.spec.ts, where the height model is real.
    installApiMocks()

    wrapper = await mountChatView('task_A')
    await waitForInitialLoad(wrapper)
    const containerA = findScrollerContainer(wrapper)
    containerA.scrollTop = 450
    containerA.dispatchEvent(new Event('scrollend'))
    expect(localStorage.getItem('chat-scroll-task_A')).toBe('450')
    wrapper.unmount()
    wrapper = null

    wrapper = await mountChatView('task_B')
    await waitForInitialLoad(wrapper)
    const containerB = findScrollerContainer(wrapper)
    containerB.scrollTop = 1500
    containerB.dispatchEvent(new Event('scrollend'))
    expect(localStorage.getItem('chat-scroll-task_B')).toBe('1500')

    // Task A's position is untouched by everything that happened in B.
    expect(localStorage.getItem('chat-scroll-task_A')).toBe('450')
    wrapper.unmount()
    wrapper = null
  })

  it('flushes the pending scroll save on unmount', async () => {
    installApiMocks()

    wrapper = await mountChatView('task_flush')
    await waitForInitialLoad(wrapper)

    const container = findScrollerContainer(wrapper)
    expect(container).not.toBeNull()

    // Simulate a debounced scroll save (debounce timer not advanced).
    container!.scrollTop = 350
    container!.dispatchEvent(new Event('scroll'))

    // Unmount before the debounce fires.
    wrapper.unmount()
    wrapper = null

    expect(localStorage.getItem('chat-scroll-task_flush')).toBe('350')
  })
})
