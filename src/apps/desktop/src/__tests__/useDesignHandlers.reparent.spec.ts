/** Behavioural tests for `useDesignHandlers.reparentLayers`.
 * Plan: docs/superpowers/plans/2026-07-30-design-layer-drag-join-or-leave-group.md
 * (Chunk 2 Task 2.3) */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'

import { useDesignHandlers } from '../composables/useDesignHandlers'
import { useNotificationStore } from '../stores/notifications'

describe('useDesignHandlers.reparentLayers', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
  })

  afterEach(() => {
    vi.restoreAllMocks()
  })

  it('calls the BATCH endpoint regardless of selection size (1 OR N elements)', async () => {
    // N-element selection
    const apiMock = vi
      .spyOn(await import('../api'), 'reparentDesignElementsBatch')
      .mockResolvedValueOnce({ updated: [] })

    const handler = useDesignHandlers({
      workspaceId: 'ws_1',
      itemId: 'item_1',
      pageId: 'page_1',
      selectedIds: { value: new Set<string>() },
    })
    await handler.reparentLayers({
      workspaceId: 'ws_1',
      itemId: 'item_1',
      pageId: 'page_1',
      elementIds: ['elem_a', 'elem_b', 'elem_c'],
      newParentId: 'group_x',
    })

    expect(apiMock).toHaveBeenCalledTimes(1)
    const [, , , passedBody] = apiMock.mock.calls[0]!
    expect(passedBody).toEqual({
      element_ids: ['elem_a', 'elem_b', 'elem_c'],
      new_parent_id: 'group_x',
      reposition: 'last_in_parent',
    })

    // Single-element: same shape (still goes through batch endpoint
    // with element_ids.length === 1).
    apiMock.mockResolvedValueOnce({ updated: [] })
    await handler.reparentLayers({
      workspaceId: 'ws_1',
      itemId: 'item_1',
      pageId: 'page_1',
      elementIds: ['elem_a'],
      newParentId: 'group_x',
    })
    expect(apiMock).toHaveBeenCalledTimes(2)
  })

  it('sends newParentId=null through as null in the batch body (leave group)', async () => {
    const apiMock = vi
      .spyOn(await import('../api'), 'reparentDesignElementsBatch')
      .mockResolvedValueOnce({ updated: [] })

    const handler = useDesignHandlers({
      workspaceId: 'ws_1',
      itemId: 'item_1',
      pageId: 'page_1',
      selectedIds: { value: new Set<string>() },
    })
    await handler.reparentLayers({
      workspaceId: 'ws_1',
      itemId: 'item_1',
      pageId: 'page_1',
      elementIds: ['elem_a', 'elem_b'],
      newParentId: null,
    })

    const [, , , passedBody] = apiMock.mock.calls[0]!
    expect(passedBody.new_parent_id).toBe(null)
  })

  it('shows an error notification when the API rejects with CycleDetected (or any error)', async () => {
    const notif = useNotificationStore()
    vi.spyOn(await import('../api'), 'reparentDesignElementsBatch').mockRejectedValueOnce(
      Object.assign(new Error('cycle'), {
        status: 400,
        body: 'Reparenting would create a cycle',
      }) as never,
    )

    const handler = useDesignHandlers({
      workspaceId: 'ws_1',
      itemId: 'item_1',
      pageId: 'page_1',
      selectedIds: { value: new Set<string>() },
    })
    await handler.reparentLayers({
      workspaceId: 'ws_1',
      itemId: 'item_1',
      pageId: 'page_1',
      elementIds: ['elem_a', 'elem_b'],
      newParentId: 'group_x',
    })

    expect(notif.notifications.length).toBeGreaterThan(0)
    const last = notif.notifications[notif.notifications.length - 1]!
    expect(last.message).toContain('cycle')
  })

  it('is a quiet no-op when any of wsId/itemId/pageId is empty OR elementIds is empty', async () => {
    const apiMock = vi
      .spyOn(await import('../api'), 'reparentDesignElementsBatch')
      .mockResolvedValueOnce({ updated: [] })

    const handler = useDesignHandlers({
      workspaceId: 'ws_1',
      itemId: 'item_1',
      pageId: 'page_1',
      selectedIds: { value: new Set<string>() },
    })

    // Empty wsId
    await handler.reparentLayers({
      workspaceId: '',
      itemId: 'item_1',
      pageId: 'page_1',
      elementIds: ['elem_a'],
      newParentId: 'group_x',
    })
    // Empty itemId
    await handler.reparentLayers({
      workspaceId: 'ws_1',
      itemId: '',
      pageId: 'page_1',
      elementIds: ['elem_a'],
      newParentId: 'group_x',
    })
    // Empty pageId
    await handler.reparentLayers({
      workspaceId: 'ws_1',
      itemId: 'item_1',
      pageId: '',
      elementIds: ['elem_a'],
      newParentId: 'group_x',
    })
    // Empty elementIds
    await handler.reparentLayers({
      workspaceId: 'ws_1',
      itemId: 'item_1',
      pageId: 'page_1',
      elementIds: [],
      newParentId: 'group_x',
    })

    expect(apiMock).not.toHaveBeenCalled()
  })
})