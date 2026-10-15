/** workspacesStore — kanban task tags passthrough (Migration 067).
 * Covers: addTask forwards tags; updateTaskDetails forwards tags;
 * updateTaskDetails rollback restores tags on API error.
 * Plan: docs/superpowers/plans/2026-07-28-kanban-task-tags.md (Task 13) */

import { describe, it, expect, beforeEach, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import * as api from '../api'
import type { Workspace, WorkspaceItem, Task } from '../api'

// Mock the API module so we can spy on createTask / updateTaskSimple
// calls without spinning up a real server.
vi.mock('../api', async (importOriginal) => {
  const actual = await importOriginal<typeof api>()
  return {
    ...actual,
    createTask: vi.fn(),
    updateTaskSimple: vi.fn(),
    getTasks: vi.fn(),
  }
})

// Helper: build a minimal Workspace + WorkspaceItem fixture for
// store-workspace tests. Only the fields the action under test
// actually reads are populated.
function fixtureWorkspaceWithItem(item: WorkspaceItem): Workspace {
  return {
    id: 'ws_1',
    name: 'Tags WS',
    icon: '📁',
    expanded: true,
    items: [item],
  }
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

describe('workspacesStore — kanban task tags passthrough', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    vi.clearAllMocks()
  })

  it('addTask passes tags to api.createTask', async () => {
    const { useWorkspacesStore } = await import('../stores/workspaces')
    const store = useWorkspacesStore()
    store.workspaces.push(
      fixtureWorkspaceWithItem({
        id: 'item_1',
        name: 'Sprint Board',
        item_type: 'kanban',
        path: '/tmp',
        tasks: [],
        hasMoreTasks: false,
      } as unknown as WorkspaceItem),
    )

    vi.mocked(api.createTask).mockResolvedValueOnce({
      id: 'task_new',
      name: 'Tagged task',
      tags: ['bug', 'urgent'],
    } as unknown as Awaited<ReturnType<typeof api.createTask>>)

    await store.addTask('ws_1', 'item_1', {
      name: 'Tagged task',
      tags: ['bug', 'urgent'],
    })

    expect(api.createTask).toHaveBeenCalledWith(
      'ws_1',
      'item_1',
      expect.objectContaining({
        name: 'Tagged task',
        tags: ['bug', 'urgent'],
      }),
    )
  })

  it('updateTaskDetails passes tags to api.updateTaskSimple', async () => {
    const { useWorkspacesStore } = await import('../stores/workspaces')
    const store = useWorkspacesStore()
    const task: Task = { id: 'task_1', name: 'Tagged', tags: ['old'] }
    store.workspaces.push(
      fixtureWorkspaceWithItem(kanbanItemWithTask(task)),
    )

    vi.mocked(api.updateTaskSimple).mockResolvedValueOnce({ success: true } as never)

    await store.updateTaskDetails('ws_1', 'item_1', 'task_1', {
      tags: ['new', 'fresh'],
    })

    expect(api.updateTaskSimple).toHaveBeenCalledWith(
      'task_1',
      expect.objectContaining({
        tags: ['new', 'fresh'],
      }),
    )
  })

  it('updateTaskDetails optimistically updates tags + rolls back on API error', async () => {
    const { useWorkspacesStore } = await import('../stores/workspaces')
    const store = useWorkspacesStore()
    const task: Task = { id: 'task_1', name: 'Tagged', tags: ['original'] }
    store.workspaces.push(
      fixtureWorkspaceWithItem(kanbanItemWithTask(task)),
    )

    // Mock the API to reject. The store rethrows so the dialog can
    // surface a retry option; the test catches to inspect rollback.
    vi.mocked(api.updateTaskSimple).mockRejectedValueOnce(new Error('boom') as never)

    await store
      .updateTaskDetails('ws_1', 'item_1', 'task_1', { tags: ['new'] })
      .catch(() => {
        /* expected rethrow */
      })

    const item = store.workspaces[0]?.items[0]
    const rolledBackTask = item?.tasks?.[0]
    expect(rolledBackTask).toBeDefined()
    // Rollback: tags should be back to ['original'].
    expect(rolledBackTask!.tags).toEqual(['original'])
  })

  it('updateTaskDetails skips the API call when no fields are provided', async () => {
    const { useWorkspacesStore } = await import('../stores/workspaces')
    const store = useWorkspacesStore()
    const task: Task = { id: 'task_1', name: 'Tagged', tags: [] }
    store.workspaces.push(
      fixtureWorkspaceWithItem(kanbanItemWithTask(task)),
    )

    // Pass an empty patch — no-op, no API call.
    await store.updateTaskDetails('ws_1', 'item_1', 'task_1', {})

    expect(api.updateTaskSimple).not.toHaveBeenCalled()
  })
})
