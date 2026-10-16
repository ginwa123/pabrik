/** Regression for frontend double-task bug (task_1788811916878_4): same task id visible in 2
 * columns until refresh. */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import * as api from '../api'
import { useWorkspacesStore } from '../stores/workspaces'
import { makeLocalStorageStub } from './helpers'

const baseItem = {
  id: 'item_1',
  name: 'Board',
  item_type: 'kanban',
  kanban_columns: [
    { id: 'colA', name: 'in progress', workspace_item_id: 'item_1', position: 0, created_at: '2026-01-01' },
    { id: 'colB', name: 'done', workspace_item_id: 'item_1', position: 1, created_at: '2026-01-01' },
  ],
}

function seedWithStaleCopy() {
  const store = useWorkspacesStore()
  store.workspaces = [
    {
      id: 'ws_1',
      name: 'WS',
      icon: '📁',
      expanded: true,
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      items: [{ ...baseItem, tasks: [{ id: 'task_1', name: 'impleme...', kanban_column_id: 'colA', kanban_position: 0 }] } as any],
    },
  ]
  return store
}

describe('fetchKanbanTasks — id dedup (double-task regression)', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    Object.defineProperty(globalThis, 'localStorage', {
      value: makeLocalStorageStub(),
      writable: true,
      configurable: true,
    })
  })

  afterEach(() => {
    vi.restoreAllMocks()
  })

  it('dest refetch evicts stale source copy with same id (mirror-miss)', async () => {
    const store = seedWithStaleCopy()
    // Server moved task_1 colA -> colB. Local still has stale colA copy
    // (mirror missed). Dest refetch returns the fresh colB copy.
    vi.spyOn(api, 'getTasks').mockResolvedValue({
      tasks: [{ id: 'task_1', name: 'impleme...', kanban_column_id: 'colB', kanban_position: 0 }],
      has_more: false,
      next_cursor: null,
    })

    await store.fetchKanbanTasks('ws_1', 'item_1', 'colB', 100)

    const tasks = store.workspaces[0]!.items[0]!.tasks!
    expect(tasks.filter((t) => t.id === 'task_1')).toHaveLength(1)
    expect(tasks.filter((t) => t.kanban_column_id === 'colA')).toHaveLength(0)
    expect(tasks.filter((t) => t.kanban_column_id === 'colB')).toHaveLength(1)
  })

  it('parallel race: two columns returning same id collapses to one copy', async () => {
    const store = seedWithStaleCopy()
    // Simulate fetch colA (stale, still has task) resolving AFTER fetch colB.
    // After both land there must be exactly one copy.
    vi.spyOn(api, 'getTasks').mockImplementation(async (ws, item, _l, _c, _s, _d, columnId) => {
      if (columnId === 'colB') {
        return { tasks: [{ id: 'task_1', name: 'x', kanban_column_id: 'colB', kanban_position: 0 }], has_more: false, next_cursor: null }
      }
      return { tasks: [{ id: 'task_1', name: 'x', kanban_column_id: 'colA', kanban_position: 0 }], has_more: false, next_cursor: null }
    })

    await store.fetchKanbanTasks('ws_1', 'item_1', 'colB', 100)
    await store.fetchKanbanTasks('ws_1', 'item_1', 'colA', 100)

    const tasks = store.workspaces[0]!.items[0]!.tasks!
    // Last writer (colA) wins, but never two copies.
    expect(tasks.filter((t) => t.id === 'task_1')).toHaveLength(1)
  })
})
