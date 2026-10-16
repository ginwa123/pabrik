/** Unit tests for the workspaces store's reorderWorkspaceItems action. reorderWorkspaceItems is the
 * optimistic-update action called by the ProjectsList drag-and-drop handler when the user reorders
 * items inside an expanded workspace. */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'

import * as api from '../api'
import { useWorkspacesStore, type Workspace, type WorkspaceItem } from '../stores/workspaces'
import { makeLocalStorageStub } from './helpers'

const item = (id: string, name: string): WorkspaceItem => ({
  id,
  name,
  item_type: 'folder',
})

const ws = (id: string, name: string, items: WorkspaceItem[] = []): Workspace => ({
  id,
  name,
  icon: '📁',
  expanded: true,
  items,
})

describe('useWorkspacesStore.reorderWorkspaceItems()', () => {
  const reorderWorkspaceItemsMock = vi.fn()

  let localStorageStub: Storage

  beforeEach(() => {
    setActivePinia(createPinia())
    localStorageStub = makeLocalStorageStub()
    Object.defineProperty(globalThis, 'localStorage', {
      value: localStorageStub,
      writable: true,
      configurable: true,
    })
    reorderWorkspaceItemsMock.mockReset()
    vi.spyOn(api, 'reorderWorkspaceItems').mockImplementation(reorderWorkspaceItemsMock)
  })

  afterEach(() => {
    vi.restoreAllMocks()
  })

  function seed(store: ReturnType<typeof useWorkspacesStore>, rows: Workspace[]) {
    // Direct mutation of the ref's inner array (Pinia setup-store
    // pattern). Equivalent to the user creating 2 workspaces via
    // the UI.
    store.workspaces.splice(0, store.workspaces.length, ...rows)
  }

  it('reorders the workspace items optimistically before the API resolves', async () => {
    reorderWorkspaceItemsMock.mockResolvedValue({ success: true, count: 3 })
    const store = useWorkspacesStore()
    seed(store, [
      ws('ws_a', 'A', [item('item1', '1'), item('item2', '2'), item('item3', '3')]),
      ws('ws_b', 'B', [item('item4', '4'), item('item5', '5'), item('item6', '6')]),
    ])

    // Drag item2 to the top of workspace A.
    const promise = store.reorderWorkspaceItems('ws_a', ['item2', 'item1', 'item3'])

    // Optimistic: order is already updated, even though the
    // promise hasn't resolved yet.
    const wsA = store.workspaces.find((w) => w.id === 'ws_a')!
    expect(wsA.items.map((i) => i.id)).toEqual(['item2', 'item1', 'item3'])
    // The other workspace is untouched.
    const wsB = store.workspaces.find((w) => w.id === 'ws_b')!
    expect(wsB.items.map((i) => i.id)).toEqual(['item4', 'item5', 'item6'])
    expect(reorderWorkspaceItemsMock).toHaveBeenCalledWith('ws_a', [
      'item2',
      'item1',
      'item3',
    ])

    await promise
    // After the API resolves, the order stays.
    expect(wsA.items.map((i) => i.id)).toEqual(['item2', 'item1', 'item3'])
  })

  it('rolls back the local order when the API call fails', async () => {
    reorderWorkspaceItemsMock.mockRejectedValue(new Error('HTTP 500'))
    const store = useWorkspacesStore()
    seed(store, [ws('ws_a', 'A', [item('item1', '1'), item('item2', '2'), item('item3', '3')])])

    // Spy on console.error to silence the expected error log.
    const errorSpy = vi.spyOn(console, 'error').mockImplementation(() => {})

    await store.reorderWorkspaceItems('ws_a', ['item2', 'item1', 'item3'])

    // Order is back to the original.
    const wsA = store.workspaces.find((w) => w.id === 'ws_a')!
    expect(wsA.items.map((i) => i.id)).toEqual(['item1', 'item2', 'item3'])
    expect(errorSpy).toHaveBeenCalled()
    errorSpy.mockRestore()
  })

  it('is a no-op when the new order matches the current order', async () => {
    const store = useWorkspacesStore()
    seed(store, [ws('ws_a', 'A', [item('item1', '1'), item('item2', '2')])])

    await store.reorderWorkspaceItems('ws_a', ['item1', 'item2'])

    expect(reorderWorkspaceItemsMock).not.toHaveBeenCalled()
  })

  it('is a no-op on an empty orderedIds array', async () => {
    const store = useWorkspacesStore()
    seed(store, [ws('ws_a', 'A', [item('item1', '1')])])

    await store.reorderWorkspaceItems('ws_a', [])

    expect(reorderWorkspaceItemsMock).not.toHaveBeenCalled()
  })

  it('refuses to reorder when the new order has a different length than the current set', async () => {
    const store = useWorkspacesStore()
    seed(store, [
      ws('ws_a', 'A', [item('item1', '1'), item('item2', '2'), item('item3', '3')]),
    ])

    // Spy on console.error to silence the expected error log.
    const errorSpy = vi.spyOn(console, 'error').mockImplementation(() => {})

    // Client sends only 2 IDs but there are 3 items.
    await store.reorderWorkspaceItems('ws_a', ['item2', 'item1'])

    // Order unchanged.
    const wsA = store.workspaces.find((w) => w.id === 'ws_a')!
    expect(wsA.items.map((i) => i.id)).toEqual(['item1', 'item2', 'item3'])
    expect(reorderWorkspaceItemsMock).not.toHaveBeenCalled()
    expect(errorSpy).toHaveBeenCalled()
    errorSpy.mockRestore()
  })

  it('is a no-op (no API call) when the workspace does not exist', async () => {
    const store = useWorkspacesStore()
    seed(store, [ws('ws_a', 'A', [item('item1', '1'), item('item2', '2')])])

    // Spy on console.error to silence the expected error log.
    const errorSpy = vi.spyOn(console, 'error').mockImplementation(() => {})

    await store.reorderWorkspaceItems('ws_nonexistent', ['item1', 'item2'])

    expect(reorderWorkspaceItemsMock).not.toHaveBeenCalled()
    expect(errorSpy).toHaveBeenCalled()
    errorSpy.mockRestore()
  })
})
