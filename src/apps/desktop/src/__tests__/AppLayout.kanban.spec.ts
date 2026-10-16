/** Tests for AppLayout's main-content rendering when the active workspace item is a kanban
 * (post-2026-06-21 migration). */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { mount } from '@vue/test-utils'
import { createApp, nextTick, reactive } from 'vue'

import * as api from '../api'
import { useWorkspacesStore } from '../stores/workspaces'
import type { Workspace, WorkspaceItem, KanbanColumn, Task } from '../stores/workspaces'
import AppLayout from '../components/AppLayout.vue'
import { makeLocalStorageStub } from './helpers'
import {
  installSseBus,
  __resetSseBus,
  __setSseBusGlobalClient,
} from '../helpers/sseBus'
import type { SseClient, SseState, SseStateInfo } from '../helpers/sseClient'

// Test-only stub SseClient. Mirrors the helper in App.spec.ts / sseBus.spec.ts (kept inline rather
// than shared to avoid coupling between spec files).
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

// Install the SSE bus singleton BEFORE mounting AppLayout.
function installBusForTests() {
  __resetSseBus()
  installSseBus(createApp({}))
  __setSseBusGlobalClient(makeStubClient('open'))
}

// AppLayout uses useRouter / useRoute. Stub the composables at module level (Options-API mocks only
// patch this.$router, not the setup-time call). The reactive route is mutated per-test to drive the
// URL-driven routes.
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

const WS_ID = 'ws_1'
const KANBAN_ID = 'item_kanban'
const FOLDER_ID = 'item_folder'
const TASK_ID = 'task_in_kanban'

const makeColumn = (overrides: Partial<KanbanColumn> = {}): KanbanColumn => ({
  id: 'col_a',
  workspace_item_id: KANBAN_ID,
  name: 'todo',
  position: 0,
  created_at: '2026-06-21 12:00:00',
  ...overrides,
})

const makeTask = (overrides: Partial<Task> = {}): Task => ({
  id: TASK_ID,
  name: 'My Task',
  ...overrides,
})

const makeKanbanItem = (overrides: Partial<WorkspaceItem> = {}): WorkspaceItem => ({
  id: KANBAN_ID,
  name: 'My Sprint',
  item_type: 'kanban',
  kanban_columns: [
    makeColumn({ id: 'col_todo', name: 'todo', position: 0 }),
    makeColumn({ id: 'col_done', name: 'done', position: 1 }),
  ],
  tasks: [],
  ...overrides,
})

const makeFolderItem = (overrides: Partial<WorkspaceItem> = {}): WorkspaceItem => ({
  id: FOLDER_ID,
  name: 'My Project',
  item_type: 'folder',
  path: '/abs/path',
  tasks: [],
  ...overrides,
})

function mountAppLayout(workspaces: Workspace[] = []) {
  const ws = useWorkspacesStore()
  // Initialize the store's `workspaces` ref directly (skip init()).
  // init() fetches from the API and is mocked below.
  ws.workspaces = workspaces
  return mount(AppLayout, {
    global: {
      stubs: {
        // Stub the heavy / unrelated children to keep the test
        // focused on main-content routing.
        Sidebar: true,
        RightSidebar: true,
        GitFileViewer: true,
        SkillDetail: true,
        ChatView: true,
        Chats: true,
        SettingsView: true,
        CodeEditor: true,
        // Stub KanbanView with the chat-pane branch + resize handle so the AppLayout-level
        // integration tests can still exercise "active task belongs to kanban → chat pane visible +
        // resize handle draggable".
        KanbanView: {
          template: `
            <div data-kanban-view="stub" :data-item-id="item.id">
              <div v-if="showChatPane" data-kanban-with-chat>
                <div data-kanban-resize-handle data-testid="kanban-resize-handle" />
                <div data-test-stub-chatview />
              </div>
            </div>
          `,
          props: ['item', 'workspaceId', 'itemId'],
          computed: {
            showChatPane() {
              const ws = useWorkspacesStore()
              return !!(ws.activeTask && ws.activeTaskWorkspaceItemId === this.item.id)
            },
          },
        },
      },
    },
  })
}

describe('AppLayout — kanban main-content rendering', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    installBusForTests()
    Object.defineProperty(globalThis, 'localStorage', {
      value: makeLocalStorageStub(),
      writable: true,
      configurable: true,
    })
    // Reset the route mock to a clean workspace default.
    useRouteMock.mockReturnValue({
      query: {} as Record<string, string>,
      path: '/app',
       
      fullPath: '/app',
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    } as any)
    // Mock workspace + chat API calls that fire-and-forget on mount.
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

  it('renders <KanbanView> in the main content area when activeWorkspaceItem is a kanban', async () => {
    const kanban = makeKanbanItem()
    const wrapper = mountAppLayout([
      { id: WS_ID, name: 'WS', icon: '📁', expanded: true, items: [kanban] } as Workspace,
    ])
    const ws = useWorkspacesStore()
    ws.setActiveWorkspaceItem(KANBAN_ID)
    await nextTick()
    // The stub <KanbanView> has data-kanban-view="stub" + a
    // data-item-id set from props.item.id. Assert the kanban
    // received the right item.
    const view = wrapper.find('[data-kanban-view="stub"]')
    expect(view.exists()).toBe(true)
    expect(view.attributes('data-item-id')).toBe(KANBAN_ID)
    wrapper.unmount()
  })

  it('does NOT render <KanbanView> for folder items (the folder branch shows the empty-state placeholder)', async () => {
    const folder = makeFolderItem()
    const wrapper = mountAppLayout([
      { id: WS_ID, name: 'WS', icon: '📁', expanded: true, items: [folder] } as Workspace,
    ])
    const ws = useWorkspacesStore()
    ws.setActiveWorkspaceItem(FOLDER_ID)
    await nextTick()
    const view = wrapper.find('[data-kanban-view="stub"]')
    expect(view.exists()).toBe(false)
    wrapper.unmount()
  })

  it('does NOT render <KanbanView> when no active workspace item is set', async () => {
    const wrapper = mountAppLayout([
      { id: WS_ID, name: 'WS', icon: '📁', expanded: true, items: [makeKanbanItem()] } as Workspace,
    ])
    await nextTick()
    const view = wrapper.find('[data-kanban-view="stub"]')
    expect(view.exists()).toBe(false)
    wrapper.unmount()
  })
})

describe('AppLayout — kanban task view (3-column layout)', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    installBusForTests()
    Object.defineProperty(globalThis, 'localStorage', {
      value: makeLocalStorageStub(),
      writable: true,
      configurable: true,
    })
    useRouteMock.mockReturnValue({
      query: {} as Record<string, string>,
       
      path: '/app',
      fullPath: '/app',
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    } as any)
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

  it('the kanban task chat REPLACES the board — <KanbanView> is not rendered alongside it', async () => {
    // The "click a kanban card" flow now opens the task's chat view alongside the kanban (not in
    // place of it). The user's kanban context is preserved while they chat, and a ✕ button in the
    // chat header collapses the chat column back to the kanban-only view.
    const kanban = makeKanbanItem({
      tasks: [makeTask({ kanban_column_id: 'col_todo' })],
    })
    // SIMPLIFY-URL-BROWSER (2026-08-15): the URL is now
    // ?view=workspace&itemId=Y/chat/task_X (the legacy view=task
    // shape has been collapsed into the workspace URL).
    const routeObj = reactive({
      query: {
        view: 'workspace',
        workspaceId: WS_ID,
        itemId: `${KANBAN_ID}/chat/${TASK_ID}`,
      } as Record<string, string>,
       
      path: '/app',
      fullPath: `/app?view=workspace&workspaceId=${WS_ID}&itemId=${KANBAN_ID}/chat/${TASK_ID}`,
    })
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    useRouteMock.mockReturnValue(routeObj as any)
    const wrapper = mountAppLayout([
      { id: WS_ID, name: 'WS', icon: '📁', expanded: true, items: [kanban] } as Workspace,
    ])
    const ws = useWorkspacesStore()
    ws.setActiveWorkspaceItem(KANBAN_ID)
    ws.setActiveTask(TASK_ID)
    await nextTick()
    // The kanban chat branch is a v-else-if BEFORE the KanbanView branch, and the KanbanView branch
    // only tests `item_type === 'kanban'`.
    const view = wrapper.find('[data-kanban-view="stub"]')
    expect(view.exists()).toBe(false)
    wrapper.unmount()
  })

  it('does NOT render <KanbanView> when the active task\'s parent is a different workspace item (single-column ChatView)', async () => {
    // When the user has a folder task selected AND a kanban is the active workspace item (an edge
    // case.
    const folder = makeFolderItem({
      id: FOLDER_ID,
      tasks: [makeTask({ id: 'task_in_folder', kanban_column_id: null })],
    })
    const kanban = makeKanbanItem({ id: KANBAN_ID }) // no tasks in this kanban
    // SIMPLIFY-URL-BROWSER (2026-08-15): the URL is now
    // ?view=workspace&itemId=Y/chat/task_X.
    const routeObj = reactive({
      query: {
        view: 'workspace',
        workspaceId: WS_ID,
        itemId: `${FOLDER_ID}/chat/task_in_folder`,
       
      } as Record<string, string>,
      path: '/app',
      fullPath: `/app?view=workspace&workspaceId=${WS_ID}&itemId=${FOLDER_ID}/chat/task_in_folder`,
    })
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    useRouteMock.mockReturnValue(routeObj as any)
    const wrapper = mountAppLayout([
      {
        id: WS_ID,
        name: 'WS',
        icon: '📁',
        expanded: true,
        items: [kanban, folder],
      } as Workspace,
    ])
    const ws = useWorkspacesStore()
    ws.setActiveWorkspaceItem(KANBAN_ID) // kanban is the active WS item
    ws.setActiveTask('task_in_folder') // ...but the active task lives in the folder
    await nextTick()
    // activeTaskWorkspaceItemId === FOLDER_ID, not KANBAN_ID. The kanban chat branch's last
    // condition (`activeTaskWorkspaceItemId === activeWorkspaceItem.id`) is false — the chat does
    // NOT mount.
    const view = wrapper.find('[data-kanban-view="stub"]')
    expect(view.exists()).toBe(false)
    const threeCol = wrapper.find('[data-kanban-with-chat]')
    expect(threeCol.exists()).toBe(false)
    wrapper.unmount()
  })

  // The 4 resize-handle / localStorage-persist tests that USED to live here were deleted as part of
  // the kanban-embed-chatview refactor (plan Task 5): the resize state machine + handle moved from
  // AppLayout into KanbanView.
})

describe('AppLayout — kanban survives route navigation (regression: activeWorkspaceItemId is NOT cleared by ?view=workspace)', () => {
  // Pre-migration, the AppLayout's route.query watcher (line 727-732) cleared activeWorkspaceItemId
  // whenever the URL query `view === 'workspace'`.
  beforeEach(() => {
    setActivePinia(createPinia())
    installBusForTests()
    Object.defineProperty(globalThis, 'localStorage', {
      value: makeLocalStorageStub(),
      writable: true,
      configurable: true,
    })
     
    // Drive AppLayout with a `?view=workspace` URL.
    useRouteMock.mockReturnValue({
      query: { view: 'workspace' } as Record<string, string>,
      path: '/app',
      fullPath: '/app?view=workspace',
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    } as any)
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

  it('when URL is ?view=workspace and activeWorkspaceItem is a kanban, the kanban renders (not the empty state)', async () => {
    // Regression guard: prior to the kanban→main-content migration, AppLayout's route.query watcher
    // at the `!view || view === 'workspace'` branch called
    // workspacesStore.setActiveWorkspaceItem(null).
    const kanban = makeKanbanItem()
    const wrapper = mountAppLayout([
      { id: WS_ID, name: 'WS', icon: '📁', expanded: true, items: [kanban] } as Workspace,
    ])
    // Set the active item AFTER mount so it doesn't race with AppLayout's onMounted →
    // initializeFromSystemFolder → init() call (which would otherwise wipe the test-injected kanban
    // from the store with the mocked-empty API response).
    const ws = useWorkspacesStore()
    ws.setActiveWorkspaceItem(KANBAN_ID)
    await nextTick()
    // currentView is 'workspace' (per the route mock) but the
    // kanban branch is checked BEFORE the workspace empty-state
    // branch in the v-else-if chain, so the kanban view wins.
    const view = wrapper.find('[data-kanban-view="stub"]')
    expect(view.exists()).toBe(true)
    wrapper.unmount()
  })

  // Regression guard for commit d0a05eb0 ("feat(design): Figma- lite redesign — file-backed HTML +
  // 3 LLM tools", PR #90). That commit added the design+chat 3-column branch at line ~1530 but
  // accidentally typed `v-if` instead of `v-else-if`.
  it('kanban renders alone — workspace folder preview is NOT in the DOM (?view=workspace + kanban active)', async () => {
    const kanban = makeKanbanItem()
    const wrapper = mountAppLayout([
      { id: WS_ID, name: 'WS', icon: '📁', expanded: true, items: [kanban] } as Workspace,
    ])
    const ws = useWorkspacesStore()
    ws.setActiveWorkspaceItem(KANBAN_ID)
    await nextTick()
    // Kanban view is rendered (sanity — passes pre-fix too).
    expect(wrapper.find('[data-kanban-view="stub"]').exists()).toBe(true)
    // THE actual regression assertion: workspace folder preview must NOT be in the DOM. Pre-fix
    // this assertion failed because the typo'd `v-if` started a second chain that also evaluated
    // `currentView === 'workspace'` to true.
    expect(wrapper.find('[data-testid="workspace-folder-preview"]').exists()).toBe(false)
    wrapper.unmount()
  })
})
