/** Behavioural tests for `ChatsList.vue` workspace scoping (plan:
 * 2026-09-22-revamp-ui-chats-workspace-scoped). */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { createApp, type App as VueApp, nextTick, reactive, ref } from 'vue'
import { mount } from '@vue/test-utils'

import * as api from '../api'
import { useWorkspacesStore } from '../stores/workspaces'
import type { Workspace } from '../stores/workspaces'
import ChatsList from '../components/views/ChatsList.vue'
import { makeLocalStorageStub } from './helpers'
import { installSseBus, __resetSseBus, __setSseBusGlobalClient } from '../helpers/sseBus'
import type { SseClient, SseState, SseStateInfo } from '../helpers/sseClient'

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

function makeStubClient(initial: SseState): SseClient {
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const stub: any = {
    close: vi.fn(),
    reconnect: vi.fn(),
    getState: () => stub._state,
    onStateChange: (_cb: (s: SseState, info: SseStateInfo) => void) => {
      return () => {}
    },
  }
  stub._state = initial
  return stub as SseClient
}

const sessionA = {
  session_id: 'sess_a',
  session_name: 'Chat A',
  updated_at: '2026-09-22T10:00:00Z',
  selected_profile_model: '',
  git_worktree_cwd: '',
  is_auto_retry_until_stop: '0',
}

// eslint-disable-next-line @typescript-eslint/no-explicit-any
function mockGetChats(sessions: any[] = [sessionA]) {
  vi.spyOn(api, 'getChats').mockResolvedValue({
    sessions,
    has_more: false,
    next_cursor: null,
    total: sessions.length,
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
  } as any)
}

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

describe('ChatsList — workspace-scoped chats', () => {
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
    __setSseBusGlobalClient(makeStubClient('connecting'))
  })
  afterEach(() => {
    __resetSseBus()
    vi.restoreAllMocks()
  })

  it('passes the URL path workspace to getChats', async () => {
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    useRouteMock.mockReturnValue({ query: {}, path: '/app/ws_A', fullPath: '/app/ws_A' } as any)
    mockGetChats()
    const getChatsSpy = vi.spyOn(api, 'getChats')
    mountChatsList()
    await flushLoadChats()
    expect(getChatsSpy).toHaveBeenCalled()
    const lastCall = getChatsSpy.mock.calls[getChatsSpy.mock.calls.length - 1]!
    // 5th positional arg is workspaceId.
    expect(lastCall[4]).toBe('ws_A')
  })

  it('falls back to the store active workspace when the URL has none', async () => {
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    useRouteMock.mockReturnValue({ query: {}, path: '/app', fullPath: '/app' } as any)
    const ws = useWorkspacesStore()
    ws.workspaces = [
      { id: 'ws_store', name: 'WS', icon: '📁', expanded: true, items: [] } as Workspace,
    ]
    ws.setActiveWorkspace('ws_store')
    mockGetChats()
    const getChatsSpy = vi.spyOn(api, 'getChats')
    mountChatsList()
    await flushLoadChats()
    const lastCall = getChatsSpy.mock.calls[getChatsSpy.mock.calls.length - 1]!
    expect(lastCall[4]).toBe('ws_store')
  })

  it('refetches with the new scope when the workspace changes', async () => {
    // Reactive route so path mutations re-run the scope computed
    // (same pattern as ChatsList.activeFromUrlReactive.spec.ts).
    const route = reactive({
      query: {} as Record<string, string>,
      path: '/app/ws_A',
      fullPath: '/app/ws_A',
    })
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    useRouteMock.mockImplementation(() => route as any)
    mockGetChats()
    const getChatsSpy = vi.spyOn(api, 'getChats')
    const wrapper = mountChatsList()
    await flushLoadChats()
    expect(getChatsSpy.mock.calls[getChatsSpy.mock.calls.length - 1]![4]).toBe('ws_A')

    // Switch workspace: the route path changes (Back/Forward or
    // dropdown push). The watcher clears + refetches with ws_B.
    route.path = '/app/ws_B'
    route.fullPath = '/app/ws_B'
    await nextTick()
    await flushLoadChats()
    const calls = getChatsSpy.mock.calls
    expect(calls.length).toBeGreaterThan(1)
    expect(calls[calls.length - 1]![4]).toBe('ws_B')
    wrapper.unmount()
  })

  it('renders no "+" new-chat button (removed 2026-09-22)', async () => {
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    useRouteMock.mockReturnValue({ query: {}, path: '/app/ws_A', fullPath: '/app/ws_A' } as any)
    mockGetChats()
    const wrapper = mountChatsList()
    await flushLoadChats()
    expect(wrapper.find('[data-testid="chats-new-chat-button"]').exists()).toBe(false)
    expect(wrapper.find('[data-testid="collapsed-new-chat-button"]').exists()).toBe(false)
    wrapper.unmount()
  })

  it('row click navigates to the path chat URL', async () => {
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    useRouteMock.mockReturnValue({ query: {}, path: '/app/ws_A', fullPath: '/app/ws_A' } as any)
    mockGetChats()
    const replaceMock = vi.fn()
    useRouterMock.mockReturnValue({ replace: replaceMock, push: vi.fn() })
    const wrapper = mountChatsList()
    await flushLoadChats()
    const buttons = wrapper.findAll('button')
    const chatButton = buttons.find((b) => b.text().includes('Chat A'))
    expect(chatButton).toBeDefined()
    await chatButton!.trigger('click')
    await nextTick()
    expect(replaceMock).toHaveBeenCalled()
    const target = replaceMock.mock.calls[0]![0] as { path: string }
    expect(target.path).toBe('/app/ws_A/chat/sess_a')
    wrapper.unmount()
  })
})
