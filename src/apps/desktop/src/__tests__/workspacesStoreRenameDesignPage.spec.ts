/**
 * Unit tests for the workspaces store's `renameDesignPage` action.
 *
 * Covers the optimistic-update + rollback contract, mirroring
 * `workspacesStoreRenameTask.spec.ts`:
 *
 *   - Renames a page in the cache + PATCHes with the trimmed name.
 *   - Rolls back on API failure.
 *   - Rejects empty / unchanged names (no-op).
 *   - No-op when the page isn't in the local cache.
 */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'

import * as api from '../api'
import { useWorkspacesStore } from '../stores/workspaces'
import { makeLocalStorageStub } from './helpers'

describe('useWorkspacesStore.renameDesignPage', () => {
  const updateDesignPageMock = vi.fn()

  let localStorageStub: Storage

  beforeEach(() => {
    setActivePinia(createPinia())
    localStorageStub = makeLocalStorageStub()
    Object.defineProperty(globalThis, 'localStorage', {
      value: localStorageStub,
      writable: true,
      configurable: true,
    })

    vi.spyOn(api, 'updateDesignPage').mockImplementation(updateDesignPageMock)
    // init() also calls these; we never trigger init() in these tests
    // but stub them defensively in case a future test does.
    vi.spyOn(api, 'getWorkspaces').mockResolvedValue({ workspaces: [] })
    vi.spyOn(api, 'getWorkspacesItems').mockResolvedValue({ items: [], count: 0 })
    vi.spyOn(api, 'getTasks').mockResolvedValue({
      tasks: [],
      has_more: false,
      next_cursor: null,
    })
  })

  afterEach(() => {
    vi.restoreAllMocks()
    updateDesignPageMock.mockReset()
  })

  // Seed the store directly with one workspace / item + a design-pages cache for that item.
  // Skipping init() keeps these tests focused on the rename contract. The cache is the source of
  // truth for design page metadata — both the sidebar tree and DesignView read from it.
  function seedStore() {
    const ws = useWorkspacesStore()
    ws.workspaces = [
      {
        id: 'ws_1',
        name: 'W1',
        icon: '📁',
        expanded: true,
        items: [
          {
            id: 'item_design',
            name: 'Design',
            item_type: 'design',
            tasks: [],
          },
        ],
      },
    ]
    // Set the design pages cache directly (mirrors what fetchDesignPages
    // would have populated).
     
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    ;(ws as any).designPagesByItemId = {
      item_design: [
        {
          id: 'page_1',
          workspace_item_id: 'item_design',
          name: 'Original Name',
          workspace_item_task_id: 'task_1',
          width: 1440,
          height: 1024,
          position: 0,
          created_at: '2026-08-06 00:00:00',
          updated_at: '2026-08-06 00:00:00',
        },
      ],
    }
    return ws
  }

  it('updates the page name optimistically and calls the API with the trimmed name', async () => {
    const ws = seedStore()
    updateDesignPageMock.mockResolvedValueOnce({
      id: 'page_1',
      workspace_item_id: 'item_design',
      name: 'Renamed Page',
      workspace_item_task_id: 'task_1',
      width: 1440,
      height: 1024,
      position: 0,
      created_at: '2026-08-06 00:00:00',
      updated_at: '2026-08-06 00:00:00',
    })

    await ws.renameDesignPage('ws_1', 'item_design', 'page_1', '  Renamed Page  ')

     
    // Optimistic: cache reflects the trimmed value.
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const cached = (ws as any).designPagesByItemId.item_design[0]
    expect(cached.name).toBe('Renamed Page')
    // API: called once with the workspace/item/page ids + width/height
    // (the row's pre-existing geometry) + trimmed name.
    expect(updateDesignPageMock).toHaveBeenCalledTimes(1)
    expect(updateDesignPageMock).toHaveBeenCalledWith('ws_1', 'item_design', 'page_1', {
      width: 1440,
      height: 1024,
      name: 'Renamed Page',
    })
  })

  it('rolls back to the previous name when the API call fails', async () => {
    const ws = seedStore()
    const error = new Error('500 Internal Server Error')
    updateDesignPageMock.mockRejectedValueOnce(error)

    await expect(
      ws.renameDesignPage('ws_1', 'item_design', 'page_1', 'Renamed Page'),
    ).rejects.toThrow('500 Internal Server Error')

 

    // Rollback: name reverts to the original.
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const cached = (ws as any).designPagesByItemId.item_design[0]
    expect(cached.name).toBe('Original Name')
  })

  it('rejects empty / whitespace-only names (no API call)', async () => {
    const ws = seedStore()

     
    await ws.renameDesignPage('ws_1', 'item_design', 'page_1', '   ')
    expect(updateDesignPageMock).not.toHaveBeenCalled()
    // Name unchanged.
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const cached = (ws as any).designPagesByItemId.item_design[0]
    expect(cached.name).toBe('Original Name')
  })

  it('rejects unchanged names (no API call)', async () => {
    const ws = seedStore()

    await ws.renameDesignPage('ws_1', 'item_design', 'page_1', 'Original Name')
    expect(updateDesignPageMock).not.toHaveBeenCalled()
  })

  it('is a no-op when the page id is not in the local cache', async () => {
    const ws = seedStore()

    await ws.renameDesignPage('ws_1', 'item_design', 'page_nonexistent', 'New Name')
    expect(updateDesignPageMock).not.toHaveBeenCalled()
  })
})