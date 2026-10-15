/**
 * Tests for AppLayout's URL sync watcher behavior when handleSelectTask
 * is invoked from Sidebar.vue.
 *
 * Bug (user report, task_1785959660154): "select task not show up"
 * Symptom: clicking a task in the sidebar doesn't navigate to the
 * task view. URL stays at `?view=workspace&workspaceId=X&itemId=Y`
 * instead of becoming `?view=task&task=Z&workspaceId=X&itemId=Y`.
 *
 * Root cause: setActiveTask(taskId) mutates activeWorkspaceItemId
 * (it auto-discovers the parent item of the task). The URL sync
 * watcher at AppLayout.vue:241 watches
 * `[activeWorkspaceItemId, activeDesignPageId]` and calls
 * `router.replace({ view: 'workspace', ... })` to keep the URL in
 * sync with the store. The watcher fires on the next microtask
 * AFTER setActiveTask synchronously mutates the store — but
 * BEFORE `router.push({ view: 'task', ... })` from
 * handleSelectTask has applied the URL change. So:
 *   1. setActiveTask mutates activeWorkspaceItemId (different value).
 *   2. Watcher fires → reads stale `route.query.view === 'workspace'`
 *      → guard `if (currentView !== 'workspace' && currentView !== undefined) return`
 *      does NOT return early → watcher calls router.replace with
 *      view=workspace.
 *   3. handleSelectTask's `router.push({ view: 'task', ... })`
 *      is queued AFTER step 2's replace — the replace wins.
 *
 * The user clicks the task → URL stays at view=workspace → main
 * content area shows the workspace view (folder/kanban) instead of
 * the task view. Task never shows up.
 *
 * This test reproduces the bug by mounting AppLayout, then calling
 * setActiveTask + simulating the router.push, and asserting that
 * the URL sync watcher did NOT clobber the URL.
 *
 * Plan: docs/superpowers/plans/2026-08-06-fix-task-url-overwrite.md
 */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { createApp, nextTick } from 'vue'
import { mount } from '@vue/test-utils'

import * as api from '../api'
import { useWorkspacesStore } from '../stores/workspaces'
import type { Workspace, WorkspaceItem } from '../stores/workspaces'
import AppLayout from '../components/AppLayout.vue'
import { makeLocalStorageStub } from './helpers'
import {
  installSseBus,
  __resetSseBus,
  __setSseBusGlobalClient,
} from '../helpers/sseBus'
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

const WS_ID = 'ws_taskurl'
const FOLDER_ID = 'item_folder_taskurl'
const TASK_ID = 'task_llls'
const OTHER_ID = 'item_other'

const makeFolderItem = (): WorkspaceItem => ({
  id: FOLDER_ID,
  name: 'config agentic ai',
  item_type: 'folder',
  tasks: [
    {
      id: TASK_ID,
      name: 'llls',
      description: '',
      task_type: 'standard',
      kanban_column_id: '',
       
      kanban_position: 0,
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    } as any,
  ],
})

const makeWorkspace = (): Workspace => ({
  id: WS_ID,
  name: 'agentic coding',
  icon: '📁',
  expanded: true,
  items: [makeFolderItem()],
})

function mountAppLayout(routeQuery: Record<string, string> = {}) {
  useRouteMock.mockReturnValue({
    query: routeQuery,
    path: '/app',
     
    fullPath:
      '/app' + (Object.keys(routeQuery).length ? `?${new URLSearchParams(routeQuery).toString()}` : ''),
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  } as any)
  const ws = useWorkspacesStore()
  ws.workspaces = [makeWorkspace()]
  return mount(AppLayout, {
    global: {
      stubs: {
        Sidebar: true,
        RightSidebar: true,
        GitFileViewer: true,
        SkillDetail: true,
        Chats: true,
        SettingsView: true,
        ChatView: true,
        CodeEditor: true,
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

describe('AppLayout — handleSelectTask does not get its URL overwritten by the URL sync watcher', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    document.body.innerHTML = ''
    Object.defineProperty(globalThis, 'localStorage', {
      value: makeLocalStorageStub(),
      writable: true,
      configurable: true,
    })
    __resetSseBus()
    const app = createApp({})
    installSseBus(app)
    __setSseBusGlobalClient(makeStubClient('open'))
    // Silence background fetches.
    vi.spyOn(api, 'getChats').mockResolvedValue({
      sessions: [],
      has_more: false,
      next_cursor: null,
      total: 0,
    })
    vi.spyOn(api, 'getWorkspaces').mockResolvedValue({
      workspaces: [],
    })
    vi.spyOn(api, 'getWorkspacesItems').mockResolvedValue({ items: [], count: 0 })
    vi.spyOn(api, 'getTasks').mockResolvedValue({
      tasks: [],
      has_more: false,
      next_cursor: null,
    })
    // Mock getSystemFolder so AppLayout's initializeFromSystemFolder path (which runs on mount)
    // doesn't hit the stubbed 404 fetch and surface as an unhandled rejection.

    // Without this mock, `api.getSystemFolder()` throws `ApiError: HTTP 404` from the global fetch
    // stub (see setup.ts) because no other code path catches the rejection. The test doesn't
    // exercise the folder picker, so a minimal empty response is sufficient.
    vi.spyOn(api, 'getSystemFolder').mockResolvedValue({
      path: '/',
      absolute: '/',
      home: '/',
      entries: [],
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
    } as any)
  })

  afterEach(() => {
    __resetSseBus()
    vi.restoreAllMocks()
  })

   
  it('clicking a task under the SAME active folder does not clobber the task URL (regression)', async () => {
    const replaceMock = vi.fn()
    const pushMock = vi.fn()
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    useRouterMock.mockReturnValue({ replace: replaceMock, push: pushMock } as any)

    // Start on view=workspace showing the folder.
    const wrapper = mountAppLayout({
      view: 'workspace',
      workspaceId: WS_ID,
      itemId: FOLDER_ID,
    })
    await nextTick()
    await nextTick()
    // AppLayout.onMounted calls initializeFromSystemFolder() which calls init() which overwrites
    // `workspaces.value` with the (empty) API mock result. Re-set workspaces so the URL watcher's
    // lookup of activeWorkspace succeeds.
    const ws = useWorkspacesStore()
    ws.workspaces = [makeWorkspace()]
    // Restore active workspace item (pendingUrlRestore would have
    // done this in real life, but the test fixture takes the
    // shortcut).
    ws.setActiveWorkspaceItem(FOLDER_ID)
    await nextTick()
    await nextTick()
    replaceMock.mockClear()
    pushMock.mockClear()

    // Simulate handleSelectTask: setActiveTask(taskId) + router.push. setActiveTask auto-discovers
    // the parent item (folder) and sets activeWorkspaceItemId = folder.id.

    // In this case the value is the SAME as the existing value, so the ref should not trigger and
    // the watcher should NOT fire. This is the regression-free path.
    ws.setActiveTask(TASK_ID)
    // Simulate handleSelectTask's router.push (the URL it would push
    // is built by buildTaskUrlQuery; here we mimic the new wire
    // shape — /chat/<taskId> suffix on itemId, view=workspace).
    pushMock({
      path: '/app',
      query: {
        view: 'workspace',
        workspaceId: WS_ID,
        itemId: `${FOLDER_ID}/chat/${TASK_ID}`,
      },
    })
    await nextTick()
    await nextTick()

    // The URL sync watcher must NOT have called replace that would clobber the chat suffix.
    // (view=workspace writes are still expected — the watcher's chat-suffix guard ensures itemId
    // stays in the /chat/<taskId> form.)
    const replaceCallsWithBareItemId = replaceMock.mock.calls.filter(
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      (call: any[]) => {
        const q = call[0]?.query as Record<string, string> | undefined
        return q && q.itemId === FOLDER_ID
      },
    )
    expect(replaceCallsWithBareItemId).toHaveLength(0)

    wrapper.unmount()
   
  })

  it('clicking a task under a DIFFERENT workspace item does not clobber the task URL (regression)', async () => {
    const replaceMock = vi.fn()
    const pushMock = vi.fn()
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    useRouterMock.mockReturnValue({ replace: replaceMock, push: pushMock } as any)

    // Start on view=workspace showing a DIFFERENT workspace item (item A). The folder (item B) is
    // expanded in the sidebar but NOT yet the active item.

    // The user clicks the task under the folder. setActiveTask will set activeWorkspaceItemId from
    // A to B — THIS IS the change that triggers the URL sync watcher.
    const OTHER_ID = 'item_other'
    useRouteMock.mockReturnValue({
      query: { view: 'workspace', workspaceId: WS_ID, itemId: OTHER_ID },
      path: '/app',
      fullPath: '/app?view=workspace&workspaceId=ws_taskurl&itemId=item_other',
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    } as any)
    const ws = useWorkspacesStore()
    ws.workspaces = [
      {
        id: WS_ID,
        name: 'agentic coding',
        icon: '📁',
        expanded: true,
        items: [
          {
            id: OTHER_ID,
            name: 'other',
            item_type: 'folder',
            tasks: [],
          },
          makeFolderItem(),
        ],
      },
    ]
    const wrapper = mount(AppLayout, {
      global: {
        stubs: {
          Sidebar: true,
          RightSidebar: true,
          GitFileViewer: true,
          SkillDetail: true,
          Chats: true,
          SettingsView: true,
          ChatView: true,
          CodeEditor: true,
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
    await nextTick()
    await nextTick()
    // Re-set workspaces after init() wiped them.
    ws.workspaces = [
      {
        id: WS_ID,
        name: 'agentic coding',
        icon: '📁',
        expanded: true,
        items: [
          { id: OTHER_ID, name: 'other', item_type: 'folder', tasks: [] },
          makeFolderItem(),
        ],
      },
    ]
    ws.setActiveWorkspaceItem(OTHER_ID)
    await nextTick()
    await nextTick()
    replaceMock.mockClear()
    pushMock.mockClear()

    // User clicks `llls` under the folder. setActiveTask will mutate activeWorkspaceItemId from
    // OTHER_ID to FOLDER_ID — a real change.

    // Mimic Sidebar's flag flip in handleSelectTask (task-url-overwrite fix, 2026-08-06): the
    // navigation flag is set BEFORE setActiveTask and cleared AFTER router.push. The AppLayout URL
    // sync watcher returns early while the flag is true.
    ws.isNavigatingToTask = true
    ws.setActiveTask(TASK_ID)
    pushMock({
      path: '/app',
      query: {
        view: 'workspace',
        workspaceId: WS_ID,
        itemId: `${FOLDER_ID}/chat/${TASK_ID}`,
      },
    })
    await nextTick()
    await nextTick()
    ws.isNavigatingToTask = false

 

    // The URL sync watcher must NOT have clobbered the URL with view=workspace pointing at OTHER_ID
    // (the pre-click active item). That was the bug: the watcher fired before router.push applied,
    // read stale URL, called router.replace({ view: 'workspace', itemId: OTHER_ID }).
    const replaceCallsWithViewWorkspace = replaceMock.mock.calls.filter(
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      (call: any[]) => call[0]?.query?.view === 'workspace',
    )
     
    expect(replaceCallsWithViewWorkspace).toHaveLength(0)

    wrapper.unmount()
  })

  it('URL sync watcher DOES overwrite when navigation flag is NOT set (regression-guard for the flag-only fix)', async () => {
     
    const replaceMock = vi.fn()
    const pushMock = vi.fn()
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    useRouterMock.mockReturnValue({ replace: replaceMock, push: pushMock } as any)

    useRouteMock.mockReturnValue({
      query: { view: 'workspace', workspaceId: WS_ID, itemId: OTHER_ID },
      path: '/app',
      fullPath: '/app?view=workspace&workspaceId=ws_taskurl&itemId=item_other',
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    } as any)
    const ws = useWorkspacesStore()
    ws.workspaces = [
      {
        id: WS_ID,
        name: 'agentic coding',
        icon: '📁',
        expanded: true,
        items: [
          { id: OTHER_ID, name: 'other', item_type: 'folder', tasks: [] },
          makeFolderItem(),
        ],
      },
    ]
    const wrapper = mount(AppLayout, {
      global: {
        stubs: {
          Sidebar: true,
          RightSidebar: true,
          GitFileViewer: true,
          SkillDetail: true,
          Chats: true,
          SettingsView: true,
          ChatView: true,
          CodeEditor: true,
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
    await nextTick()
    await nextTick()
    ws.workspaces = [
      {
        id: WS_ID,
        name: 'agentic coding',
        icon: '📁',
        expanded: true,
        items: [
          { id: OTHER_ID, name: 'other', item_type: 'folder', tasks: [] },
          makeFolderItem(),
        ],
      },
    ]
    ws.setActiveWorkspaceItem(OTHER_ID)
    await nextTick()
    await nextTick()
    replaceMock.mockClear()
    pushMock.mockClear()

 

    // The flag is NOT set (we're simulating a buggy caller that forgot to flip it). The watcher
    // SHOULD overwrite the URL — the flag is the only guard, and it's intentionally conservative
    // (no flag → URL gets synced normally).
    ws.setActiveTask(TASK_ID)
    await nextTick()
    await nextTick()

    const replaceCallsWithWorkspacePath = replaceMock.mock.calls.filter(
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      (call: any[]) =>
        typeof call[0]?.path === 'string' && call[0].path.startsWith('/app/'),
    )
    expect(replaceCallsWithWorkspacePath.length).toBeGreaterThan(0)

    wrapper.unmount()
  })
})