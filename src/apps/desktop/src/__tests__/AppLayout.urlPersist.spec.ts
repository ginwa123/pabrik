/** Tests for AppLayout's URL → activeWorkspaceItemId persistence on page reload. Plan: feature "url
 * browser kanban" (workspace kanban URL persistence). */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { createApp, nextTick } from 'vue'
import { mount } from '@vue/test-utils'
import * as api from '../api'
import { useWorkspacesStore } from '../stores/workspaces'
import type { Workspace, WorkspaceItem, KanbanColumn } from '../stores/workspaces'
import AppLayout from '../components/AppLayout.vue'
import { makeLocalStorageStub } from './helpers'
import { installSseBus, __resetSseBus, __setSseBusGlobalClient } from '../helpers/sseBus'
import type { SseClient, SseState, SseStateInfo } from '../helpers/sseClient'

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

function installBusForTests() {
  __resetSseBus()
  installSseBus(createApp({}))
  __setSseBusGlobalClient(makeStubClient('open'))
}

const { useRouteMock, useRouterMock } = vi.hoisted(() => ({
  useRouteMock: vi.fn(() => ({
    query: {} as Record<string, string>,
    path: '/app',
    fullPath: '/app',
  })),
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

const WS_ID = 'ws_test'

const KANBAN_ID = 'item_kanban_url'

const OTHER_WS_ID = 'ws_other'

const makeColumn = (overrides: Partial<KanbanColumn> = {}): KanbanColumn => ({
  id: 'col_test',
  workspace_item_id: KANBAN_ID,
  name: 'todo',
  position: 0,
  created_at: '2026-07-16 12:00:00',
  ...overrides,
})

const makeKanbanItem = (overrides: Partial<WorkspaceItem> = {}): WorkspaceItem => ({
  id: KANBAN_ID,
  name: 'Sprint Backlog',
  item_type: 'kanban',
  kanban_columns: [
    makeColumn({ id: 'col_todo', name: 'todo', position: 0 }),
    makeColumn({ id: 'col_inprogress', name: 'in progress', position: 1 }),
  ],
  tasks: [],
  ...overrides,
})

function mountAppLayout(
  workspaces: Workspace[] = [],
  routeQuery: Record<string, string> = {},
  routePath = '/app',
) {
  useRouteMock.mockReturnValue({
    query: routeQuery,
    path: routePath,

    fullPath:
      routePath +
      (Object.keys(routeQuery).length ? `?${new URLSearchParams(routeQuery).toString()}` : ''),
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
  } as any)
  const ws = useWorkspacesStore()
  ws.workspaces = workspaces
  return mount(AppLayout, {
    global: {
      stubs: {
        // Stub Sidebar so it doesn't try to render / fetch data
        Sidebar: true,
        RightSidebar: true,
        GitFileViewer: true,
        SkillDetail: true,
        Chats: true,
        SettingsView: true,
        ChatView: true,
        CodeViewerStage: true,
        KanbanView: {
          template: '<div data-kanban-view="stub" :data-item-id="item.id" />',
          props: ['item', 'workspaceId', 'itemId'],
        },
        DesignView: {
          template: '<div data-design-view="stub" :data-item-id="item.id" />',
          props: ['item', 'workspaceId', 'itemId'],
        },
      },
    },
  })
}

describe('AppLayout — page reload of /app/{ws}/projects/{item} restores the active item', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    installBusForTests()
    Object.defineProperty(globalThis, 'localStorage', {
      value: makeLocalStorageStub(),
      writable: true,
      configurable: true,
    })
    vi.spyOn(api, 'getWorkspaces').mockResolvedValue({ workspaces: [] })
    vi.spyOn(api, 'getWorkspacesItems').mockResolvedValue({ items: [], count: 0 })
    vi.spyOn(api, 'getTasks').mockResolvedValue({ tasks: [], has_more: false, next_cursor: null })
    vi.spyOn(api, 'getSystemFolder').mockResolvedValue({
      entries: [],
      path: '/',
      absolute: '/',
      home: '/',
    })
    vi.spyOn(api, 'listKanbanColumns').mockResolvedValue({ columns: [], count: 0 })
  })

  afterEach(() => {
    vi.restoreAllMocks()
  })

  it('mounting with /app/{ws}/projects/{item} in the URL restores activeWorkspaceItemId', async () => {
    const ws = useWorkspacesStore()
    const kanban = makeKanbanItem()
    // The API mocks return the workspace + its items so init()
    // populates the tree instead of wiping the seeded fixtures.
    vi.spyOn(api, 'getWorkspaces').mockResolvedValue({
      workspaces: [{ id: WS_ID, name: 'WS', icon: '📁', expanded: true, items: [] }],
    })
    vi.spyOn(api, 'getWorkspacesItems').mockResolvedValue({ items: [kanban], count: 1 })
    const wrapper = mountAppLayout(
      [{ id: WS_ID, name: 'WS', icon: '📁', expanded: true, items: [kanban] } as Workspace],
      {},
      `/app/${WS_ID}/projects/${KANBAN_ID}`,
    )
    // The restore watcher fires on mount (seeded fixtures) and again after init() loads the items
    // from the API mocks. init() is async (workspace list → items → columns), so wait for the
    // kanban view to actually render instead of counting ticks.
    await vi.waitFor(() => {
      expect(ws.activeWorkspaceItemId).toBe(KANBAN_ID)
      expect(wrapper.find('[data-kanban-view="stub"]').exists()).toBe(true)
    })
    wrapper.unmount()
  })

  it('stale URL (item no longer exists) is ignored — no crash, activeWorkspaceItemId stays null', async () => {
    const ws = useWorkspacesStore()
    const otherKanban = makeKanbanItem({ id: 'item_other_kanban' })
    const wrapper = mountAppLayout(
      [
        {
          id: OTHER_WS_ID,
          name: 'WS',
          icon: '📁',
          expanded: true,
          items: [otherKanban],
        } as Workspace,
      ],
      // URL refers to an item that's NOT in the workspaces list:
      { view: 'workspace', workspaceId: WS_ID, itemId: KANBAN_ID },
    )
    await nextTick()
    await nextTick()
    // The pending restore watcher should detect the mismatch and clear
    // itself, leaving activeWorkspaceItemId null.
    expect(ws.activeWorkspaceItemId).toBeNull()
    // The kanban view should NOT render — there's no active item.
    const view = wrapper.find('[data-kanban-view="stub"]')
    expect(view.exists()).toBe(false)
    wrapper.unmount()
  })

  it('loads the workspace selected by a project deep link instead of the persisted workspace', async () => {
    const ws = useWorkspacesStore()
    const agent = {
      id: 'item_agent_url',
      name: 'Agent settings',
      item_type: 'agent',
      path: '/tmp/agent',
      tasks: [],
    } as WorkspaceItem
    vi.spyOn(api, 'getWorkspaces').mockResolvedValue({
      workspaces: [
        { id: OTHER_WS_ID, name: 'Other', icon: '📁', expanded: true, items: [] },
        { id: WS_ID, name: 'WS', icon: '📁', expanded: true, items: [] },
      ],
    })
    vi.spyOn(api, 'getWorkspacesItems').mockImplementation(async (workspaceId: string) => ({
      items: workspaceId === WS_ID ? [agent] : [],
      count: workspaceId === WS_ID ? 1 : 0,
    }))
    const localStorageStub = makeLocalStorageStub()
    localStorageStub.setItem('pabrik-active-workspace', OTHER_WS_ID)
    Object.defineProperty(globalThis, 'localStorage', {
      value: localStorageStub,
      writable: true,
      configurable: true,
    })

    const wrapper = mountAppLayout(
      [
        { id: OTHER_WS_ID, name: 'Other', icon: '📁', expanded: true, items: [] },
        { id: WS_ID, name: 'WS', icon: '📁', expanded: true, items: [agent] },
      ] as Workspace[],
      {},
      `/app/${WS_ID}/projects/${agent.id}`,
    )

    await vi.waitFor(() => {
      expect(ws.activeWorkspaceId).toBe(WS_ID)
      expect(ws.activeWorkspaceItemId).toBe(agent.id)
    })
    wrapper.unmount()
  })

  it('mounting with no URL params does NOT auto-select any workspace item', async () => {
    const ws = useWorkspacesStore()
    const wrapper = mountAppLayout(
      [
        {
          id: WS_ID,
          name: 'WS',
          icon: '📁',
          expanded: true,
          items: [makeKanbanItem()],
        } as Workspace,
      ],
      {},
    )
    await nextTick()
    await nextTick()
    expect(ws.activeWorkspaceItemId).toBeNull()
    const view = wrapper.find('[data-kanban-view="stub"]')
    expect(view.exists()).toBe(false)
    wrapper.unmount()
  })
})
