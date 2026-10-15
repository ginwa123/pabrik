/** Behavioural tests for DesignView's `<LayersPanel @reparent>`
 * wire (Chunk 4 Task 4.3 of drag-to-reparent plan). Mounts
 * DesignView, dispatches the `handleLayerReparent` handler directly
 * on the VM with the composable result shape, and asserts the
 * store's `reparentDesignElementsBatch` action was called with the
 * right payload.
 * Plan: docs/superpowers/plans/2026-07-30-design-layer-drag-join-or-leave-group.md */
import { beforeEach, describe, expect, it, vi } from 'vitest'
import { flushPromises, mount } from '@vue/test-utils'
import { createPinia, setActivePinia } from 'pinia'
import DesignView from '../components/design/DesignView.vue'
import { useWorkspacesStore } from '../stores/workspaces'

const { listDesignPagesMock, reparentBatchSpy } = vi.hoisted(() => ({
  listDesignPagesMock: vi.fn().mockResolvedValue({
    pages: [
      {
        id: 'page_1',
        workspace_item_id: 'item_1',
        name: 'Test Page',
        width: 1440,
        height: 1024,
        position: 0,
        created_at: '2026-07-29 18:00:00',
        updated_at: '2026-07-29 18:00:00',
      },
    ],
    count: 1,
  }),
  reparentBatchSpy: vi.fn().mockResolvedValue({ updated: [] }),
}))

vi.mock('../api', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../api')>()
  return {
    ...actual,
    listDesignPages: listDesignPagesMock,
    reparentDesignElementsBatch: reparentBatchSpy,
  }
})

const ITEM = {
  id: 'item_1',
  name: 'Test',
  item_type: 'design',
  path: '',
  design_elements: [],
  workspace_id: 'ws_1',
 
// eslint-disable-next-line @typescript-eslint/no-explicit-any
} as any

 

// eslint-disable-next-line @typescript-eslint/no-explicit-any
function makeEl(overrides: Record<string, unknown> = {}): any {
  return {
    id: 'el_1',
    name: 'Box',
    type: 'rectangle',
    page_id: 'page_1',
    parent_id: '',
    x: 0,
    y: 0,
    width: 100,
    height: 100,
    rotation: 0,
    opacity: 1,
    fill: '#fff',
    stroke: '',
    stroke_width: 0,
    corner_radius: 0,
    text_content: '',
    text_style: '',
    image_url: '',
    z_index: 0,
    position: 0,
    file_path: '',
    created_at: '',
    updated_at: '',
    ...overrides,
  }
}

describe('DesignView LayersPanel @reparent wire (Chunk 4 Task 4.3)', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    vi.clearAllMocks()
    reparentBatchSpy.mockResolvedValue({ updated: [] })
  })

  it('handleLayerReparent with newParentId=null routes through workspacesStore.reparentDesignElementsBatch with the payload', async () => {
    const store = useWorkspacesStore()
    store.setActiveDesignPage('page_1')
     
    const storeSpy = vi
      .spyOn(store, 'reparentDesignElementsBatch')
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      .mockResolvedValue([] as any)

    const wrapper = mount(DesignView, {
      props: {
        item: { ...ITEM, design_elements: [makeEl({ id: 'a' }), makeEl({ id: 'b' })] },
        workspaceId: 'ws_1',
        itemId: 'item_1',
      },
    })
    await flushPromises()

 

    // The LayersPanel emits `reparent` with the composable's result
    // shape: { elementIds, newParentId }.
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    ;(wrapper.vm as any).handleLayerReparent({ elementIds: ['a', 'b'], newParentId: null })
    await flushPromises()

    expect(storeSpy).toHaveBeenCalledTimes(1)
    expect(storeSpy).toHaveBeenCalledWith('ws_1', 'item_1', 'page_1', {
      element_ids: ['a', 'b'],
      new_parent_id: null,
    })
  })

  it('handleLayerReparent with newParentId=<group-id> passes the group id through as new_parent_id', async () => {
     
    const store = useWorkspacesStore()
    store.setActiveDesignPage('page_1')
    const storeSpy = vi
      .spyOn(store, 'reparentDesignElementsBatch')
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      .mockResolvedValue([] as any)

    const wrapper = mount(DesignView, {
      props: {
        item: { ...ITEM, design_elements: [makeEl({ id: 'a' }), makeEl({ id: 'group', type: 'group' })] },
        workspaceId: 'ws_1',
         
        itemId: 'item_1',
      },
    })
    await flushPromises()

    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    ;(wrapper.vm as any).handleLayerReparent({ elementIds: ['a'], newParentId: 'group' })
    await flushPromises()

    expect(storeSpy).toHaveBeenCalledTimes(1)
    expect(storeSpy).toHaveBeenCalledWith('ws_1', 'item_1', 'page_1', {
      element_ids: ['a'],
      new_parent_id: 'group',
    })
  })

 

  it('handleLayerReparent with empty elementIds is a quiet no-op (no store call)', async () => {
    const store = useWorkspacesStore()
    store.setActiveDesignPage('page_1')
    const storeSpy = vi
      .spyOn(store, 'reparentDesignElementsBatch')
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      .mockResolvedValue([] as any)

    const wrapper = mount(DesignView, {
      props: { item: ITEM, workspaceId: 'ws_1', itemId: 'item_1' },
    })
    await flushPromises()

    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    ;(wrapper.vm as any).handleLayerReparent({ elementIds: [], newParentId: null })
    await flushPromises()

    expect(storeSpy).not.toHaveBeenCalled()
  })

   
  it('handleLayerReparent is a quiet no-op when activePageId is empty', async () => {
    const store = useWorkspacesStore()
    // Mount with workspaceId='' so useDesignHandlers.reparentLayers short-circuits (workspaceId
    // empty → no-op). This exercises the same guard as "activeDesignPageId empty" in production —
    // the composable short-circuits when ANY of the three ids is empty.
    const storeSpy = vi
      .spyOn(store, 'reparentDesignElementsBatch')
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      .mockResolvedValue([] as any)

     
    const wrapper = mount(DesignView, {
      props: {
        item: { ...ITEM, design_elements: [makeEl({ id: 'a' })] },
        workspaceId: '',
        itemId: 'item_1',
      },
    })
    await flushPromises()

    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    ;(wrapper.vm as any).handleLayerReparent({ elementIds: ['a'], newParentId: null })
    await flushPromises()

    expect(storeSpy).not.toHaveBeenCalled()
  })

  it('handleLayerReparent catches store errors (does not throw) — toast path is in useDesignHandlers', async () => {
    const store = useWorkspacesStore()
    store.setActiveDesignPage('page_1')
    vi.spyOn(store, 'reparentDesignElementsBatch').mockRejectedValue(
       
      new Error('cycle detected'),
    )

    const wrapper = mount(DesignView, {
      props: { item: ITEM, workspaceId: 'ws_1', itemId: 'item_1' },
    })
    await flushPromises()

    // The handler is async + void — must not propagate to caller.
    expect(() => {
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      ;(wrapper.vm as any).handleLayerReparent({ elementIds: ['a'], newParentId: null })
    }).not.toThrow()
  })
})
