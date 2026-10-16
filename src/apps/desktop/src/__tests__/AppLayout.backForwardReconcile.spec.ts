/** Repro for the board-URL-renders-chat anomaly (task_1789421136160_2). Screenshots: URL is the
 * board URL (`/app?view=workspace&workspaceId=WS&itemId=BOARD`, sidebar on the board) but <main>
 * still shows the chat transcript. */
import { beforeEach, afterEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { createApp, nextTick, reactive } from 'vue'
import { mount } from '@vue/test-utils'

import * as api from '../api'
import { useWorkspacesStore, type Workspace, type WorkspaceItem } from '../stores/workspaces'
import { useNavigationStore } from '../stores/navigation'
import { useTabsStore } from '../stores/tabs'
import AppLayout from '../components/AppLayout.vue'
import { makeLocalStorageStub } from './helpers'
import { installSseBus, __resetSseBus, __setSseBusGlobalClient } from '../helpers/sseBus'
import type { SseClient, SseState, SseStateInfo } from '../helpers/sseClient'
import { __resetWindowIdForTests } from '../helpers/windowId'

function makeStubClient(initial: SseState = 'open'): SseClient {
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const stub: any = {
    close: vi.fn(),
    reconnect: vi.fn(),
    getState: () => stub._state,
    onStateChange: (cb: (s: SseState, info: SseStateInfo) => void) => {
      stub.__stateListeners.push(cb)
      return () => {
        const i = stub.__stateListeners.indexOf(cb)
        if (i >= 0) stub.__stateListeners.splice(i, 1)
      }
    },
  }
  stub._state = initial
  stub.__stateListeners = [] as Array<(s: SseState, info: SseStateInfo) => void>
  return stub as SseClient
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

const WS_ID = 'ws_backforward'
const BOARD_ID = 'item_board_backforward'
const SESSION_X = 'session_chat_x'
const SESSION_Y = 'session_chat_y'

const makeBoardItem = (): WorkspaceItem => ({
  id: BOARD_ID,
  name: 'AGENTIC_KANBAN',
  item_type: 'kanban',
  tasks: [],
})

const makeWorkspace = (): Workspace => ({
  id: WS_ID,
  name: 'agentic coding',
  icon: '📁',
  expanded: true,
  items: [makeBoardItem()],
})

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
  KanbanView: {
    template: '<div data-kanban-view="stub" :data-item-id="item.id" />',
    props: ['item', 'workspaceId', 'itemId'],
  },
  DesignView: {
    template: '<div data-design-view="stub" :data-item-id="item.id" />',
    props: ['item', 'workspaceId', 'itemId'],
  },
}

function fullPathOf(query: Record<string, string>): string {
  const qs = new URLSearchParams(query).toString()
  return '/app' + (qs ? `?${qs}` : '')
}

/**  * Seed the fixture tree AND rewire the API mocks to serve it, so init() populates instead of wiping
 * (lazy init reads the mocks after replacing the tree — a live read would see the wipe). */
function seedFixtureTree() {
  const ws = useWorkspacesStore()
  ws.workspaces = [makeWorkspace()]
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const snapshot = JSON.parse(JSON.stringify(ws.workspaces)) as any[]
  vi.spyOn(api, 'getWorkspaces').mockResolvedValue({ workspaces: snapshot } as never)
  vi.spyOn(api, 'getWorkspacesItems').mockResolvedValue({
    items: snapshot[0].items,
    count: snapshot[0].items.length,
  } as never)
  return ws
}

/** Mount with a REACTIVE route so tests can simulate popstate (URL-only change). */
function mountWithRoute(initialQuery: Record<string, string>, initialPath = '/app') {
  const routeState = reactive({
    query: { ...initialQuery },
    path: initialPath,
    fullPath: initialPath + fullPathOf(initialQuery).slice('/app'.length),
    params: {},
  })
  useRouteMock.mockReturnValue(routeState)
  const wrapper = mount(AppLayout, {
    global: { stubs: STUB_CONFIG },
  })
  return { wrapper, routeState }
}

/** Simulate browser Back/Forward: ONLY the URL changes, stores stay stale. */
function navigateTo(
  routeState: { query: Record<string, string>; path: string; fullPath: string },
  query: Record<string, string>,
  path = '/app',
) {
  routeState.query = { ...query }
  routeState.path = path
  const qs = new URLSearchParams(query).toString()
  routeState.fullPath = path + (qs ? `?${qs}` : '')
}

describe('AppLayout — Back/Forward reconciles stores from the URL', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    document.body.innerHTML = ''
    Object.defineProperty(globalThis, 'localStorage', {
      value: makeLocalStorageStub(),
      writable: true,
      configurable: true,
    })
    Object.defineProperty(globalThis, 'sessionStorage', {
      value: Object.assign(makeLocalStorageStub(), { getItem: () => 'w_backforward' }),
      writable: true,
      configurable: true,
    })
    __resetWindowIdForTests()
    __resetSseBus()
    const app = createApp({})
    installSseBus(app)
    __setSseBusGlobalClient(makeStubClient('open'))
    vi.spyOn(api, 'getChats').mockResolvedValue({
      sessions: [],
      has_more: false,
      next_cursor: null,
      total: 0,
    })
    vi.spyOn(api, 'getWorkspaces').mockResolvedValue({ workspaces: [] })
    vi.spyOn(api, 'getWorkspacesItems').mockResolvedValue({ items: [], count: 0 })
    vi.spyOn(api, 'getTasks').mockResolvedValue({ tasks: [], has_more: false, next_cursor: null })
    vi.spyOn(api, 'getSystemFolder').mockResolvedValue({
      path: '/',
      absolute: '/',
      home: '/',
      entries: [],
    } as never)
    vi.spyOn(api, 'getSessionWorkspaceId').mockResolvedValue(WS_ID)
    vi.spyOn(api, 'getSession').mockResolvedValue({ id: SESSION_X, cwd: '/' } as never)
    vi.spyOn(api, 'getChatHistory').mockResolvedValue({ cwd: '/' } as never)
  })

  afterEach(() => {
    __resetSseBus()
    vi.restoreAllMocks()
  })

  it('Back from a standalone chat to a board URL renders the board, not the chat', async () => {
    // Seed BEFORE mount so init() populates from the mocks.
    const ws = seedFixtureTree()
    // Boot on the chat URL (mount restore sets the chat, like a refresh).
    const { wrapper, routeState } = mountWithRoute({}, `/app/${WS_ID}/chat/${SESSION_X}`)
    await nextTick()
    await nextTick()
    const nav = useNavigationStore()
    expect(nav.activeChatId).toBe(`chat-${SESSION_X}`)
    expect(wrapper.find('[data-chat-view]').exists()).toBe(true)

    // Browser Back: URL pops to the board URL. No sidebar handler runs —
    // only the URL changes (stores stay stale, exactly like popstate).
    navigateTo(routeState, {}, `/app/${WS_ID}/projects/${BOARD_ID}`)

    // init() + the Back reconcile are async — wait for the board to
    // actually render instead of counting ticks.
    await vi.waitFor(() => {
      expect(wrapper.find('[data-kanban-view]').exists()).toBe(true)
    })
    expect(wrapper.find('[data-chat-view]').exists()).toBe(false)
    expect(nav.activeChatId).toBe('')
    expect(ws.activeWorkspaceItemId).toBe(BOARD_ID)
    wrapper.unmount()
  })

  it('Forward from a board to a chat URL renders the chat, not the chats list', async () => {
    const { wrapper, routeState } = mountWithRoute({}, `/app/${WS_ID}/projects/${BOARD_ID}`)
    await nextTick()
    await nextTick()
    const ws = useWorkspacesStore()
    const nav = useNavigationStore()
    ws.workspaces = [makeWorkspace()]
    await nextTick()
    await nextTick()
    expect(ws.activeWorkspaceItemId).toBe(BOARD_ID)
    expect(wrapper.find('[data-kanban-view]').exists()).toBe(true)

    // Browser Forward: URL goes to a standalone chat. Stores stay stale.
    navigateTo(routeState, {}, `/app/${WS_ID}/chat/${SESSION_Y}`)
    await nextTick()
    await nextTick()
    await nextTick()

    expect(nav.activeChatId).toBe(`chat-${SESSION_Y}`)
    expect(wrapper.find('[data-chat-view]').exists()).toBe(true)
    expect(wrapper.find('[data-chats-view]').exists()).toBe(false)
    expect(ws.activeWorkspaceItemId).toBe(null)
    wrapper.unmount()
  })

  it('tab mode: Back from a chat to a board URL renders the board', async () => {
    useTabsStore().setEnabled(true)
    seedFixtureTree()
    const { wrapper, routeState } = mountWithRoute({}, `/app/${WS_ID}/chat/${SESSION_X}`)
    await nextTick()
    await nextTick()
    const nav = useNavigationStore()
    expect(nav.activeChatId).toBe(`chat-${SESSION_X}`)

    navigateTo(routeState, {}, `/app/${WS_ID}/projects/${BOARD_ID}`)

    await vi.waitFor(() => {
      expect(wrapper.find('[data-kanban-view]').exists()).toBe(true)
    })
    expect(wrapper.find('[data-chat-view]').exists()).toBe(false)
    wrapper.unmount()
  })
})
