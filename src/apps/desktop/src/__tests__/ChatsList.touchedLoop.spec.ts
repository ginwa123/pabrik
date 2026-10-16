/** Touched-echo loop regression tests. Bug: ChatsList.loadChats() fired POST /touched on every load
 * while a chat was open, and the backend answers that POST with an SSE `session.updated` event. */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { createApp, type App as VueApp, nextTick, ref } from 'vue'
import { mount } from '@vue/test-utils'

import ChatsList from '../components/views/ChatsList.vue'
import type { Chat } from '../api'
import { makeLocalStorageStub } from './helpers'
import {
  installSseBus,
  __resetSseBus,
  __setSseBusGlobalClient,
  __dispatchSseBus,
} from '../helpers/sseBus'
import type { SseClient } from '../helpers/sseClient'

const { useRouteMock, getChatsMock, markSessionTouchedMock, routerReplaceMock } = vi.hoisted(() => ({
  useRouteMock: vi.fn(() => ({
    query: {} as Record<string, string>,
    path: '/app',
    fullPath: '/app',
  })),
  getChatsMock: vi.fn(),
  markSessionTouchedMock: vi.fn(),
  routerReplaceMock: vi.fn(),
}))

vi.mock('vue-router', async () => {
  const actual = await vi.importActual<typeof import('vue-router')>('vue-router')
  return {
    ...actual,
    useRoute: useRouteMock,
    useRouter: () => ({ replace: routerReplaceMock }),
  }
})

vi.mock('../api/index', async () => {
  const actual = await vi.importActual<typeof import('../api/index')>('../api/index')
  return {
    ...actual,
    getChats: getChatsMock,
    markSessionTouched: markSessionTouchedMock,
  }
})

function makeSession(overrides: Partial<Chat> = {}): Chat {
  return {
    session_id: 'sess_default',
    session_name: 'Test chat',
    status: 'active',
    selected_profile_model: '',
    is_auto_retry_until_stop: '0',
    last_human_touched_at: '',
    updated_at: '',
    ...overrides,
  }
}

function makeStubClient(state: 'connecting' | { next: 'open'; attempt: number }): SseClient {
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const stub: any = {
    close: vi.fn(),
    reconnect: vi.fn(),
    getState: () => stub._state,
    onStateChange: () => () => {},
  }
  stub._state = state
  return stub as SseClient
}

function dateToSqliteUtc(agoMs: number): string {
  const date = new Date(Date.now() - agoMs)
  return date.toISOString().replace('T', ' ').slice(0, 19)
}

async function flushLoadChats() {
  await new Promise((r) => setTimeout(r, 0))
  await nextTick()
  await nextTick()
}

async function sleep(ms: number) {
  await new Promise((r) => setTimeout(r, ms))
}

describe('ChatsList - touched-echo loop guard', () => {
  let app: VueApp

  beforeEach(() => {
    setActivePinia(createPinia())
    Object.defineProperty(globalThis, 'localStorage', {
      value: makeLocalStorageStub(),
      writable: true,
      configurable: true,
    })
    __resetSseBus()
    app = createApp({})
    installSseBus(app)
    __setSseBusGlobalClient(makeStubClient({ next: 'open', attempt: 0 }))
    getChatsMock.mockReset()
    markSessionTouchedMock.mockReset()
    routerReplaceMock.mockReset()
    useRouteMock.mockReset()
    useRouteMock.mockReturnValue({
      query: {} as Record<string, string>,
      path: '/app',
      fullPath: '/app',
    })
    markSessionTouchedMock.mockResolvedValue({ success: true, session_id: 'sess_loop' })
  })

  afterEach(() => {
    __resetSseBus()
    vi.restoreAllMocks()
    app.unmount()
  })

  function mountChatsList() {
    return mount(ChatsList, {
      global: {
        mocks: { $router: { replace: vi.fn() } },
        provide: { processingState: ref<Record<string, boolean>>({}) },
      },
    })
  }

  it('deep-link touch fires once even across repeated loadChats (no double-touch)', async () => {
    useRouteMock.mockReturnValue({
      query: { view: 'chat', session: 'sess_loop' },
      path: '/app',
      fullPath: '/app?view=chat&session=sess_loop',
    })
    getChatsMock.mockResolvedValue({
      sessions: [
        makeSession({
          session_id: 'sess_loop',
          session_name: 'Loop chat',
          last_human_touched_at: dateToSqliteUtc(2 * 60 * 60 * 1000),
          updated_at: dateToSqliteUtc(30 * 1000),
        }),
      ],
      has_more: false,
      next_cursor: null,
      total: 1,
    })

    const wrapper = mountChatsList()
    await flushLoadChats()

    expect(markSessionTouchedMock).toHaveBeenCalledTimes(1)
    expect(markSessionTouchedMock).toHaveBeenCalledWith('sess_loop')

    // Simulate what the old code did on every SSE echo: a second full
    // loadChats. The guard must NOT fire a second POST.
    const exposed = wrapper.vm as unknown as { loadChats: () => Promise<void> }
    await exposed.loadChats()
    await flushLoadChats()

    expect(markSessionTouchedMock).toHaveBeenCalledTimes(1)
    expect(getChatsMock).toHaveBeenCalledTimes(2)
  })

  it('SSE updated echo of our own touch does NOT trigger a refetch', async () => {
    useRouteMock.mockReturnValue({
      query: { view: 'chat', session: 'sess_loop' },
      path: '/app',
      fullPath: '/app?view=chat&session=sess_loop',
    })
    getChatsMock.mockResolvedValue({
      sessions: [
        makeSession({
          session_id: 'sess_loop',
          session_name: 'Loop chat',
          last_human_touched_at: dateToSqliteUtc(2 * 60 * 60 * 1000),
          updated_at: dateToSqliteUtc(30 * 1000),
        }),
      ],
      has_more: false,
      next_cursor: null,
      total: 1,
    })

    mountChatsList()
    await flushLoadChats()
    expect(getChatsMock).toHaveBeenCalledTimes(1)
    expect(markSessionTouchedMock).toHaveBeenCalledTimes(1)

    // Backend echo of our own POST arrives ~immediately.
    __dispatchSseBus('session', {
      action: 'updated',
      id: 'sess_loop',
      name: 'Loop chat',
      status: 'active',
      cwd: '',
      created_at: '',
      updated_at: dateToSqliteUtc(1000),
    } as never)

    // Wait past the 400ms debounce — a buggy handler would have
    // scheduled a reload by now.
    await sleep(700)
    await flushLoadChats()

    expect(getChatsMock).toHaveBeenCalledTimes(1)
  })

  it('SSE updated for an untouched session DOES trigger a (debounced) refetch', async () => {
    getChatsMock.mockResolvedValue({
      sessions: [makeSession({ session_id: 'sess_a', session_name: 'A' })],
      has_more: false,
      next_cursor: null,
      total: 1,
    })

    mountChatsList()
    await flushLoadChats()
    expect(getChatsMock).toHaveBeenCalledTimes(1)
    expect(markSessionTouchedMock).not.toHaveBeenCalled()

    __dispatchSseBus('session', {
      action: 'updated',
      id: 'sess_other',
      name: 'Renamed elsewhere',
      status: 'active',
      cwd: '',
      created_at: '',
      updated_at: dateToSqliteUtc(1000),
    } as never)

    await sleep(700)
    await flushLoadChats()

    expect(getChatsMock).toHaveBeenCalledTimes(2)
  })

  it('an SSE burst coalesces into a single refetch', async () => {
    getChatsMock.mockResolvedValue({
      sessions: [makeSession({ session_id: 'sess_a', session_name: 'A' })],
      has_more: false,
      next_cursor: null,
      total: 1,
    })

    mountChatsList()
    await flushLoadChats()
    expect(getChatsMock).toHaveBeenCalledTimes(1)

    for (let i = 0; i < 5; i++) {
      __dispatchSseBus('session', {
        action: 'created',
        id: `sess_new_${i}`,
        name: `New ${i}`,
        status: 'active',
        cwd: '',
        created_at: '',
        updated_at: '',
      } as never)
    }

    await sleep(700)
    await flushLoadChats()

    expect(getChatsMock).toHaveBeenCalledTimes(2)
  })
})
