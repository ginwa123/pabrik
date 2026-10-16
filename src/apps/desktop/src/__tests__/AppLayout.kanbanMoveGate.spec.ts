/**
 * AppLayout kanban move gate: a 409 opens the "Move anyway" confirm, confirming retries with force === true, cancelling changes nothing.
 */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { mount, flushPromises } from '@vue/test-utils'
import { createApp, nextTick } from 'vue'

import * as api from '../api'
import { ApiError } from '../api'
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
  return { ...actual, useRouter: useRouterMock, useRoute: useRouteMock }
})

const WS_ID = 'ws_1'
const KANBAN_ID = 'item_kanban'

const makeColumn = (overrides: Partial<KanbanColumn> = {}): KanbanColumn => ({
  id: 'col_a',
  workspace_item_id: KANBAN_ID,
  name: 'todo',
  position: 0,
  created_at: '2026-06-21 12:00:00',
  ...overrides,
})

const BLOCKERS = [
  { task_id: 'task_dep', name: 'Fix login', column_id: 'col_a', column_name: 'todo' },
]

function mountAppLayout(workspaces: Workspace[] = []) {
  const ws = useWorkspacesStore()
  ws.workspaces = workspaces
  return mount(AppLayout, {
    attachTo: document.body,
    global: {
      stubs: {
        Sidebar: true,
        RightSidebar: true,
        GitFileViewer: true,
        SkillDetail: true,
        ChatView: true,
        Chats: true,
        SettingsView: true,
        CodeEditor: true,
        // Emitting stub: a button that fires the move-task event
        // the real KanbanView would emit on drop.
        KanbanView: {
          template: `
            <div data-kanban-view="stub">
              <button
                data-testid="stub-move"
                @click="$emit('moveTask', { taskId: 'task_1', columnId: 'col_b', position: 0 })"
              >move</button>
            </div>
          `,
          props: ['item', 'workspaceId', 'itemId'],
        },
      },
    },
  })
}

function kanbanWithTask(): WorkspaceItem {
  return {
    id: KANBAN_ID,
    name: 'My Sprint',
    item_type: 'kanban',
    kanban_columns: [
      makeColumn({ id: 'col_a', name: 'todo', position: 0 }),
      makeColumn({ id: 'col_b', name: 'done', position: 1 }),
    ],
    tasks: [{ id: 'task_1', name: 'My Task', kanban_column_id: 'col_a' } as Task],
  }
}

function confirmButton(): HTMLElement | null {
  const btns = Array.from(document.body.querySelectorAll('button'))
  return (btns.find((b) => b.textContent?.includes('Move anyway')) as HTMLElement) ?? null
}

function cancelButton(): HTMLElement | null {
  const btns = Array.from(document.body.querySelectorAll('button'))
  return (btns.find((b) => b.textContent?.trim() === 'Cancel') as HTMLElement) ?? null
}

describe('AppLayout — kanban move gate', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    installBusForTests()
    document.body.innerHTML = ''
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
    document.body.innerHTML = ''
    vi.restoreAllMocks()
  })

  async function openBoard() {
    const wrapper = mountAppLayout([])
    // Let AppLayout's boot init() settle first: it re-fetches (mocked to []) and would wipe a
    // tree seeded before mount, while a re-seed after it is stable.
    await flushPromises()
    const ws = useWorkspacesStore()
    ws.workspaces = [
      { id: WS_ID, name: 'WS', icon: '📁', expanded: true, items: [kanbanWithTask()] } as Workspace,
    ]
    ws.setActiveWorkspaceItem(KANBAN_ID)
    await nextTick()
    return wrapper
  }

  function reject409Once() {
    vi.spyOn(api, 'moveTask').mockRejectedValueOnce(
      new ApiError(
        409,
        'Conflict',
        JSON.stringify({ error: 'Task is blocked by incomplete dependency tasks', blockers: BLOCKERS }),
      ),
    )
  }

  it('a 409 surfaces the confirm dialog naming the blockers', async () => {
    reject409Once()
    const wrapper = await openBoard()
    await wrapper.find('[data-testid="stub-move"]').trigger('click')
    await flushPromises()
    expect(document.body.textContent).toContain('Fix login')
    expect(document.body.textContent).toContain('Move anyway')
    wrapper.unmount()
  })

  it('confirming retries with force === true and lands the move', async () => {
    reject409Once()
    const moveSpy = vi.mocked(api.moveTask)
    moveSpy.mockResolvedValueOnce({ id: 'task_1', kanban_column_id: 'col_b' } as Task)
    const wrapper = await openBoard()
    await wrapper.find('[data-testid="stub-move"]').trigger('click')
    await flushPromises()
    confirmButton()?.click()
    await flushPromises()
    expect(moveSpy).toHaveBeenCalledTimes(2)
    expect(moveSpy.mock.calls[1]).toEqual(['ws_1', KANBAN_ID, 'task_1', 'col_b', 0, true])
    const task = useWorkspacesStore().workspaces[0]?.items[0]?.tasks?.[0]
    expect(task?.kanban_column_id).toBe('col_b')
    wrapper.unmount()
  })

  it('cancelling leaves the store task in its original column', async () => {
    reject409Once()
    const moveSpy = vi.mocked(api.moveTask)
    const wrapper = await openBoard()
    await wrapper.find('[data-testid="stub-move"]').trigger('click')
    await flushPromises()
    cancelButton()?.click()
    await flushPromises()
    expect(moveSpy).toHaveBeenCalledTimes(1)
    const task = useWorkspacesStore().workspaces[0]?.items[0]?.tasks?.[0]
    expect(task?.kanban_column_id).toBe('col_a')
    wrapper.unmount()
  })
})
