/** Repro for "url browser not match with selected workspace" (task_1791556124905_10). Screenshots:
 * the browser URL is `/app/ws_1785055733544_…/chat/task_…` (workspace "agentic coding") while the
 * sidebar header shows a DIFFERENT workspace ("testttt", ws_1790703859430_…). */
import { beforeEach, afterEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { createApp, reactive } from 'vue'
import { mount } from '@vue/test-utils'

import * as api from '../api'
import { useWorkspacesStore, type Workspace } from '../stores/workspaces'
import AppLayout from '../components/AppLayout.vue'
import { makeLocalStorageStub } from './helpers'
import { installSseBus, __resetSseBus, __setSseBusGlobalClient } from '../helpers/sseBus'
import type { SseClient, SseState, SseStateInfo } from '../helpers/sseClient'
import { __resetWindowIdForTests } from '../helpers/windowId'

function makeStubClient(initial: SseState = 'open'): SseClient {
  const listeners: Array<(s: SseState, info: SseStateInfo) => void> = []
  const stub = {
    _state: initial,
    close: vi.fn(),
    reconnect: vi.fn(),
    getState: () => stub._state,
    onStateChange: (cb: (s: SseState, info: SseStateInfo) => void) => {
      listeners.push(cb)
      return () => {
        const i = listeners.indexOf(cb)
        if (i >= 0) listeners.splice(i, 1)
      }
    },
  }
  return stub as unknown as SseClient
}

const { useRouteMock, useRouterMock } = vi.hoisted(() => ({
  useRouteMock: vi.fn(),
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

// The two workspaces from the screenshots.
const WS_URL = 'ws_1785055733544_28e79c9db8950100' // "agentic coding" — in the URL
const WS_PERSISTED = 'ws_1790703859430_0000e6762ec98901' // "testttt" — in the sidebar
const SESSION = 'task_1791518339586_4'

const makeWorkspace = (id: string, name: string): Workspace => ({
  id,
  name,
  icon: '📁',
  expanded: false,
  items: [],
})

const SEEDED = [makeWorkspace(WS_URL, 'agentic coding'), makeWorkspace(WS_PERSISTED, 'testttt')]

const STUB_CONFIG = {
  Sidebar: true,
  RightSidebar: true,
  GitFileViewer: true,
  SkillDetail: true,
  SettingsView: true,
  CodeEditor: true,
  Chats: { template: '<div data-chats-view="stub" />' },
  ChatView: {
    template: '<div data-chat-view="stub" :data-chat-id="chatId" />',
    props: ['chatId'],
  },
  StandardTaskChatView: { template: '<div data-standard-task-chat-view="stub" />' },
  KanbanView: { template: '<div />', props: ['item', 'workspaceId', 'itemId'] },
  DesignView: { template: '<div />', props: ['item', 'workspaceId', 'itemId'] },
}

/** Mount with a REACTIVE route so tests can simulate popstate (URL-only change). */
function mountWithRoute(initialPath: string) {
  const routeState = reactive({
    query: {} as Record<string, string>,
    path: initialPath,
    fullPath: initialPath,
    params: {},
  })
  useRouteMock.mockReturnValue(routeState)
  const wrapper = mount(AppLayout, {
    global: { stubs: STUB_CONFIG },
  })
  return { wrapper, routeState }
}

describe('AppLayout — a chat path adopts the workspace encoded in that path', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    document.body.innerHTML = ''
    Object.defineProperty(globalThis, 'localStorage', {
      value: makeLocalStorageStub(),
      writable: true,
      configurable: true,
    })
    Object.defineProperty(globalThis, 'sessionStorage', {
      value: Object.assign(makeLocalStorageStub(), { getItem: () => 'w_chatws' }),
      writable: true,
      configurable: true,
    })
    __resetWindowIdForTests()
    __resetSseBus()
    installSseBus(createApp({}))
    __setSseBusGlobalClient(makeStubClient('open'))

    vi.spyOn(api, 'getWorkspaces').mockResolvedValue({ workspaces: SEEDED } as never)
    vi.spyOn(api, 'getWorkspacesItems').mockResolvedValue({ items: [], count: 0 } as never)
    vi.spyOn(api, 'getTasks').mockResolvedValue({ tasks: [], has_more: false, next_cursor: null })
    vi.spyOn(api, 'getSystemFolder').mockResolvedValue({
      path: '/',
      absolute: '/',
      home: '/',
      entries: [],
    } as never)
    vi.spyOn(api, 'getChats').mockResolvedValue({
      sessions: [],
      has_more: false,
      next_cursor: null,
      total: 0,
    })
    vi.spyOn(api, 'getSession').mockResolvedValue({ id: SESSION, cwd: '/' } as never)
    vi.spyOn(api, 'getSessionWorkspaceId').mockResolvedValue(WS_URL)
    vi.spyOn(api, 'getChatHistory').mockResolvedValue({ cwd: '/' } as never)
  })

  afterEach(() => {
    __resetSseBus()
    vi.restoreAllMocks()
  })

  it('boot on /app/{ws}/chat/{sid} selects THAT workspace, not the persisted one', async () => {
    // The persisted selection is a DIFFERENT workspace — the state a
    // user is in after switching workspaces in another tab, or after
    // the last session ended on another workspace.
    localStorage.setItem('pabrik-active-workspace', WS_PERSISTED)

    const { wrapper } = mountWithRoute(`/app/${WS_URL}/chat/${SESSION}`)
    await vi.waitFor(() => {
      expect(wrapper.find('[data-chat-view]').exists()).toBe(true)
    })

    const ws = useWorkspacesStore()
    // The URL names WS_URL. The sidebar must agree with the URL.
    expect(ws.activeWorkspaceId).toBe(WS_URL)
    expect(ws.activeWorkspace?.name).toBe('agentic coding')
    wrapper.unmount()
  })

  it('Back/Forward into a chat path also adopts that path workspace', async () => {
    const { wrapper, routeState } = mountWithRoute(`/app/${WS_PERSISTED}`)
    await vi.waitFor(() => {
      expect(useWorkspacesStore().activeWorkspaceId).toBe(WS_PERSISTED)
    })

    // Browser Back/Forward: ONLY the URL changes, no handler runs.
    routeState.path = `/app/${WS_URL}/chat/${SESSION}`
    routeState.fullPath = routeState.path

    await vi.waitFor(() => {
      expect(useWorkspacesStore().activeWorkspaceId).toBe(WS_URL)
    })
    wrapper.unmount()
  })
})
