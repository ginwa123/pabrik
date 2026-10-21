/** Unit tests for the workspaces store's `updateTaskDetails` action. */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'

import * as api from '../api'
import { useWorkspacesStore } from '../stores/workspaces'
import { useNavigationStore } from '../stores/navigation'
import { makeLocalStorageStub } from './helpers'

describe('useWorkspacesStore.updateTaskDetails', () => {
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

  // Seed the store with a single workspace / item / task that already
  // has a description. Skipping init() keeps the tests focused on the
  // patch application + rollback logic.
  function seedStore(taskName: string, taskDescription: string) {
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
            tasks: [{ id: 'task_1', name: taskName, description: taskDescription }],
          },
        ],
      },
    ]
    return ws
  }

  it('updates both name and description optimistically and calls the API with both', async () => {
    const ws = seedStore('Old Name', 'old desc')
    updateTaskSimpleMock.mockResolvedValueOnce({ success: true })

    await ws.updateTaskDetails('ws_1', 'item_a', 'task_1', {
      name: 'New Name',
      description: 'New desc',
    })

    // Optimistic: both fields reflect the new values.
    expect(ws.workspaces[0]!.items[0]!.tasks![0]!.name).toBe('New Name')
    expect(ws.workspaces[0]!.items[0]!.tasks![0]!.description).toBe('New desc')
    // API: called once with both fields, in a single PATCH shape.
    expect(updateTaskSimpleMock).toHaveBeenCalledTimes(1)
    expect(updateTaskSimpleMock).toHaveBeenCalledWith('task_1', {
      name: 'New Name',
      description: 'New desc',
    })
  })

  it('updates description only when name is omitted', async () => {
    const ws = seedStore('Original Name', 'old desc')
    updateTaskSimpleMock.mockResolvedValueOnce({ success: true })

    await ws.updateTaskDetails('ws_1', 'item_a', 'task_1', {
      description: 'New desc only',
    })

    // Name unchanged, description updated.
    expect(ws.workspaces[0]!.items[0]!.tasks![0]!.name).toBe('Original Name')
    expect(ws.workspaces[0]!.items[0]!.tasks![0]!.description).toBe('New desc only')
    // API payload should NOT include name (caller didn't send it).
    expect(updateTaskSimpleMock).toHaveBeenCalledTimes(1)
    expect(updateTaskSimpleMock).toHaveBeenCalledWith('task_1', {
      description: 'New desc only',
    })
  })

  it('rolls back both name and description when the API call fails', async () => {
    const ws = seedStore('Original', 'old desc')
    updateTaskSimpleMock.mockRejectedValueOnce(new Error('network down'))

    // The plan says updateTaskDetails throws on failure so the dialog
    // can show a retry option. Catch it locally so the assertion
    // below runs.
    await expect(
      ws.updateTaskDetails('ws_1', 'item_a', 'task_1', {
        name: 'Attempted',
        description: 'Attempted desc',
      }),
    ).rejects.toThrow('network down')

    // Both fields restored to their pre-call values.
    expect(ws.workspaces[0]!.items[0]!.tasks![0]!.name).toBe('Original')
    expect(ws.workspaces[0]!.items[0]!.tasks![0]!.description).toBe('old desc')
  })

  it('treats description = "" as a valid clear (sends the empty string to the API)', async () => {
    const ws = seedStore('Name', 'old desc')
    updateTaskSimpleMock.mockResolvedValueOnce({ success: true })

    await ws.updateTaskDetails('ws_1', 'item_a', 'task_1', {
      description: '',
    })

    // Description cleared locally (empty string, not undefined).
    expect(ws.workspaces[0]!.items[0]!.tasks![0]!.description).toBe('')
    // API payload should include the empty string — this is the
    // user's explicit "clear the description" intent.
    expect(updateTaskSimpleMock).toHaveBeenCalledTimes(1)
    expect(updateTaskSimpleMock).toHaveBeenCalledWith('task_1', {
      description: '',
    })
  })

  it('is a no-op when both name and description are undefined (no API call)', async () => {
    const ws = seedStore('Original', 'old desc')
    await ws.updateTaskDetails('ws_1', 'item_a', 'task_1', {})
    expect(ws.workspaces[0]!.items[0]!.tasks![0]!.name).toBe('Original')
    expect(ws.workspaces[0]!.items[0]!.tasks![0]!.description).toBe('old desc')
    expect(updateTaskSimpleMock).not.toHaveBeenCalled()
  })

  it('updates navigationStore.activeChatName when renaming the active task alongside a description change', async () => {
    const ws = seedStore('Old Active', 'old desc')
    const nav = useNavigationStore()
    ws.setActiveTask('task_1')
    nav.setActiveChatName('Old Active')

    updateTaskSimpleMock.mockResolvedValueOnce({ success: true })
    await ws.updateTaskDetails('ws_1', 'item_a', 'task_1', {
      name: 'New Active',
      description: 'new desc',
    })

    // Active chat header now reflects the new name.
    expect(nav.activeChatName).toBe('New Active')
  })

  it('rolls back navigationStore.activeChatName when the API call fails', async () => {
    const ws = seedStore('Original', 'old desc')
    const nav = useNavigationStore()
    ws.setActiveTask('task_1')
    nav.setActiveChatName('Original')

    updateTaskSimpleMock.mockRejectedValueOnce(new Error('boom'))

    await expect(
      ws.updateTaskDetails('ws_1', 'item_a', 'task_1', {
        name: 'Attempted',
        description: 'Attempted desc',
      }),
    ).rejects.toThrow('boom')

    // Both fields AND the nav header restored.
    expect(ws.workspaces[0]!.items[0]!.tasks![0]!.name).toBe('Original')
    expect(ws.workspaces[0]!.items[0]!.tasks![0]!.description).toBe('old desc')
    expect(nav.activeChatName).toBe('Original')
  })
})