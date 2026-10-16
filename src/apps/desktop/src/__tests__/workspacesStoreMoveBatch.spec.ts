/**  * Behavioural tests for `workspacesStore.moveDesignElementsBatch`. Plan:
 * docs/superpowers/plans/2026-08-06-move-element-with-descendants.md (Chunk 3, Task 3.3) */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'

import { useWorkspacesStore } from '../stores/workspaces'
describe('workspacesStore.moveDesignElementsBatch', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
  })

  afterEach(() => {
    vi.restoreAllMocks()
  })

  function makeWorkspacesStore() {
    const store = useWorkspacesStore()
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
            created_at: '2026-08-06 12:00:00',
            updated_at: '2026-08-06 12:00:00',
            design_pages: [
              {
                id: 'page_1',
                workspace_item_id: 'item_1',
                name: 'Login',
                width: 1440,
                height: 1024,
                position: 0,
                created_at: '2026-08-06 12:00:00',
                updated_at: '2026-08-06 12:00:00',
              },
            ],
            design_elements: [
              {
                id: 'elem_root',
                page_id: 'page_1',
                parent_id: '',
                type: 'frame',
                name: 'root',
                x: 0, y: 0, width: 200, height: 200,
                z_index: 0, position: 0,
                fill: '', stroke: '', stroke_width: 0, corner_radius: 0, rotation: 0,
                opacity: 1.0, text_content: '', text_style: '',
                image_url: '', file_path: '', created_at: '', updated_at: '',
              },
              {
                id: 'elem_child1',
                page_id: 'page_1',
                parent_id: 'elem_root',
                type: 'rectangle',
                name: 'c1',
                x: 10, y: 10, width: 50, height: 50,
                z_index: 0, position: 0,
                fill: '', stroke: '', stroke_width: 0, corner_radius: 0, rotation: 0,
                opacity: 1.0, text_content: '', text_style: '',
                image_url: '', file_path: '', created_at: '', updated_at: '',
              },
              {
                id: 'elem_child2',
                page_id: 'page_1',
                parent_id: 'elem_root',
                type: 'rectangle',
                name: 'c2',
                x: 100, y: 100, width: 50, height: 50,
                z_index: 0, position: 1,
                fill: '', stroke: '', stroke_width: 0, corner_radius: 0, rotation: 0,
                opacity: 1.0, text_content: '', text_style: '',
                image_url: '', file_path: '', created_at: '', updated_at: '',
              },
            ],
          },
        ],
      },
    ] as never
    return store
  }

  it('POSTs the move-batch to the right URL with the right body', async () => {
    const store = makeWorkspacesStore()

    const apiMock = vi
      .spyOn(await import('../api'), 'moveDesignElementsBatch')
      .mockResolvedValueOnce({
        updated: [
          {
            id: 'elem_root', page_id: 'page_1', parent_id: '',
            type: 'frame', name: 'root',
            x: 100, y: 50, width: 200, height: 200,
            z_index: 0, position: 0,
            fill: '', stroke: '', stroke_width: 0, corner_radius: 0, rotation: 0,
            opacity: 1.0, text_content: '', text_style: '',
            image_url: '', file_path: '', created_at: '', updated_at: '',
          },
        ],
      })

    await store.moveDesignElementsBatch('ws_1', 'item_1', 'page_1', [
      { element_id: 'elem_root', dx: 100, dy: 50 },
    ])

    expect(apiMock).toHaveBeenCalledWith('ws_1', 'item_1', 'page_1', {
      items: [{ element_id: 'elem_root', dx: 100, dy: 50 }],
    })
  })

  it('mirrors every returned updated row into item.design_elements in input order', async () => {
    const store = makeWorkspacesStore()

    vi.spyOn(await import('../api'), 'moveDesignElementsBatch').mockResolvedValueOnce({
      updated: [
        {
          id: 'elem_root', page_id: 'page_1', parent_id: '',
          type: 'frame', name: 'root',
          x: 100, y: 50, width: 200, height: 200,
          z_index: 0, position: 0,
          fill: '', stroke: '', stroke_width: 0, corner_radius: 0, rotation: 0,
          opacity: 1.0, text_content: '', text_style: '',
          image_url: '', file_path: '', created_at: '', updated_at: '',
        },
        {
          id: 'elem_child1', page_id: 'page_1', parent_id: 'elem_root',
          type: 'rectangle', name: 'c1',
          x: 110, y: 60, width: 50, height: 50,
          z_index: 0, position: 0,
          fill: '', stroke: '', stroke_width: 0, corner_radius: 0, rotation: 0,
          opacity: 1.0, text_content: '', text_style: '',
          image_url: '', file_path: '', created_at: '', updated_at: '',
        },
        {
          id: 'elem_child2', page_id: 'page_1', parent_id: 'elem_root',
          type: 'rectangle', name: 'c2',
          x: 200, y: 150, width: 50, height: 50,
          z_index: 0, position: 1,
          fill: '', stroke: '', stroke_width: 0, corner_radius: 0, rotation: 0,
          opacity: 1.0, text_content: '', text_style: '',
          image_url: '', file_path: '', created_at: '', updated_at: '',
        },
      ] as never,
    })

    const result = await store.moveDesignElementsBatch('ws_1', 'item_1', 'page_1', [
      { element_id: 'elem_root', dx: 100, dy: 50 },
    ])
    expect(result.length).toBe(3)

    // Local cache mirrors the server response.
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const elements = (store.workspaces[0] as any).items[0].design_elements
    expect(elements[0].x).toBe(100)
    expect(elements[0].y).toBe(50)
    expect(elements[1].x).toBe(110)
    expect(elements[1].y).toBe(60)
    expect(elements[2].x).toBe(200)
    expect(elements[2].y).toBe(150)
  })

  it('returns [] for empty items (no API call)', async () => {
    const store = makeWorkspacesStore()
    const spy = vi.spyOn(await import('../api'), 'moveDesignElementsBatch')

    const result = await store.moveDesignElementsBatch('ws_1', 'item_1', 'page_1', [])
    expect(result).toEqual([])
    expect(spy).not.toHaveBeenCalled()
  })

  it('rethrows on API error (does not silently swallow)', async () => {
    const store = makeWorkspacesStore()
    vi.spyOn(await import('../api'), 'moveDesignElementsBatch').mockRejectedValueOnce(
      new Error('cascade failed'),
    )

    await expect(
      store.moveDesignElementsBatch('ws_1', 'item_1', 'page_1', [
        { element_id: 'elem_root', dx: 10, dy: 0 },
      ]),
    ).rejects.toThrow('cascade failed')
  })

  it('passes through optional width/height/rotation to the API wrapper', async () => {
    const store = makeWorkspacesStore()
    const apiMock = vi
      .spyOn(await import('../api'), 'moveDesignElementsBatch')
      .mockResolvedValueOnce({ updated: [] })

    await store.moveDesignElementsBatch('ws_1', 'item_1', 'page_1', [
      { element_id: 'elem_root', dx: 0, dy: 0, width: 500, height: 300, rotation: 0.5 },
    ])

    expect(apiMock).toHaveBeenCalledWith('ws_1', 'item_1', 'page_1', {
      items: [{ element_id: 'elem_root', dx: 0, dy: 0, width: 500, height: 300, rotation: 0.5 }],
    })
  })

  it('local mirror survives a fetchDesignElements array replace (race regression)', async () => {
    // Bug history (2026-08-06): the first drag of a group/frame moved only the group, not the
    // descendants.
    const store = makeWorkspacesStore()

    // Initial baseline: stub getDesignPage to return the same
    // elements array reference (NOT replaced by fetch).
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const baseline = (store.workspaces[0] as any).items[0].design_elements
    expect(baseline.length).toBe(3)

    // Mock the API to return the cascade — group + 2 children,
    // each with new x/y.
    vi.spyOn(await import('../api'), 'moveDesignElementsBatch').mockResolvedValueOnce({
      updated: [
        {
          id: 'elem_root', page_id: 'page_1', parent_id: '',
          type: 'frame', name: 'root',
          x: 100, y: 50, width: 200, height: 200,
          z_index: 0, position: 0,
          fill: '', stroke: '', stroke_width: 0, corner_radius: 0, rotation: 0,
          opacity: 1.0, text_content: '', text_style: '',
          image_url: '', file_path: '', created_at: '', updated_at: '',
        },
        {
          id: 'elem_child1', page_id: 'page_1', parent_id: 'elem_root',
          type: 'rectangle', name: 'c1',
          x: 110, y: 60, width: 50, height: 50,
          z_index: 0, position: 0,
          fill: '', stroke: '', stroke_width: 0, corner_radius: 0, rotation: 0,
          opacity: 1.0, text_content: '', text_style: '',
          image_url: '', file_path: '', created_at: '', updated_at: '',
        },
        {
          id: 'elem_child2', page_id: 'page_1', parent_id: 'elem_root',
          type: 'rectangle', name: 'c2',
          x: 200, y: 150, width: 50, height: 50,
          z_index: 0, position: 1,
          fill: '', stroke: '', stroke_width: 0, corner_radius: 0, rotation: 0,
          opacity: 1.0, text_content: '', text_style: '',
          image_url: '', file_path: '', created_at: '', updated_at: '',
        },
      ] as never,
    })

    await store.moveDesignElementsBatch('ws_1', 'item_1', 'page_1', [
      { element_id: 'elem_root', dx: 100, dy: 50 },
    ])

    // CRITICAL: the design_elements array must be the SAME reference after the mirror — Vue 3
    // reactivity depends on per-index writes to the same reactive array.
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const after = (store.workspaces[0] as any).items[0].design_elements
    expect(after).toBe(baseline)
    // All 3 elements were updated in place.
    expect(after[0].x).toBe(100)
    expect(after[0].y).toBe(50)
    expect(after[1].x).toBe(110)
    expect(after[1].y).toBe(60)
    expect(after[2].x).toBe(200)
    expect(after[2].y).toBe(150)
  })

  /** BUG FIX (2026-08-06, design-mode-second-drag): the `POST .../elements/move-batch` endpoint
   * historically emitted `elem_type` (the Zig struct field name) instead of `type` on the wire. */
  it('local mirror preserves `type` when backend emits `elem_type` (legacy wire shape)', async () => {
    const store = makeWorkspacesStore()
    // Seed the store with an item containing a group + a leaf.
    const baseline = [
      {
        id: 'g1', name: 'G', type: 'group', page_id: 'page_1',
        x: 100, y: 100, width: 200, height: 200, rotation: 0,
        fill: '', stroke: '', stroke_width: 0, corner_radius: 0,
        opacity: 1, text_content: '', text_style: '',
        image_url: '', file_path: '', created_at: '', updated_at: '',
         
        parent_id: '', z_index: 0, position: 0,
      },
    ]
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    ;(store.workspaces[0] as any).items[0].design_elements = baseline

    // Backend response uses `elem_type` (the BUGGY shape) — no `type` field.
    vi.spyOn(await import('../api'), 'moveDesignElementsBatch')
      .mockResolvedValueOnce({
        updated: [
          {
            id: 'g1',
            // No `type` field — only `elem_type`.
            elem_type: 'group',
            x: 150, y: 150, width: 200, height: 200,
            rotation: 0, fill: '', stroke: '', stroke_width: 0,
            corner_radius: 0, opacity: 1, text_content: '',
            text_style: '', image_url: '', file_path: '',
            parent_id: '', z_index: 0, position: 0,
            page_id: 'page_1', name: 'G',
            created_at: '', updated_at: '',
          },
        ] as never,
      })

    await store.moveDesignElementsBatch('ws_1', 'item_1', 'page_1', [
      { element_id: 'g1', dx: 50, dy: 50 },
     
    ])

    // EXPECTED: the local mirror preserves `type === 'group'` so the
    // next drag still sees `isGroupLike = true` and uses the cascade.
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const after = (store.workspaces[0] as any).items[0].design_elements
    expect(after[0].type).toBe('group')
    expect(after[0].x).toBe(150)
    expect(after[0].y).toBe(150)
  })

  /**    * Same bug as above but verifying the canonical wire shape is also accepted (the new backend).
   * Locks in that we don't regress the happy path while defending against the legacy shape. */
  it('local mirror preserves `type` when backend emits `type` (canonical wire shape)', async () => {
    const store = makeWorkspacesStore()
    const baseline = [
      {
        id: 'g1', name: 'G', type: 'group', page_id: 'page_1',
        x: 100, y: 100, width: 200, height: 200, rotation: 0,
        fill: '', stroke: '', stroke_width: 0, corner_radius: 0,
         
        opacity: 1, text_content: '', text_style: '',
        image_url: '', file_path: '', created_at: '', updated_at: '',
        parent_id: '', z_index: 0, position: 0,
      },
    ]
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    ;(store.workspaces[0] as any).items[0].design_elements = baseline

    vi.spyOn(await import('../api'), 'moveDesignElementsBatch')
      .mockResolvedValueOnce({
        updated: [
          {
            id: 'g1',
            type: 'group',  // canonical
            x: 150, y: 150, width: 200, height: 200,
            rotation: 0, fill: '', stroke: '', stroke_width: 0,
            corner_radius: 0, opacity: 1, text_content: '',
            text_style: '', image_url: '', file_path: '',
            parent_id: '', z_index: 0, position: 0,
            page_id: 'page_1', name: 'G',
            created_at: '', updated_at: '',
          },
        ] as never,
       
      })

    await store.moveDesignElementsBatch('ws_1', 'item_1', 'page_1', [
      { element_id: 'g1', dx: 50, dy: 50 },
    ])

    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const after = (store.workspaces[0] as any).items[0].design_elements
    expect(after[0].type).toBe('group')
  })
})
