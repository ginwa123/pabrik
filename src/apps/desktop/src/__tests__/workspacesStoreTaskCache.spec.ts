/** Mutation coherence for the local-first task-list cache (plan
 * docs/superpowers/plans/2026-09-24-local-first-task-list-caching.md). */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { createApp, type App as VueApp } from 'vue'

import * as api from '../api'
import type { Task } from '../api'
import { useWorkspacesStore } from '../stores/workspaces'
import { makeLocalStorageStub } from './helpers'
import { installSseBus, __resetSseBus, __setSseBusGlobalClient } from '../helpers/sseBus'
import type { SseClient, SseState, SseStateInfo } from '../helpers/sseClient'

function makeStubClient(initial: SseState): SseClient {
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const stub: any = {
    close: vi.fn(),
    reconnect: vi.fn(),
    getState: () => stub._state,
    onStateChange: (_cb: (s: SseState, info: SseStateInfo) => void) => {
      return () => {}
    },
  }
  stub._state = initial
  return stub as SseClient
}

const wireTask = (over: Record<string, unknown> = {}) => ({
  id: 't1',
  name: 'Task one',
  workspace_item_id: 'item_1a',
  task_type: 'standard',
  created_at: '2026-09-24 10:00:00',
  updated_at: '2026-09-24 10:00:00',
  kanban_column_id: 'col_a',
  completed: false,
  ...over,
})

type Store = ReturnType<typeof useWorkspacesStore>

function seedKanbanStore(): Store {
  const ws = useWorkspacesStore()
  ws.workspaces = [
    {
      id: 'ws_1',
      name: 'ws',
      icon: '📁',
      expanded: false,
      items: [
        {
          id: 'item_1a',
          name: 'Test Kanban',
          item_type: 'kanban',
          path: '/tmp',
          kanban_columns: [
            {
              id: 'col_a',
              name: 'todo',
              workspace_item_id: 'item_1a',
              position: 0,
              created_at: '2026-01-01',
            },
            {
              id: 'col_b',
              name: 'doing',
              workspace_item_id: 'item_1a',
              position: 1,
              created_at: '2026-01-01',
            },
          ],
          tasks: [],
          // eslint-disable-next-line @typescript-eslint/no-explicit-any
        } as any,
      ],
    },
  ]
  return ws
}

function itemTasks(ws: Store) {
  return ws.workspaces[0]!.items[0]!.tasks ?? []
}

describe('useWorkspacesStore task cache — mutation coherence', () => {
  const getTasksMock = vi.fn()

  let app: VueApp

  beforeEach(() => {
    setActivePinia(createPinia())
    Object.defineProperty(globalThis, 'localStorage', {
      value: makeLocalStorageStub(),
      writable: true,
      configurable: true,
    })

    __resetSseBus()
    app = createApp({})
    installSseBus(app)
    __setSseBusGlobalClient(makeStubClient('connecting'))

    getTasksMock.mockReset()
    vi.spyOn(api, 'getTasks').mockImplementation(getTasksMock)
    vi.spyOn(api, 'getWorkspaces').mockResolvedValue({ workspaces: [] })
    vi.spyOn(api, 'getWorkspacesItems').mockResolvedValue({ items: [], count: 0 })
  })

  afterEach(() => {
    __resetSseBus()
    vi.restoreAllMocks()
  })

  // Populate the cache through the public fetch path (first page,
  // complete — has_more=false).
  async function populateCache(ws: Store, tasks: ReturnType<typeof wireTask>[]) {
    getTasksMock.mockResolvedValueOnce({ tasks, has_more: false, next_cursor: null })
    await ws.fetchKanbanTasks('ws_1', 'item_1a', 'col_a', 10, undefined, undefined)
  }

  // Wipe in-memory state, then re-fetch with the network down — the
  // repaint can only come from the local cache.
  async function offlineRepaint(ws: Store, columnId = 'col_a') {
    ws.workspaces[0]!.items[0]!.tasks = []
    getTasksMock.mockRejectedValueOnce(new Error('offline'))
    await ws.fetchKanbanTasks('ws_1', 'item_1a', columnId, 10, undefined, undefined)
  }

  it('addTask writes through so an offline repaint restores the new task', async () => {
    const ws = seedKanbanStore()
    vi.spyOn(api, 'createTask').mockResolvedValueOnce(
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      wireTask({ id: 't_new', name: 'Fresh card' }) as any,
    )

    await ws.addTask('ws_1', 'item_1a', { name: 'Fresh card', description: '' })
    expect(itemTasks(ws).map((t) => t.id)).toEqual(['t_new'])

    await offlineRepaint(ws)
    expect(itemTasks(ws).map((t) => t.id)).toEqual(['t_new'])
  })

  it('deleteTask evicts so an offline repaint stays empty', async () => {
    const ws = seedKanbanStore()
    await populateCache(ws, [wireTask()])
    expect(itemTasks(ws)).toHaveLength(1)

    vi.spyOn(api, 'deleteTask').mockResolvedValueOnce({ success: true })
    await ws.deleteTask('ws_1', 'item_1a', 't1')
    expect(itemTasks(ws)).toHaveLength(0)

    await offlineRepaint(ws)
    expect(itemTasks(ws)).toHaveLength(0)
  })

  it('moveTaskToColumn writes through so an offline repaint shows the new column', async () => {
    const ws = seedKanbanStore()
    await populateCache(ws, [wireTask()])
    vi.spyOn(api, 'moveTask').mockResolvedValueOnce(wireTask({ kanban_column_id: 'col_b' }) as Task)

    await ws.moveTaskToColumn('ws_1', 'item_1a', 't1', 'col_b', 0)

    await offlineRepaint(ws, 'col_b')
    const tasks = itemTasks(ws)
    expect(tasks.map((t) => t.id)).toEqual(['t1'])
    expect(tasks[0]!.kanban_column_id).toBe('col_b')
  })

  it('toggleTask writes through so an offline repaint shows the flipped flag', async () => {
    const ws = seedKanbanStore()
    await populateCache(ws, [wireTask({ completed: false })])
    vi.spyOn(api, 'updateTask').mockResolvedValueOnce({ success: true })

    await ws.toggleTask('ws_1', 'item_1a', 't1')
    expect(itemTasks(ws)[0]!.completed).toBe(true)

    await offlineRepaint(ws)
    expect(itemTasks(ws)[0]!.completed).toBe(true)
  })

  it('renameTask writes through so an offline repaint shows the new name', async () => {
    const ws = seedKanbanStore()
    await populateCache(ws, [wireTask({ name: 'Old name' })])
    vi.spyOn(api, 'updateTaskSimple').mockResolvedValueOnce({ success: true })

    await ws.renameTask('ws_1', 'item_1a', 't1', 'New name')

    await offlineRepaint(ws)
    expect(itemTasks(ws)[0]!.name).toBe('New name')
  })

  it('a complete revalidation drops a remotely-deleted row instead of merging it back', async () => {
    const ws = seedKanbanStore()
    await populateCache(ws, [wireTask({ id: 't1' }), wireTask({ id: 't2', name: 'Gone' })])
    expect(
      itemTasks(ws)
        .map((t) => t.id)
        .sort(),
    ).toEqual(['t1', 't2'])

    // Remote delete: the server's complete page lists only t1.
    getTasksMock.mockResolvedValueOnce({
      tasks: [wireTask({ id: 't1' })],
      has_more: false,
      next_cursor: null,
    })
    await ws.fetchKanbanTasks('ws_1', 'item_1a', 'col_a', 10, undefined, undefined)
    expect(itemTasks(ws).map((t) => t.id)).toEqual(['t1'])

    // The eviction persists — a later offline repaint stays clean too.
    await offlineRepaint(ws)
    expect(itemTasks(ws).map((t) => t.id)).toEqual(['t1'])
  })
})
