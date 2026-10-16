/** Behavioural tests for `workspacesStore.reparentDesignElementsBatch`.
 * Plan: docs/superpowers/plans/2026-07-30-design-layer-drag-join-or-leave-group.md
 * (Chunk 2 Task 2.2) */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'

import { useWorkspacesStore } from '../stores/workspaces'
describe('workspacesStore.reparentDesignElementsBatch', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
  })

  afterEach(() => {
    vi.restoreAllMocks()
  })

  function makeWorkspacesStore() {
    const store = useWorkspacesStore()
    // Seed the workspaces array with one workspace + one item + a few
    // design_elements rows.
    store.workspaces = [
      {
        id: 'ws_1',
        name: 'ws',
        position: 0,
        items: [
          {
            id: 'item_1',
            workspace_id: 'ws_1',
            name: 'design item',
            item_type: 'design',
            path: '/tmp/foo',
            position: 0,
            created_at: '2026-07-30 12:00:00',
            updated_at: '2026-07-30 12:00:00',
            design_pages: [
              {
                id: 'page_1',
                workspace_item_id: 'item_1',
                name: 'Login',
                width: 1440,
                height: 1024,
                position: 0,
                created_at: '2026-07-30 12:00:00',
                updated_at: '2026-07-30 12:00:00',
              },
            ],
            design_elements: [
              {
                id: 'elem_a',
                page_id: 'page_1',
                parent_id: '',
                type: 'rectangle',
                name: 'a',
                x: 0, y: 0, width: 100, height: 100,
                z_index: 0, position: 0,
                fill: '', stroke: '', stroke_width: 0, corner_radius: 0, rotation: 0,
                opacity: 1.0, text_content: '', text_style: '',
                image_url: '', file_path: '', created_at: '',
                updated_at: '',
              },
              {
                id: 'elem_b',
                page_id: 'page_1',
                parent_id: '',
                type: 'rectangle',
                name: 'b',
                x: 100, y: 0, width: 100, height: 100,
                z_index: 0, position: 1,
                fill: '', stroke: '', stroke_width: 0, corner_radius: 0, rotation: 0,
                opacity: 1.0, text_content: '', text_style: '',
                image_url: '', file_path: '', created_at: '',
                updated_at: '',
              },
            ],
          },
        ],
      },
    ] as never
    return store
  }

  it('POSTs the batch and mirrors every server response into item.design_elements in input order', async () => {
    const store = makeWorkspacesStore()

    const apiMock = vi
      .spyOn(await import('../api'), 'reparentDesignElementsBatch')
      .mockResolvedValueOnce({
        updated: [
          {
            id: 'elem_a', page_id: 'page_1', parent_id: 'group_1',
            type: 'rectangle', name: 'a',
            x: 0, y: 0, width: 100, height: 100,
            z_index: 0, position: 0,
            fill: '', stroke: '', stroke_width: 0, corner_radius: 0, rotation: 0,
            opacity: 1.0, text_content: '', text_style: '',
            image_url: '', file_path: '', created_at: '', updated_at: '',
          },
          {
            id: 'elem_b', page_id: 'page_1', parent_id: 'group_1',
            type: 'rectangle', name: 'b',
            x: 100, y: 0, width: 100, height: 100,
            z_index: 0, position: 1,
            fill: '', stroke: '', stroke_width: 0, corner_radius: 0, rotation: 0,
            opacity: 1.0, text_content: '', text_style: '',
            image_url: '', file_path: '', created_at: '', updated_at: '',
          },
        ],
      })

    await store.reparentDesignElementsBatch('ws_1', 'item_1', 'page_1', {
      element_ids: ['elem_a', 'elem_b'],
      new_parent_id: 'group_1',
    })

    // The store should call the API with reposition defaulted to last_in_parent.
    expect(apiMock).toHaveBeenCalledTimes(1)
    const [passedWs, passedItem, passedPage, passedBody] = apiMock.mock.calls[0]!
    expect(passedWs).toBe('ws_1')
    expect(passedItem).toBe('item_1')
    expect(passedPage).toBe('page_1')
    expect(passedBody).toEqual({
      element_ids: ['elem_a', 'elem_b'],
      new_parent_id: 'group_1',
      reposition: 'last_in_parent',
    })

    // The store should mirror the server response into local state.
    const item = store.workspaces[0]!.items[0]!
    const ea = item.design_elements!.find((e) => e.id === 'elem_a')!
    const eb = item.design_elements!.find((e) => e.id === 'elem_b')!
    expect(ea.parent_id).toBe('group_1')
    expect(eb.parent_id).toBe('group_1')
  })

  it('sends new_parent_id = null to leave a group (top-level)', async () => {
    const store = makeWorkspacesStore()

    const apiMock = vi
      .spyOn(await import('../api'), 'reparentDesignElementsBatch')
      .mockResolvedValueOnce({
        updated: [
          {
            id: 'elem_a', page_id: 'page_1', parent_id: '',
            type: 'rectangle', name: 'a',
            x: 0, y: 0, width: 100, height: 100,
            z_index: 0, position: 0,
            fill: '', stroke: '', stroke_width: 0, corner_radius: 0, rotation: 0,
            opacity: 1.0, text_content: '', text_style: '',
            image_url: '', file_path: '', created_at: '', updated_at: '',
          },
        ],
      })

    await store.reparentDesignElementsBatch('ws_1', 'item_1', 'page_1', {
      element_ids: ['elem_a'],
      new_parent_id: null,
    })

    const [, , , passedBody] = apiMock.mock.calls[0]!
    expect(passedBody.new_parent_id).toBe(null)
  })

  it('propagates backend errors (cycle) without mutating local state', async () => {
    const store = makeWorkspacesStore()

    vi.spyOn(await import('../api'), 'reparentDesignElementsBatch').mockRejectedValueOnce(
      Object.assign(new Error('cycle'), {
        status: 400,
        body: 'Reparenting would create a cycle',
      }) as never,
    )

    await expect(
      store.reparentDesignElementsBatch('ws_1', 'item_1', 'page_1', {
        element_ids: ['elem_a'],
        new_parent_id: 'group_x',
      }),
    ).rejects.toMatchObject({ status: 400 })

    // Local state unchanged: elem_a still has parent_id === ''.
    const item = store.workspaces[0]!.items[0]!
    const ea = item.design_elements!.find((e) => e.id === 'elem_a')!
    expect(ea.parent_id).toBe('')
  })

  it('defaults the reposition field to "last_in_parent" when not provided', async () => {
    const store = makeWorkspacesStore()

    const apiMock = vi
      .spyOn(await import('../api'), 'reparentDesignElementsBatch')
      .mockResolvedValueOnce({ updated: [] })

    await store.reparentDesignElementsBatch('ws_1', 'item_1', 'page_1', {
      element_ids: ['elem_a'],
      new_parent_id: null,
    })

    const [, , , passedBody] = apiMock.mock.calls[0]!
    expect(passedBody.reposition).toBe('last_in_parent')
  })
})