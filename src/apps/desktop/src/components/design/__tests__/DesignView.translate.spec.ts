/**
 * Behavioural tests for the SINGLE-element drag wire.
 *
 * Plan: docs/superpowers/plans/2026-08-06-split-move-resize.md
 *
 * The wire is:
 *   1. User pointerdown on a single (non-group) element body.
 *   2. DesignElement.vue fires `translate` with the (dx, dy) cursor delta.
 *   3. DesignView.vue's `@translate="handleElementTranslate"` handler
 *      receives the delta and emits `translateElement(id, dx, dy)` upward.
 *   4. AppLayout.vue's `@translate-element="handleDesignTranslateElement"`
 *      calls `useDesignHandlers.translateElement` which calls
 *      `workspacesStore.translateDesignElement` which POSTs
 *      `/api/workspaces/.../elements/:id/translate`.
 *
 * This test exercises steps 1-3 by mounting DesignView, dispatching
 * pointerdown + pointermove + pointerup, and asserting the
 * `translateElement` emit carries the right (id, dx, dy).
 *
 * Companion spec `workspacesStoreTranslateResize.spec.ts` covers
 * step 4 at the store layer.
 */
import { beforeEach, describe, expect, it, vi } from 'vitest'
import { flushPromises, mount } from '@vue/test-utils'
import { createPinia, setActivePinia } from 'pinia'
import DesignView from '../DesignView.vue'
import { useWorkspacesStore } from '../../../stores/workspaces'

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
        created_at: '2026-08-06 00:00:00',
        updated_at: '2026-08-06 00:00:00',
      },
    ],
    count: 1,
  }),
}))

vi.mock('../../../api', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../../../api')>()
  return { ...actual, listDesignPages: listDesignPagesMock }
})

const ELEMENT = {
  id: 'el_1', name: 'Box', type: 'rectangle', page_id: 'page_1',
  x: 100, y: 100, width: 200, height: 200,
  rotation: 0, opacity: 1, fill: '#fff', stroke: '', stroke_width: 0,
  corner_radius: 0, text_content: '', text_style: '', image_url: '',
  z_index: 0, position: 0, file_path: '', created_at: '', updated_at: '',
  parent_id: '',
 
// eslint-disable-next-line @typescript-eslint/no-explicit-any
} as any

const ITEM = {
  id: 'item_1', name: 'Test', item_type: 'design', path: '',
   
  workspace_id: 'ws_1',
// eslint-disable-next-line @typescript-eslint/no-explicit-any
} as any

describe('DesignView single-element drag → translate emit', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    vi.clearAllMocks()
  })

  it('sends translate emit with (id, dx, dy) when user drags the body', async () => {
    const store = useWorkspacesStore()
    store.setActiveDesignPage('page_1')
    const wrapper = mount(DesignView, {
      props: {
        item: { ...ITEM, design_elements: [ELEMENT] },
        workspaceId: 'ws_1',
        itemId: 'item_1',
      },
    })
    try {
      await flushPromises()
      const elementEl = wrapper.find('[data-design-element]').element as HTMLElement
      elementEl.setPointerCapture = () => {}
      elementEl.releasePointerCapture = () => {}
      elementEl.hasPointerCapture = (): boolean => true

      // 1. pointerdown (selects + starts drag)
      elementEl.dispatchEvent(new PointerEvent('pointerdown', {
        button: 0, pointerId: 1, clientX: 100, clientY: 100, bubbles: true,
      }))
      await flushPromises()

      // 2. simulate the pointermove + pointerup that DesignElement's
      // `startDrag` registers on the element's addEventListener.
      let moveHandler: ((e: PointerEvent) => void) | null = null
      let upHandler: ((e: PointerEvent) => void) | null = null
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      ;(elementEl as any).addEventListener = (type: string, cb: any) => {
         
        if (type === 'pointermove') moveHandler = cb
        if (type === 'pointerup') upHandler = cb
      }
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      ;(elementEl as any).removeEventListener = () => {}

      elementEl.dispatchEvent(new PointerEvent('pointerdown', {
        button: 0, pointerId: 1, clientX: 100, clientY: 100, bubbles: true,
      }))
      await flushPromises()

      expect(moveHandler).toBeTypeOf('function')
      expect(upHandler).toBeTypeOf('function')

      // Drag right by 50, down by 30.
      moveHandler!(new PointerEvent('pointermove', {
        clientX: 150, clientY: 130, pointerId: 1,
      }))
      upHandler!(new PointerEvent('pointerup', { pointerId: 1 }))
      await flushPromises()

      // 3. expect the `translateElement` emit to have fired with
      //    (el_1, 50, 30) — the delta in design-px (zoom=1.0).
      const translates = wrapper.emitted('translateElement') ?? []
      const last = translates[translates.length - 1]
      expect(last).toBeDefined()
      expect(last).toEqual(['el_1', 50, 30])
    } finally {
      wrapper.unmount()
    }
  })

  /** REGRESSION (2026-08-06, design-mode-cannot-move bug): the single-element drag wire previously
   * bailed with `selectedIds.value.size !== 1` — if the user had a stale multi- select from earlier
   * (e.g. multi-clicked to deselect, or never reset), the drag silently no-op'd. */
  /** The wire was rewired to trust the `elementId` carried in the `translate` event instead of
   * fishing it out of `selectedIds`. This test pins the new contract. Scenario: element is dragged
   * after `selectedIds` was wiped (size 0). */
  /** The drag still fires the `translateElement` emit because the source emits `translate` with `{
   * elementId, dx, dy }` (the post-#162 fix). */
  it('sends translate emit even when selectedIds is empty (drag source carries elementId)', async () => {
    const _store = useWorkspacesStore()
    _store.setActiveDesignPage('page_1')

    const wrapper = mount(DesignView, {
      props: {
        item: { ...ITEM, design_elements: [ELEMENT] },
        workspaceId: 'ws_1',
        itemId: 'item_1',
      },
    })
    try {
      await flushPromises()

      // Force the designLogger on so the warn log we expect shows up
      // in test output (the spec is most useful when it surfaces
      // those warns in a future regression hunt).
      const { setDesignLoggerEnabled } = await import('../../../helpers/designLogger')
       
      setDesignLoggerEnabled(true)

      // Simulate the bug condition: wipe the local selection so the
      // OLD wire would have bailed with selectedIds.size === 0.
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      ;(wrapper.vm as any).selectedIds = new Set<string>()

      const elementEl = wrapper.find('[data-design-element]').element as HTMLElement
      elementEl.setPointerCapture = () => {}
       
      elementEl.releasePointerCapture = () => {}
      elementEl.hasPointerCapture = (): boolean => true

      let moveHandler: ((e: PointerEvent) => void) | null = null
       
      let upHandler: ((e: PointerEvent) => void) | null = null
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      ;(elementEl as any).addEventListener = (type: string, cb: any) => {
        if (type === 'pointermove') moveHandler = cb
        if (type === 'pointerup') upHandler = cb
      }
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      ;(elementEl as any).removeEventListener = () => {}

      // pointerdown — fires emit('select', ...) which replaces
      // selectedIds with {el_1}, then enters single-element drag path.
      elementEl.dispatchEvent(new PointerEvent('pointerdown', {
        button: 0, pointerId: 1, clientX: 100, clientY: 100, bubbles: true,
      }))
      await flushPromises()

      expect(moveHandler).toBeTypeOf('function')
      expect(upHandler).toBeTypeOf('function')

      // Drag right by 20, down by 10.
      moveHandler!(new PointerEvent('pointermove', {
        clientX: 120, clientY: 110, pointerId: 1,
      }))
      upHandler!(new PointerEvent('pointerup', { pointerId: 1 }))
      await flushPromises()

      // EXPECT: the drag still calls the store action even though we
      // wiped selectedIds before the gesture started. The wire must
      // rely on the event-carried elementId, not on selectedIds state.
      const translates = wrapper.emitted('translateElement') ?? []
      expect(translates.length).toBeGreaterThan(0)
      const last = translates[translates.length - 1]
      expect(last).toEqual(['el_1', 20, 10])
    } finally {
      wrapper.unmount()
    }
  })

  /** Regression: the OLD wire bailed when selectedIds had 2+ elements (the old assumption was
   * "single-element drag ⇒ exactly one selected"); the NEW wire still fires because the `translate`
   * event carries the elementId directly. The drag SOURCE is the // eslint-disable-next-line
   * @typescript-eslint/no-explicit-any */
  /** drag source — not the selection set. / */
  it('still fires translate when selectedIds has multiple ids (drag source carries elementId)', async () => {
    const _store = useWorkspacesStore()
    _store.setActiveDesignPage('page_1')

    // Add a second element so the multi-select is real.
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const other: any = {
      ...ELEMENT,
      id: 'el_2',
      name: 'Other',
      type: 'rectangle',
      x: 400, y: 100,
    }

    const wrapper = mount(DesignView, {
      props: {
        item: { ...ITEM, design_elements: [ELEMENT, other] },
        workspaceId: 'ws_1',
        itemId: 'item_1',
      },
     
    })
    try {
      await flushPromises()

      const { setDesignLoggerEnabled } = await import('../../../helpers/designLogger')
      setDesignLoggerEnabled(true)

      // OLD wire would have bailed here (size === 2).
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      ;(wrapper.vm as any).selectedIds = new Set<string>(['el_1', 'el_2'])

      const elementEl = wrapper.findAll('[data-design-element]')[0]!.element as HTMLElement
      elementEl.setPointerCapture = () => {}
       
      elementEl.releasePointerCapture = () => {}
      elementEl.hasPointerCapture = (): boolean => true

      let moveHandler: ((e: PointerEvent) => void) | null = null
      let upHandler: ((e: PointerEvent) => void) | null = null
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      ;(elementEl as any).addEventListener = (type: string, cb: any) => {
        if (type === 'pointermove') moveHandler = cb
        if (type === 'pointerup') upHandler = cb
      }
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      ;(elementEl as any).removeEventListener = () => {}

      elementEl.dispatchEvent(new PointerEvent('pointerdown', {
        button: 0, pointerId: 1, clientX: 100, clientY: 100, bubbles: true,
      }))
      await flushPromises()

      expect(moveHandler).toBeTypeOf('function')

      // Drag right by 10, down by 5.
      moveHandler!(new PointerEvent('pointermove', {
        clientX: 110, clientY: 105, pointerId: 1,
      }))
      upHandler!(new PointerEvent('pointerup', { pointerId: 1 }))
      await flushPromises()

      const translates = wrapper.emitted('translateElement') ?? []
      expect(translates.length).toBeGreaterThan(0)
      const last = translates[translates.length - 1]
      // The dragged element is el_1 (the one we dispatched on), even
      // though el_2 was also selected.
      expect(last).toEqual(['el_1', 10, 5])
    } finally {
      wrapper.unmount()
    }
  })
})
