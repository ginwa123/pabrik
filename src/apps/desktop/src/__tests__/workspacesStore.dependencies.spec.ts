/**
 * workspacesStore — kanban task dependencies passthrough.
 * Covers: updateTaskDetails forwards `depends_on` (and omits it
 * when untouched); moveTaskToColumn threads `force` through to
 * api.moveTask; a 409 refusal leaves local task state untouched.
 *
 * API-module mock style mirrors workspacesStore.tags.spec.ts.
 */
import { describe, it, expect, beforeEach, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import * as api from '../api'
import type { Workspace, WorkspaceItem, Task } from '../api'

vi.mock('../api', async (importOriginal) => {
  const actual = await importOriginal<typeof api>()
  return {
    ...actual,
    updateTaskSimple: vi.fn(),
    moveTask: vi.fn(),
  }
})

function fixtureWorkspaceWithItem(item: WorkspaceItem): Workspace {
  return { id: 'ws_1', name: 'Deps WS', icon: '📁', expanded: true, items: [item] }
}

function kanbanItemWithTask(task: Task): WorkspaceItem {
  return {
    id: 'item_1',
    name: 'Sprint Board',
    item_type: 'kanban',
    path: '/tmp',
    tasks: [task],
    hasMoreTasks: false,
  } as unknown as WorkspaceItem
}

describe('workspacesStore — kanban task dependencies', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    vi.clearAllMocks()
  })

  it('updateTaskDetails passes depends_on to api.updateTaskSimple', async () => {
    const { useWorkspacesStore } = await import('../stores/workspaces')
    const store = useWorkspacesStore()
    store.workspaces.push(
      fixtureWorkspaceWithItem(kanbanItemWithTask({ id: 'task_1', name: 'T' })),
    )

    vi.mocked(api.updateTaskSimple).mockResolvedValueOnce({ success: true } as never)
    await store.updateTaskDetails('ws_1', 'item_1', 'task_1', { depends_on: ['a'] })

    expect(api.updateTaskSimple).toHaveBeenCalledWith(
      'task_1',
      expect.objectContaining({ depends_on: ['a'] }),
    )
  })

  it('updateTaskDetails omits depends_on when the caller did not send it', async () => {
    const { useWorkspacesStore } = await import('../stores/workspaces')
    const store = useWorkspacesStore()
    store.workspaces.push(
      fixtureWorkspaceWithItem(kanbanItemWithTask({ id: 'task_1', name: 'T' })),
    )

    vi.mocked(api.updateTaskSimple).mockResolvedValueOnce({ success: true } as never)
    await store.updateTaskDetails('ws_1', 'item_1', 'task_1', { name: 'Renamed' })

    expect(api.updateTaskSimple).toHaveBeenCalledWith('task_1', { name: 'Renamed' })
  })

  it('moveTaskToColumn threads force through to api.moveTask', async () => {
    const { useWorkspacesStore } = await import('../stores/workspaces')
    const store = useWorkspacesStore()
    store.workspaces.push(
      fixtureWorkspaceWithItem(
        kanbanItemWithTask({ id: 'task_1', name: 'T', kanban_column_id: 'col_a' }),
      ),
    )

    vi.mocked(api.moveTask).mockResolvedValueOnce({ id: 'task_1' } as never)
    await store.moveTaskToColumn('ws_1', 'item_1', 'task_1', 'col_b', 0, true)

    expect(api.moveTask).toHaveBeenCalledWith('ws_1', 'item_1', 'task_1', 'col_b', 0, true)
  })

  it('a 409 refusal leaves the local task in its original column', async () => {
    const { useWorkspacesStore } = await import('../stores/workspaces')
    const store = useWorkspacesStore()
    store.workspaces.push(
      fixtureWorkspaceWithItem(
        kanbanItemWithTask({ id: 'task_1', name: 'T', kanban_column_id: 'col_a' }),
      ),
    )

    const blockers = [{ task_id: 'a', name: 'Fix login', column_id: 'c', column_name: 'todo' }]
    vi.mocked(api.moveTask).mockRejectedValue(
      new api.ApiError(409, 'Conflict', JSON.stringify({ error: 'blocked', blockers })),
    )

    let thrown: unknown = null
    await store.moveTaskToColumn('ws_1', 'item_1', 'task_1', 'col_b', 0).catch((err: unknown) => {
      thrown = err
    })
    expect(thrown).toMatchObject({ status: 409 })

    const task = store.workspaces[0]?.items[0]?.tasks?.[0]
    expect(task?.kanban_column_id).toBe('col_a')
    // The blocker list survives on the thrown error for the caller.
    expect(api.parseMoveBlockers(thrown)).toEqual(blockers)
  })
})
