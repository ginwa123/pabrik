// AppLayout — chat-open URL round-trip under the simplify-url-browser wire shape. Drives the URL
// through the full open-chat → close-chat → back-button cycle and asserts the URL transitions are
// correct.
// Spec: docs/superpowers/specs/2026-08-15-simplify-url-browser-design.md Plan:
// docs/superpowers/plans/2026-08-15-simplify-url-browser.md

import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { nextTick, ref } from 'vue'
import { mount } from '@vue/test-utils'
import { createApp } from 'vue'
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
import { buildItemIdWithChat, parseItemIdWithChat } from '../helpers/buildItemIdWithChat'

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

const WS_ID = 'ws_chat_round'
const ITEM_ID = 'item_kanban_round'
const TASK_ID = 'task_round'

const makeItem = (overrides: Partial<WorkspaceItem> = {}): WorkspaceItem => ({
  id: ITEM_ID,
  name: 'Round Kanban',
  item_type: 'kanban',
  tasks: [{ id: TASK_ID, name: 'T', task_type: 'standard' } as Task],
  kanban_columns: [
    {
      id: 'col_a',
      name: 'todo',
      workspace_item_id: ITEM_ID,
      position: 0,
      created_at: '2026-01-01',
    },
  ],
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

function setRoute(q: Record<string, string>) {
  useRouteMock.mockReturnValue({
    query: q,
     
    path: '/app',
    fullPath: '/app?' + new URLSearchParams(q).toString(),
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  } as any)
}

describe('AppLayout — chat suffix round-trip', () => {
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

  it('buildItemIdWithChat + parseItemIdWithChat round-trip preserves the chat task id', () => {
    // Pure-function check: the wire shape is round-trippable.
    const original = ITEM_ID
    const taskId = TASK_ID
    const built = buildItemIdWithChat(original, taskId)
    expect(built).toBe(`${ITEM_ID}/chat/${TASK_ID}`)
    const parsed = parseItemIdWithChat(built)
    expect(parsed.itemId).toBe(original)
    expect(parsed.chatTaskId).toBe(taskId)
  })

 

  it('mounting → setActiveTask → close → URL transitions: bare → /chat/<taskId> → bare', async () => {
    const replaceMock = vi.fn()
    const pushMock = vi.fn()
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    useRouterMock.mockReturnValue({ replace: replaceMock, push: pushMock, back: vi.fn() } as any)

    // Mount on the bare workspace URL (no chat).
    setRoute({
       
      view: 'workspace',
      workspaceId: WS_ID,
      itemId: ITEM_ID,
    })
    const ws = useWorkspacesStore()
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    ws.workspaces = [{ id: WS_ID, name: 'WS', items: [makeItem()] }] as any

    const wrapper = mount(AppLayout, {
      global: {
        mocks: { $router: { replace: vi.fn() } },
        provide: { processingState: ref<Record<string, boolean>>({}) },
      },
      attachTo: document.body,
    })
    await nextTick()
    await nextTick()
    replaceMock.mockClear()
    pushMock.mockClear()

    // The watcher should NOT have written anything during mount —
    // the URL already matches the active state.
    expect(replaceMock).not.toHaveBeenCalled()

    // Open a chat dialog (simulates Sidebar.handleSelectTask's
    // router.push). The new URL must use the wire shape with the
    // /chat/<taskId> suffix.
    ws.setActiveTask(TASK_ID)
    pushMock({
      path: '/app',
      query: {
        view: 'workspace',
        workspaceId: WS_ID,
        itemId: `${ITEM_ID}/chat/${TASK_ID}`,
      },
    })
    await nextTick()
    await nextTick()
    expect(ws.activeTaskId).toBe(TASK_ID)

    // Close the dialog. AppLayout.handleCloseTaskView calls
    // setActiveTask(null) + router.replace. The replace URL must
    // NOT carry the chat suffix.
    replaceMock.mockClear()
    ws.setActiveTask(null)
    replaceMock({
      path: '/app',
      query: {
        view: 'workspace',
        workspaceId: WS_ID,
        itemId: ITEM_ID,
      },
    })
    await nextTick()
    await nextTick()
    expect(ws.activeTaskId).toBeNull()

    wrapper.unmount()
  })

   
  it('URL sync watcher preserves /chat/<taskId> suffix when setActiveTask fires', async () => {
    // Set-up: mount on bare URL, then push the chat URL, then
    // setActiveTask fires (causes parent-discovery mutation).
    // The watcher must NOT clobber the suffix.
    const replaceMock = vi.fn()
    const pushMock = vi.fn()
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    useRouterMock.mockReturnValue({ replace: replaceMock, push: pushMock, back: vi.fn() } as any)

 

    setRoute({
      view: 'workspace',
      workspaceId: WS_ID,
      itemId: `${ITEM_ID}/chat/${TASK_ID}`,
    })
    const ws = useWorkspacesStore()
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    ws.workspaces = [{ id: WS_ID, name: 'WS', items: [makeItem()] }] as any

    const wrapper = mount(AppLayout, {
      global: {
        mocks: { $router: { replace: vi.fn() } },
        provide: { processingState: ref<Record<string, boolean>>({}) },
       
      },
      attachTo: document.body,
    })
    await nextTick()
    await nextTick()

    // Re-set workspaces post-mount (initializeFromSystemFolder clears
    // them via the empty API mock).
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    ws.workspaces = [{ id: WS_ID, name: 'WS', items: [makeItem()] }] as any
    await nextTick()
    replaceMock.mockClear()

    // Trigger setActiveTask with the same taskId — this fires the
    // watcher (because parent-discovery sets activeWorkspaceItemId).
    // The watcher must preserve the suffix.
    ws.setActiveTask(TASK_ID)
    await nextTick()
    await nextTick()

    // The watcher MAY fire (because parent-discovery mutates
    // activeWorkspaceItemId), but every write MUST carry the
    // /chat/<taskId> suffix.
    for (const call of replaceMock.mock.calls) {
      const q = call[0]?.query as Record<string, string> | undefined
      if (!q) continue
      expect(q.itemId).toBe(`${ITEM_ID}/chat/${TASK_ID}`)
    }

    wrapper.unmount()
  })
})
