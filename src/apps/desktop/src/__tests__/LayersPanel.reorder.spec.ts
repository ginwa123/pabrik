/** Wire-up regression test for LayersPanel.vue ▲/▼ buttons. Pre-fix symptom (silent-drop bug):
 * clicking ▲ or ▼ on a layer row emits `reorder` upward → DesignView re-emits as `reorderElements`
 * → AppLayout has no `@reorder-elements` listener → nothing happens. */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { mount, type VueWrapper } from '@vue/test-utils'
import { createPinia, setActivePinia } from 'pinia'
import { nextTick } from 'vue'
import LayersPanel from '../components/design/LayersPanel.vue'
import { useWorkspacesStore } from '../stores/workspaces'
import type { DesignElement } from '../api'

function makeElement(overrides: Partial<DesignElement> = {}): DesignElement {
  return {
    id: 'elem_1',
    page_id: 'page_1',
    name: 'Element 1',
    type: 'rectangle',
    x: 0,
    y: 0,
    width: 100,
    height: 50,
    rotation: 0,
    fill: '#ffffff',
    stroke: '',
    stroke_width: 1,
    corner_radius: 0,
    opacity: 1,
    text_content: '',
    text_style: '',
    image_url: '',
    file_path: '',
    parent_id: null,
    z_index: 0,
    position: 0,
    created_at: '2026-07-29 12:00:00',
    updated_at: '2026-07-29 12:00:00',
    ...overrides,
  }
}

describe('LayersPanel ▲/▼ wire-up (Chunk 1 of undo/redo plan)', () => {
  let wrapper: VueWrapper | null = null

  beforeEach(() => {
    setActivePinia(createPinia())
  })

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    vi.restoreAllMocks()
  })

  it('▲ button on layer row triggers reorderDesignElements with mode: "bring_forward"', async () => {
    const store = useWorkspacesStore()
    // Seed an active workspace/item/page so the store can resolve them
    // from activeWorkspace / activeWorkspaceItem / activeDesignPageId.
    store.workspaces.push({
      id: 'ws_1',
      name: 'WS',
      items: [
        {
          id: 'item_1',
          name: 'Design',
          item_type: 'design',
          path: '/tmp',
          workspace_id: 'ws_1',
          design_elements: [],
         
        // eslint-disable-next-line @typescript-eslint/no-explicit-any
        } as any,
       
      ],
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    } as any)
    // The workspace is derived from the active item — no separate
    // setActiveWorkspace exists in the store. Setting the active
    // workspace item id is sufficient to resolve both ids.
    store.setActiveWorkspaceItem('item_1')
    store.setActiveDesignPage('page_1')

     
    const reorderSpy = vi
      .spyOn(store, 'reorderDesignElements')
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      .mockResolvedValue([] as any)

    // Render with 3 elements (z_index DESC: top to bottom). The panel
    // shows them top-down. Click ▲ on the middle one (z_index 1).
    const elements = [
      makeElement({ id: 'elem_a', z_index: 2, position: 0 }),
      makeElement({ id: 'elem_b', z_index: 1, position: 1 }),
      makeElement({ id: 'elem_c', z_index: 0, position: 2 }),
    ]
    wrapper = mount(LayersPanel, {
      props: { elements, selectedIds: [], readonly: false },
    })
    await nextTick()

    const upButton = wrapper.find(
      '[data-testid="design-layer-reorder-up-elem_b"]',
    )
    expect(upButton.exists()).toBe(true)
    await upButton.trigger('click')

    expect(reorderSpy).toHaveBeenCalledOnce()
    const [wsId, itemId, pageId, mode, ids] = reorderSpy.mock.calls[0]!
    expect(wsId).toBe('ws_1')
    expect(itemId).toBe('item_1')
    expect(pageId).toBe('page_1')
    expect(mode).toBe('bring_forward')
    // The store action takes just the moved id (mirrors the keyboard
    // shortcut path which passes `selectedIds`); the server applies
    // the mode to each id and returns the reordered rows.
    expect(ids).toEqual(['elem_b'])
  })

  it('▼ button on layer row triggers reorderDesignElements with mode: "send_backward"', async () => {
    const store = useWorkspacesStore()
    store.workspaces.push({
      id: 'ws_1',
      name: 'WS',
      items: [
        {
          id: 'item_1',
          name: 'Design',
          item_type: 'design',
           
          path: '/tmp',
          workspace_id: 'ws_1',
           
          design_elements: [],
        // eslint-disable-next-line @typescript-eslint/no-explicit-any
        } as any,
      ],
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    } as any)
     
    store.setActiveWorkspaceItem('item_1')
    store.setActiveDesignPage('page_1')

    const reorderSpy = vi
      .spyOn(store, 'reorderDesignElements')
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      .mockResolvedValue([] as any)

    const elements = [
      makeElement({ id: 'elem_a', z_index: 2, position: 0 }),
      makeElement({ id: 'elem_b', z_index: 1, position: 1 }),
      makeElement({ id: 'elem_c', z_index: 0, position: 2 }),
    ]
    wrapper = mount(LayersPanel, {
      props: { elements, selectedIds: [], readonly: false },
    })
    await nextTick()

    const downButton = wrapper.find(
      '[data-testid="design-layer-reorder-down-elem_b"]',
    )
    expect(downButton.exists()).toBe(true)
    await downButton.trigger('click')

    expect(reorderSpy).toHaveBeenCalledOnce()
    const [, , , mode, ids] = reorderSpy.mock.calls[0]!
    expect(mode).toBe('send_backward')
    expect(ids).toEqual(['elem_b'])
  })
})
