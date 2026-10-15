/**
 * Behavioral tests for DesignView.vue's keyboard nudge (arrow keys
 * move selection by 1px; Shift+arrow by 10px). Plan:
 * docs/superpowers/plans/2026-07-25-design-element-drag-and-drop.md
 * (Chunk 4, Task 4.1).
 *
 * 3 tests:
 *   1. Arrow key nudges selection by 1 design-px.
 *   2. Shift+arrow nudges by 10 design-px.
 *   3. Arrow keys are no-op when nothing is selected.
 */
import { beforeEach, describe, expect, it, vi } from 'vitest'
import { flushPromises, mount } from '@vue/test-utils'
import { createPinia, setActivePinia } from 'pinia'
import DesignView from '../DesignView.vue'
import { useWorkspacesStore } from '../../../stores/workspaces'

// vi.mock factories are hoisted above `const` declarations by Vitest, so the spy must be created
// inside `vi.hoisted()` to exist before the factory runs (which eagerly imports DesignView.vue →
// DesignElement.vue → ../../api during module evaluation).
const { updateDesignElementGeometrySpy, listDesignPagesMock } = vi.hoisted(() => ({
  updateDesignElementGeometrySpy: vi.fn().mockResolvedValue({ id: 'el_1' }),
  listDesignPagesMock: vi.fn().mockResolvedValue({
    pages: [
      {
        id: 'page_1',
        workspace_item_id: 'item_1',
        name: 'Test Page',
        width: 1440,
        height: 1024,
        position: 0,
        created_at: '2026-07-25 00:00:00',
        updated_at: '2026-07-25 00:00:00',
      },
    ],
    count: 1,
  }),
}))

vi.mock('../../../api', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../../../api')>()
  return {
    ...actual,
    listDesignPages: listDesignPagesMock,
    updateDesignElementGeometry: updateDesignElementGeometrySpy,
  }
})

const ITEM = {
  id: 'item_1', name: 'Test', item_type: 'design', path: '', design_elements: [],
  workspace_id: 'ws_1',
 
// eslint-disable-next-line @typescript-eslint/no-explicit-any
} as any

const ELEMENT = {
  id: 'el_1', name: 'Box', type: 'rectangle', page_id: 'page_1',
  x: 100, y: 100, width: 200, height: 200,
  rotation: 0, opacity: 1, fill: '#fff', stroke: '', stroke_width: 0,
  corner_radius: 0, text_content: '', text_style: '', image_url: '',
   
  z_index: 0, position: 0, file_path: '', created_at: '', updated_at: '',
// eslint-disable-next-line @typescript-eslint/no-explicit-any
} as any

describe('DesignView keyboard nudge', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    vi.clearAllMocks()
  })

  it('arrow key nudges selection by 1 design-px', async () => {
    const store = useWorkspacesStore()
    store.setActiveDesignPage('page_1')
    const wrapper = mount(DesignView, {
      props: { item: { ...ITEM, design_elements: [ELEMENT] }, workspaceId: 'ws_1', itemId: 'item_1' },
    })
    try {
      await flushPromises()
      // Select the element by dispatching a native pointerdown on its
      // root. Use native dispatchEvent (NOT wrapper.trigger) — jsdom 29
      // makes MouseEvent.button a readonly getter, which @vue/test-utils
      // tries to assign post-construction (same workaround used in
      // DesignElement.drag.spec.ts).
      const elementEl = wrapper.find('[data-design-element]').element as HTMLElement
      elementEl.setPointerCapture = () => {}
      elementEl.releasePointerCapture = () => {}
      elementEl.hasPointerCapture = (): boolean => true
      elementEl.dispatchEvent(new PointerEvent('pointerdown', {
        button: 0, pointerId: 1, clientX: 100, clientY: 100, bubbles: true,
      }))
      await flushPromises()
      updateDesignElementGeometrySpy.mockClear()
      // Arrow right.
      document.dispatchEvent(new KeyboardEvent('keydown', { key: 'ArrowRight' }))
      await flushPromises()
       
      // Expect at least one call with x=101.
      const calls = updateDesignElementGeometrySpy.mock.calls
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      expect(calls.some((c: any[]) => c[4]?.x === 101)).toBe(true)
    } finally {
      wrapper.unmount()
    }
  })

  it('Shift+arrow nudges by 10 design-px', async () => {
    const store = useWorkspacesStore()
    store.setActiveDesignPage('page_1')
    const wrapper = mount(DesignView, {
      props: { item: { ...ITEM, design_elements: [ELEMENT] }, workspaceId: 'ws_1', itemId: 'item_1' },
    })
    try {
      await flushPromises()
      const elementEl = wrapper.find('[data-design-element]').element as HTMLElement
      elementEl.setPointerCapture = () => {}
      elementEl.releasePointerCapture = () => {}
      elementEl.hasPointerCapture = (): boolean => true
      elementEl.dispatchEvent(new PointerEvent('pointerdown', {
        button: 0, pointerId: 1, clientX: 100, clientY: 100, bubbles: true,
      }))
      await flushPromises()
      updateDesignElementGeometrySpy.mockClear()
       
      document.dispatchEvent(new KeyboardEvent('keydown', { key: 'ArrowRight', shiftKey: true }))
      await flushPromises()
      const calls = updateDesignElementGeometrySpy.mock.calls
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      expect(calls.some((c: any[]) => c[4]?.x === 110)).toBe(true)
    } finally {
      wrapper.unmount()
    }
  })

  it('arrow keys are no-op when nothing is selected', async () => {
    const store = useWorkspacesStore()
    store.setActiveDesignPage('page_1')
    const wrapper = mount(DesignView, {
      props: { item: { ...ITEM, design_elements: [ELEMENT] }, workspaceId: 'ws_1', itemId: 'item_1' },
    })
    try {
      await flushPromises()
      updateDesignElementGeometrySpy.mockClear()
      document.dispatchEvent(new KeyboardEvent('keydown', { key: 'ArrowRight' }))
      await flushPromises()
      expect(updateDesignElementGeometrySpy).not.toHaveBeenCalled()
    } finally {
      wrapper.unmount()
    }
  })
})
