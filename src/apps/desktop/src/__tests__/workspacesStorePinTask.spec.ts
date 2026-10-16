/** Unit tests for the workspaces store's `pinTask` action — the optimistic update behind the
 * pin/unpin button on a per-task row in `WorkspaceItemTask.vue`. */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'

import * as api from '../api'
import {
  useWorkspacesStore,
  type Workspace,
  type WorkspaceItem,
  type Task,
} from '../stores/workspaces'
import { makeLocalStorageStub } from './helpers'

const task = (id: string, name: string, opts: Partial<Task> = {}): Task => ({
  id,
  name,
  task_type: 'standard',
  ...opts,
})

const item = (id: string, tasks: Task[] = []): WorkspaceItem => ({
  id,
  name: 'item',
  item_type: 'folder',
  tasks,
})

const ws = (id: string, items: WorkspaceItem[] = []): Workspace => ({
  id,
  name: 'ws',
  icon: '📁',
  expanded: true,
  items,
})

describe('useWorkspacesStore.pinTask()', () => {
  const pinTaskMock = vi.fn()

  beforeEach(() => {
    setActivePinia(createPinia())
    Object.defineProperty(globalThis, 'localStorage', {
      value: makeLocalStorageStub(),
      writable: true,
      configurable: true,
    })
    pinTaskMock.mockReset()
    vi.spyOn(api, 'pinTask').mockImplementation(pinTaskMock)
  })

  afterEach(() => {
    vi.restoreAllMocks()
  })

  function seed(store: ReturnType<typeof useWorkspacesStore>, rows: Workspace[]) {
    // Mirrors the seed pattern in workspacesStoreItemReorder.spec.ts
    // (which works in the existing test suite): replace the
    // workspaces array in place so Vue reactivity is preserved.
    store.workspaces.splice(0, store.workspaces.length, ...rows)
  }

  it('flips is_pinned to true and bumps pinned_position to MAX+1', async () => {
    const store = useWorkspacesStore()
    // Seed: 1 pinned task at position 0, 1 unpinned task to be pinned.
    const t1 = task('task_1', 'first', { is_pinned: true, pinned_position: 0 })
    const t2 = task('task_2', 'second')
    seed(store, [ws('ws_1', [item('item_1', [t1, t2])])])

    pinTaskMock.mockResolvedValue({
      success: true,
      id: 'task_2',
      is_pinned: true,
      pinned_position: 1,
    })

    const result = await store.pinTask('ws_1', 'item_1', 'task_2', true)
    expect(result?.success).toBe(true)
    expect(result?.pinned_position).toBe(1)

    // Optimistic state was applied.
    const ws1 = store.workspaces.find((w) => w.id === 'ws_1')!
    const item1 = ws1.items.find((i) => i.id === 'item_1')!
    const tasks = item1.tasks!
    const updated = tasks.find((t) => t.id === 'task_2')!
    expect(updated.is_pinned).toBe(true)
    expect(updated.pinned_position).toBe(1)

    // API was called once with the right shape.
    expect(pinTaskMock).toHaveBeenCalledTimes(1)
    expect(pinTaskMock).toHaveBeenCalledWith('ws_1', 'item_1', 'task_2', true)
  })

  it('flips is_pinned to false and resets pinned_position to 0', async () => {
    const store = useWorkspacesStore()
    const t1 = task('task_1', 'pinned', { is_pinned: true, pinned_position: 3 })
    seed(store, [ws('ws_1', [item('item_1', [t1])])])

    pinTaskMock.mockResolvedValue({
      success: true,
      id: 'task_1',
      is_pinned: false,
      pinned_position: 0,
    })

    const result = await store.pinTask('ws_1', 'item_1', 'task_1', false)
    expect(result?.success).toBe(true)
    const ws1 = store.workspaces.find((w) => w.id === 'ws_1')!
    const item1 = ws1.items.find((i) => i.id === 'item_1')!
    const tasks = item1.tasks!
    const updated = tasks.find((t) => t.id === 'task_1')!
    expect(updated.is_pinned).toBe(false)
    expect(updated.pinned_position).toBe(0)
  })

  it('rolls back is_pinned and pinned_position on API failure', async () => {
    const store = useWorkspacesStore()
    const t1 = task('task_1', 'first', { is_pinned: true, pinned_position: 0 })
    const t2 = task('task_2', 'second')
    seed(store, [ws('ws_1', [item('item_1', [t1, t2])])])

    pinTaskMock.mockRejectedValue(new Error('network'))

    const result = await store.pinTask('ws_1', 'item_1', 'task_2', true)
    expect(result).toBeUndefined()

    // State was rolled back: task_2 is back to unpinned.
    const ws1 = store.workspaces.find((w) => w.id === 'ws_1')!
    const item1 = ws1.items.find((i) => i.id === 'item_1')!
    const tasks = item1.tasks!
    const updated = tasks.find((t) => t.id === 'task_2')!
    expect(updated.is_pinned).toBe(false)
    expect(updated.pinned_position).toBe(0)
  })
})
