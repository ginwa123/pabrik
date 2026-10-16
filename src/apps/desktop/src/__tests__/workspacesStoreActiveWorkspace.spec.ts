/** Unit tests for the workspaces store's active-workspace selection — the state behind the header
 * dropdown + sidebar Projects section. Plan:
 * docs/plans/2026-09-22-revamp-workspace-ui-dropdown-projects.md */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'

import * as api from '../api'
import { useWorkspacesStore, type Workspace, type WorkspaceItem } from '../stores/workspaces'
import { makeLocalStorageStub } from './helpers'

const ws = (id: string, name: string, items: WorkspaceItem[] = []): Workspace => ({
  id,
  name,
  icon: '📁',
  expanded: false,
  items,
})

const item = (id: string, tasks: Array<{ id: string; name?: string }> = []): WorkspaceItem =>
  ({
    id,
    item_type: 'folder',
    name: id,
    tasks,
  }) as unknown as WorkspaceItem

describe('useWorkspacesStore active workspace selection', () => {
  let localStorageStub: Storage

  beforeEach(() => {
    setActivePinia(createPinia())
    localStorageStub = makeLocalStorageStub()
    Object.defineProperty(globalThis, 'localStorage', {
      value: localStorageStub,
      writable: true,
      configurable: true,
    })
  })

  afterEach(() => {
    vi.restoreAllMocks()
  })

  function seed(store: ReturnType<typeof useWorkspacesStore>, rows: Workspace[]) {
    store.workspaces.splice(0, store.workspaces.length, ...rows)
  }

  it('setActiveWorkspace selects the workspace and persists the choice', () => {
    const store = useWorkspacesStore()
    seed(store, [ws('ws_a', 'A'), ws('ws_b', 'B')])

    store.setActiveWorkspace('ws_b')

    expect(store.activeWorkspaceId).toBe('ws_b')
    expect(store.activeWorkspace?.id).toBe('ws_b')
    expect(localStorageStub.getItem('pabrik-active-workspace')).toBe('ws_b')
  })

  it('setActiveWorkspace ignores unknown ids once the list is loaded', () => {
    const store = useWorkspacesStore()
    seed(store, [ws('ws_a', 'A')])

    store.setActiveWorkspace('ws_missing')

    expect(store.activeWorkspaceId).toBeNull()
    expect(localStorageStub.getItem('pabrik-active-workspace')).toBeNull()
  })

  it('clears an active item + task that belong to a DIFFERENT workspace', () => {
    const store = useWorkspacesStore()
    seed(store, [ws('ws_a', 'A', [item('item_a', [{ id: 'task_1', name: 'T' }])]), ws('ws_b', 'B')])
    store.setActiveWorkspace('ws_a')
    store.setActiveTask('task_1')
    expect(store.activeWorkspaceItemId).toBe('item_a')

    store.setActiveWorkspace('ws_b')

    expect(store.activeWorkspaceId).toBe('ws_b')
    expect(store.activeWorkspaceItemId).toBeNull()
    expect(store.activeTask).toBeNull()
  })

  it('keeps the active item when re-selecting its OWN workspace', () => {
    const store = useWorkspacesStore()
    seed(store, [ws('ws_a', 'A', [item('item_a')]), ws('ws_b', 'B')])
    store.setActiveWorkspace('ws_a')
    store.setActiveWorkspaceItem('item_a')

    store.setActiveWorkspace('ws_a')

    expect(store.activeWorkspaceItemId).toBe('item_a')
  })

  it('getter precedence: explicit selection wins over everything', () => {
    const store = useWorkspacesStore()
    localStorageStub.setItem('pabrik-active-workspace', 'ws_b')
    seed(store, [ws('ws_a', 'A'), ws('ws_b', 'B'), ws('ws_c', 'C')])

    store.setActiveWorkspace('ws_a')

    expect(store.activeWorkspace?.id).toBe('ws_a')
  })

  it('getter precedence: persisted choice beats item-derived', () => {
    const store = useWorkspacesStore()
    localStorageStub.setItem('pabrik-active-workspace', 'ws_b')
    seed(store, [ws('ws_a', 'A', [item('item_a')]), ws('ws_b', 'B')])
    store.setActiveWorkspaceItem('item_a')

    expect(store.activeWorkspace?.id).toBe('ws_b')
  })

  it('getter precedence: item-derived beats first when nothing persisted', () => {
    const store = useWorkspacesStore()
    seed(store, [ws('ws_a', 'A', [item('item_a')]), ws('ws_b', 'B')])
    store.setActiveWorkspaceItem('item_a')

    expect(store.activeWorkspace?.id).toBe('ws_a')
  })

  it('getter falls back to the first workspace when nothing else resolves', () => {
    const store = useWorkspacesStore()
    seed(store, [ws('ws_x', 'X'), ws('ws_y', 'Y')])

    expect(store.activeWorkspace?.id).toBe('ws_x')
  })

  it('ignores a stale persisted id whose workspace no longer exists', () => {
    const store = useWorkspacesStore()
    localStorageStub.setItem('pabrik-active-workspace', 'ws_deleted')
    seed(store, [ws('ws_a', 'A')])

    expect(store.activeWorkspace?.id).toBe('ws_a')
  })

  it('removing the selected workspace clears the selection + persisted id', async () => {
    const deleteMock = vi.fn().mockResolvedValue({ success: true })
    vi.spyOn(api, 'deleteWorkspace').mockImplementation(deleteMock)

    const store = useWorkspacesStore()
    seed(store, [ws('ws_a', 'A'), ws('ws_b', 'B')])
    store.setActiveWorkspace('ws_a')

    await store.removeWorkspace('ws_a')

    expect(store.activeWorkspaceId).toBeNull()
    expect(localStorageStub.getItem('pabrik-active-workspace')).toBeNull()
    // Getter falls back down the precedence chain to the next workspace.
    expect(store.activeWorkspace?.id).toBe('ws_b')
    expect(deleteMock).toHaveBeenCalledWith('ws_a')
  })
})
