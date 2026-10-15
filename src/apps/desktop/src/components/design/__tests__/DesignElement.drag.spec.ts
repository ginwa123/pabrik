import { flushPromises, mount } from '@vue/test-utils'
import { createPinia, setActivePinia } from 'pinia'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import DesignElement from '../DesignElement.vue'
import { useWorkspacesStore } from '../../../stores/workspaces'
import type { DesignElement as DesignElementApi } from '../../../api'

const ELEMENT: DesignElementApi = {
  id: 'el_1', name: 'Box', type: 'rectangle',
  page_id: 'page_1', x: 100, y: 100, width: 200, height: 200,
  rotation: 0, opacity: 1, fill: '#fff', stroke: '', stroke_width: 0,
  corner_radius: 0, text_content: '', text_style: '', image_url: '',
  z_index: 0, position: 0,
  file_path: '', created_at: '', updated_at: '',
}

// jsdom 29 doesn't implement pointer capture on HTMLDivElement. The production code calls
// `target.setPointerCapture(event.pointerId)` unconditionally; jsdom throws "is not a function".
// Stub on the prototype so every element has a no-op (matches the spirit of the per-element
// stubbing in the plan's test bodies).
if (!HTMLElement.prototype.setPointerCapture) {
  HTMLElement.prototype.setPointerCapture = () => {}
}
if (!HTMLElement.prototype.releasePointerCapture) {
  HTMLElement.prototype.releasePointerCapture = () => {}
}
if (!HTMLElement.prototype.hasPointerCapture) {
  HTMLElement.prototype.hasPointerCapture = (): boolean => true
}

describe('DesignElement drag', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
  })

  it('emits translate with dx/dy delta on pointermove (move mode)', async () => {
    const wrapper = mount(DesignElement, {
      props: { element: ELEMENT, selected: true, zoom: 1.0 },
    })
    const root = wrapper.find('[data-design-element]').element as HTMLElement
    // Stub pointer-capture so jsdom doesn't error.
    root.setPointerCapture = () => {}
    root.releasePointerCapture = () => {}
    root.hasPointerCapture = () => true
     
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    ;(root as any).addEventListener = vi.fn()
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    ;(root as any).removeEventListener = vi.fn()

    // Native dispatchEvent (NOT wrapper.trigger) — jsdom 29 makes
    // MouseEvent.button a readonly getter, which @vue/test-utils
    // tries to assign post-construction. The PointerEvent constructor
    // itself accepts `button` as an init option (mirrors the pattern
    // in DesignView.handPan.spec.ts).
    root.dispatchEvent(new PointerEvent('pointerdown', { button: 0, pointerId: 1, clientX: 100, clientY: 100, bubbles: true }))

 

     
    // Move handler was registered on addEventListener('pointermove', ...)
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const moveHandler = (root as any).addEventListener.mock.calls.find(
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      (c: any[]) => c[0] === 'pointermove',
    )?.[1]
    expect(moveHandler).toBeDefined()

    // Simulate a +50, +30 move.
    moveHandler(new PointerEvent('pointermove', { clientX: 150, clientY: 130, pointerId: 1 }))
     
    // Within the throttle window — may or may not have emitted yet.
    // Use the wrapper's emitted() after waiting.
    await new Promise((r) => setTimeout(r, 300))  // wait past the 250 ms trailing-edge debounce (Chunk 3)
    const translates = wrapper.emitted('translate') ?? []
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const lastTranslate = translates[translates.length - 1]?.[0] as any
    expect(lastTranslate).toMatchObject({ dx: 50, dy: 30 })
  })

  it('emits a trailing translate on pointerup with the final delta', async () => {
    const wrapper = mount(DesignElement, {
      props: { element: ELEMENT, selected: true, zoom: 1.0 },
     
    })
     
    const root = wrapper.find('[data-design-element]').element as HTMLElement
    root.setPointerCapture = () => {}
    root.releasePointerCapture = () => {}
    root.hasPointerCapture = () => true
     
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    let moveHandler: any, upHandler: any
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    ;(root as any).addEventListener = (type: string, cb: any) => {
      if (type === 'pointermove') moveHandler = cb
      if (type === 'pointerup') upHandler = cb
    }
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    ;(root as any).removeEventListener = () => {}

     
    root.dispatchEvent(new PointerEvent('pointerdown', { button: 0, pointerId: 1, clientX: 100, clientY: 100, bubbles: true }))
    moveHandler(new PointerEvent('pointermove', { clientX: 999, clientY: 999, pointerId: 1 }))
    // Fire pointerup immediately (within throttle window).
    upHandler(new PointerEvent('pointerup', { pointerId: 1 }))

    // The trailing emit must include the final delta even if the
    // throttle hadn't fired.
    const translates = wrapper.emitted('translate') ?? []
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const lastTranslate = translates[translates.length - 1]?.[0] as any
    expect(lastTranslate).toMatchObject({ dx: 899, dy: 899 })
  })

 

   
  it('applies 1/zoom to the delta so zoomed canvases stay 1:1 with cursor', async () => {
    const wrapper = mount(DesignElement, {
      props: { element: ELEMENT, selected: true, zoom: 0.5 },  // 50% zoom
     
    })
    const root = wrapper.find('[data-design-element]').element as HTMLElement
    root.setPointerCapture = () => {}
    root.releasePointerCapture = () => {}
    root.hasPointerCapture = () => true
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    let moveHandler: any
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    ;(root as any).addEventListener = (type: string, cb: any) => {
      if (type === 'pointermove') moveHandler = cb
    }
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    ;(root as any).removeEventListener = () => {}

    root.dispatchEvent(new PointerEvent('pointerdown', { button: 0, pointerId: 1, clientX: 100, clientY: 100, bubbles: true }))
    moveHandler(new PointerEvent('pointermove', { clientX: 200, clientY: 100, pointerId: 1 }))
    // 100 screen-px move at 50% zoom = 200 design-px move.
    // emit('translate', {dx: (200-100)/0.5 = 200, dy: 0})
    await new Promise((r) => setTimeout(r, 300))
    const translates = wrapper.emitted('translate') ?? []
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const lastTranslate = translates[translates.length - 1]?.[0] as any
    expect(lastTranslate.dx).toBe(200)
    expect(lastTranslate.dy).toBe(0)
  })

  it('preview mode swallows drag (no emit)', async () => {
    const wrapper = mount(DesignElement, {
      props: { element: ELEMENT, selected: true, previewMode: true },
    })
    const root = wrapper.find('[data-design-element]').element as HTMLElement
    root.dispatchEvent(new PointerEvent('pointerdown', { button: 0, pointerId: 1, clientX: 100, clientY: 100, bubbles: true }))
    expect(wrapper.emitted('update')).toBeUndefined()
  })

  it('readonly swallows drag (no emit)', async () => {
    const wrapper = mount(DesignElement, {
      props: { element: ELEMENT, selected: true, readonly: true },
    })
    const root = wrapper.find('[data-design-element]').element as HTMLElement
     
    root.dispatchEvent(new PointerEvent('pointerdown', { button: 0, pointerId: 1, clientX: 100, clientY: 100, bubbles: true }))
     
    expect(wrapper.emitted('update')).toBeUndefined()
  })

   
  it('resize handle emits resize patch with sign flip', async () => {
    const wrapper = mount(DesignElement, {
      props: { element: ELEMENT, selected: true, zoom: 1.0 },
    })
    const nwHandle = wrapper.find(`[data-testid="design-element-handle-${ELEMENT.id}-nw"]`)
    const nwEl = nwHandle.element as HTMLElement
    nwEl.setPointerCapture = () => {}
    nwEl.releasePointerCapture = () => {}
     
    nwEl.hasPointerCapture = () => true
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    let moveHandler: any
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    ;(nwEl as any).addEventListener = (type: string, cb: any) => {
      if (type === 'pointermove') moveHandler = cb
    }
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    ;(nwEl as any).removeEventListener = () => {}

    nwEl.dispatchEvent(new PointerEvent('pointerdown', { button: 0, pointerId: 1, clientX: 100, clientY: 100, bubbles: true }))
    // Drag NW handle up-left by (-30, -40): width grows by 30, height grows by 40,
    // x shrinks by 30, y shrinks by 40.
    moveHandler(new PointerEvent('pointermove', { clientX: 70, clientY: 60, pointerId: 1 }))
    await new Promise((r) => setTimeout(r, 300))
    const resizes = wrapper.emitted('resize') ?? []
     
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const lastResize = resizes[resizes.length - 1]?.[0] as any
    expect(lastResize.width).toBe(230)   // 200 + 30
    expect(lastResize.height).toBe(240)  // 200 + 40
     
    expect(lastResize.x).toBe(70)        // 100 - 30
    expect(lastResize.y).toBe(60)        // 100 - 40
  })

  it('resize clamps width/height to minimum 10px', async () => {
    const wrapper = mount(DesignElement, {
      props: { element: ELEMENT, selected: true, zoom: 1.0 },
     
    })
    const eHandle = wrapper.find(`[data-testid="design-element-handle-${ELEMENT.id}-e"]`)
    const eEl = eHandle.element as HTMLElement
    eEl.setPointerCapture = () => {}
    eEl.releasePointerCapture = () => {}
    eEl.hasPointerCapture = () => true
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    let moveHandler: any
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    ;(eEl as any).addEventListener = (type: string, cb: any) => {
      if (type === 'pointermove') moveHandler = cb
    }
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    ;(eEl as any).removeEventListener = () => {}

    eEl.dispatchEvent(new PointerEvent('pointerdown', { button: 0, pointerId: 1, clientX: 100, clientY: 100, bubbles: true }))
    // Drag E handle -1000px left: width would go to -800, clamped to 10.
    moveHandler(new PointerEvent('pointermove', { clientX: -900, clientY: 100, pointerId: 1 }))
    await new Promise((r) => setTimeout(r, 300))
    const resizes = wrapper.emitted('resize') ?? []
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const lastResize = resizes[resizes.length - 1]?.[0] as any
    expect(lastResize.width).toBe(10)
  })

  // Symptom of the bug fixed in 2026-07-30: when the user clicks a resize handle, the handle's
  // pointerdown fires startDrag(e, { resize: handle }) which then bubbles to the wrapper's
  // @pointerdown (startDrag(e, 'move')).
  // The wrapper's setPointerCapture steals capture from the handle, and the wrapper's move handler
  // runs instead of the handle's resize handler. The element MOVES instead of resizing.
  // The simplest invariant to test is the duplicate handler invocation: with the bug, both handle
  // and wrapper fire startDrag, so 'select' is emitted twice. With the fix, only the handle fires
  // (startDrag calls event.stopPropagation() for any non-'move' mode), so 'select' is emitted once.
  it('resize handle pointerdown does NOT bubble to the wrapper (single select emit, no duplicate handler)', async () => {
    const wrapper = mount(DesignElement, {
      props: { element: ELEMENT, selected: true, zoom: 1.0 },
    })
    const nwHandle = wrapper.find(`[data-testid="design-element-handle-${ELEMENT.id}-nw"]`)
    const nwEl = nwHandle.element as HTMLElement
    nwEl.setPointerCapture = () => {}
    nwEl.releasePointerCapture = () => {}
    nwEl.hasPointerCapture = (): boolean => true
    // Deliberately do NOT stub addEventListener on the handle — let both the handle's and the
    // wrapper's listeners register normally so we can verify the bubble behaviour. (Stubbing the
    // handle's addEventListener is what hid the bug in the existing test.)

    nwEl.dispatchEvent(new PointerEvent('pointerdown', { button: 0, pointerId: 1, clientX: 100, clientY: 100, bubbles: true }))

    // Pre-fix: 'select' emitted TWICE (handle + wrapper).
    // Post-fix: 'select' emitted ONCE (handle only — wrapper's
    // @pointerdown never fired because the handle called
    // event.stopPropagation()).
     
    const selects = wrapper.emitted('select') ?? []
    expect(selects).toHaveLength(1)
    // Also assert 'dragStart' is emitted once (same duplicate-handler
    // pattern would cause a duplicate dragStart).
     
    const dragStarts = wrapper.emitted('dragStart') ?? []
    expect(dragStarts).toHaveLength(1)
  })

  // Strict throttle test: fires 3 rapid pointermoves within the 50ms throttle window and asserts
  // the trailing patch was applied exactly once (not 3 times).
  // This is the test that proves the throttle is in effect — the plan's 7 tests all happen to pass
  // against the pre-fix unthrottled code because each one's last emit happens to be the final patch
  // anyway. This 8th test catches the bug.
  it('throttles rapid pointermoves: 3 moves within 50ms emit at most 1 translate before pointerup', async () => {
    const wrapper = mount(DesignElement, {
      props: { element: ELEMENT, selected: true, zoom: 1.0 },
    })
    const root = wrapper.find('[data-design-element]').element as HTMLElement
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    let moveHandler: any, upHandler: any
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    ;(root as any).addEventListener = (type: string, cb: any) => {
      if (type === 'pointermove') moveHandler = cb
      if (type === 'pointerup') upHandler = cb
     
    }
     
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    ;(root as any).removeEventListener = () => {}

    root.dispatchEvent(new PointerEvent('pointerdown', { button: 0, pointerId: 1, clientX: 100, clientY: 100, bubbles: true }))
    // Fire 3 moves within the throttle window (no await between them).
    moveHandler(new PointerEvent('pointermove', { clientX: 110, clientY: 110, pointerId: 1 }))
    moveHandler(new PointerEvent('pointermove', { clientX: 120, clientY: 120, pointerId: 1 }))
    moveHandler(new PointerEvent('pointermove', { clientX: 130, clientY: 130, pointerId: 1 }))
    // Snapshot BEFORE pointerup — the trailing emit happens on pointerup.
     
    const emitsBeforeUp = (wrapper.emitted('translate') ?? []).length
     
    // Throttled: 0 emits (none past the 50ms window). Unthrottled: 3 emits.
    expect(emitsBeforeUp).toBeLessThanOrEqual(1)
    upHandler(new PointerEvent('pointerup', { pointerId: 1 }))
    // BUG FIX 2026-08-06: the wire now sends INCREMENTAL dx/dy (delta since last emit). The
    // trailing pointerup emit carries only the delta from the last throttled emit.
    // The test below locks in the incremental contract: dx/dy in each emit is the delta since the
    // previous emit, and the SUM of all emitted dx/dy equals the cumulative cursor movement.
    // This is what prevents the server-side `x = x + dx` from compounding across ticks (which would
    // make the element move "so fast").
    const translates = wrapper.emitted('translate') ?? []
    // Sum of dx/dy across all emits must equal the cursor delta (30).
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const sumDx = translates.reduce((acc, t) => acc + (t[0] as any).dx, 0)
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const sumDy = translates.reduce((acc, t) => acc + (t[0] as any).dy, 0)
    expect(sumDx).toBe(30)
    expect(sumDy).toBe(30)
    // Every individual emit must be in the range [-MAX, +MAX]. Each emit carries only the delta
    // since the previous one, never the cumulative (a single emit carrying dx=30, dy=30 would mean
    // the old wire-format is back, which would re-introduce the compounding bug).
    for (const t of translates) {
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      expect(Math.abs((t[0] as any).dx)).toBeLessThanOrEqual(30)
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      expect(Math.abs((t[0] as any).dy)).toBeLessThanOrEqual(30)
    }
  })

  // ─── Chunk 2: multi-select ────────────────────────────────────────

  it('emits select with the element id on pointerdown', async () => {
    const wrapper = mount(DesignElement, {
      props: { element: ELEMENT, selectedIds: [], zoom: 1.0 },
    })
    const root = wrapper.find('[data-design-element]').element as HTMLElement
    root.dispatchEvent(new PointerEvent('pointerdown', { button: 0, pointerId: 1, clientX: 100, clientY: 100, bubbles: true }))
    expect(wrapper.emitted('select')?.[0]).toEqual([{ elementId: 'el_1', additive: false }])
  })

  it('Delete key emits delete for every selected element', async () => {
    const wrapper = mount(DesignElement, {
      props: { element: ELEMENT, selectedIds: ['el_1', 'el_2', 'el_3'], zoom: 1.0 },
    })
    document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Delete' }))
    const deletes = wrapper.emitted('delete') ?? []
    expect(deletes.map((d) => d[0])).toEqual(['el_1', 'el_2', 'el_3'])
  })

  it('Delete inside an input does NOT fire delete', async () => {
    const wrapper = mount(DesignElement, {
      props: { element: ELEMENT, selectedIds: ['el_1'], zoom: 1.0 },
    })
    const input = document.createElement('input')
    document.body.appendChild(input)
    input.focus()
    input.dispatchEvent(new KeyboardEvent('keydown', { key: 'Delete', bubbles: true }))
    document.body.removeChild(input)
    expect(wrapper.emitted('delete')).toBeUndefined()
  })

  /** REGRESSION (2026-08-06, design-mode-moves-so-fast v2): the wire `dx` was historically the
   * CUMULATIVE cursor delta from drag-start (`dx = e.clientX - startClientX`). The backend
   * interprets `dx` as "set x = x + dx", so each throttled emit compounded: after N //
   * eslint-disable-next-line @typescript-eslint/no-explicit-any */
  /** ticks of cursor movement d, the element ended up at d·N·(N+1)/2 // eslint-disable-next-line
   * @typescript-eslint/no-explicit-any */
  /**    * instead of d — making the element visibly leap ahead of the cursor (the "moves so fast" user
   * complaint). The fix sends the INCREMENTAL dx (delta since last emit). Each //
   * eslint-disable-next-line @typescript-eslint/no-explicit-any */
  /** emit carries only the cursor movement SINCE the previous emit. The backend still ADDs, but the
   * cumulative effect across emits now equals the cursor delta — not a quadratically-compounded
   * value. */
  /** This test pins the contract via `awplusTrick`-free simulates (no setTimeout-based waitFor): 3
   * sequential pointermoves with fake timestamps inside the same throttle window, then a pointerup
   * trailing emit. */
  /** We assert: (1) SUM of dx/dy across all emits equals cursor delta (30, 30) (2) each individual
   * emit carries delta ≤ |cursor delta| (never the cumulative) If anyone reverts to the cumulative
   * format, (2) catches it. / */
  it('each translate emit carries INCREMENTAL dx/dy (sum equals cursor delta, never compounded)', async () => {
    const wrapper = mount(DesignElement, {
      props: { element: ELEMENT, selected: true, zoom: 1.0 },
     
    })
     
    const root = wrapper.find('[data-design-element]').element as HTMLElement
    root.setPointerCapture = () => {}
    root.releasePointerCapture = () => {}
    root.hasPointerCapture = (): boolean => true
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    let moveHandler: any, upHandler: any
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    ;(root as any).addEventListener = (type: string, cb: any) => {
      if (type === 'pointermove') moveHandler = cb
      if (type === 'pointerup') upHandler = cb
     
    }
     
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    ;(root as any).removeEventListener = () => {}

    root.dispatchEvent(new PointerEvent('pointerdown', {
      button: 0, pointerId: 1, clientX: 100, clientY: 100, bubbles: true,
    }))
    // 3 pointermoves, each 10 design-px in dx/dy, all within the
    // throttle window. Total cursor delta = (30, 30).
    moveHandler(new PointerEvent('pointermove', { clientX: 110, clientY: 110, pointerId: 1 }))
    moveHandler(new PointerEvent('pointermove', { clientX: 120, clientY: 120, pointerId: 1 }))
    moveHandler(new PointerEvent('pointermove', { clientX: 130, clientY: 130, pointerId: 1 }))
    upHandler(new PointerEvent('pointerup', { pointerId: 1 }))
    await flushPromises()

    const translates = wrapper.emitted('translate') ?? []

    // (1) Sum across all emits equals cursor delta — server will
    // apply each emit with `x = x + dx`, so the cumulative effect
    // must equal the cursor movement (not compound to 30·4/2 = 60).
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const sumDx = translates.reduce((acc, t) => acc + (t[0] as any).dx, 0)
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const sumDy = translates.reduce((acc, t) => acc + (t[0] as any).dy, 0)
    expect(sumDx).toBe(30)
     
    expect(sumDy).toBe(30)

    // (2) Each individual emit carries delta ≤ cursor delta. If
    // anyone reverts to the old cumulative format, an emit with
    // dx=30 (the full cursor delta) would appear in the SECOND
    // emit — that means the wire is back to sending `e.clientX -
    // startClientX` per tick, which compounds on the server.
    for (const t of translates) {
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      const dx = (t[0] as any).dx
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      const dy = (t[0] as any).dy
      expect(Math.abs(dx)).toBeLessThanOrEqual(30)
      expect(Math.abs(dy)).toBeLessThanOrEqual(30)
     
    }

 

    // (3) Specifically — the SUM never reaches the compounded value.
    // A compounded value would be: 10 + 20 + 30 = 60 (NOT 30).
    expect(sumDx).toBeLessThan(60)
  })

   
  // Chunk 2: group drag. When this element is part of a multi-selection and the user drags the
  // body, the component emits `groupDrag` events (NOT single-element `update` events) so the parent
  // can apply the same dx/dy to every selected element.
  it('drag on a multi-selected element emits groupDrag, not update', async () => {
    const wrapper = mount(DesignElement, {
      props: { element: ELEMENT, selectedIds: ['el_1', 'el_2'], zoom: 1.0 },
    })
    const root = wrapper.find('[data-design-element]').element as HTMLElement
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    let moveHandler: any, upHandler: any
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    ;(root as any).addEventListener = (type: string, cb: any) => {
      if (type === 'pointermove') moveHandler = cb
      if (type === 'pointerup') upHandler = cb
    }
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    ;(root as any).removeEventListener = () => {}

    root.dispatchEvent(new PointerEvent('pointerdown', { button: 0, pointerId: 1, clientX: 100, clientY: 100, bubbles: true }))
     
    // Move +50, +30 within the throttle window → only the trailing
    // pointerup emit will fire, carrying the final delta.
    moveHandler(new PointerEvent('pointermove', { clientX: 150, clientY: 130, pointerId: 1 }))
    upHandler(new PointerEvent('pointerup', { pointerId: 1 }))

     
    // BUG FIX 2026-08-06: the wire sends INCREMENTAL dx/dy (delta since last emit). For a single
    // pointermove followed by a pointerup with no throttle window crossed, the trailing emit
    // carries the FULL cursor delta (since lastEmittedDx was 0).
    // The sum across emits must equal the cursor movement (50, 30).
    const groupDrags = wrapper.emitted('groupDrag') ?? []
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const sumDx = groupDrags.reduce((acc, g) => acc + (g[0] as any).dx, 0)
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const sumDy = groupDrags.reduce((acc, g) => acc + (g[0] as any).dy, 0)
    expect(sumDx).toBe(50)
    expect(sumDy).toBe(30)
    // Trailing emit alone carries the full delta (no throttle fired before pointerup). The first
    // emit's dx/dy is whatever landed before the trailing — depends on the throttle timing.
    // We don't pin groupDrags[groupDrags.length - 1][0].dx specifically here — see the
    // throttles-rapid test for that invariant. Critically: this is a GROUP drag, so no `update`
    // should fire. The parent decides where to route the per-element updates.
    expect(wrapper.emitted('update')).toBeUndefined()
  })

  // Counterpart: a single-element drag (no multi-selection context) emits `translate` (delta-based)
  // — the new typed event replacing the old conflated `update` event. See
  // docs/superpowers/plans/2026-08-06-split-move-resize.md.
  it('drag with empty selectedIds still emits translate (single-element path)', async () => {
    const wrapper = mount(DesignElement, {
      props: { element: ELEMENT, selectedIds: [], selected: true, zoom: 1.0 },
    })
    const root = wrapper.find('[data-design-element]').element as HTMLElement
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    let moveHandler: any, upHandler: any
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    ;(root as any).addEventListener = (type: string, cb: any) => {
      if (type === 'pointermove') moveHandler = cb
      if (type === 'pointerup') upHandler = cb
    }
     
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    ;(root as any).removeEventListener = () => {}

    root.dispatchEvent(new PointerEvent('pointerdown', { button: 0, pointerId: 1, clientX: 100, clientY: 100, bubbles: true }))
    moveHandler(new PointerEvent('pointermove', { clientX: 150, clientY: 130, pointerId: 1 }))
     
    upHandler(new PointerEvent('pointerup', { pointerId: 1 }))

    // Empty selectedIds means no group-drag — the single-element
    // throttled path runs, emitting `translate` with the cursor delta.
    const translates = wrapper.emitted('translate') ?? []
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const lastTranslate = translates[translates.length - 1]?.[0] as any
    expect(lastTranslate).toMatchObject({ dx: 50, dy: 30 })
    // groupDrag should NOT fire in single-element mode.
    expect(wrapper.emitted('groupDrag')).toBeUndefined()
  })

  // ─── Child-of-group drag suppression (2026-08-06) ───────────────── User request: elements
  // nested inside a parent group/frame should NOT be independently movable. Clicking a child still
  // selects it (so the user can edit properties), but pointer-drag is suppressed.
  // The user has to drag the parent group / frame header to move the whole subtree. Resize handles
  // still work on the child (Figma parity — child resize is independent, only child move is
  // blocked).
  // Wire-form note: the backend uses `COALESCE(parent_id, '')` so a top-level element arrives as
  // `parent_id = ''`. A nested element arrives as `parent_id = 'elem_<parent>'`. Legacy shapes may
  // have `parent_id = null` or `undefined` — both are treated as top-level.

  it('drag on a child element (parent_id set) does NOT emit translate', async () => {
    const CHILD: DesignElementApi = {
      ...ELEMENT,
      id: 'el_child',
      // The bug: child elements could be dragged independently. The
      // fix: drag is suppressed, only select fires.
      parent_id: 'el_parent_group',
    }
    const wrapper = mount(DesignElement, {
      props: { element: CHILD, selected: true, zoom: 1.0 },
    })
    const root = wrapper.find('[data-design-element]').element as HTMLElement
    root.setPointerCapture = () => {}
    root.releasePointerCapture = () => {}
    root.hasPointerCapture = (): boolean => true
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    let moveHandler: any, upHandler: any
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    ;(root as any).addEventListener = (type: string, cb: any) => {
       
      if (type === 'pointermove') moveHandler = cb
       
      if (type === 'pointerup') upHandler = cb
    }
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    ;(root as any).removeEventListener = () => {}

    root.dispatchEvent(new PointerEvent('pointerdown', {
      button: 0, pointerId: 1, clientX: 100, clientY: 100, bubbles: true,
    }))
    // Attempt a drag — the engine should NOT register any handler
    // because the early-return fires before addEventListener.
    if (moveHandler) {
      moveHandler(new PointerEvent('pointermove', {
        clientX: 150, clientY: 130, pointerId: 1,
       
      }))
      upHandler(new PointerEvent('pointerup', { pointerId: 1 }))
    }
    await flushPromises()

    // The whole point: no translate, no groupDrag, no update. The
    // child is selectable (still emits select) but not draggable.
    expect(wrapper.emitted('translate')).toBeUndefined()
    expect(wrapper.emitted('groupDrag')).toBeUndefined()
    expect(wrapper.emitted('update')).toBeUndefined()
    // Selection still happens (the user can edit properties).
    expect(wrapper.emitted('select')?.[0]).toEqual([
      { elementId: 'el_child', additive: false },
    ])
    // No dragStart/dragEnd either — the suppress happens before the
    // gesture state machine starts.
    expect(wrapper.emitted('dragStart')).toBeUndefined()
    expect(wrapper.emitted('dragEnd')).toBeUndefined()
  })

  it('resize on a child element still emits resize (resize handles unaffected)', async () => {
    const CHILD: DesignElementApi = {
       
      ...ELEMENT,
       
      id: 'el_child_resize',
      parent_id: 'el_parent_group',
    }
    const wrapper = mount(DesignElement, {
       
      props: { element: CHILD, selected: true, zoom: 1.0 },
    })
    const nwHandle = wrapper.find(`[data-testid="design-element-handle-${CHILD.id}-nw"]`)
    const nwEl = nwHandle.element as HTMLElement
    nwEl.setPointerCapture = () => {}
    nwEl.releasePointerCapture = () => {}
    nwEl.hasPointerCapture = (): boolean => true
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    let moveHandler: any
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    ;(nwEl as any).addEventListener = (type: string, cb: any) => {
      if (type === 'pointermove') moveHandler = cb
    }
     
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    ;(nwEl as any).removeEventListener = () => {}

    nwEl.dispatchEvent(new PointerEvent('pointerdown', {
      button: 0, pointerId: 1, clientX: 100, clientY: 100, bubbles: true,
    }))
    moveHandler(new PointerEvent('pointermove', {
      clientX: 70, clientY: 60, pointerId: 1,
    }))
    await new Promise((r) => setTimeout(r, 300))
    const resizes = wrapper.emitted('resize') ?? []
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const lastResize = resizes[resizes.length - 1]?.[0] as any
    // Only the move branch is blocked — resize fires normally.
    expect(lastResize).toBeDefined()
    expect(lastResize.width).toBe(230)
    expect(lastResize.height).toBe(240)
  })

  it('drag on a top-level element (parent_id === "") still emits translate (regression guard)', async () => {
     
    // parent_id is the empty string (the backend's COALESCE form for
    // NULL). This is the boundary case — empty string means top-level.
    const TOP_LEVEL: DesignElementApi = {
      ...ELEMENT,
      id: 'el_top',
       
      parent_id: '',
    }
    const wrapper = mount(DesignElement, {
      props: { element: TOP_LEVEL, selected: true, zoom: 1.0 },
    })
    const root = wrapper.find('[data-design-element]').element as HTMLElement
    root.setPointerCapture = () => {}
    root.releasePointerCapture = () => {}
    root.hasPointerCapture = (): boolean => true
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    let moveHandler: any, upHandler: any
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    ;(root as any).addEventListener = (type: string, cb: any) => {
      if (type === 'pointermove') moveHandler = cb
      if (type === 'pointerup') upHandler = cb
    }
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    ;(root as any).removeEventListener = () => {}

    root.dispatchEvent(new PointerEvent('pointerdown', {
      button: 0, pointerId: 1, clientX: 100, clientY: 100, bubbles: true,
    }))
    moveHandler(new PointerEvent('pointermove', {
      clientX: 150, clientY: 130, pointerId: 1,
    }))
    upHandler(new PointerEvent('pointerup', { pointerId: 1 }))
    await flushPromises()

    const translates = wrapper.emitted('translate') ?? []
    expect(translates.length).toBeGreaterThan(0)
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const lastTranslate = translates[translates.length - 1]?.[0] as any
    expect(lastTranslate).toMatchObject({ dx: 50, dy: 30 })
   
  })

 

  it('drag on a child element with parent_id = null (legacy shape) is treated as top-level', async () => {
    // Legacy elements returned by the API before parent_id was added
    // have `parent_id = null` (or undefined). They should be treated
    // as top-level — drag is allowed.
    const LEGACY: DesignElementApi = {
      ...ELEMENT,
      id: 'el_legacy',
      parent_id: null,
    }
    const wrapper = mount(DesignElement, {
      props: { element: LEGACY, selected: true, zoom: 1.0 },
    })
    const root = wrapper.find('[data-design-element]').element as HTMLElement
    root.setPointerCapture = () => {}
    root.releasePointerCapture = () => {}
    root.hasPointerCapture = (): boolean => true
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    let moveHandler: any, upHandler: any
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    ;(root as any).addEventListener = (type: string, cb: any) => {
      if (type === 'pointermove') moveHandler = cb
      if (type === 'pointerup') upHandler = cb
    }
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    ;(root as any).removeEventListener = () => {}

    root.dispatchEvent(new PointerEvent('pointerdown', {
      button: 0, pointerId: 1, clientX: 100, clientY: 100, bubbles: true,
    }))
    moveHandler(new PointerEvent('pointermove', {
      clientX: 150, clientY: 130, pointerId: 1,
    }))
    upHandler(new PointerEvent('pointerup', { pointerId: 1 }))
    await flushPromises()

    const translates = wrapper.emitted('translate') ?? []
    expect(translates.length).toBeGreaterThan(0)
  })

  it('multi-select containing children still triggers groupDrag (parent_id ignored in multi-select)', async () => {
    // Multi-select already routes through the groupDrag branch (the `triggerGroupDrag =
    // (inMultiselect || isGroupLike) && mode === 'move'` check). The child-blocks-move guard has an
    // `!inMultiSelect` exception, so a multi-select of children can still move.
    const CHILD: DesignElementApi = {
      ...ELEMENT,
      id: 'el_child_multi',
      parent_id: 'el_parent_group',
    }
    const wrapper = mount(DesignElement, {
      // Two-child multi-select — neither is at top-level.
      props: { element: CHILD, selectedIds: ['el_child_multi', 'el_child_2'], zoom: 1.0 },
    })
    const root = wrapper.find('[data-design-element]').element as HTMLElement
    root.setPointerCapture = () => {}
    root.releasePointerCapture = () => {}
    root.hasPointerCapture = (): boolean => true
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    let moveHandler: any, upHandler: any
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    ;(root as any).addEventListener = (type: string, cb: any) => {
      if (type === 'pointermove') moveHandler = cb
      if (type === 'pointerup') upHandler = cb
    }
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    ;(root as any).removeEventListener = () => {}

    root.dispatchEvent(new PointerEvent('pointerdown', {
      button: 0, pointerId: 1, clientX: 100, clientY: 100, bubbles: true,
    }))
    moveHandler(new PointerEvent('pointermove', {
      clientX: 150, clientY: 130, pointerId: 1,
    }))
    upHandler(new PointerEvent('pointerup', { pointerId: 1 }))

    // Multi-select → groupDrag, NOT translate. The child-suppress guard
    // never fires because inMultiSelect=true short-circuits the guard.
    const groupDrags = wrapper.emitted('groupDrag') ?? []
    expect(groupDrags.length).toBeGreaterThan(0)
    expect(wrapper.emitted('translate')).toBeUndefined()
  })

  // ─── Click on child: select parent (2026-08-06 follow-up) ──────────── User report: "when i
  // click the element group, why its still select that child element? why not directly select the
  // group? so i can move the group layer".
  // Clicking a child element should now select the parent group (Figma-style deep grouping), so the
  // user can immediately drag the group without first clicking the header.
  // Helper: register a parent element in the workspace store so `parentElement` (computed via
  // `useWorkspacesStore`) can find it.
  const seedParentFor = (parentId: string): void => {
    const wsId = 'ws_test'
    const itemId = 'item_test'
    const parent: DesignElementApi = {
      id: parentId,
      name: 'Group 5',
      type: 'frame',
      page_id: 'page_1',
      x: 0, y: 0, width: 1440, height: 1024,
      rotation: 0, opacity: 1, fill: '', stroke: '', stroke_width: 0,
      corner_radius: 0, text_content: '', text_style: '', image_url: '',
      z_index: 0, position: 0,
      file_path: '', created_at: '', updated_at: '',
    }
    const ws = useWorkspacesStore()
    ws.workspaces.push({
      // The store's Workspace type accepts a permissive shape — fields
      // unused by `parentElement` lookup can be `any`.
      id: wsId,
      name: 'Test Workspace',
      slug: 'test',
      path: '/tmp/test',
      items: [],
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
    } as any)
    ws.workspaces[0]!.items.push({
      id: itemId,
      name: 'Design Item',
      path: '/tmp/test/design',
      design_elements: [parent],
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
    } as any)
  }

  it('click on a child emits select with the PARENT id (not the child)', async () => {
    const CHILD: DesignElementApi = {
      ...ELEMENT,
      id: 'el_child',
      parent_id: 'el_parent_group',
    }
    setActivePinia(createPinia())
    seedParentFor('el_parent_group')

    const wrapper = mount(DesignElement, {
      props: { element: CHILD, selected: true, zoom: 1.0, workspaceId: 'ws_test', itemId: 'item_test', pageId: 'page_1' },
    })
    const root = wrapper.find('[data-design-element]').element as HTMLElement
    root.dispatchEvent(new PointerEvent('pointerdown', {
      button: 0, pointerId: 1, clientX: 100, clientY: 100, bubbles: true,
    }))

    // The whole point: select is emitted with the PARENT's id, not the child's. The parent has a
    // `'frame'` shape (created in seedParentFor). The user now sees the parent selected in the
    // Properties panel + Layers panel and can immediately drag it.
    const selects = wrapper.emitted('select') ?? []
    expect(selects.length).toBe(1)
    expect(selects[0]?.[0]).toEqual({
      elementId: 'el_parent_group',
      additive: false,
    })
  })

  it('click on a child with shift held still emits select with the CHILD id (toggle behaviour preserved)', async () => {
    const CHILD: DesignElementApi = {
      ...ELEMENT,
      id: 'el_child_shift',
      parent_id: 'el_parent_group',
    }
    setActivePinia(createPinia())
    seedParentFor('el_parent_group')

    const wrapper = mount(DesignElement, {
      props: { element: CHILD, selected: true, zoom: 1.0, workspaceId: 'ws_test', itemId: 'item_test', pageId: 'page_1' },
    })
    const root = wrapper.find('[data-design-element]').element as HTMLElement
    // Shift+click — additive=true → user wants the child in the
    // multi-select, NOT the parent.
    root.dispatchEvent(new PointerEvent('pointerdown', {
      button: 0, pointerId: 1, clientX: 100, clientY: 100, bubbles: true, shiftKey: true,
    }))

    const selects = wrapper.emitted('select') ?? []
    expect(selects[0]?.[0]).toEqual({
      elementId: 'el_child_shift',
      additive: true,
    })
  })

  it('click on a top-level element emits select with SELF id (regression guard)', async () => {
    // Top-level element (parent_id === '') — no parent to redirect
    // to. Existing behaviour preserved.
    const TOP: DesignElementApi = {
      ...ELEMENT,
      id: 'el_top',
      parent_id: '',
    }
    setActivePinia(createPinia())
    // No need to seed a parent — the lookup returns null for top-level.

    const wrapper = mount(DesignElement, {
      props: { element: TOP, selected: true, zoom: 1.0 },
    })
    const root = wrapper.find('[data-design-element]').element as HTMLElement
    root.dispatchEvent(new PointerEvent('pointerdown', {
      button: 0, pointerId: 1, clientX: 100, clientY: 100, bubbles: true,
    }))

    const selects = wrapper.emitted('select') ?? []
    expect(selects[0]?.[0]).toEqual({
      elementId: 'el_top',
      additive: false,
    })
  })

  it('click on a child with parent NOT in the store falls back to selecting the child (safe-degrade)', async () => {
    // Seeded store has no element matching the child's parent_id. Lookup returns null →
    // safe-degrade to the old behaviour (select the child). Prevents a "select nothing" if the page
    // data is mid-fetch or the parent was deleted.
    const CHILD_ORPHAN: DesignElementApi = {
      ...ELEMENT,
      id: 'el_orphan',
      parent_id: 'el_parent_missing',
    }
    setActivePinia(createPinia())
    seedParentFor('el_parent_other')  // different parent on purpose

    const wrapper = mount(DesignElement, {
      props: { element: CHILD_ORPHAN, selected: true, zoom: 1.0, workspaceId: 'ws_test', itemId: 'item_test', pageId: 'page_1' },
    })
    const root = wrapper.find('[data-design-element]').element as HTMLElement
    root.dispatchEvent(new PointerEvent('pointerdown', {
      button: 0, pointerId: 1, clientX: 100, clientY: 100, bubbles: true,
    }))

    const selects = wrapper.emitted('select') ?? []
    expect(selects[0]?.[0]).toEqual({
      elementId: 'el_orphan',
      additive: false,
    })
  })
})