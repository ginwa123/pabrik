/**
 * Behavioral tests for DesignView.vue's pinch-to-zoom via Pointer
 * Events. This handler is what makes trackpad pinches work on
 * Linux WebKitGTK 4.1 (the desktop app's Linux webview) — the
 * browser there does NOT auto-convert trackpad pinches to
 * ctrlKey: true wheel events the way macOS Safari / WKWebView do,
 * so the @wheel handler can't see them.
 *
 * 4 tests:
 *   1. Two simultaneous pointerdowns + a wider pointermove → zoom in.
 *   2. Pinch direction inverts correctly (closer = zoom out).
 *   3. Mouse pointerdown is ignored (mice don't pinch).
 *   4. Pinch starting on a design element does NOT zoom the canvas
 *      (the element's own drag handler takes the gesture).
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
        created_at: '2026-07-29 00:00:00',
        updated_at: '2026-07-29 00:00:00',
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

/**
 * jsdom 29 doesn't implement `setPointerCapture` / `releasePointerCapture`
 * / `hasPointerCapture` on HTMLElement. The native browser equivalents
 * require a real pointer-id-to-element binding that jsdom can't model.
 * We stub them to no-ops so the Vue handlers don't crash; the
 * pointer-state-tracking we actually want to test lives in the
 * `pinchPointers` Map inside the component.
 */
function stubPointerCapture(el: HTMLElement): void {
  el.setPointerCapture = () => {}
  el.releasePointerCapture = () => {}
  el.hasPointerCapture = (): boolean => false
}

describe('DesignView pinch-to-zoom (Pointer Events)', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    vi.clearAllMocks()
    // Reset the persisted zoom between tests so a prior test's 200%
    // doesn't bleed into the next test's "zoom in" assertion.
    if (typeof localStorage !== 'undefined') localStorage.clear()
  })

  it('two simultaneous pointers moving apart zoom in (ratio > 1)', async () => {
    const store = useWorkspacesStore()
    store.setActiveDesignPage('page_1')
    const wrapper = mount(DesignView, {
      props: { item: ITEM, workspaceId: 'ws_1', itemId: 'item_1' },
    })
    try {
      await flushPromises()
      const container = wrapper
        .find('[data-testid="design-canvas-scroll-container"]')
        .element as HTMLElement
      stubPointerCapture(container)

      // 1st finger lands at (200, 200), 2nd at (300, 300) — 141px apart.
      container.dispatchEvent(new PointerEvent('pointerdown', {
        pointerId: 1, pointerType: 'touch',
        clientX: 200, clientY: 200, bubbles: true,
      }))
      container.dispatchEvent(new PointerEvent('pointerdown', {
        pointerId: 2, pointerType: 'touch',
        clientX: 300, clientY: 300, bubbles: true,
      }))

      // Fingers spread to (200, 200) + (400, 400) — 282px apart (×2).
      container.dispatchEvent(new PointerEvent('pointermove', {
        pointerId: 1, pointerType: 'touch',
        clientX: 200, clientY: 200, bubbles: true,
      }))
      container.dispatchEvent(new PointerEvent('pointermove', {
        pointerId: 2, pointerType: 'touch',
        clientX: 400, clientY: 400, bubbles: true,
      }))
      await flushPromises()

      const resetBtn = wrapper.find('[data-testid="design-zoom-reset"]')
      const pct = parseInt(resetBtn.text() ?? '0', 10)
      expect(pct).toBeGreaterThan(100)
      // 2× distance = 2× zoom = 200%. Allow a tiny rounding slack.
      expect(pct).toBeGreaterThanOrEqual(195)
      expect(pct).toBeLessThanOrEqual(205)
    } finally {
      wrapper.unmount()
    }
  })

  it('two simultaneous pointers moving together zoom out (ratio < 1)', async () => {
    const store = useWorkspacesStore()
    store.setActiveDesignPage('page_1')
    const wrapper = mount(DesignView, {
      props: { item: ITEM, workspaceId: 'ws_1', itemId: 'item_1' },
    })
    try {
      await flushPromises()
      const container = wrapper
        .find('[data-testid="design-canvas-scroll-container"]')
        .element as HTMLElement
      stubPointerCapture(container)

      // Start 282px apart.
      container.dispatchEvent(new PointerEvent('pointerdown', {
        pointerId: 1, pointerType: 'touch',
        clientX: 200, clientY: 200, bubbles: true,
      }))
      container.dispatchEvent(new PointerEvent('pointerdown', {
        pointerId: 2, pointerType: 'touch',
        clientX: 400, clientY: 400, bubbles: true,
      }))

      // Pinch together to 141px (½ distance → 50% zoom).
      container.dispatchEvent(new PointerEvent('pointermove', {
        pointerId: 1, pointerType: 'touch',
        clientX: 250, clientY: 250, bubbles: true,
      }))
      container.dispatchEvent(new PointerEvent('pointermove', {
        pointerId: 2, pointerType: 'touch',
        clientX: 350, clientY: 350, bubbles: true,
      }))
      await flushPromises()

      const resetBtn = wrapper.find('[data-testid="design-zoom-reset"]')
      const pct = parseInt(resetBtn.text() ?? '0', 10)
      expect(pct).toBeLessThan(100)
      expect(pct).toBeGreaterThanOrEqual(45)
      expect(pct).toBeLessThanOrEqual(55)
    } finally {
      wrapper.unmount()
    }
  })

  it('mouse pointerdown is ignored (mice do not pinch)', async () => {
    const store = useWorkspacesStore()
    store.setActiveDesignPage('page_1')
    const wrapper = mount(DesignView, {
      props: { item: ITEM, workspaceId: 'ws_1', itemId: 'item_1' },
    })
    try {
      await flushPromises()
      const container = wrapper
        .find('[data-testid="design-canvas-scroll-container"]')
        .element as HTMLElement
      stubPointerCapture(container)

      // Two pointerdowns with pointerType='mouse' should NOT trigger any zoom — there's no third
      // finger, just a single mouse button doing double duty. (Real mice can't pinch; this guards
      // against accidentally firing the handler on a phantom 2nd mouse click.)
      container.dispatchEvent(new PointerEvent('pointerdown', {
        pointerId: 1, pointerType: 'mouse',
        clientX: 200, clientY: 200, bubbles: true,
      }))
      container.dispatchEvent(new PointerEvent('pointerdown', {
        pointerId: 2, pointerType: 'mouse',
        clientX: 400, clientY: 400, bubbles: true,
      }))
      container.dispatchEvent(new PointerEvent('pointermove', {
        pointerId: 1, pointerType: 'mouse',
        clientX: 100, clientY: 100, bubbles: true,
      }))
      container.dispatchEvent(new PointerEvent('pointermove', {
        pointerId: 2, pointerType: 'mouse',
        clientX: 500, clientY: 500, bubbles: true,
      }))
      await flushPromises()

      const resetBtn = wrapper.find('[data-testid="design-zoom-reset"]')
      const pct = parseInt(resetBtn.text() ?? '0', 10)
      expect(pct).toBe(100)
    } finally {
      wrapper.unmount()
    }
  })

  it('pinch starting on a design element does NOT zoom the canvas (closet() guard)', async () => {
    const store = useWorkspacesStore()
    store.setActiveDesignPage('page_1')
    const ELEMENT = {
      id: 'el_1', name: 'Box', type: 'rectangle', page_id: 'page_1',
      x: 100, y: 100, width: 200, height: 200,
      rotation: 0, opacity: 1, fill: '#fff', stroke: '', stroke_width: 0,
      corner_radius: 0, text_content: '', text_style: '', image_url: '',
       
      z_index: 0, position: 0, file_path: '', created_at: '', updated_at: '',
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    } as any
    const wrapper = mount(DesignView, {
      props: {
        item: { ...ITEM, design_elements: [ELEMENT] },
        workspaceId: 'ws_1',
        itemId: 'item_1',
      },
    })
    try {
      await flushPromises()
      const container = wrapper
        .find('[data-testid="design-canvas-scroll-container"]')
        .element as HTMLElement
      stubPointerCapture(container)

      const elementEl = wrapper
        .find('[data-design-element]')
        .element as HTMLElement
      stubPointerCapture(elementEl)

      // Dispatch on the element so the bubbling pointerdown reaches the container with
      // `event.target === elementEl`. The handler walks `target.closest('[data-design-element]')` →
      // matches → bails before adding the pointer to pinchPointers.
      elementEl.dispatchEvent(new PointerEvent('pointerdown', {
        pointerId: 10, pointerType: 'touch',
        clientX: 150, clientY: 150, bubbles: true,
      }))
      elementEl.dispatchEvent(new PointerEvent('pointerdown', {
        pointerId: 11, pointerType: 'touch',
        clientX: 350, clientY: 350, bubbles: true,
      }))
      // Even if the container's pointermove saw both pointers, the
      // pinchPointers Map is empty (handler bailed on pointerdown) so
      // nothing happens. Verify by widening them — no zoom change.
      container.dispatchEvent(new PointerEvent('pointermove', {
        pointerId: 10, pointerType: 'touch',
        clientX: 100, clientY: 100, bubbles: true,
      }))
      container.dispatchEvent(new PointerEvent('pointermove', {
        pointerId: 11, pointerType: 'touch',
        clientX: 500, clientY: 500, bubbles: true,
      }))
      await flushPromises()

      const resetBtn = wrapper.find('[data-testid="design-zoom-reset"]')
      const pct = parseInt(resetBtn.text() ?? '0', 10)
      // Pinch starting on a design element must not zoom the canvas —
      // the element's own drag handler absorbs the gesture.
      expect(pct).toBe(100)
    } finally {
      wrapper.unmount()
    }
  })
})