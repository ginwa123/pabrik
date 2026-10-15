/**
 * Tests for AppLayout's URL sync watcher behavior when Sidebar.handleChatsNavigate
 * fires (navigating AWAY from a workspace item to a chat session).
 *
 * Bug (user report, task_1787844892180_2, 2026-08-27):
 *   Steps to reproduce:
 *     1. Create a kanban workspace item.
 *     2. Create a task on that kanban.
 *     3. Click the task — the chat opens (its own tab), URL becomes
 *        `?view=workspace&workspaceId=X&itemId=Y/chat/task_Z`.
 *     4. Close the chat — URL becomes
 *        `?view=workspace&workspaceId=X&itemId=Y` with
 *        activeWorkspaceItemId = Y and activeTask = null.
 *     5. Click any chat session in the sidebar.
 *   Expected URL: `?view=chat&session=S`.
 *   Actual URL: `?view=workspace` (clobbered by the mirror watcher).
 *
 * Root cause: this is the inverse of task_1785959660154 (task-click URL
 * race, fixed by commit e0ac21392604). When Sidebar.handleChatsNavigate
 * fires it synchronously calls:
 *     setActiveWorkspaceItem(null)
 *     setActiveTask(null)
 *     router.replace({ path: '/app', query: { view: 'chat', session: S } })
 * The mirror watcher at AppLayout.vue:298 fires on the next microtask
 * AFTER the store mutations — but BEFORE Vue Router's URL change has
 * propagated to route.query.view. So:
 *   1. setActiveWorkspaceItem(null) → itemId becomes null.
 *   2. Watcher fires → route.query.view is still 'workspace' (from
 *      step 4 above). The guard
 *      `if (currentView !== 'workspace' && currentView !== undefined) return`
 *      does NOT return early → watcher calls router.replace with
 *      `view: 'workspace'`.
 *   3. Sidebar.handleChatsNavigate's `router.replace({view: 'chat', ...})`
 *      is queued AFTER step 2's replace — the replace wins.
 *
 * The user clicks the chat → URL stays at view=workspace → main content
 * area shows the workspace view (kanban/folder) instead of the chat.
 *
 * Two-test spec mirroring the structure of
 * AppLayout.taskClickUrlOverwrite.spec.ts:
 *   Test 1 (regression): reproduces the bug; fails before the fix.
 *   Test 2 (regression-guard): proves the mirror still works for the
 *   legitimate null → truthy transition (future keyboard shortcut /
 *   deep link path); guards against an over-broad early-return.
 *
 * Plan: docs/superpowers/plans/2026-08-27-fix-chat-click-url-overwrite.md
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

const WS_ID = 'ws_chaturl'
const FOLDER_ID = 'item_folder_chaturl'
const SESSION_ID = 'session_chat_clicked'

const makeFolderItem = (): WorkspaceItem => ({
  id: FOLDER_ID,
  name: 'kanban project',
  item_type: 'folder',
  tasks: [],
})

const makeWorkspace = (): Workspace => ({
  id: WS_ID,
  name: 'agentic coding',
  icon: '📁',
  expanded: true,
  items: [makeFolderItem()],
})

// Shared stub config — same pattern as AppLayout.taskClickUrlOverwrite.spec.ts.
const STUB_CONFIG = {
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
}

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
    global: { stubs: STUB_CONFIG },
  })
}

describe("AppLayout — Sidebar chat click does NOT get its URL overwritten by the URL sync watcher", () => {
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
    // Silence background fetches — same set as taskClickUrlOverwrite spec.
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
    // Same rationale as taskClickUrlOverwrite.spec.ts:194 — without
    // this, AppLayout's onMounted initializeFromSystemFolder hits the
    // 404 fetch stub and surfaces as an unhandled rejection.
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

  it('clicking a chat session after closing a kanban task does NOT clobber the URL to ?view=workspace (regression)', async () => {
    const replaceMock = vi.fn()
    const pushMock = vi.fn()
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    useRouterMock.mockReturnValue({ replace: replaceMock, push: pushMock } as any)

    // Steps 1–4 of the user report: arrive on the workspace view with
    // a kanban item active and no chat task open.
    const wrapper = mountAppLayout({
      view: 'workspace',
      workspaceId: WS_ID,
      itemId: FOLDER_ID,
    })
    await nextTick()
    await nextTick()
    // initializeFromSystemFolder wipes workspaces on mount (matches the
    // taskClickUrlOverwrite spec pattern); restore them so the watcher
    // can resolve activeWorkspace.
    const ws = useWorkspacesStore()
    ws.workspaces = [makeWorkspace()]
    ws.setActiveWorkspaceItem(FOLDER_ID)
    await nextTick()
    await nextTick()
    replaceMock.mockClear()
    pushMock.mockClear()

    // Step 5: simulate Sidebar.handleChatsNavigate's synchronous
    // block. It calls setActiveWorkspaceItem(null) + setActiveTask(null)
    // + router.replace({ view: 'chat', session }) in that order. The
    // router mock is a plain vi.fn() — it does not propagate to
    // route.query.view. So when the watcher fires on the next microtask,
    // route.query.view is STILL 'workspace' (from the initial mock
    // return set on line ~130), which is the exact production race.
    ws.setActiveWorkspaceItem(null)
    ws.setActiveTask(null)
    replaceMock({
      path: '/app',
      query: { view: 'chat', session: SESSION_ID },
    })
    await nextTick()
    await nextTick()

    // Assert: the mirror watcher must NOT have called router.replace with a `?view=workspace` query
    // (the bug). The destination's own router.replace({view: 'chat', session: S}) is the
    // authoritative URL update and must not be clobbered.
    const clobberCalls = replaceMock.mock.calls.filter(
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      (call: any[]) => {
        const q = call[0]?.query as Record<string, string> | undefined
        return q && q.view === 'workspace'
      },
    )
    expect(clobberCalls).toHaveLength(0)

    wrapper.unmount()

  })

  it("mirror watcher STILL mirrors when activeWorkspaceItemId goes from null to a truthy value (regression-guard for the flag-only fix)", async () => {
    const replaceMock = vi.fn()
    const pushMock = vi.fn()
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    useRouterMock.mockReturnValue({ replace: replaceMock, push: pushMock } as any)

    // Start with NO active workspace item and an empty URL — this simulates a future code path
    // (keyboard shortcut, deep link, localStorage restoration) that programmatically sets an
    // activeWorkspaceItem. The watcher MUST mirror that to the URL.
    useRouteMock.mockReturnValue({
      query: {},
      path: '/app',
      fullPath: '/app',
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
    } as any)
    const ws = useWorkspacesStore()
    ws.workspaces = [makeWorkspace()]
    const wrapper = mount(AppLayout, {
      global: { stubs: STUB_CONFIG },
    })
    await nextTick()
    await nextTick()
    // Same restore-workspaces-after-init pattern as Test 1.
    ws.workspaces = [makeWorkspace()]
    replaceMock.mockClear()
    pushMock.mockClear()

    // Programmatic setActiveWorkspaceItem (oldItemId is null → itemId
    // is FOLDER_ID, a truthy value). The watcher's mirror must fire
    // exactly once with the kanban item's id in the URL.
    ws.setActiveWorkspaceItem(FOLDER_ID)
    await nextTick()
    await nextTick()

    const mirrorCall = replaceMock.mock.calls.find(
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      (call: any[]) => call[0]?.path === `/app/${WS_ID}/projects/${FOLDER_ID}`,
    )
    expect(mirrorCall).toBeDefined()

    wrapper.unmount()
  })
})
