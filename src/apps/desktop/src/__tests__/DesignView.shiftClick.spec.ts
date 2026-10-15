/**
 * Behavioural tests for the canvas Shift+click multi-select toggle
 * (Chunk 3 of the right-click group menu plan).
 *
 * Before this chunk the canvas's @select on DesignElement hard-coded
 * `additive: false`, so Shift+click on canvas never toggled membership.
 * This chunk wires `event.shiftKey` through DesignElement.vue's select
 * emit so the canvas matches the layers panel behaviour.
 *
 * 4 tests:
 *   1. Plain click on canvas element B selects only B.
 *   2. Shift+click on canvas element C adds it to the selection.
 *   3. Shift+click on canvas element C again toggles it OFF.
 *   4. Shift+click on element A (not in selection) extends selection.
 *
 * The canvas's `selectedIds` is local state in DesignView; the
 * LayersPanel reads it via a :selected-ids prop, so the assertions
 * go through the prop on the rendered <LayersPanel>.
 */
import { beforeEach, describe, expect, it, vi } from 'vitest'
import { flushPromises, mount } from '@vue/test-utils'
import { createPinia, setActivePinia } from 'pinia'
import DesignView from '../components/design/DesignView.vue'
import { useWorkspacesStore } from '../stores/workspaces'

const { listDesignPagesMock } = vi.hoisted(() => ({
  listDesignPagesMock: vi.fn().mockResolvedValue({
    pages: [
      {
        id: 'page_1',
        workspace_item_id: 'item_1',
        name: 'Test Page',
        width: 1440,
        height: 1024,
        position: 0,
        created_at: '2026-07-29 12:00:00',
        updated_at: '2026-07-29 12:00:00',
      },
    ],
    count: 1,
  }),
}))

vi.mock('../api', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../api')>()
  return {
    ...actual,
    listDesignPages: listDesignPagesMock,
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
    x: 100,
    y: 100,
    width: 200,
    height: 200,
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

describe('DesignView canvas Shift+click multi-select toggle', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    vi.clearAllMocks()
  })

 

  // Helper: mount DesignView with 3 elements and let initial load settle.
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  async function mountWith(elements: any[]): Promise<any> {
    const store = useWorkspacesStore()
    store.setActiveDesignPage('page_1')
    const wrapper = mount(DesignView, {
      props: { item: { ...ITEM, design_elements: elements }, workspaceId: 'ws_1', itemId: 'item_1' },
    })
    await flushPromises()
    return wrapper
  }

  // Helper: dispatch a pointerdown on a <DesignElement>'s root.
   
  // jsdom 29 makes PointerEvent.button a readonly getter, so we use native dispatchEvent.
  // setPointerCapture stubbed to a noop so the drag handler doesn't blow up in jsdom.
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  function dispatchSelect(wrapper: any, elementId: string, shiftKey: boolean): void {
    const target = wrapper.find(`[data-testid="design-element-${elementId}"]`)
    if (!target.exists()) throw new Error(`Element ${elementId} not found in canvas`)
    const rootEl = target.element as HTMLElement
    rootEl.setPointerCapture = () => {}
    rootEl.releasePointerCapture = () => {}
    rootEl.hasPointerCapture = (): boolean => true
    rootEl.dispatchEvent(new PointerEvent('pointerdown', {
      button: 0,
      pointerId: 1,
      clientX: 100,
      clientY: 100,
      shiftKey,
      bubbles: true,
    }))
  }

  it('plain click on canvas element B selects only B', async () => {
    const wrapper = await mountWith([
      makeEl({ id: 'el_a', z_index: 2 }),
      makeEl({ id: 'el_b', z_index: 1 }),
      makeEl({ id: 'el_c', z_index: 0 }),
    ])
    try {
      dispatchSelect(wrapper, 'el_b', false)
      await flushPromises()
      const layers = wrapper.findComponent({ name: 'LayersPanel' })
      expect(layers.props('selectedIds')).toEqual(['el_b'])
    } finally {
      wrapper.unmount()
    }
  })

  it('Shift+click on canvas element C adds it to the selection', async () => {
    const wrapper = await mountWith([
      makeEl({ id: 'el_a', z_index: 2 }),
      makeEl({ id: 'el_b', z_index: 1 }),
      makeEl({ id: 'el_c', z_index: 0 }),
    ])
    try {
      dispatchSelect(wrapper, 'el_b', false)
      await flushPromises()
      dispatchSelect(wrapper, 'el_c', true)
      await flushPromises()
      const layers = wrapper.findComponent({ name: 'LayersPanel' })
      const ids = layers.props('selectedIds') as string[]
      expect(ids).toContain('el_b')
      expect(ids).toContain('el_c')
      expect(ids).toHaveLength(2)
    } finally {
      wrapper.unmount()
    }
  })

  it('Shift+click on canvas element C again toggles it OFF', async () => {
    const wrapper = await mountWith([
      makeEl({ id: 'el_a', z_index: 2 }),
      makeEl({ id: 'el_b', z_index: 1 }),
      makeEl({ id: 'el_c', z_index: 0 }),
    ])
    try {
      dispatchSelect(wrapper, 'el_b', false)
      await flushPromises()
      dispatchSelect(wrapper, 'el_c', true)
      await flushPromises()
      dispatchSelect(wrapper, 'el_c', true) // toggle off
      await flushPromises()
      const layers = wrapper.findComponent({ name: 'LayersPanel' })
      expect(layers.props('selectedIds')).toEqual(['el_b'])
    } finally {
      wrapper.unmount()
    }
  })

  it('Shift+click on element A (not in selection) extends selection', async () => {
    const wrapper = await mountWith([
      makeEl({ id: 'el_a', z_index: 2 }),
      makeEl({ id: 'el_b', z_index: 1 }),
      makeEl({ id: 'el_c', z_index: 0 }),
    ])
    try {
      dispatchSelect(wrapper, 'el_b', false)
      await flushPromises()
      dispatchSelect(wrapper, 'el_a', true)
      await flushPromises()
      const layers = wrapper.findComponent({ name: 'LayersPanel' })
      const ids = layers.props('selectedIds') as string[]
      expect(ids).toContain('el_b')
      expect(ids).toContain('el_a')
      expect(ids).toHaveLength(2)
    } finally {
      wrapper.unmount()
    }
  })
})