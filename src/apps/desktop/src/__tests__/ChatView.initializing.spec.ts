/** Tests for ChatView's initializing ready-gate. While the first history fetch is outstanding
 * (`isInitializing`), the transcript shows a skeleton (not the empty state) and the composer is
 * disabled (textarea + send). */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { createApp, nextTick, type App as VueApp } from 'vue'
import { mount, type VueWrapper } from '@vue/test-utils'
import { Effect } from 'effect'

import * as api from '../api'
import ChatView from '../components/views/ChatView.vue'
import FileInput from '../components/file/FileInput.vue'
import { installSseBus, __resetSseBus, __setSseBusGlobalClient } from '../helpers/sseBus'
import type { SseClient, SseState, SseStateInfo } from '../helpers/sseClient'
import { makeLocalStorageStub } from './helpers'

const { useRouteMock, useRouterMock } = vi.hoisted(() => ({
  useRouteMock: vi.fn(() => ({
    query: {} as Record<string, string>,
    path: '/app',
    fullPath: '/app',
  })),
  useRouterMock: vi.fn(() => ({ replace: vi.fn(), push: vi.fn(), back: vi.fn() })),
}))

vi.mock('vue-router', async () => {
  const actual = await vi.importActual<typeof import('vue-router')>('vue-router')
  return {
    ...actual,
    useRouter: useRouterMock,
    useRoute: useRouteMock,
  }
})

const EMPTY_HISTORY = {
  messages: [] as unknown[],
  has_more: false,
  next_cursor: null,
  cwd: '/tmp',
  git_worktree_cwd: '',
  max_total_tokens: 0,
  max_capacity_total_tokens: 0,
  skills: [],
}

/** Read at CALL time by the mocked network seam (see the file header). */
const ctl = vi.hoisted(() => ({
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
  /** 'pending' = in flight until `release()`; 'resolve'; 'fail'. */
  mode: 'pending' as 'pending' | 'resolve' | 'fail',
  release: null as null | (() => void),
  fetchCalls: 0,
}))

vi.mock('../api', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../api')>()
  return {
    ...actual,
    getChatHistory: () => Promise.resolve(ctl.page),
    fetchChatHistoryEffect: () => {
      ctl.fetchCalls += 1
      if (ctl.mode === 'resolve') return Effect.succeed(ctl.page)
      if (ctl.mode === 'fail') return Effect.fail(new Error('offline'))
      return Effect.promise(
        () =>
          new Promise((resolve) => {
            ctl.release = () => resolve(ctl.page)
          }),
      )
    },
  }
})

// Collapse the backoff so the exhausted-retry path is reachable in ms. The
// policy itself is covered by helpers/__tests__/chatHistoryRetry.spec.ts.
vi.mock('../helpers/chatHistoryRetry', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../helpers/chatHistoryRetry')>()
  return {
    ...actual,
    fetchInitialHistoryWithRetry: (
      attempt: () => Effect.Effect<unknown, unknown>,
      options: { onRetry?: (error: unknown) => void } = {},
    ) => actual.fetchInitialHistoryWithRetry(attempt, { ...options, delaysMs: [0, 0, 0, 0] }),
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

const SKELETON = '[data-testid="chat-initializing-skeleton"]'

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

function installBaseMocks() {
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  vi.spyOn(api, 'getQueuedMessages').mockResolvedValue({ messages: [] } as any)
  vi.spyOn(api, 'getSession').mockResolvedValue({
    session_id: 's_init',
    session_name: '',
    selectedAgent: null,
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
  vi.spyOn(api, 'getStreamSnapshot').mockResolvedValue({
    active: false,
    content: '',
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
  } as any)
}

/** Poll until `predicate` holds (or give up), flushing a macrotask each round. */
async function waitFor(predicate: () => boolean, tries = 80): Promise<void> {
  for (let i = 0; i < tries; i++) {
    if (predicate()) return
    await new Promise((r) => setTimeout(r, 10))
    await nextTick()
  }
}

describe('ChatView initializing gate', () => {
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

    ctl.page = { ...EMPTY_HISTORY }
    ctl.mode = 'pending'
    ctl.release = null
    ctl.fetchCalls = 0

    __resetSseBus()
    app = createApp({})
    installSseBus(app)
    __setSseBusGlobalClient(makeStubClient())
    installBaseMocks()
  })

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    __resetSseBus()
    app = null
    vi.restoreAllMocks()
  })

  it('shows the skeleton + disabled composer while history is in flight, then resolves to ready', async () => {
    ctl.mode = 'pending'

    wrapper = mount(ChatView, {
      props: { chatId: 's_init', chatName: 'Init Chat' },
      attachTo: document.body,
    })
    // The skeleton is up from the first frame, so waiting on it proves
    // nothing — wait for the load to actually reach the network seam.
    await waitFor(() => ctl.fetchCalls > 0)

    // Initializing: skeleton visible, empty state hidden, composer disabled.
    expect(wrapper.find(SKELETON).exists()).toBe(true)
    expect(wrapper.find('[data-testid="chat-load-error"]').exists()).toBe(false)
    expect(wrapper.text()).not.toContain('How can I help you?')
    const fileInput = wrapper.findComponent(FileInput)
    expect(fileInput.props('isInitializing')).toBe(true)
    expect(
      wrapper.find('[data-testid="chat-message-textarea"]').attributes('disabled'),
    ).toBeDefined()

    // History resolves (empty) → skeleton gone, empty state shown, composer enabled.
    ctl.release?.()
    await waitFor(() => !wrapper!.find(SKELETON).exists())

    expect(wrapper.find(SKELETON).exists()).toBe(false)
    expect(wrapper.findComponent(FileInput).props('isInitializing')).toBe(false)
    expect(
      wrapper.find('[data-testid="chat-message-textarea"]').attributes('disabled'),
    ).toBeUndefined()
    expect(wrapper.text()).toContain('How can I help you?')
  })

  it('pending drafts render ready immediately (no skeleton)', async () => {
    wrapper = mount(ChatView, {
      props: { chatId: 'pending-123', chatName: 'Draft' },
      attachTo: document.body,
    })
    await new Promise((r) => setTimeout(r, 30))
    await nextTick()

    expect(ctl.fetchCalls).toBe(0)
    expect(wrapper.find(SKELETON).exists()).toBe(false)
    expect(wrapper.findComponent(FileInput).props('isInitializing')).toBe(false)
  })

  it('renders the load error with retry when history fails', async () => {
    ctl.mode = 'fail'
    wrapper = mount(ChatView, {
      props: { chatId: 's_init', chatName: 'Init Chat' },
      attachTo: document.body,
    })
    // Every attempt fails; the collapsed schedule exhausts in milliseconds.
    await waitFor(() => wrapper!.find('[data-testid="chat-load-error"]').exists())

    expect(wrapper.find('[data-testid="chat-load-error"]').exists()).toBe(true)
    expect(wrapper.find(SKELETON).exists()).toBe(false)
    // The failure is a retried load, not a one-shot.
    expect(ctl.fetchCalls).toBeGreaterThan(1)
    // …and it is NOT the empty state: "the server is down" is not "no messages".
    expect(wrapper.text()).not.toContain('How can I help you?')
  })
})
