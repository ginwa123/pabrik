/** Unit tests for the workspaces store's `renameTask` action.
 * Covers the optimistic-update + rollback contract, the navigation
 * store sync when the renamed task is the active one, and the
 * early-return guards for empty / unchanged names. */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'

import * as api from '../api'
import { useWorkspacesStore } from '../stores/workspaces'
import { useNavigationStore } from '../stores/navigation'
import { makeLocalStorageStub } from './helpers'

describe('useWorkspacesStore.renameTask', () => {
  const updateTaskSimpleMock = vi.fn()

  let localStorageStub: Storage

  beforeEach(() => {
    setActivePinia(createPinia())
    localStorageStub = makeLocalStorageStub()
    Object.defineProperty(globalThis, 'localStorage', {
      value: localStorageStub,
      writable: true,
      configurable: true,
    })

    vi.spyOn(api, 'updateTaskSimple').mockImplementation(updateTaskSimpleMock)
    // init() also calls these; we never trigger init() in these tests
    // but stub them defensively in case a future test does.
    vi.spyOn(api, 'getWorkspaces').mockResolvedValue({ workspaces: [] })
    vi.spyOn(api, 'getWorkspacesItems').mockResolvedValue({ items: [], count: 0 })
    vi.spyOn(api, 'getTasks').mockResolvedValue({ tasks: [], has_more: false, next_cursor: null })
  })

  afterEach(() => {
    vi.restoreAllMocks()
    updateTaskSimpleMock.mockReset()
  })

  // Seed the store directly with one workspace / item / task. The
  // rename action operates on a fully-resolved state tree, so
  // skipping init() keeps the tests focused.
  function seedStore(taskName: string) {
    const ws = useWorkspacesStore()
    ws.workspaces = [
      {
        id: 'ws_1',
        name: 'W1',
        icon: '📁',
        expanded: true,
        items: [
          {
            id: 'item_a',
            name: 'A',
            item_type: 'folder',
            tasks: [{ id: 'task_1', name: taskName }],
          },
        ],
      },
    ]
    return ws
  }

  it('updates the task name optimistically and calls the API with the trimmed name', async () => {
    const ws = seedStore('Old Name')
    updateTaskSimpleMock.mockResolvedValueOnce({ success: true })

    await ws.renameTask('ws_1', 'item_a', 'task_1', '  New Name  ')

    // Optimistic: name reflects the trimmed value.
    expect(ws.workspaces[0]!.items[0]!.tasks![0]!.name).toBe('New Name')
    // API: called once with task id and trimmed name.
    expect(updateTaskSimpleMock).toHaveBeenCalledTimes(1)
    expect(updateTaskSimpleMock).toHaveBeenCalledWith('task_1', { name: 'New Name' })
  })

  it('rolls back to the previous name when the API call fails', async () => {
    const ws = seedStore('Original')
    updateTaskSimpleMock.mockRejectedValueOnce(new Error('network down'))

    await ws.renameTask('ws_1', 'item_a', 'task_1', 'Renamed')

    expect(ws.workspaces[0]!.items[0]!.tasks![0]!.name).toBe('Original')
  })

  it('is a no-op when the trimmed new name is empty (whitespace only)', async () => {
    const ws = seedStore('Original')
    await ws.renameTask('ws_1', 'item_a', 'task_1', '     ')
    expect(ws.workspaces[0]!.items[0]!.tasks![0]!.name).toBe('Original')
    expect(updateTaskSimpleMock).not.toHaveBeenCalled()
  })

  it('is a no-op when the trimmed new name equals the current name', async () => {
    const ws = seedStore('Same')
    await ws.renameTask('ws_1', 'item_a', 'task_1', '  Same  ')
    expect(ws.workspaces[0]!.items[0]!.tasks![0]!.name).toBe('Same')
    expect(updateTaskSimpleMock).not.toHaveBeenCalled()
  })

  it('updates navigationStore.activeChatName when renaming the active task', async () => {
    const ws = seedStore('Old Active')
    const nav = useNavigationStore()
    // Set the renamed task as the active one (drives the
    // chat-view / chat-list header binding).
    ws.setActiveTask('task_1')
    // And seed the navigation store's current name (as
    // setActiveTask would, by transitivity: the AppLayout header
    // sets it on chat-list interactions; we set it directly here).
    nav.setActiveChatName('Old Active')

    updateTaskSimpleMock.mockResolvedValueOnce({ success: true })
    await ws.renameTask('ws_1', 'item_a', 'task_1', 'New Active')
    expect(nav.activeChatName).toBe('New Active')
  })

  it('does not touch navigationStore when renaming a non-active task', async () => {
    const ws = seedStore('Old')
    const nav = useNavigationStore()
    // Active task is a DIFFERENT id; the renamed task is not active.
    ws.setActiveTask('other_task')
    nav.setActiveChatName('Other Task Header')

    updateTaskSimpleMock.mockResolvedValueOnce({ success: true })
    await ws.renameTask('ws_1', 'item_a', 'task_1', 'New')
    // Active chat header should be untouched.
    expect(nav.activeChatName).toBe('Other Task Header')
  })

  it('rolls back navigationStore.activeChatName when the API call fails', async () => {
    const ws = seedStore('Original')
    const nav = useNavigationStore()
    ws.setActiveTask('task_1')
    nav.setActiveChatName('Original')

    updateTaskSimpleMock.mockRejectedValueOnce(new Error('boom'))
    await ws.renameTask('ws_1', 'item_a', 'task_1', 'Attempted')

    expect(ws.workspaces[0]!.items[0]!.tasks![0]!.name).toBe('Original')
    expect(nav.activeChatName).toBe('Original')
  })
})
