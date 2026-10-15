/** Idle content-size observer specs for VirtualScroller.vue. */

/** Symptom: "small scroll suddenly shows content / jumps". measureItems runs on scroll,
 * remeasure(), and rendered-range change — but NOT when an already-rendered item grows on its own
 * (async image decode, a PresentFiles source fetch resolving, progress filling in). */

/** The model lags reality until the NEXT scroll, which applies all pending corrections at once. Fix
 * pinned here: a ResizeObserver on the CONTENT box schedules a debounced measure (~150ms) whenever
 * the real content box grows while idle, so corrections land promptly instead of accumulating. */

/** Loop safety (a naive container observer once froze the browser): only the content div's own box
 * is observed — nothing in the measure path alters that box (transforms move position, not size;
 * the sizer is a sibling). */

/** Sub-2px noise is ignored, preserve/pre-paint windows are skipped, and the observer stays quiet
 * shortly after a scroll (the scroll path already measures). */

/** Timer hygiene note: the scroller's debounce chains (measure → height-rebuild → range watcher →
 * trailing measure) cascade across fake-timer advances, so every phase below ends with drain() —
 * several advance+flush rounds that leave NO path pending. */

/** Each phase then proves exactly one measurement path. */
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { mount } from '@vue/test-utils'
import { nextTick } from 'vue'
import VirtualScroller from '../VirtualScroller.vue'

type Item = { id: string }

type ROCallback = (entries: unknown[], observer: unknown) => void

let roCallbacks: ROCallback[] = []

class ControllableRO {
  cb: ROCallback
  constructor(cb: ROCallback) {
    this.cb = cb
    roCallbacks.push(cb)
  }
  observe(): void {}
  unobserve(): void {}
  disconnect(): void {}
}

function fireContentRO(): void {
  // The LAST observer constructed is the content observer (the
  // container observer is constructed first in onMounted).
  const cb = roCallbacks[roCallbacks.length - 1]
  if (!cb) throw new Error('content ResizeObserver was not constructed')
  cb([], null)
}

function makeItems(n: number): Item[] {
  return Array.from({ length: n }, (_, i) => ({ id: `item-${i}` }))
}

function mountFullList() {
  const wrapper = mount(VirtualScroller, {
    props: {
      items: makeItems(20),
      buffer: 30,
      defaultItemHeight: 64,
      totalCount: 20,
      itemKey: (item: unknown) => (item as Item).id,
    },
  })
  const el = wrapper.element as HTMLElement
  Object.defineProperty(el, 'clientHeight', { value: 800, configurable: true })
  Object.defineProperty(el, 'scrollHeight', { value: 100000, configurable: true })
  return { wrapper, el }
}

function mockAllChildren(el: HTMLElement, h: number) {
  const content = el.querySelector('.virtual-scroller-content')
  if (!content) throw new Error('.virtual-scroller-content not found')
  for (const child of Array.from(content.children)) {
    Object.defineProperty(child, 'offsetHeight', { value: h, configurable: true })
  }
}

function mockContentH(el: HTMLElement, h: number) {
  const content = el.querySelector('.virtual-scroller-content') as HTMLElement
  if (!content) throw new Error('.virtual-scroller-content not found')
  Object.defineProperty(content, 'offsetHeight', { value: h, configurable: true })
}

function modelTotalOf(wrapper: { vm: unknown }): number {
  return (wrapper.vm as unknown as { modelTotal: number }).modelTotal
}

/** Flush every pending debounce cascade so the next phase starts clean. */
async function drain(rounds = 4): Promise<void> {
  for (let i = 0; i < rounds; i++) {
    vi.advanceTimersByTime(500)
    await nextTick()
  }
}

describe('VirtualScroller idle content-size observer', () => {
  beforeEach(() => {
    vi.useFakeTimers()
    roCallbacks = []
    vi.stubGlobal('ResizeObserver', ControllableRO)
  })
  afterEach(() => {
    vi.unstubAllGlobals()
    vi.useRealTimers()
  })

  it('re-measures when the content box grows while idle (no scroll)', async () => {
    const { wrapper, el } = mountFullList()
    await nextTick()

    // Settle at 100px/child with a fully drained cascade: model = 2000
    // and nothing pending.
    el.scrollTop = 0
    el.dispatchEvent(new Event('scroll'))
    mockAllChildren(el, 100)
    mockContentH(el, 2000)
    await drain()
    expect(modelTotalOf(wrapper)).toBe(2000)

    // Async growth with NO scroll (image decode / fetch resolving). Only the content observer can
    // pick this up: without the fix the model parks at 2000 until the user's next scroll applies
    // the whole correction at once.
    mockAllChildren(el, 200)
    mockContentH(el, 4000)
    fireContentRO()
    await drain()
    expect(modelTotalOf(wrapper)).toBe(4000)
    wrapper.unmount()
  })

  it('scroll-path measurement still converges promptly (RO defers to it)', async () => {
    const { wrapper, el } = mountFullList()
    await nextTick()

    el.scrollTop = 0
    el.dispatchEvent(new Event('scroll'))
    mockAllChildren(el, 100)
    mockContentH(el, 2000)
    await drain()
    expect(modelTotalOf(wrapper)).toBe(2000)

    // A scroll just happened (Date.now is fake-timer controlled, so the observer sees it as recent)
    // and growth lands on top of it.

    // The scroll debounce (50ms) owns this measurement: advancing just past it — but before the RO
    // debounce (150ms) could fire — must already show the converged model. The RO may still fire
    // later, but only as a harmless no-op (model already exact).
    el.dispatchEvent(new Event('scroll'))
    mockAllChildren(el, 200)
    mockContentH(el, 4000)
    fireContentRO()
    vi.advanceTimersByTime(60)
    await nextTick()
    expect(modelTotalOf(wrapper)).toBe(4000)
    await drain()
    expect(modelTotalOf(wrapper)).toBe(4000)
    wrapper.unmount()
  })

  it('ignores sub-2px content-box noise', async () => {
    const { wrapper, el } = mountFullList()
    await nextTick()

    el.scrollTop = 0
    el.dispatchEvent(new Event('scroll'))
    mockAllChildren(el, 100)
    mockContentH(el, 2000)
    await drain()
    expect(modelTotalOf(wrapper)).toBe(2000)

    // Sync the observer baseline: fire once at the settled box size (in a real browser the observer
    // fires on every change and the baseline tracks; in jsdom it only fires when the test says so).
    // The scheduled measure is a no-op (children already exact).
    fireContentRO()
    await drain()
    expect(modelTotalOf(wrapper)).toBe(2000)

    // 1px of box noise: no measure may be scheduled. (Children are deliberately moved to 130 — a
    // 30px growth the observer must NOT pick up from a 1px box delta. In a real browser the box
    // always reflects child growth, so this only exercises the noise gate.

    // The pre-phase drain guarantees no other path is pending, so a 2600 here can only come from a
    // broken gate.)
    mockAllChildren(el, 130)
    mockContentH(el, 2001)
    fireContentRO()
    await drain()
    expect(modelTotalOf(wrapper)).toBe(2000)
    wrapper.unmount()
  })
})
