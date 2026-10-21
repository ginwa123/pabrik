/** Unit tests for the workspaces store's reorderWorkspaces action. reorderWorkspaces is the
 * optimistic-update action for workspace-level ordering (the 2026-09-22 revamp removed the sidebar
 * UI; store + API remain). */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'

import * as api from '../api'
import { useWorkspacesStore, type Workspace } from '../stores/workspaces'
import { makeLocalStorageStub } from './helpers'

const ws = (id: string, name: string): Workspace => ({
  id,
  name,
  icon: '📁',
  expanded: false,
  items: [],
})

describe('useWorkspacesStore.reorderWorkspaces()', () => {
  const reorderWorkspacesMock = vi.fn()

  let localStorageStub: Storage

  beforeEach(() => {
    setActivePinia(createPinia())
    localStorageStub = makeLocalStorageStub()
    Object.defineProperty(globalThis, 'localStorage', {
      value: localStorageStub,
      writable: true,
      configurable: true,
    })
    reorderWorkspacesMock.mockReset()
    vi.spyOn(api, 'reorderWorkspaces').mockImplementation(reorderWorkspacesMock)
  })

  afterEach(() => {
    vi.restoreAllMocks()
  })

  function seed(store: ReturnType<typeof useWorkspacesStore>, rows: Workspace[]) {
    // Direct mutation of the ref's inner array (Pinia setup-store
    // pattern). Equivalent to the user creating 3 workspaces via
    // the UI.
    store.workspaces.splice(0, store.workspaces.length, ...rows)
  }

  it('reorders the local array optimistically before the API resolves', async () => {
    reorderWorkspacesMock.mockResolvedValue({ success: true, count: 3 })
    const store = useWorkspacesStore()
    seed(store, [ws('ws_c', 'C'), ws('ws_a', 'A'), ws('ws_b', 'B')])

    // Drag ws_a to the top.
    const promise = store.reorderWorkspaces(['ws_a', 'ws_c', 'ws_b'])

    // Optimistic: order is already updated, even though the
    // promise hasn't resolved yet.
    expect(store.workspaces.map((w) => w.id)).toEqual(['ws_a', 'ws_c', 'ws_b'])
    expect(reorderWorkspacesMock).toHaveBeenCalledWith(['ws_a', 'ws_c', 'ws_b'])

    await promise
    // After the API resolves, the order stays.
    expect(store.workspaces.map((w) => w.id)).toEqual(['ws_a', 'ws_c', 'ws_b'])
  })

  it('rolls back the local order when the API call fails', async () => {
    reorderWorkspacesMock.mockRejectedValue(new Error('HTTP 500'))
    const store = useWorkspacesStore()
    seed(store, [ws('ws_c', 'C'), ws('ws_a', 'A'), ws('ws_b', 'B')])

    // Spy on console.error to silence the expected error log.
    const errorSpy = vi.spyOn(console, 'error').mockImplementation(() => {})

    await store.reorderWorkspaces(['ws_a', 'ws_c', 'ws_b'])

    // Order is back to the original.
    expect(store.workspaces.map((w) => w.id)).toEqual(['ws_c', 'ws_a', 'ws_b'])
    expect(errorSpy).toHaveBeenCalled()
    errorSpy.mockRestore()
  })

  it('is a no-op when the new order matches the current order', async () => {
    const store = useWorkspacesStore()
    seed(store, [ws('ws_a', 'A'), ws('ws_b', 'B')])

    await store.reorderWorkspaces(['ws_a', 'ws_b'])

    expect(reorderWorkspacesMock).not.toHaveBeenCalled()
  })

  it('is a no-op on an empty orderedIds array', async () => {
    const store = useWorkspacesStore()
    seed(store, [ws('ws_a', 'A')])

    await store.reorderWorkspaces([])

    expect(reorderWorkspacesMock).not.toHaveBeenCalled()
  })

  it('refuses to reorder when the new order has a different length than the current set', async () => {
    const store = useWorkspacesStore()
    seed(store, [ws('ws_a', 'A'), ws('ws_b', 'B'), ws('ws_c', 'C')])

    // Spy on console.error to silence the expected error log.
    const errorSpy = vi.spyOn(console, 'error').mockImplementation(() => {})

    // Client sends only 2 IDs but there are 3 workspaces.
    await store.reorderWorkspaces(['ws_b', 'ws_a'])

    // Order unchanged.
    expect(store.workspaces.map((w) => w.id)).toEqual(['ws_a', 'ws_b', 'ws_c'])
    expect(reorderWorkspacesMock).not.toHaveBeenCalled()
    expect(errorSpy).toHaveBeenCalled()
    errorSpy.mockRestore()
  })
})
