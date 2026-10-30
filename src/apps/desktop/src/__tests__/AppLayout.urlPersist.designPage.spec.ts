/** Tests for AppLayout's URL → activeWorkspaceItemId persistence on page reload. Plan: feature "url
 * browser kanban" (workspace kanban URL persistence). */
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
