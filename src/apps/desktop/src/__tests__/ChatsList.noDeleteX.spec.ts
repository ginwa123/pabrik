/** Sidebar local-first + delete-X removal pins. - No per-row `×` delete button is rendered (the X
 * is gone; deletion no longer has a sidebar entry point). */
import { beforeEach, afterEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { createApp, type App as VueApp, nextTick, ref } from 'vue'
import { Effect } from 'effect'

import ChatsList from '../components/views/ChatsList.vue'
import { sessionEngineDb } from '../sync/SessionEngineDb'
import { toSessionRow } from '../sync/SessionEngineDb'
import type { Chat } from '../api'
import { mount } from '@vue/test-utils'
import { makeLocalStorageStub } from './helpers'
import { installSseBus, __resetSseBus, __setSseBusGlobalClient } from '../helpers/sseBus'
import type { SseClient, SseState } from '../helpers/sseClient'

const { mockGetChats } = vi.hoisted(() => ({ mockGetChats: vi.fn() }))

vi.mock('../api', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../api')>()
  return {
    ...actual,
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    getChats: (...args: any[]) => mockGetChats(...args),
  }
})

function makeStubClient(initial: SseState): SseClient {
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const stub: any = {
    close: vi.fn(),
    reconnect: vi.fn(),
    getState: () => stub._state,
    onStateChange: () => () => {},
  }
  stub._state = initial
  return stub as SseClient
}

const { useRouteMock, useRouterMock } = vi.hoisted(() => ({
  useRouteMock: vi.fn(() => ({ query: {} as Record<string, string>, path: '/', fullPath: '/' })),
  useRouterMock: vi.fn(() => ({ replace: vi.fn(), push: vi.fn() })),
}))

vi.mock('vue-router', async () => {
  const actual = await vi.importActual<typeof import('vue-router')>('vue-router')
  return {
    ...actual,
    useRouter: useRouterMock,
    useRoute: useRouteMock,
  }
})

const sess = (id: string, name: string, updated_at: string): Chat =>
  ({
    session_id: id,
    session_name: name,
    status: 'active',
    updated_at,
    last_human_touched_at: '',
  }) as Chat

function mountChatsList() {
  return mount(ChatsList, {
    global: {
      mocks: { $router: { replace: vi.fn() } },
      provide: { processingState: ref<Record<string, boolean>>({}) },
    },
  })
}

async function flushLoadChats() {
  await new Promise((r) => setTimeout(r, 0))
  await nextTick()
  await nextTick()
}

describe('ChatsList local-first + no delete X', () => {
  let app: VueApp

  beforeEach(async () => {
    setActivePinia(createPinia())
    Object.defineProperty(globalThis, 'localStorage', {
      value: makeLocalStorageStub(),
      writable: true,
      configurable: true,
    })
    __resetSseBus()
    app = createApp({})
    installSseBus(app)
    __setSseBusGlobalClient(makeStubClient('connecting'))
    mockGetChats.mockReset()
    // Unscoped in tests (no active workspace) → cache ctx 'all'.
    await Effect.runPromise(sessionEngineDb.clear('all'))
  })

  afterEach(() => {
    __resetSseBus()
    vi.restoreAllMocks()
  })

  it('renders rows with no per-row delete X button', async () => {
    mockGetChats.mockResolvedValue({
      sessions: [sess('s1', 'First chat', '2026-09-20 10:00:00')],
      has_more: false,
      next_cursor: null,
      total: 1,
    })
    const wrapper = mountChatsList()
    await flushLoadChats()
    expect(wrapper.text()).toContain('First chat')
    expect(wrapper.find('button[title="Delete chat"]').exists()).toBe(false)
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    expect((wrapper.vm as any).confirmDeleteChat).toBeUndefined()
    wrapper.unmount()
  })

  it('paints cached rows instantly while the delta is in flight', async () => {
    await Effect.runPromise(
      sessionEngineDb.putLocal('all', [
        toSessionRow(sess('cached-1', 'Cached chat', '2026-09-19 10:00:00')),
      ]),
    )
    let resolveDelta!: (v: {
      sessions: Chat[]
      has_more: boolean
      next_cursor: string | null
      total: number
    }) => void
    mockGetChats.mockImplementation(
      () =>
        new Promise((resolve) => {
          resolveDelta = resolve
        }),
    )
    const wrapper = mountChatsList()
    await flushLoadChats()
    // Cache paint landed before the network responded.
    expect(wrapper.text()).toContain('Cached chat')
    resolveDelta({
      sessions: [sess('fresh-1', 'Fresh chat', '2026-09-21 10:00:00')],
      has_more: false,
      next_cursor: null,
      total: 1,
    })
    await flushLoadChats()
    expect(wrapper.text()).toContain('Fresh chat')
    wrapper.unmount()
  })
})
