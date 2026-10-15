/**
 * Behavioural tests for `Sidebar.handleSelectTask` URL behaviour.
 *
 * Plans:
 *   - 2026-08-06-better-url-browser: click appends (not replaces) the URL.
 *   - 2026-08-06-add-workspace-id-params: task URLs include workspaceId.
 *   - 2026-08-15-simplify-url-browser: collapse view=task into the
 *     workspace URL with /chat/<taskId> suffix on itemId.
 *
 * **Bug fixed (2026-08-06):** "when click task in kanban, no need
 * replace url, but append the url browser" — clicking a kanban task
 * REPLACED the URL with `?view=task&task=X&itemId=Y`, dropping the
 * workspace + per-column sort context. After the fix, clicking a
 * kanban task PRESERVES the current URL context (workspaceId,
 * itemId, sorts, pageId) so:
 *
 *   1. The browser back button returns to the kanban URL naturally
 *      (router.push vs router.replace).
 *   2. The URL shows the user where they came from — the kanban URL
 *      with `view=task&task=X` appended on top.
 *   3. The savedSortsParam snapshot mechanism remains the fallback
 *      for cases where the user lands on the task view WITHOUT a
 *      kanban URL (e.g. deep link via bookmark) — the round-trip
 *      test in AppLayout.sortUrlRoundTrip.spec.ts still passes.
 *
 * No static-contract checks — every assertion is on the live URL
 * after a router push.
 */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { nextTick, ref, createApp } from 'vue'
import { mount } from '@vue/test-utils'

import Sidebar from '../components/shell/Sidebar.vue'
import * as api from '../api'
import { useWorkspacesStore } from '../stores/workspaces'
import { makeLocalStorageStub } from './helpers'
import {
  installSseBus,
  __resetSseBus,
  __setSseBusGlobalClient,
} from '../helpers/sseBus'
import type { SseClient } from '../helpers/sseClient'

// Local SseClient stub. Mirrors sidebarKanbanSortUrl.spec.ts:30-46.
// eslint-disable-next-line @typescript-eslint/no-explicit-any
function makeStubClient(initial: 'connecting'): any {
  return {
    state: initial,
    lastError: null,
    getState: () => initial,
    isConnected: () => false,
    onEvent: () => {},
    onError: () => {},
    onStateChange: () => () => {},
    close: () => {},
  }
}

// Stub vue-router. Sidebar calls useRouter() and useRoute() in setup —
// we replace them with mocks whose query + push/replace are
// controllable per-test. Mirrors AppLayout.sortUrlRoundTrip.spec.ts:45-59.
const { useRouteMock, useRouterMock } = vi.hoisted(() => {
  // Per-test controlled query + router stubs. These mutable refs are
  // captured by closure; each beforeEach re-initialises them.
  const routeRef = { query: {} as Record<string, string> }
  const routerStub = { replace: vi.fn(), push: vi.fn() }
  return {
    useRouteMock: vi.fn(() => routeRef),
    useRouterMock: vi.fn(() => routerStub),
    // Exported for test setup so beforeEach can re-init per-test.
    __routeRef: routeRef,
    __routerStub: routerStub,
  }
})
vi.mock('vue-router', async () => {
  const actual = await vi.importActual<typeof import('vue-router')>('vue-router')
  return {
    ...actual,
    useRouter: useRouterMock,
    useRoute: useRouteMock,
  }
})

const WS_ID = 'ws_better_url'
const ITEM_ID = 'item_kanban_better_url'
const TASK_ID = 'task_better_url'

const baseItem = {
  id: ITEM_ID,
  name: 'Better URL Test',
  item_type: 'kanban',
  path: '/tmp',
  kanban_columns: [
    { id: 'col_a', name: 'todo', workspace_item_id: ITEM_ID, position: 0, created_at: '2026-01-01' },
    { id: 'col_b', name: 'in_progress', workspace_item_id: ITEM_ID, position: 1, created_at: '2026-01-01' },
  ],
  tasks: [{ id: TASK_ID, name: 'Some Task' }],
  isLoaded: true,
  isLoading: false,
}

function mountSidebar() {
  return mount(Sidebar, {
    global: {
      mocks: { $router: { replace: vi.fn() } },
      provide: { processingState: ref<Record<string, boolean>>({}) },
    },
  })
}

describe('Sidebar.handleSelectTask — APPEND URL, not REPLACE (better-url-browser, 2026-08-06)', () => {
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
    __setSseBusGlobalClient(makeStubClient('connecting') as SseClient)
    // Silence child-component fetches.
    vi.spyOn(api, 'getChats').mockResolvedValue({
      sessions: [],
      has_more: false,
      next_cursor: null,
      total: 0,
    })
    // Reset the mock router for each test.
    useRouterMock.mockClear()
     
    // Reset route query for each test.
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    ;(useRouteMock as any).mockImplementation(() => ({
      query: {} as Record<string, string>,
      path: '/app',
      fullPath: '/app',
    }))
    // The current vi.hoisted() returns a stable mock; the implementation reads from a single
    // routeRef. We reset that ref's query here. (useRouteMock.getMockImplementation() returns the
    // closure fn that builds a fresh object each call; we want a stable one for state.)
    useRouteMock.mockImplementation(() => ({
      query: {},
      path: '/app',
      fullPath: '/app',
    }))
  })

  afterEach(() => {
    __resetSseBus()
    vi.restoreAllMocks()
  })

  function setRouteQuery(q: Record<string, string>) {
    // Re-implement useRoute to return a stable object whose query is
    // mutated by tests. Mirrors AppLayout.urlPersist.spec.ts:167-176.
    useRouteMock.mockImplementation(() => ({
      query: q,
      path: '/app',
      fullPath: '/app',
    }))
  }

  function lastPushCall() {
    // eslint-disable-next-line @typescript-eslint/no-explicit-any -- intentional escape hatch; the surrounding type is intentionally opaque.
    const router = (useRouterMock as any).getMockImplementation()()
    const pushCalls = router.push.mock.calls
    expect(pushCalls.length).toBeGreaterThan(0)
    return pushCalls[pushCalls.length - 1]![0]
  }

  it('preserves workspaceId, itemId, sorts in the new task URL (kanban → task)', async () => {
    const store = useWorkspacesStore()
    store.workspaces = [
      {
        id: WS_ID,
         
        name: 'WS',
        items: [baseItem],
      },
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    ] as any
    store.setActiveWorkspaceItem(ITEM_ID)
    setRouteQuery({
      view: 'workspace',
      workspaceId: WS_ID,
      itemId: ITEM_ID,
       
      sorts: 'col_a:updated_at:desc,col_b:updated_at:desc',
    })

    const wrapper = mountSidebar()
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const sidebar = wrapper.vm as any
    expect(typeof sidebar.selectTask).toBe('function')

    sidebar.selectTask(TASK_ID)
    await nextTick()

    const pushArg = lastPushCall()
    // PATH-BASED (2026-09-22 revamp): the task chat lives at
    // /app/{ws}/projects/{item}/chat/{task}; sorts ride in the query.
    expect(pushArg.path).toBe(`/app/${WS_ID}/projects/${ITEM_ID}/chat/${TASK_ID}`)
    expect(pushArg.query.sorts).toBe(
      'col_a:updated_at:desc,col_b:updated_at:desc',
    )

    wrapper.unmount()
  })

 

  it('uses router.push (not router.replace) so browser back works', async () => {
    const store = useWorkspacesStore()
    store.workspaces = [
      { id: WS_ID, name: 'WS', items: [baseItem] },
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    ] as any
    store.setActiveWorkspaceItem(ITEM_ID)
    setRouteQuery({
       
      view: 'workspace',
      workspaceId: WS_ID,
      itemId: ITEM_ID,
    })

 

    const wrapper = mountSidebar()
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const sidebar = wrapper.vm as any
    sidebar.selectTask(TASK_ID)
    await nextTick()

    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const router = (useRouterMock as any).getMockImplementation()()
    expect(router.push).toHaveBeenCalled()
    // Pre-fix this used router.replace, which would clobber the
    // kanban URL in the browser history. The user reported
    // "append the url browser" — push is the right primitive.
    expect(router.replace).not.toHaveBeenCalled()

    wrapper.unmount()
  })

  it('preserves pageId for design tasks (design → task)', async () => {
    const store = useWorkspacesStore()
     
    store.workspaces = [
      {
        id: WS_ID,
        name: 'WS',
        items: [
          { ...baseItem, id: 'item_design', item_type: 'design', tasks: [{ id: TASK_ID, name: 'T' }] },
        ],
      },
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    ] as any
     
    store.setActiveWorkspaceItem('item_design')
    setRouteQuery({
      view: 'workspace',
      workspaceId: WS_ID,
      itemId: 'item_design',
      pageId: 'page_first',
    })

    const wrapper = mountSidebar()
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const sidebar = wrapper.vm as any
    sidebar.selectTask(TASK_ID)
    await nextTick()

    const pushArg = lastPushCall()
    // PATH-BASED (2026-09-22 revamp)
    expect(pushArg.path).toBe(`/app/${WS_ID}/projects/item_design/chat/${TASK_ID}`)
    expect(pushArg.query.pageId).toBe('page_first')

    wrapper.unmount()
  })

  it('from a deep-link task URL, clicking another task DOES add workspaceId from the store (add-workspace-id-params, 2026-08-06)', async () => {
    const store = useWorkspacesStore()
    store.workspaces = [
      { id: WS_ID, name: 'WS', items: [baseItem] },
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    ] as any
    // The URL is a deep link — no workspaceId in route.query. The new URL MUST add workspaceId from
    // the active store state (setActiveTask auto-discovers the parent item + workspace via
    // workspacesStore.setActiveTask's parent-item lookup at workspaces.ts:3366).

    // This addresses the user's report (task_1785774094183): task URLs were missing `workspaceId`
    // and the user wanted it added so the URL bar shows the kanban / design context (share /
    // refresh / back work).
    setRouteQuery({
      view: 'workspace',
      workspaceId: WS_ID,
      itemId: `${ITEM_ID}/chat/task_older`,
    })

    const wrapper = mountSidebar()
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const sidebar = wrapper.vm as any
    sidebar.selectTask(TASK_ID)
    await nextTick()

    const pushArg = lastPushCall()
    // PATH-BASED (2026-09-22 revamp)
    expect(pushArg.path).toBe(`/app/${WS_ID}/projects/${ITEM_ID}/chat/${TASK_ID}`)
    // No sorts was in the URL before — must not be appended.
    expect(pushArg.query.sorts).toBeUndefined()

    wrapper.unmount()
  })

  it('snapshots route.query.sorts into savedSortsParam before navigating (close-restore fallback)', async () => {
    const store = useWorkspacesStore()
     
    store.workspaces = [
      { id: WS_ID, name: 'WS', items: [baseItem] },
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    ] as any
    store.setActiveWorkspaceItem(ITEM_ID)
    setRouteQuery({
      view: 'workspace',
      workspaceId: WS_ID,
      itemId: ITEM_ID,
      sorts: 'col_a:name:asc',
    })

    const wrapper = mountSidebar()
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const sidebar = wrapper.vm as any
    sidebar.selectTask(TASK_ID)
    await nextTick()

    // The snapshot is the close-restore fallback. AppLayout's
    // handleCloseTaskView reads savedSortsParam and writes it back
    // into the workspace URL on close.
    expect(store.savedSortsParam).toBe('col_a:name:asc')

     
    wrapper.unmount()
  })

  // ─── add-workspace-id-params plan (2026-08-06) ────────────────── The user reported
  // (task_1785774094183): task URLs were missing `workspaceId`.

  // These tests lock in the new contract: when the user clicks a task in kanban / design mode, the
  // new task URL MUST include workspaceId (from the active store state).

  it('writes workspaceId from the active store even when the URL breadcrumb lacks it (add-workspace-id-params, 2026-08-06)', async () => {
    const store = useWorkspacesStore()
    store.workspaces = [
      { id: WS_ID, name: 'WS', items: [baseItem] },
     
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    ] as any
    store.setActiveWorkspaceItem(ITEM_ID)
    // Simulate a URL refresh that landed the user on a task view WITHOUT workspaceId in route.query
    // — e.g. an older URL bookmark, or a code path that stripped workspaceId. The user wants the
    // URL to be repaired with workspaceId once they click a task.
    setRouteQuery({
      view: 'workspace',
      workspaceId: WS_ID,
      itemId: `${ITEM_ID}/chat/task_stale`,
    })

    const wrapper = mountSidebar()
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const sidebar = wrapper.vm as any
    sidebar.selectTask(TASK_ID)
    await nextTick()

 

    const pushArg = lastPushCall()
    // PATH-BASED (2026-09-22 revamp)
    expect(pushArg.path).toBe(`/app/${WS_ID}/projects/${ITEM_ID}/chat/${TASK_ID}`)

    wrapper.unmount()
   
  })

  it('always writes workspaceId for a kanban click (user mental model: kanban-mode task URL)', async () => {
    const store = useWorkspacesStore()
    store.workspaces = [
      { id: WS_ID, name: 'WS', items: [baseItem] },
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    ] as any
    store.setActiveWorkspaceItem(ITEM_ID)
    setRouteQuery({
      view: 'workspace',
      workspaceId: WS_ID,
      itemId: ITEM_ID,
      sorts: 'col_a:updated_at:desc',
    })

    const wrapper = mountSidebar()
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const sidebar = wrapper.vm as any
    sidebar.selectTask(TASK_ID)
    await nextTick()

    const pushArg = lastPushCall()
    // The URL should include the kanban-mode breadcrumb:
    //   /app/W/projects/K/chat/task_X?sorts=S
    // PATH-BASED (2026-09-22 revamp)
    expect(pushArg.path).toBe(`/app/${WS_ID}/projects/${ITEM_ID}/chat/${TASK_ID}`)
    expect(pushArg.query.sorts).toBe('col_a:updated_at:desc')

    wrapper.unmount()
  })

  it('writes workspaceId + itemId + pageId for a design click (user mental model: design-mode task URL)', async () => {
    const store = useWorkspacesStore()
    store.workspaces = [
       
      {
        id: WS_ID,
        name: 'WS',
        items: [
          { ...baseItem, id: 'item_design', item_type: 'design', tasks: [{ id: TASK_ID, name: 'T' }] },
        ],
      },
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    ] as any
    store.setActiveWorkspaceItem('item_design')
    // The design-mode URL pattern is ?view=workspace&workspaceId=W&itemId=K&pageId=P
    setRouteQuery({
      view: 'workspace',
      workspaceId: WS_ID,
      itemId: 'item_design',
      pageId: 'page_first',
    })

    const wrapper = mountSidebar()
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const sidebar = wrapper.vm as any
    sidebar.selectTask(TASK_ID)
    await nextTick()

    const pushArg = lastPushCall()
    // PATH-BASED (2026-09-22 revamp)
    expect(pushArg.path).toBe(`/app/${WS_ID}/projects/item_design/chat/${TASK_ID}`)
    // pageId preserved from URL (the URL is the source of truth for
    // design page state, mirrored from the store's activeDesignPageId
    // via DesignView's onMount + tab switch watcher).
    expect(pushArg.query.pageId).toBe('page_first')

    wrapper.unmount()
  })
})
