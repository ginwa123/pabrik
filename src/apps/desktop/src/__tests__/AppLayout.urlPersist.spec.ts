/**
 * Tests for AppLayout's URL → activeWorkspaceItemId persistence on
 * page reload. Before this feature, the URL `?view=workspace` was
 * preserved on reload but the active kanban/folder/design item was
 * lost (the in-memory `activeWorkspaceItemId` reset to null on every
 * page refresh). This file pins:
 *
 *   1. Sidebar's handleSelectItem emits `navigate` with
 *      (workspaceId, itemId) so the parent can mirror them into URL
 *   2. AppLayout's handleNavigate('workspace', ..., wsId, itemId)
 *      pushes the workspaceId + itemId query params alongside view
 *   3. On mount, AppLayout reads (workspaceId, itemId) from URL and
 *      restores activeWorkspaceItemId once the workspaces list loads
 *   4. A stale URL (item no longer exists) does not crash — the
 *      kanban-empty state is shown and the pending restore clears.
 *
 * Plan: feature "url browser kanban" (workspace kanban URL persistence).
 */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { createApp, nextTick } from 'vue'
import { mount } from '@vue/test-utils'

import * as api from '../api'
import { useWorkspacesStore } from '../stores/workspaces'
import { useNavigationStore } from '../stores/navigation'
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
const DESIGN_ID = 'item_design_url'
const OTHER_WS_ID = 'ws_other'
const PAGE_ID_1 = 'page_first'
const PAGE_ID_2 = 'page_second'

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

const makeDesignItem = (overrides: Partial<WorkspaceItem> = {}): WorkspaceItem => ({
  id: DESIGN_ID,
  name: 'Design Mockup',
  item_type: 'design',
  path: '/tmp/design',
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

describe('AppLayout — design item URL persistence (Chunk 3 of design-url-persistence plan)', () => {
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

  it('mounting with /app/{ws}/projects/{designId} restores the design view', async () => {
    const ws = useWorkspacesStore()
    const design = makeDesignItem()
    vi.spyOn(api, 'getWorkspaces').mockResolvedValue({
      workspaces: [{ id: WS_ID, name: 'WS', icon: '📁', expanded: true, items: [] }],
    })
    vi.spyOn(api, 'getWorkspacesItems').mockResolvedValue({ items: [design], count: 1 })
    const wrapper = mountAppLayout(
      [{ id: WS_ID, name: 'WS', icon: '📁', expanded: true, items: [design] } as Workspace],
      {},
      `/app/${WS_ID}/projects/${DESIGN_ID}`,
    )
    await vi.waitFor(() => {
      expect(ws.activeWorkspaceItemId).toBe(DESIGN_ID)
      expect(wrapper.find('[data-design-view="stub"]').exists()).toBe(true)
    })
    wrapper.unmount()
  })

  it('activeWorkspaceItem → URL watcher fires when activeWorkspaceItemId changes externally', async () => {
    const replaceMock = vi.fn()
    useRouteMock.mockReturnValue({
      query: { view: 'workspace' },

      path: '/app',

      fullPath: '/app?view=workspace',
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
    } as any)
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    useRouterMock.mockReturnValue({ replace: replaceMock, push: vi.fn() } as any)
    const ws = useWorkspacesStore()
    ws.workspaces = [
      { id: WS_ID, name: 'WS', icon: '📁', expanded: true, items: [makeDesignItem()] } as Workspace,
    ]
    const wrapper = mountAppLayout(ws.workspaces, {}, `/app/${WS_ID}`)
    await nextTick()
    await nextTick()
    // AppLayout.onMounted calls initializeFromSystemFolder() which calls init() which overwrites
    // `workspaces.value` with the (empty) API mock result. Re-set workspaces so the URL watcher's
    // lookup of activeWorkspace succeeds.
    ws.workspaces = [
      { id: WS_ID, name: 'WS', icon: '📁', expanded: true, items: [makeDesignItem()] } as Workspace,
    ]
    await nextTick()
    replaceMock.mockClear()
    // Externally set activeWorkspaceItemId — the watcher should fire
    // and call router.replace with the new URL.
    ws.setActiveWorkspaceItem(DESIGN_ID)
    await nextTick()
    await nextTick()
    expect(replaceMock).toHaveBeenCalledWith({
      path: `/app/${WS_ID}/projects/${DESIGN_ID}`,
      query: {},
    })
    wrapper.unmount()
  })

  it('activeWorkspaceItem → URL watcher does NOT overwrite the URL when the chat suffix is present', async () => {
    // SIMPLIFY-URL-BROWSER (2026-08-15): the legacy view=task shape is gone. The chat-open state is
    // encoded as /chat/<taskId> on itemId while view=workspace. The watcher's chat-suffix guard
    // MUST preserve the suffix on every write.
    const replaceMock = vi.fn()
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    useRouterMock.mockReturnValue({ replace: replaceMock, push: vi.fn() } as any)
    const ws = useWorkspacesStore()
    ws.workspaces = [
      { id: WS_ID, name: 'WS', icon: '📁', expanded: true, items: [makeDesignItem()] } as Workspace,
    ]
    // URL carries view=workspace + the chat suffix on itemId. The
    // watcher must NOT clobber the suffix when activeWorkspaceItem
    // changes underneath it.
    const wrapper = mountAppLayout(
      ws.workspaces,
      {},
      `/app/${WS_ID}/projects/${DESIGN_ID}/chat/task_xyz`,
    )
    await nextTick()
    await nextTick()
    replaceMock.mockClear()
    ws.setActiveWorkspaceItem(DESIGN_ID)
    await nextTick()
    await nextTick()
    expect(replaceMock).not.toHaveBeenCalled()
    wrapper.unmount()
  })

  // FIX (chatview-bug, task_1785726648589): when the user navigates from a design item to a kanban
  // (or folder), the store's `activeDesignPageId` is NOT reset by `setActiveWorkspaceItem` — it
  // stays whatever the design's active page was.
  // The URL watcher reads `[activeWorkspaceItemId, activeDesignPageId]` and writes the URL based on
  // both. Pre-fix, the watcher included `pageId` in the URL purely because `activeDesignPageId` was
  // truthy, without checking whether the new active item is a design.
  // The URL ended up as `?view=workspace&itemId=KANBAN_ID&pageId=DESIGN_PAGE_ID` — stale, and a
  // reload would try to restore the design page against a kanban that doesn't have pages. The fix:
  // only include `pageId` in the URL when the active item is a design.
  it('activeWorkspaceItem → URL watcher does NOT leak stale pageId when switching from design to kanban', async () => {
    const replaceMock = vi.fn()

    useRouteMock.mockReturnValue({
      query: { pageId: PAGE_ID_1 },
      path: `/app/${WS_ID}/projects/${DESIGN_ID}`,
      fullPath: `/app/${WS_ID}/projects/${DESIGN_ID}?pageId=page_first`,
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
    } as any)
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    useRouterMock.mockReturnValue({ replace: replaceMock, push: vi.fn() } as any)
    const ws = useWorkspacesStore()
    // Both design AND kanban items live in the same workspace.
    ws.workspaces = [
      {
        id: WS_ID,
        name: 'WS',
        icon: '📁',
        expanded: true,
        items: [makeDesignItem(), makeKanbanItem()],
      } as Workspace,
    ]
    const wrapper = mountAppLayout(ws.workspaces, {
      view: 'workspace',
      workspaceId: WS_ID,
      itemId: DESIGN_ID,
      pageId: PAGE_ID_1,
    })
    await nextTick()
    await nextTick()
    // AppLayout.onMounted calls initializeFromSystemFolder() which calls init() which overwrites
    // `workspaces.value` with the (empty) API mock result. Re-set workspaces so the URL watcher's
    // lookup of activeWorkspace succeeds.
    ws.workspaces = [
      {
        id: WS_ID,
        name: 'WS',
        icon: '📁',
        expanded: true,
        items: [makeDesignItem(), makeKanbanItem()],
      } as Workspace,
    ]
    await nextTick()
    replaceMock.mockClear()
    // Simulate the user clicking the kanban in the sidebar — activeWorkspaceItemId changes to the
    // kanban. The store's activeDesignPageId is STILL PAGE_ID_1 (stale, set from the previous
    // design mount) — that's the leak.
    ws.setActiveWorkspaceItem(KANBAN_ID)
    await nextTick()
    await nextTick()
    // The URL the watcher writes must NOT include pageId — the active item is a kanban, and pageId
    // is design-item-scoped. We don't care which exact call the URL-sync watcher made; any
    // router.replace after the item switch that includes a pageId would be the bug.
    const calls = replaceMock.mock.calls
    const lastCall = calls[calls.length - 1]
    expect(lastCall).toBeDefined()
    // lastCall[0] is the router.replace arg; non-null assertion is safe because
    // expect(lastCall).toBeDefined() above narrowed `lastCall` (still possibly undefined per the
    // index lookup — TS doesn't carry the toBeDefined narrowing across expressions).
    const lastArg = lastCall![0] as { path: string; query: Record<string, string> }
    expect(lastArg).toMatchObject({
      path: `/app/${WS_ID}/projects/${KANBAN_ID}`,
      query: {},
    })
    expect(lastArg.query.pageId).toBeUndefined()
    wrapper.unmount()
  })

  // FIX (chatview-bug, task_1785726648589, sibling case): same scenario as the kanban test above,
  // but the user navigates from a design to a folder. Folders don't have design pages either, so
  // the URL must NOT carry the stale pageId.
  it('activeWorkspaceItem → URL watcher does NOT leak stale pageId when switching from design to folder', async () => {
    const FOLDER_ID = 'item_folder_url'
    const makeFolderItem = (overrides: Partial<WorkspaceItem> = {}): WorkspaceItem => ({
      id: FOLDER_ID,
      name: 'Folder',
      item_type: 'folder',
      path: '/tmp/folder',
      tasks: [],

      ...overrides,
    })
    const replaceMock = vi.fn()
    useRouteMock.mockReturnValue({
      query: { pageId: PAGE_ID_1 },
      path: `/app/${WS_ID}/projects/${DESIGN_ID}`,
      fullPath: `/app/${WS_ID}/projects/${DESIGN_ID}?pageId=page_first`,
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
    } as any)
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    useRouterMock.mockReturnValue({ replace: replaceMock, push: vi.fn() } as any)
    const ws = useWorkspacesStore()
    ws.workspaces = [
      {
        id: WS_ID,
        name: 'WS',
        icon: '📁',
        expanded: true,
        items: [makeDesignItem(), makeFolderItem()],
      } as Workspace,
    ]
    const wrapper = mountAppLayout(ws.workspaces, {
      view: 'workspace',
      workspaceId: WS_ID,
      itemId: DESIGN_ID,
      pageId: PAGE_ID_1,
    })
    await nextTick()
    await nextTick()
    ws.workspaces = [
      {
        id: WS_ID,
        name: 'WS',
        icon: '📁',
        expanded: true,
        items: [makeDesignItem(), makeFolderItem()],
      } as Workspace,
    ]
    await nextTick()
    replaceMock.mockClear()
    // Simulate the user clicking the folder in the sidebar.
    ws.setActiveWorkspaceItem(FOLDER_ID)
    await nextTick()
    await nextTick()
    const calls = replaceMock.mock.calls
    const lastCall = calls[calls.length - 1]
    expect(lastCall).toBeDefined()
    const lastArg = lastCall![0] as { path: string; query: Record<string, string> }
    expect(lastArg).toMatchObject({
      path: `/app/${WS_ID}/projects/${FOLDER_ID}`,
      query: {},
    })
    expect(lastArg.query.pageId).toBeUndefined()
    wrapper.unmount()
  })

  it('handleCloseTaskView preserves workspaceId + itemId when the active task belongs to a design', async () => {
    const replaceMock = vi.fn()
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    useRouterMock.mockReturnValue({ replace: replaceMock, push: vi.fn() } as any)
    const ws = useWorkspacesStore()
    const design = makeDesignItem()
    ws.workspaces = [
      { id: WS_ID, name: 'WS', icon: '📁', expanded: true, items: [design] } as Workspace,
    ]
    const wrapper = mountAppLayout(ws.workspaces, {})
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const layout = wrapper.vm as any
    await nextTick()
    await nextTick()
    // Re-set workspaces after init() overwrites them.
    ws.workspaces = [
      { id: WS_ID, name: 'WS', icon: '📁', expanded: true, items: [design] } as Workspace,
    ]
    // Simulate the user opening a task chat on the design item, with
    // an active design page (the typical workflow — design canvas +
    // page tabs + chat panel).
    ws.setActiveWorkspaceItem(DESIGN_ID)
    ws.setActiveDesignPage(PAGE_ID_2)
    ws.setActiveTask('task_design_chat')
    await nextTick()
    await nextTick()
    replaceMock.mockClear()
    layout.handleCloseTaskView()
    expect(replaceMock).toHaveBeenCalledWith({
      path: `/app/${WS_ID}/projects/${DESIGN_ID}`,
      query: { pageId: PAGE_ID_2 },
    })

    wrapper.unmount()
  })

  it('handleCloseTaskView omits pageId when no design page is active', async () => {
    const replaceMock = vi.fn()
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    useRouterMock.mockReturnValue({ replace: replaceMock, push: vi.fn() } as any)
    const ws = useWorkspacesStore()
    ws.workspaces = [
      { id: WS_ID, name: 'WS', icon: '📁', expanded: true, items: [makeKanbanItem()] } as Workspace,
    ]
    const wrapper = mountAppLayout(ws.workspaces, {})
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const layout = wrapper.vm as any
    await nextTick()
    await nextTick()
    ws.workspaces = [
      { id: WS_ID, name: 'WS', icon: '📁', expanded: true, items: [makeKanbanItem()] } as Workspace,
    ]
    ws.setActiveWorkspaceItem(KANBAN_ID)
    ws.setActiveTask('task_kanban_chat')
    await nextTick()
    await nextTick()

    replaceMock.mockClear()
    layout.handleCloseTaskView()
    expect(replaceMock).toHaveBeenCalledWith({
      path: `/app/${WS_ID}/projects/${KANBAN_ID}`,
      query: {},
    })

    const lastQuery = replaceMock.mock.calls[replaceMock.mock.calls.length - 1]![0].query
    expect(lastQuery.pageId).toBeUndefined()
    wrapper.unmount()
  })

  it('closeGitViewer preserves workspaceId + itemId + pageId when on a design item', async () => {
    const replaceMock = vi.fn()
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    useRouterMock.mockReturnValue({ replace: replaceMock, push: vi.fn() } as any)
    const ws = useWorkspacesStore()
    ws.workspaces = [
      { id: WS_ID, name: 'WS', icon: '📁', expanded: true, items: [makeDesignItem()] } as Workspace,
    ]
    const wrapper = mountAppLayout(ws.workspaces, {})
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const layout = wrapper.vm as any
    await nextTick()
    await nextTick()
    // Re-set workspaces after init() overwrites them.
    ws.workspaces = [
      { id: WS_ID, name: 'WS', icon: '📁', expanded: true, items: [makeDesignItem()] } as Workspace,
    ]
    ws.setActiveWorkspaceItem(DESIGN_ID)
    ws.setActiveDesignPage(PAGE_ID_2)
    await nextTick()
    await nextTick()
    replaceMock.mockClear()

    layout.closeGitViewer()
    expect(replaceMock).toHaveBeenCalledWith({
      path: `/app/${WS_ID}/projects/${DESIGN_ID}`,
      query: { pageId: PAGE_ID_2 },
    })
    wrapper.unmount()
  })

  it('closeSkillViewer preserves workspaceId + itemId + pageId when on a design item', async () => {
    const replaceMock = vi.fn()
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    useRouterMock.mockReturnValue({ replace: replaceMock, push: vi.fn() } as any)
    const ws = useWorkspacesStore()
    ws.workspaces = [
      { id: WS_ID, name: 'WS', icon: '📁', expanded: true, items: [makeDesignItem()] } as Workspace,
    ]
    const wrapper = mountAppLayout(ws.workspaces, {})
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const layout = wrapper.vm as any
    await nextTick()
    await nextTick()
    // Re-set workspaces after init() overwrites them.
    ws.workspaces = [
      { id: WS_ID, name: 'WS', icon: '📁', expanded: true, items: [makeDesignItem()] } as Workspace,
    ]
    ws.setActiveWorkspaceItem(DESIGN_ID)
    ws.setActiveDesignPage(PAGE_ID_2)
    await nextTick()

    await nextTick()
    replaceMock.mockClear()
    layout.closeSkillViewer()
    expect(replaceMock).toHaveBeenCalledWith({
      path: `/app/${WS_ID}/projects/${DESIGN_ID}`,
      query: { pageId: PAGE_ID_2 },
    })
    wrapper.unmount()
  })

  it('closeCodeEditor preserves workspaceId + itemId + pageId when on a design item', async () => {
    const replaceMock = vi.fn()
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    useRouterMock.mockReturnValue({ replace: replaceMock, push: vi.fn() } as any)
    const ws = useWorkspacesStore()
    ws.workspaces = [
      { id: WS_ID, name: 'WS', icon: '📁', expanded: true, items: [makeDesignItem()] } as Workspace,
    ]
    const wrapper = mountAppLayout(ws.workspaces, {})
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const layout = wrapper.vm as any
    await nextTick()
    await nextTick()
    // Re-set workspaces after init() overwrites them.
    ws.workspaces = [
      { id: WS_ID, name: 'WS', icon: '📁', expanded: true, items: [makeDesignItem()] } as Workspace,
    ]
    ws.setActiveWorkspaceItem(DESIGN_ID)
    ws.setActiveDesignPage(PAGE_ID_2)
    await nextTick()
    await nextTick()
    replaceMock.mockClear()
    layout.closeCodeEditor()
    expect(replaceMock).toHaveBeenCalledWith({
      path: `/app/${WS_ID}/projects/${DESIGN_ID}`,
      query: { pageId: PAGE_ID_2 },
    })

    wrapper.unmount()
  })

  // ─── add-workspace-id-params plan (2026-08-06) ──────────────────
  //
  // When the user closes a git/skill/code-editor viewer while a
  // task is active (e.g. they opened a viewer from the chat
  // panel of a kanban task), the new URL must include workspaceId
  // + itemId + pageId so the kanban / design context survives the
  // navigation. Pre-fix these branches wrote `?view=task&task=X`
  // only, dropping the breadcrumb.
  it('closeGitViewer includes workspaceId + itemId when the active task belongs to a kanban (add-workspace-id-params)', async () => {
    const replaceMock = vi.fn()
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    useRouterMock.mockReturnValue({ replace: replaceMock, push: vi.fn() } as any)
    const ws = useWorkspacesStore()
    const kanban = makeKanbanItem()
    // Inject the active task into the kanban's `tasks` array so the activeTask computed can find it
    // (mirrors the workspaces store's setActiveTask auto-discovery at workspaces.ts:3366).
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    kanban.tasks = [{ id: 'task_active', name: 'Active Task' } as any]
    ws.workspaces = [
      { id: WS_ID, name: 'WS', icon: '📁', expanded: true, items: [kanban] } as Workspace,
    ]
    const wrapper = mountAppLayout(ws.workspaces, {})
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const layout = wrapper.vm as any
    await nextTick()
    await nextTick()
    ws.workspaces = [
      { id: WS_ID, name: 'WS', icon: '📁', expanded: true, items: [kanban] } as Workspace,
    ]
    ws.setActiveWorkspaceItem(KANBAN_ID)

    ws.setActiveTask('task_active')
    await nextTick()
    await nextTick()
    replaceMock.mockClear()
    layout.closeGitViewer()
    const lastCall = replaceMock.mock.calls[replaceMock.mock.calls.length - 1]
    expect(lastCall).toBeDefined()

    const lastArg = lastCall![0] as { path: string; query: Record<string, string> }
    // The close-viewer priority is: activeWorkspaceItem > activeTask
    // > chat. The user has both a kanban active AND a task active,
    // so the URL returns to the kanban project path.
    expect(lastArg.path).toBe(`/app/${WS_ID}/projects/${KANBAN_ID}`)
    // pageId must NOT leak into a kanban URL.
    expect(lastArg.query.pageId).toBeUndefined()
    wrapper.unmount()
  })

  it('closeGitViewer falls to chat branch when only the task is active (no workspace item)', async () => {
    const replaceMock = vi.fn()
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    useRouterMock.mockReturnValue({ replace: replaceMock, push: vi.fn() } as any)
    const ws = useWorkspacesStore()
    // No workspace item active — only a chat task (chat-only).
    ws.workspaces = [{ id: WS_ID, name: 'WS', icon: '📁', expanded: true, items: [] } as Workspace]
    const wrapper = mountAppLayout(ws.workspaces, {})
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const layout = wrapper.vm as any
    await nextTick()
    await nextTick()

    ws.workspaces = [{ id: WS_ID, name: 'WS', icon: '📁', expanded: true, items: [] } as Workspace]

    // activeTask.value is null because no item owns the task — activeTask computed walks the tree.
    // The branch falls through to chat since neither activeWorkspaceItem nor activeTask computed is
    // truthy. Defensive: workspaceId absent.
    ws.setActiveTask('task_chat_only')

    await nextTick()
    await nextTick()
    replaceMock.mockClear()
    layout.closeGitViewer()
    const lastCall = replaceMock.mock.calls[replaceMock.mock.calls.length - 1]
    expect(lastCall).toBeDefined()
    const lastArg = lastCall![0] as { path: string; query: Record<string, string> }
    // Falls through to the landing (no workspace item, no resolvable
    // task, no active chat to return to).
    expect(lastArg.path).toBe('/app')
    expect(lastArg.query.workspaceId).toBeUndefined()
    expect(lastArg.query.itemId).toBeUndefined()
    wrapper.unmount()
  })

  it('closeSkillViewer includes workspaceId + itemId + pageId when the active task belongs to a design', async () => {
    const replaceMock = vi.fn()
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    useRouterMock.mockReturnValue({ replace: replaceMock, push: vi.fn() } as any)
    const ws = useWorkspacesStore()
    const design = makeDesignItem()
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    design.tasks = [{ id: 'task_design_active', name: 'Design Task' } as any]
    ws.workspaces = [
      { id: WS_ID, name: 'WS', icon: '📁', expanded: true, items: [design] } as Workspace,
    ]
    const wrapper = mountAppLayout(ws.workspaces, {})
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const layout = wrapper.vm as any
    await nextTick()

    await nextTick()
    ws.workspaces = [
      { id: WS_ID, name: 'WS', icon: '📁', expanded: true, items: [design] } as Workspace,
    ]
    ws.setActiveWorkspaceItem(DESIGN_ID)
    ws.setActiveDesignPage(PAGE_ID_2)
    ws.setActiveTask('task_design_active')

    await nextTick()
    await nextTick()
    replaceMock.mockClear()
    layout.closeSkillViewer()
    const lastCall = replaceMock.mock.calls[replaceMock.mock.calls.length - 1]
    expect(lastCall).toBeDefined()
    const lastArg = lastCall![0] as { path: string; query: Record<string, string> }
    // The close-viewer priority is: activeWorkspaceItem > activeTask
    // > chat. Both the design item AND the task are active, so the
    // URL returns to the design project path (carrying the active page).
    expect(lastArg.path).toBe(`/app/${WS_ID}/projects/${DESIGN_ID}`)
    expect(lastArg.query.pageId).toBe(PAGE_ID_2)
    wrapper.unmount()
  })

  it('closeCodeEditor falls through to chat when no workspace item owns the task', async () => {
    const replaceMock = vi.fn()
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    useRouterMock.mockReturnValue({ replace: replaceMock, push: vi.fn() } as any)
    const ws = useWorkspacesStore()
    // No workspace item active — chat-only task.
    ws.workspaces = [{ id: WS_ID, name: 'WS', icon: '📁', expanded: true, items: [] } as Workspace]
    const wrapper = mountAppLayout(ws.workspaces, {})
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const layout = wrapper.vm as any
    await nextTick()
    await nextTick()
    ws.workspaces = [{ id: WS_ID, name: 'WS', icon: '📁', expanded: true, items: [] } as Workspace]
    ws.setActiveTask('task_chat_only')
    await nextTick()
    await nextTick()
    replaceMock.mockClear()
    layout.closeCodeEditor()
    const lastCall = replaceMock.mock.calls[replaceMock.mock.calls.length - 1]
    expect(lastCall).toBeDefined()
    const lastArg = lastCall![0] as { path: string; query: Record<string, string> }
    // The branch falls through to the landing (no active workspace
    // item, and `activeTask` computed returns null because no item
    // owns the task).
    expect(lastArg.path).toBe('/app')
    expect(lastArg.query.workspaceId).toBeUndefined()
    expect(lastArg.query.itemId).toBeUndefined()
    wrapper.unmount()
  })
})

describe('AppLayout — design page URL persistence (pageId in URL)', () => {
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

  it('activeDesignPage → URL watcher fires when activeDesignPageId changes externally', async () => {
    const replaceMock = vi.fn()
    useRouteMock.mockReturnValue({
      query: {},
      path: `/app/${WS_ID}/projects/${DESIGN_ID}`,
      fullPath: `/app/${WS_ID}/projects/${DESIGN_ID}`,
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
    } as any)
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    useRouterMock.mockReturnValue({ replace: replaceMock, push: vi.fn() } as any)
    const ws = useWorkspacesStore()
    ws.workspaces = [
      { id: WS_ID, name: 'WS', icon: '📁', expanded: true, items: [makeDesignItem()] } as Workspace,
    ]
    const wrapper = mountAppLayout(ws.workspaces, {}, `/app/${WS_ID}/projects/${DESIGN_ID}`)

    await nextTick()

    await nextTick()
    // Re-set workspaces after init() overwrites them.
    ws.workspaces = [
      { id: WS_ID, name: 'WS', icon: '📁', expanded: true, items: [makeDesignItem()] } as Workspace,
    ]
    await nextTick()
    replaceMock.mockClear()
    // Externally set activeDesignPageId — the watcher should fire
    // and call router.replace with the new URL including pageId.
    ws.setActiveDesignPage(PAGE_ID_2)
    await nextTick()
    await nextTick()
    expect(replaceMock).toHaveBeenCalledWith({
      path: `/app/${WS_ID}/projects/${DESIGN_ID}`,
      query: { pageId: PAGE_ID_2 },
    })
    wrapper.unmount()
  })

  it('URL mirror does NOT include pageId when activeDesignPageId is empty', async () => {
    const replaceMock = vi.fn()
    useRouteMock.mockReturnValue({
      query: { view: 'workspace' },
      path: '/app',
      fullPath: '/app?view=workspace',
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
    } as any)
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    useRouterMock.mockReturnValue({ replace: replaceMock, push: vi.fn() } as any)
    const ws = useWorkspacesStore()
    ws.workspaces = [
      { id: WS_ID, name: 'WS', icon: '📁', expanded: true, items: [makeDesignItem()] } as Workspace,
    ]
    const wrapper = mountAppLayout(ws.workspaces, {}, `/app/${WS_ID}`)
    await nextTick()
    await nextTick()
    ws.workspaces = [
      { id: WS_ID, name: 'WS', icon: '📁', expanded: true, items: [makeDesignItem()] } as Workspace,
    ]

    await nextTick()
    replaceMock.mockClear()
    // Set the active workspace item (with no pageId).
    ws.setActiveWorkspaceItem(DESIGN_ID)
    await nextTick()
    await nextTick()
    expect(replaceMock).toHaveBeenCalledWith({
      path: `/app/${WS_ID}/projects/${DESIGN_ID}`,
      query: {},
    })
    // Ensure pageId is NOT in the query.
    const calls = replaceMock.mock.calls
    const lastCall = calls[calls.length - 1]
    expect(lastCall![0].query.pageId).toBeUndefined()
    wrapper.unmount()
  })

  it('URL mirror does NOT clobber the chat suffix when activeDesignPageId changes', async () => {
    // SIMPLIFY-URL-BROWSER (2026-08-15): the chat suffix on itemId must survive every URL write by
    // the watcher. This pins the invariant: even if `setActiveDesignPage` fires (which changes
    // activeDesignPageId), the watcher's write must NOT drop the suffix from itemId.
    const replaceMock = vi.fn()
    useRouteMock.mockReturnValue({
      query: {
        view: 'workspace',
        workspaceId: WS_ID,
        itemId: `${DESIGN_ID}/chat/task_xyz`,
      },
      path: '/app',
      fullPath: `/app?view=workspace&workspaceId=${WS_ID}&itemId=${DESIGN_ID}/chat/task_xyz`,
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
    } as any)
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    useRouterMock.mockReturnValue({ replace: replaceMock, push: vi.fn() } as any)
    const ws = useWorkspacesStore()
    ws.workspaces = [
      { id: WS_ID, name: 'WS', icon: '📁', expanded: true, items: [makeDesignItem()] } as Workspace,
    ]
    const wrapper = mountAppLayout(
      ws.workspaces,
      {},
      `/app/${WS_ID}/projects/${DESIGN_ID}/chat/task_xyz`,
    )
    await nextTick()
    await nextTick()
    // AppLayout.onMounted calls initializeFromSystemFolder() which calls init() which overwrites
    // `workspaces.value` with the (empty) API mock result. Re-set workspaces so the URL watcher's
    // lookup of activeWorkspace succeeds.
    ws.workspaces = [
      { id: WS_ID, name: 'WS', icon: '📁', expanded: true, items: [makeDesignItem()] } as Workspace,
    ]
    await nextTick()
    replaceMock.mockClear()
    ws.setActiveDesignPage(PAGE_ID_1)
    await nextTick()
    await nextTick()
    // If the watcher DID fire, every write's path must still carry the chat suffix. The pre-fix
    // watcher overwrote itemId with `DESIGN_ID` (bare) on every setActiveDesignPage call, which
    // closed the chat dialog. Post-fix it preserves the suffix.
    for (const call of replaceMock.mock.calls) {
      const target = call[0] as { path: string; query: Record<string, string> }
      expect(target.path).toBe(`/app/${WS_ID}/projects/${DESIGN_ID}/chat/task_xyz`)
    }
    wrapper.unmount()
  })

  it('mounting with ?view=workspace&pageId=Z restores activeDesignPageId in the store', async () => {
    const ws = useWorkspacesStore()
    const design = makeDesignItem()
    const wrapper = mountAppLayout(
      [{ id: WS_ID, name: 'WS', icon: '📁', expanded: true, items: [design] } as Workspace],
      { view: 'workspace', workspaceId: WS_ID, itemId: DESIGN_ID, pageId: PAGE_ID_2 },
    )
    await nextTick()
    await nextTick()
    expect(ws.activeWorkspaceItemId).toBe(DESIGN_ID)
    expect(ws.activeDesignPageId).toBe(PAGE_ID_2)
    wrapper.unmount()
  })

  it('mounting without pageId does NOT auto-select any design page', async () => {
    const ws = useWorkspacesStore()
    const wrapper = mountAppLayout(
      [
        {
          id: WS_ID,
          name: 'WS',
          icon: '📁',
          expanded: true,
          items: [makeDesignItem()],
        } as Workspace,
      ],
      { view: 'workspace', workspaceId: WS_ID, itemId: DESIGN_ID },
    )
    await nextTick()
    await nextTick()
    expect(ws.activeWorkspaceItemId).toBe(DESIGN_ID)
    expect(ws.activeDesignPageId).toBe('')
    wrapper.unmount()
  })
})

describe('AppLayout — readable code-editor URLs (keep-append)', () => {
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

  it('openInCodeEditor appends a readable file param to the current route (no base64, no cwd)', async () => {
    const replaceMock = vi.fn()
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    useRouterMock.mockReturnValue({ replace: replaceMock, push: vi.fn() } as any)
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    vi.spyOn(api, 'readFileContent').mockResolvedValue({ content: 'hello' } as any)
    const ws = useWorkspacesStore()
    ws.workspaces = [
      { id: WS_ID, name: 'WS', icon: '📁', expanded: true, items: [makeDesignItem()] } as Workspace,
    ]
    const wrapper = mountAppLayout(
      ws.workspaces,
      { pageId: PAGE_ID_2 },
      `/app/${WS_ID}/projects/${DESIGN_ID}`,
    )
    await nextTick()
    await nextTick()
    replaceMock.mockClear()
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const layout = wrapper.vm as any
    await layout.openInCodeEditor({ filePath: 'src/foo.ts', cwd: '/tmp/design', line: 7 })
    expect(replaceMock).toHaveBeenCalledWith({
      path: `/app/${WS_ID}/projects/${DESIGN_ID}`,
      query: { pageId: PAGE_ID_2, view: 'code-editor', file: 'src/foo.ts', line: '7' },
    })
    const lastCall = replaceMock.mock.calls[replaceMock.mock.calls.length - 1]![0] as {
      query: Record<string, string>
    }
    expect(lastCall.query.cwd).toBeUndefined()
    wrapper.unmount()
  })

  it('closeCodeEditor strips only the editor keys on a context path', async () => {
    const replaceMock = vi.fn()
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    useRouterMock.mockReturnValue({ replace: replaceMock, push: vi.fn() } as any)
    const ws = useWorkspacesStore()
    ws.workspaces = [
      { id: WS_ID, name: 'WS', icon: '📁', expanded: true, items: [makeDesignItem()] } as Workspace,
    ]
    const wrapper = mountAppLayout(
      ws.workspaces,
      { view: 'code-editor', file: 'src/foo.ts', line: '3', pageId: PAGE_ID_2 },
      `/app/${WS_ID}/projects/${DESIGN_ID}`,
    )
    await nextTick()
    await nextTick()
    replaceMock.mockClear()
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const layout = wrapper.vm as any
    layout.closeCodeEditor()
    expect(replaceMock).toHaveBeenCalledWith({
      path: `/app/${WS_ID}/projects/${DESIGN_ID}`,
      query: { pageId: PAGE_ID_2 },
    })
    wrapper.unmount()
  })

  it('boot restores the editor from a readable chat-path link', async () => {
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    useRouterMock.mockReturnValue({ replace: vi.fn(), push: vi.fn() } as any)
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    vi.spyOn(api, 'getSession').mockResolvedValue({ cwd: '/w' } as any)
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const readMock = vi.spyOn(api, 'readFileContent').mockResolvedValue({ content: 'hi' } as any)
    const ws = useWorkspacesStore()
    ws.workspaces = [{ id: WS_ID, name: 'WS', icon: '📁', expanded: true, items: [] } as Workspace]
    const wrapper = mountAppLayout(
      ws.workspaces,
      { view: 'code-editor', file: 'notes.txt' },
      `/app/${WS_ID}/chat/sess_9`,
    )
    await vi.waitFor(() => {
      expect(readMock).toHaveBeenCalledWith('/w', 'notes.txt')
    })
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const layout = wrapper.vm as any
    expect(layout.codeEditorFile?.path).toBe('notes.txt')
    wrapper.unmount()
  })

  it('boot retries the restore when the item cwd arrives late', async () => {
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    useRouterMock.mockReturnValue({ replace: vi.fn(), push: vi.fn() } as any)
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const readMock = vi.spyOn(api, 'readFileContent').mockResolvedValue({ content: 'late' } as any)
    const ws = useWorkspacesStore()
    const kanban = makeKanbanItem({ path: '/tmp/kb' })
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    kanban.tasks = [{ id: 'task_active', name: 'Active Task' } as any]
    const wrapper = mountAppLayout(
      [],
      { view: 'code-editor', file: 'late.txt' },
      `/app/${WS_ID}/projects/${KANBAN_ID}/chat/task_active`,
    )
    await nextTick()
    await nextTick()
    // No cwd yet: explicit error state, no read attempted.
    expect(readMock).not.toHaveBeenCalled()
    // Tree + task arrive late (cold-boot race).
    ws.workspaces = [
      { id: WS_ID, name: 'WS', icon: '📁', expanded: true, items: [kanban] } as Workspace,
    ]
    ws.setActiveWorkspaceItem(KANBAN_ID)
    ws.setActiveTask('task_active')
    await vi.waitFor(() => {
      expect(readMock).toHaveBeenCalledWith('/tmp/kb', 'late.txt')
    })
    wrapper.unmount()
  })
})

describe('AppLayout — code viewer surface (the right sidebar must survive)', () => {
  // Regression: opening a file from the right-sidebar Explorer replaced the WHOLE <main> with the
  // viewer overlay, so ChatView — which owns that sidebar, the header and the composer — was never
  // mounted and the sidebar (plus its composer underneath) vanished.
  // The viewer now renders inside ChatView; the overlay is a fallback for contexts with no chat on
  // screen.
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

  it('keeps the chat (and its sidebar) as the main surface when a file is open', async () => {
    const replaceMock = vi.fn()
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    useRouterMock.mockReturnValue({ replace: replaceMock, push: vi.fn() } as any)
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    useRouteMock.mockReturnValue({ query: {}, path: '/app', fullPath: '/app' } as any)
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    vi.spyOn(api, 'getSession').mockResolvedValue({ cwd: '/w' } as any)
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    vi.spyOn(api, 'readFileContent').mockResolvedValue({ content: 'hello' } as any)

    const wrapper = mountAppLayout([], {}, '/app')
    const nav = useNavigationStore()
    nav.setActiveChat('sess_sidebar', 'Sidebar chat')
    await nextTick()
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    await (wrapper.vm as any).openInCodeEditor({ filePath: 'notes.txt', cwd: '/w' })
    await nextTick()

    // The full-surface overlay must NOT be mounted: ChatView renders the
    // file itself, so the right sidebar stays exactly where it was.
    expect(wrapper.find('[data-testid="code-viewer-overlay"]').exists()).toBe(false)
    expect(wrapper.find('chat-view-stub').exists()).toBe(true)
    wrapper.unmount()
  })

  it('still overlays the whole surface when no chat is on screen', async () => {
    const replaceMock = vi.fn()
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    useRouterMock.mockReturnValue({ replace: replaceMock, push: vi.fn() } as any)
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    useRouteMock.mockReturnValue({ query: {}, path: '/app', fullPath: '/app' } as any)
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    vi.spyOn(api, 'getSession').mockResolvedValue({ cwd: '/w' } as any)
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    vi.spyOn(api, 'readFileContent').mockResolvedValue({ content: 'hello' } as any)

    const wrapper = mountAppLayout([], {}, '/app')
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    await (wrapper.vm as any).openInCodeEditor({ filePath: 'notes.txt', cwd: '/w' })
    await nextTick()

    expect(wrapper.find('[data-testid="code-viewer-overlay"]').exists()).toBe(true)
    wrapper.unmount()
  })
})
