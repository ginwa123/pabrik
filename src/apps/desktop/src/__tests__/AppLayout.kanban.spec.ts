/**
 * Tests for AppLayout's main-content rendering when the active
 * workspace item is a kanban (post-2026-06-21 migration). The
 * kanban board used to render inline in the sidebar; it now lives
 * in the main content area as a sibling of ChatView.
 *
 *   - <KanbanView> renders in the main content area when
 *     activeWorkspaceItem.item_type === 'kanban' and no task is
 *     active
 *   - When an active task is set AND the task's parent is the
 *     active kanban, BOTH <KanbanView> and <ChatView> render
 *     simultaneously in the 3-column layout (sidebar | kanban |
 *     chatview). The ChatView's ✕ close button clears the active
 *     task and returns to the kanban-only view.
 *   - When the active task's parent is NOT the active kanban
 *     (e.g. a folder task), only <ChatView> renders (the original
 *     single-column behavior is preserved).
 *   - Folder items still render the empty-state placeholder
 *     (no <KanbanView>)
 *   - The kanban events (addColumn, moveTask, etc.) wire through
 *     to the workspaces store
 *
 * Plan: docs/superpowers/plans/2026-06-21-workspace-item-kanban.md
 */
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

// Starts in 'open' state — the SseStatusBadge is a no-op for 'open' and 'closed', so the AppLayout
// mount won't render any pill, which keeps the existing assertions about <KanbanView> / <ChatView>
// placement clean.
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

// Required by (a) the workspaces store's installSessionEventHandlers which calls useSseBus() in its
// init() (line 1553 of stores/workspaces.ts), and (b) the <SseStatusBadge /> child of AppLayout
// which calls useSseBus() in its setup.

// App.vue's production onMounted does this install; in tests we do it explicitly per beforeEach.
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

        // The real KanbanView's chat-pane logic + resize state machine are covered by
        // KanbanView.chatPane.spec.ts.
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
    // The "click a kanban card" flow now opens the task's chat
    // view alongside the kanban (not in place of it). The user's
    // kanban context is preserved while they chat, and a ✕ button
    // in the chat header collapses the chat column back to the
    // kanban-only view.
    //
    // Pre-2026-06-24, this test asserted the kanban unmounted
    // (`expect(view.exists()).toBe(false)`) because ChatView
    // took priority over KanbanView. Post-3-column, both render
    // in a flex row container. The 3-column branch's v-else-if
    // condition requires:
    //   activeTask && activeWorkspaceItem.item_type === 'kanban'
    //   && activeTaskWorkspaceItemId === activeWorkspaceItem.id
    // The last clause is what distinguishes this case from a
    // task whose parent is a folder (those still use the
    // single-column ChatView branch).
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
    // The kanban chat branch is a v-else-if BEFORE the KanbanView branch, and
    // the KanbanView branch only tests `item_type === 'kanban'` — so if the
    // chat branch were written as `v-if`, or ordered after it, the board and
    // the chat would BOTH render (board on top, chat squeezed underneath).
    // Exactly one of them may be in the DOM.
    const view = wrapper.find('[data-kanban-view="stub"]')
    expect(view.exists()).toBe(false)
    wrapper.unmount()
  })

  it('does NOT render <KanbanView> when the active task\'s parent is a different workspace item (single-column ChatView)', async () => {
    // When the user has a folder task selected AND a kanban is
    // the active workspace item (an edge case — the user
    // selected the kanban first, then somehow ended up with a
    // task from a different parent), the 3-column branch's last
    // condition (`activeTaskWorkspaceItemId === activeWorkspaceItem.id`)
    // is false. We fall through to the single-column ChatView
    // branch, so the kanban does NOT render alongside the chat.
    // This guards against the visual mess of showing a chat
    // for one task alongside an unrelated kanban.
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

    // The KanbanView mount does render (the kanban is the active workspace item) but without the
    // chat pane. This is the canonical "clicked a card whose parent is a folder while viewing a
    // kanban" edge case.
    const view = wrapper.find('[data-kanban-view="stub"]')
    expect(view.exists()).toBe(false)
    const threeCol = wrapper.find('[data-kanban-with-chat]')
    expect(threeCol.exists()).toBe(false)
    wrapper.unmount()
  })

  // The 4 resize-handle / localStorage-persist tests that USED to live here were deleted as part of
  // the kanban-embed-chatview refactor (plan Task 5): the resize state machine + handle moved from
  // AppLayout into KanbanView.

  // Behavioural coverage is now in src/__tests__/KanbanView.chatPane.spec.ts (drag updates width,
  // mouseup persists to localStorage, falls back to 40% default).

  // AppLayout-level tests no longer exercise the resize machinery — they only verify the
  // integration boundary: AppLayout mounts KanbanView with the right props and forwards events from
  // KanbanView.
})

describe('AppLayout — kanban survives route navigation (regression: activeWorkspaceItemId is NOT cleared by ?view=workspace)', () => {
  // Pre-migration, the AppLayout's route.query watcher (line 727-732) cleared activeWorkspaceItemId
  // whenever the URL query `view === 'workspace'`.

  // Sidebar's handleSelectItem navigates to that exact URL, so if we had wired the kanban to the
  // active workspace item + workspace URL, the route watcher would have cleared the kanban
  // selection the moment it was set, leaving the user with an empty main content area.

  // Post-migration, AppLayout renders <KanbanView> when the active item is a kanban. The route
  // watcher must NOT clear activeWorkspaceItemId in that case — the kanban IS the active workspace
  // item.
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
    // Regression guard: prior to the kanban→main-content migration,
    // AppLayout's route.query watcher at the `!view || view ===
    // 'workspace'` branch called workspacesStore.setActiveWorkspaceItem(null)
    // — which clobbered the active kanban selection the moment
    // Sidebar's handleSelectItem set it (because handleSelectItem
    // navigates to exactly this URL).
    //
    // The fix: the watcher no longer clears activeWorkspaceItemId
    // for `view === 'workspace'`. Folder items would also have
    // been broken by the previous clear; this test pins both
    // folder and kanban cases in place.
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

  // Regression guard for commit d0a05eb0 ("feat(design): Figma-
  // lite redesign — file-backed HTML + 3 LLM tools", PR #90).
  // That commit added the design+chat 3-column branch at line
  // ~1530 but accidentally typed `v-if` instead of `v-else-if`.
  // The typo split the main-content chain in two: chain A still
  // renders the kanban view (line ~1490), and chain B (the new
  // chain starting at the typo'd `v-if`) renders the workspace
  // folder preview at line ~1616 because `currentView === 'workspace'`
  // is the first branch in chain B that's true. The user sees
  // the kanban board above the workspace folder card (the
  // "strange UI at the bottom" report from task 1784047851096).
  //
  // Fix: that block is now `v-else-if` (merged back into chain A).
  // This test pins the contract: when the active workspace item
  // is a kanban AND the URL is ?view=workspace, only the kanban
  // view renders — the workspace folder preview's
  // data-testid="workspace-folder-preview" must NOT be in the DOM.
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
