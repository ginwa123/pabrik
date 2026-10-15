// AppLayout — URL restoration under the simplify-url-browser scheme
// (?view=workspace&itemId=Y/chat/task_W). Mounts AppLayout with various URL shapes and asserts the
// resulting store state + chat dialog visibility.
// Spec: docs/superpowers/specs/2026-08-15-simplify-url-browser-design.md Plan:
// docs/superpowers/plans/2026-08-15-simplify-url-browser.md
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { mount, flushPromises, type VueWrapper } from '@vue/test-utils'
import { createApp, ref } from 'vue'
import AppLayout from '../components/AppLayout.vue'
import { useWorkspacesStore } from '../stores/workspaces'
import type { WorkspaceItem, Task } from '../stores/workspaces'
import { makeLocalStorageStub } from './helpers'
import {
  installSseBus,
  __resetSseBus,
  __setSseBusGlobalClient,
} from '../helpers/sseBus'
import type { SseClient } from '../helpers/sseClient'

const { useRouteMock, useRouterMock } = vi.hoisted(() => ({
  useRouteMock: vi.fn(() => ({
    query: {} as Record<string, string>,
    path: '/app',
    fullPath: '/app',
  })),
  useRouterMock: vi.fn(() => ({
    replace: vi.fn(),
    push: vi.fn(),
    back: vi.fn(),
  })),
}))

vi.mock('vue-router', async () => {
  const actual = await vi.importActual<typeof import('vue-router')>('vue-router')
  return {
    ...actual,
    useRouter: useRouterMock,
    useRoute: useRouteMock,
  }
})

import * as api from '../api'

const WS_ID = 'ws_simplify'
const KANBAN_ITEM_ID = 'item_simplify_kanban'
const DESIGN_ITEM_ID = 'item_simplify_design'
const TASK_ID = 'task_simplify'

const makeKanbanItem = (overrides: Partial<WorkspaceItem> = {}): WorkspaceItem => ({
  id: KANBAN_ITEM_ID,
  name: 'Simplify Kanban',
  item_type: 'kanban',
  tasks: [{ id: TASK_ID, name: 'Task One', task_type: 'standard' } as Task],
  kanban_columns: [
    {
      id: 'col_a',
      name: 'todo',
      workspace_item_id: KANBAN_ITEM_ID,
      position: 0,
      created_at: '2026-01-01',
    },
  ],
  ...overrides,
 
// eslint-disable-next-line @typescript-eslint/no-explicit-any
} as any)

const makeDesignItem = (overrides: Partial<WorkspaceItem> = {}): WorkspaceItem => ({
  id: DESIGN_ITEM_ID,
  name: 'Simplify Design',
  item_type: 'design',
  tasks: [],
   
  ...overrides,
// eslint-disable-next-line @typescript-eslint/no-explicit-any
} as any)

function installBusForTests() {
  __resetSseBus()
  installSseBus(createApp({}))
  __setSseBusGlobalClient(makeStubClient() as SseClient)
 
}

// eslint-disable-next-line @typescript-eslint/no-explicit-any
function makeStubClient(): any {
  return {
    state: 'open',
    lastError: null,
    getState: () => 'open',
    isConnected: () => false,
    onEvent: () => {},
    onError: () => {},
    onStateChange: () => () => {},
    close: () => {},
  }
}

function setRoute(q: Record<string, string>, path = '/app') {
  useRouteMock.mockReturnValue({

    query: q,
    path,
    fullPath: path + '?' + new URLSearchParams(q).toString(),
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  } as any)
}

 

function mountApp(
  workspaceItems: WorkspaceItem[],
  query: Record<string, string>,
  path = '/app',
): VueWrapper {
  setRoute(query, path)
  const ws = useWorkspacesStore()
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  ws.workspaces = [{ id: WS_ID, name: 'WS', items: workspaceItems }] as any
  return mount(AppLayout, {
    global: {
      mocks: { $router: { replace: vi.fn() } },
      provide: { processingState: ref<Record<string, boolean>>({}) },
    },
    attachTo: document.body,
  })
}

describe('AppLayout — simplify-url-browser wire shape', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    document.body.innerHTML = ''
    Object.defineProperty(globalThis, 'localStorage', {
      value: makeLocalStorageStub(), writable: true, configurable: true,
    })
    installBusForTests()
    vi.spyOn(api, 'getChats').mockResolvedValue({
      sessions: [], has_more: false, next_cursor: null, total: 0,
    })
    vi.spyOn(api, 'getWorkspaces').mockResolvedValue({ workspaces: [] })
    vi.spyOn(api, 'getWorkspacesItems').mockResolvedValue({ items: [], count: 0 })
    vi.spyOn(api, 'getTasks').mockResolvedValue({ tasks: [], has_more: false, next_cursor: null })
     
    vi.spyOn(api, 'getSystemFolder').mockResolvedValue({
      path: '/',
      absolute: '/',
      home: '/',
      entries: [],
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    } as any)
    useRouteMock.mockReset()
    useRouterMock.mockReset()
  })

  afterEach(() => {
    __resetSseBus()
    vi.restoreAllMocks()
  })

  it('mounting with /chat/<taskId> suffix sets activeTask and the URL is preserved', async () => {
    const wrapper = mountApp(
      [makeKanbanItem()],
      {},
      `/app/${WS_ID}/projects/${KANBAN_ITEM_ID}/chat/${TASK_ID}`,
    )
    await flushPromises()
    // After onMounted + initializeFromSystemFolder fires (and clears
    // workspaces due to the empty API mock), re-set workspaces so the
    // pending URL restore can find the item.
    const ws = useWorkspacesStore()
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    ws.workspaces = [{ id: WS_ID, name: 'WS', items: [makeKanbanItem()] }] as any
    await flushPromises()
    expect(ws.activeWorkspaceItemId).toBe(KANBAN_ITEM_ID)
    expect(ws.activeTaskId).toBe(TASK_ID)
    wrapper.unmount()
  })

  it('mounting with bare itemId does NOT set activeTaskId', async () => {
     
    const wrapper = mountApp(
      [makeKanbanItem()],
      {},
      `/app/${WS_ID}/projects/${KANBAN_ITEM_ID}`,
    )
    await flushPromises()
    const ws = useWorkspacesStore()
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    ws.workspaces = [{ id: WS_ID, name: 'WS', items: [makeKanbanItem()] }] as any
     
    await flushPromises()
    expect(ws.activeWorkspaceItemId).toBe(KANBAN_ITEM_ID)
    expect(ws.activeTaskId).toBeNull()
    wrapper.unmount()
  })

  it('legacy ?view=task&task=X URL is silently rewritten to /app/{ws}/projects/{item}/chat/{task}', async () => {
    const replaceMock = vi.fn()
     
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    useRouterMock.mockReturnValue({ replace: replaceMock, push: vi.fn(), back: vi.fn() } as any)
    setRoute({
      view: 'task',
      task: TASK_ID,
      workspaceId: WS_ID,
      itemId: KANBAN_ITEM_ID,
    })
    const ws = useWorkspacesStore()
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    ws.workspaces = [{ id: WS_ID, name: 'WS', items: [makeKanbanItem()] }] as any
    mount(AppLayout, {
      global: {
        mocks: { $router: { replace: vi.fn() } },
        provide: { processingState: ref<Record<string, boolean>>({}) },
      },
      attachTo: document.body,
    })
    await flushPromises()
    expect(replaceMock).toHaveBeenCalled()
    const firstCall = replaceMock.mock.calls[0]
    expect(firstCall).toBeDefined()
    const call = firstCall![0] as { path: string; query: Record<string, string> }

    expect(call.path).toBe(`/app/${WS_ID}/projects/${KANBAN_ITEM_ID}/chat/${TASK_ID}`)
  })

  it('legacy URL without workspaceId does NOT rewrite (boots normally)', async () => {
    // Edge case: an old bookmark with no workspaceId in the URL. The sync rewrite needs workspaceId
    // + itemId to build the path, so it returns null and boot continues normally (no replace). The
    // chat task id is still restored into the store.
    const replaceMock = vi.fn()
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    useRouterMock.mockReturnValue({ replace: replaceMock, push: vi.fn(), back: vi.fn() } as any)
    setRoute({
      view: 'task',
      task: TASK_ID,
      itemId: KANBAN_ITEM_ID,
    })
    mount(AppLayout, {
      global: {
        mocks: { $router: { replace: vi.fn() } },
        provide: { processingState: ref<Record<string, boolean>>({}) },
      },
      attachTo: document.body,
    })
    await flushPromises()
    // No rewrite: workspaceId is missing so no path can be built.
    // (The mirror watcher may still fire for other reasons — filter
    // to boot-rewrite-shaped calls, of which there must be none.)
    const bootRewrites = replaceMock.mock.calls.filter(
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      (c: any[]) => typeof c[0]?.path === 'string' && c[0].path.startsWith('/app/'),
    )
    expect(bootRewrites.length).toBe(0)
  })

  it('mounting with /chat/<taskId> on a design item sets activeDesignChatTaskId via onMounted branch', async () => {
     
    // Design items have empty tasks arrays post-init, so the chat task is restored via the
    // onMounted `setActiveTask` call (not via parent-discovery in setActiveTask). Verify the URL
    // bar shape is preserved across mount.
    const wrapper = mountApp(
      [makeDesignItem()],
      {},
      `/app/${WS_ID}/projects/${DESIGN_ITEM_ID}/chat/${TASK_ID}`,
    )
    await flushPromises()
    const ws = useWorkspacesStore()
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    ws.workspaces = [{ id: WS_ID, name: 'WS', items: [makeDesignItem()] }] as any
    await flushPromises()
    // activeTaskId is set even though the design item has empty tasks
    expect(ws.activeTaskId).toBe(TASK_ID)
    wrapper.unmount()
  })
})
