/** Tests for the Task type + `addTask` params signature (post-Migration 084): `task_type` is
 * 'standard' | 'memory' (the per-task 'routine' value was deleted — routines are first-class
 * workspace items now), plus the `runRoutineItem` + `addRoutineItem` store actions. */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'

import * as api from '../api'
import { useWorkspacesStore } from '../stores/workspaces'
import { makeLocalStorageStub } from './helpers'

describe('useWorkspacesStore.addTask — standard/memory only', () => {
  const createTaskMock = vi.fn()

  let localStorageStub: Storage

  beforeEach(() => {
    setActivePinia(createPinia())
    localStorageStub = makeLocalStorageStub()
    Object.defineProperty(globalThis, 'localStorage', {
      value: localStorageStub,
      writable: true,
      configurable: true,
    })

    vi.spyOn(api, 'createTask').mockImplementation(createTaskMock)
    // init()'s other API calls — defensive in case a future test triggers it.
    vi.spyOn(api, 'getWorkspaces').mockResolvedValue({ workspaces: [] })
    vi.spyOn(api, 'getWorkspacesItems').mockResolvedValue({ items: [], count: 0 })
    vi.spyOn(api, 'getTasks').mockResolvedValue({ tasks: [], has_more: false, next_cursor: null })
  })

  afterEach(() => {
    vi.restoreAllMocks()
    createTaskMock.mockReset()
  })

  function seedStore() {
    const ws = useWorkspacesStore()
    ws.workspaces = [
      {
        id: 'ws_1',
        name: 'W1',
        icon: '📁',
        expanded: true,
        items: [
          { id: 'item_a', name: 'A', item_type: 'folder', tasks: [] },
        ],
      },
    ]
    return ws
  }

  it('passes taskType="standard" through for a standard task (default path)', async () => {
    const ws = seedStore()
    createTaskMock.mockResolvedValueOnce({
      id: 'task_std_1',
      name: 'Quick chat',
      task_type: 'standard',
    })

    await ws.addTask('ws_1', 'item_a', {
      name: 'Quick chat',
      description: 'a quick test',
      taskType: 'standard',
    })

    expect(createTaskMock).toHaveBeenCalledWith('ws_1', 'item_a', {
      name: 'Quick chat',
      description: 'a quick test',
      taskType: 'standard',
      memory: undefined,
    })
  })

  it('defaults taskType to "standard" when omitted (backwards-compat with existing call sites)', async () => {
    const ws = seedStore()
    createTaskMock.mockResolvedValueOnce({ id: 'task_std_2', name: 'Old way', task_type: 'standard' })

    // Existing call sites pass {name, description} and rely on the
    // legacy signature. The modified signature must accept this
    // shape and forward taskType: 'standard'.
    await ws.addTask('ws_1', 'item_a', {
      name: 'Old way',
      description: 'legacy call',
    })

    expect(createTaskMock).toHaveBeenCalledWith('ws_1', 'item_a', {
      name: 'Old way',
      description: 'legacy call',
      taskType: 'standard',
      memory: undefined,
    })
  })

  it('falls back to a local-only task if the API call fails (preserves the legacy fallback contract)', async () => {
    const ws = seedStore()
    createTaskMock.mockRejectedValueOnce(new Error('network down'))

    const taskId = await ws.addTask('ws_1', 'item_a', {
      name: 'Offline',
      taskType: 'memory',
      memory: { name: 'note.md', content: 'x' },
    })

    expect(taskId).toBeDefined()
    const tasks = ws.workspaces[0]!.items[0]!.tasks!
    expect(tasks).toHaveLength(1)
    expect(tasks[0]!.task_type).toBe('memory')
    expect(tasks[0]!.memory_name).toBe('note.md')
  })
})

describe('useWorkspacesStore.runRoutineItem', () => {
  const runRoutineItemApiMock = vi.fn()

  let localStorageStub: Storage

  beforeEach(() => {
    setActivePinia(createPinia())
    localStorageStub = makeLocalStorageStub()
    Object.defineProperty(globalThis, 'localStorage', {
      value: localStorageStub,
      writable: true,
      configurable: true,
    })
    vi.spyOn(api, 'runWorkspaceRoutine').mockImplementation(runRoutineItemApiMock)
  })

  afterEach(() => {
    vi.restoreAllMocks()
    runRoutineItemApiMock.mockReset()
  })

  it('calls api.runWorkspaceRoutine with (workspaceId, itemId, routineId) and returns the session_id', async () => {
    const ws = useWorkspacesStore()
    runRoutineItemApiMock.mockResolvedValueOnce({ session_id: 'item_r_1' })

    const result = await ws.runRoutineItem('ws_1', 'item_r_1', 'item_r_1')

    expect(runRoutineItemApiMock).toHaveBeenCalledWith('ws_1', 'item_r_1', 'item_r_1')
    expect(result).toEqual({ session_id: 'item_r_1' })
  })

  it('returns undefined (does not throw) if the API call fails — the caller handles the error toast', async () => {
    const ws = useWorkspacesStore()
    runRoutineItemApiMock.mockRejectedValueOnce(new Error('409 conflict'))

    // We don't want a console.error to fail the test; silence it.
    const consoleErrSpy = vi.spyOn(console, 'error').mockImplementation(() => {})
    const result = await ws.runRoutineItem('ws_1', 'item_r_1', 'item_r_1')
    consoleErrSpy.mockRestore()

    expect(result).toBeUndefined()
  })
})

describe('useWorkspacesStore.addRoutineItem', () => {
  const createRoutineItemMock = vi.fn()

  let localStorageStub: Storage

  beforeEach(() => {
    setActivePinia(createPinia())
    localStorageStub = makeLocalStorageStub()
    Object.defineProperty(globalThis, 'localStorage', {
      value: localStorageStub,
      writable: true,
      configurable: true,
    })
    vi.spyOn(api, 'createRoutineItem').mockImplementation(createRoutineItemMock)
    vi.spyOn(api, 'getWorkspaces').mockResolvedValue({ workspaces: [] })
    vi.spyOn(api, 'getWorkspacesItems').mockResolvedValue({ items: [], count: 0 })
    vi.spyOn(api, 'getTasks').mockResolvedValue({ tasks: [], has_more: false, next_cursor: null })
  })

  afterEach(() => {
    vi.restoreAllMocks()
    createRoutineItemMock.mockReset()
  })

  function seedStore() {
    const ws = useWorkspacesStore()
    ws.workspaces = [
      {
        id: 'ws_1',
        name: 'W1',
        icon: '📁',
        expanded: false,
        items: [],
      },
    ]
    return ws
  }

  it('creates a routine item via the API and pushes it into the store', async () => {
    const ws = seedStore()
    createRoutineItemMock.mockResolvedValueOnce({
      item: { id: 'item_r_1', workspace_id: 'ws_1', item_type: 'routine', name: 'Nightly', path: '/tmp/x', position: 0 },
      routine: { id: 'item_r_1', workspace_item_id: 'item_r_1' },
    })

    const itemId = await ws.addRoutineItem('ws_1', 'Nightly', '/tmp/x')

    expect(itemId).toBe('item_r_1')
    expect(createRoutineItemMock).toHaveBeenCalledWith('ws_1', 'Nightly', '/tmp/x', undefined)
    const items = ws.workspaces[0]!.items
    expect(items).toHaveLength(1)
    expect(items[0]!.item_type).toBe('routine')
    // Workspace auto-expands so the new item is visible.
    expect(ws.workspaces[0]!.expanded).toBe(true)
  })

  it('forwards the instruction and schedule the dialog collected', async () => {
    const ws = seedStore()
    createRoutineItemMock.mockResolvedValueOnce({
      item: { id: 'item_r_2', workspace_id: 'ws_1', item_type: 'routine', name: 'Hourly', path: '/tmp/y', position: 1 },
      routine: { id: 'item_r_2', workspace_item_id: 'item_r_2' },
    })

    await ws.addRoutineItem('ws_1', 'Hourly', '/tmp/y', {
      instruction: 'summarise issues',
      schedule: '0 * * * *',
    })

    expect(createRoutineItemMock).toHaveBeenCalledWith('ws_1', 'Hourly', '/tmp/y', {
      instruction: 'summarise issues',
      schedule: '0 * * * *',
    })
  })

  it('returns undefined if the API call fails', async () => {
    const ws = seedStore()
    createRoutineItemMock.mockRejectedValueOnce(new Error('network down'))

    const consoleErrSpy = vi.spyOn(console, 'error').mockImplementation(() => {})
    const itemId = await ws.addRoutineItem('ws_1', 'Nightly', '/tmp/x')
    consoleErrSpy.mockRestore()

    expect(itemId).toBeUndefined()
  })
})
