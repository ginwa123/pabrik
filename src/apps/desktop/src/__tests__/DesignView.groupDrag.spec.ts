/** Behavioural tests for the group-drag move-batch wire. */

/** Plan: docs/superpowers/plans/2026-08-06-move-element-with-descendants.md (Chunk 4, Task 4.3) The
 * drag path now uses `moveDesignElementsBatch` (server-side cascade) instead of
 * `updateDesignElementsGeometryBatch` (frontend expansion + N x/y pairs). */

/** The tests below exercise the new wire. */
import { beforeEach, describe, expect, it, vi } from 'vitest'
import { flushPromises, mount } from '@vue/test-utils'
import { createPinia, setActivePinia } from 'pinia'
import DesignView from '../components/design/DesignView.vue'
import { useWorkspacesStore } from '../stores/workspaces'

const { listDesignPagesMock, moveBatchSpy } = vi.hoisted(() => ({
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
  moveBatchSpy: vi.fn().mockResolvedValue({ updated: [] }),
}))

vi.mock('../api', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../api')>()
  return {
    ...actual,
    listDesignPages: listDesignPagesMock,
    moveDesignElementsBatch: moveBatchSpy,
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


 

describe('DesignView group drag — move-batch (server-side cascade)', () => {
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  let moveSpy: any

  beforeEach(() => {
    setActivePinia(createPinia())
    vi.clearAllMocks()
    moveSpy = vi.fn().mockResolvedValue({
      updated: [
        makeEl({ id: 'el_1', x: 50, y: 70 }),
        makeEl({ id: 'el_2', x: 100, y: 120 }),
      ],
    })
  })

  it('groupDrag with a 5-element selection fires ONE moveDesignElementsBatch call per pointermove (not N per-element PATCHes)', async () => {
    const _store = useWorkspacesStore()
    _store.setActiveDesignPage('page_1')

    // Spy on the SINGLE-element action — must NOT be called during a
    // group drag (the whole point of the batch is to avoid N calls).
    const singleSpy = vi.spyOn(_store, 'updateDesignElementGeometry')
    vi.spyOn(_store, 'moveDesignElementsBatch').mockImplementation(moveSpy)

    const elements = [
      makeEl({ id: 'el_1', x: 0, y: 0 }),
      makeEl({ id: 'el_2', x: 50, y: 0 }),
      makeEl({ id: 'el_3', x: 100, y: 0 }),
      makeEl({ id: 'el_4', x: 150, y: 0 }),
      makeEl({ id: 'el_5', x: 200, y: 0 }),
    ]
    const wrapper = mount(DesignView, {
      props: { item: { ...ITEM, design_elements: elements }, workspaceId: 'ws_1', itemId: 'item_1' },
    })
     
    await flushPromises()

     
    // Simulate a 5-element multi-selection by setting selectedIds on the VM.
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    ;(wrapper.vm as any).selectedIds = new Set(['el_1', 'el_2', 'el_3', 'el_4', 'el_5'])

    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    ;(wrapper.vm as any).handleGroupDrag({ dx: 10, dy: 20 })
    await flushPromises()

    expect(moveSpy).toHaveBeenCalledTimes(1)
    expect(singleSpy).not.toHaveBeenCalled()
  })

  it('groupDrag calls moveDesignElementsBatch with one item per selected element (no client-side expansion)', async () => {
    const _store = useWorkspacesStore()
    _store.setActiveDesignPage('page_1')
    const singleSpy = vi.spyOn(_store, 'updateDesignElementGeometry')
    // The legacy batch endpoint must NOT be called; the cascade is
    // server-side now.
    const geoBatchSpy = vi.spyOn(_store, 'updateDesignElementsGeometryBatch')
    vi.spyOn(_store, 'moveDesignElementsBatch').mockImplementation(moveSpy)

    const elements = [
      makeEl({ id: 'el_1', x: 0, y: 0 }),
      makeEl({ id: 'el_2', x: 50, y: 0 }),
      makeEl({ id: 'el_3', x: 100, y: 0 }),
     
    ]
    const wrapper = mount(DesignView, {
       
      props: { item: { ...ITEM, design_elements: elements }, workspaceId: 'ws_1', itemId: 'item_1' },
    })
    await flushPromises()
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    ;(wrapper.vm as any).selectedIds = new Set(['el_1', 'el_2', 'el_3'])

    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    ;(wrapper.vm as any).handleGroupDrag({ dx: 10, dy: 20 })
    await flushPromises()

     
    expect(moveSpy).toHaveBeenCalledTimes(1)
    expect(geoBatchSpy).not.toHaveBeenCalled()
    expect(singleSpy).not.toHaveBeenCalled()

    // Wire shape: ONE item per selected element, each carrying the cursor delta (rounded). Backend
    // cascades the delta to descendants via the recursive CTE. eslint-disable-next-line
    // @typescript-eslint/no-explicit-any
    const callArgs = moveSpy.mock.calls[0] as any[]
    const items = callArgs[3] as Array<{ element_id: string; dx: number; dy: number }>
    expect(items.length).toBe(3)
    expect(items[0]!.element_id).toBe('el_1')
    expect(items[0]!.dx).toBe(10)
    expect(items[0]!.dy).toBe(20)
    expect(items[1]!.element_id).toBe('el_2')
    expect(items[2]!.element_id).toBe('el_3')
  })

  it('groupDrag with a single leaf selection fires moveDesignElementsBatch with one item', async () => {
    const _store = useWorkspacesStore()
     
    _store.setActiveDesignPage('page_1')
    vi.spyOn(_store, 'moveDesignElementsBatch').mockImplementation(moveSpy)

 

    const elements = [makeEl({ id: 'el_1', x: 0, y: 0 })]
    const wrapper = mount(DesignView, {
      props: { item: { ...ITEM, design_elements: elements }, workspaceId: 'ws_1', itemId: 'item_1' },
     
    })
    await flushPromises()
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    ;(wrapper.vm as any).selectedIds = new Set(['el_1'])

    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    ;(wrapper.vm as any).handleGroupDrag({ dx: 5, dy: 0 })
    await flushPromises()

    expect(moveSpy).toHaveBeenCalledTimes(1)
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const items = (moveSpy.mock.calls[0] as any)[3] as Array<{ element_id: string; dx: number; dy: number }>
    expect(items.length).toBe(1)
    expect(items[0]!.element_id).toBe('el_1')
    expect(items[0]!.dx).toBe(5)
    expect(items[0]!.dy).toBe(0)
  })
})
