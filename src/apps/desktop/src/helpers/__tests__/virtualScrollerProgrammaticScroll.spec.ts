/**
 * Regression tests for the programmatic-scroll signal (2026-08-25
 * append-gap fix, task_1787668645042_0).
 *
 * Bug: VirtualScroller.measureItems()'s anchor compensation writes
 * `containerRef.scrollTop` directly. Assigning `.scrollTop` fires a
 * REAL native scroll event — indistinguishable from a user gesture by
 * the time it reaches ChatView's `handleVirtualScroll`. When a
 * re-measured item settles SHORTER than its estimate (streamed markdown
 * collapsing, code fences closing), the compensation moves scrollTop
 * DOWN; `userScrolledUp = deltaTop < 0` read that as a real upward
 * gesture, flipped `isAtBottom` to false, and the auto-stick
 * disengaged for the rest of the stream. Every later SSE chunk's
 * contentShift then hit the `spacer-resize-skip` guard and the gap
 * below the last message accumulated with each chunk — never
 * self-healing.
 *
 * Fix: the scroller marks its own scrollTop writes (compensation +
 * endPreserve restoration) and forwards `isProgrammatic` as the 4th
 * `scroll` emit arg; ChatView excludes programmatic events from the
 * `userScrolledUp` computation.
 *
 * jsdom note: jsdom does NOT fire a scroll event when `.scrollTop` is
 * assigned (real browsers do). Each test dispatches the follow-up
 * scroll event manually — exactly what the browser does after a
 * programmatic write — so the mark/consume wiring is observable.
 */
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { mount } from '@vue/test-utils'
import { nextTick } from 'vue'
import VirtualScroller from '../VirtualScroller.vue'

/** Mount a scroller with N items at the ChatView-like settings
 * (defaultItemHeight 64, buffer 30) and a fixed 800px viewport. */
function mountScroller(n: number) {
  const items = Array.from({ length: n }, (_, i) => ({ id: i }))
  const wrapper = mount(VirtualScroller, {
    props: {
      items,
      buffer: 30,
      defaultItemHeight: 64,
      totalCount: n,
      loadMoreAtTop: true,
    },
  })
  const el = wrapper.element as HTMLElement
  Object.defineProperty(el, 'clientHeight', { value: 800, configurable: true })
  Object.defineProperty(el, 'scrollHeight', { value: n * 64, configurable: true })
  return { wrapper, el }
}

/** Dispatch a scroll event; onScroll reads el.scrollTop synchronously. */
function scroll(el: HTMLElement, top: number) {
  el.scrollTop = top
  el.dispatchEvent(new Event('scroll'))
}

/**  * Simulate the browser firing the scroll event that follows a programmatic scrollTop write:
 * dispatch WITHOUT touching scrollTop — the element's current (post-write) value is what onScroll
 * reads. */
function fireScrollEvent(el: HTMLElement) {
  el.dispatchEvent(new Event('scroll'))
}

/** Give every rendered child a fake offsetHeight: `tallPx` for items
 * above `anchorIndex`, `estimatePx` for the rest. */
function mockChildHeights(el: HTMLElement, anchorIndex: number, tallPx: number, estimatePx: number) {
  const content = el.querySelector('.virtual-scroller-content')
  if (!content) throw new Error('.virtual-scroller-content not found')
  for (const child of Array.from(content.children)) {
    const idx = Number((child as HTMLElement).getAttribute('data-vs-index'))
    const h = idx < anchorIndex ? tallPx : estimatePx
    Object.defineProperty(child, 'offsetHeight', { value: h, configurable: true })
  }
}

/** All `scroll` emits so far, as [scrollTop, dir, target, isProgrammatic] tuples. */
function scrollEmits(wrapper: ReturnType<typeof mountScroller>['wrapper']) {
  return (wrapper.emitted('scroll') ?? []) as Array<[number, string, HTMLElement, boolean]>
}

// Viewport geometry: scrollTop 6400 → anchor item 100; buffer=30 puts
// items 70..143 in the DOM, so 30 children sit ABOVE the anchor.
const ABOVE_ANCHOR_COUNT = 30

describe('VirtualScroller programmatic-scroll signal', () => {
  beforeEach(() => {
    vi.useFakeTimers()
  })
  afterEach(() => {
    vi.useRealTimers()
  })

  it('user scroll events emit isProgrammatic=false', async () => {
    const { wrapper, el } = mountScroller(255)
    await nextTick()

    scroll(el, 6400)
    await nextTick()

    const emits = scrollEmits(wrapper)
    expect(emits.length).toBeGreaterThan(0)
    for (const args of emits) {
      expect(args[3]).toBe(false)
    }
    wrapper.unmount()
  })

  it('anchor-compensation scrollTop write emits isProgrammatic=true (the append-gap misread)', async () => {
    // Scenario: user parked mid-list (anchor = item 100). The measure pass discovers every
    // above-anchor buffer item is really 300px (vs the 64px estimate) → compensation moves
    // scrollTop UP by Σ(300−64).

    // The browser then fires a scroll event for that write; it must be labeled programmatic.
    const { wrapper, el } = mountScroller(255)
    await nextTick()

    scroll(el, 6400)
    await nextTick()
    vi.advanceTimersByTime(60) // flush the initial measure pass
    const emitsAfterUserScroll = scrollEmits(wrapper).length

    mockChildHeights(el, 100, 300, 64)
    scroll(el, 6400) // user event that triggers the measure pass (emits too)
    vi.advanceTimersByTime(60) // debounced measureItems runs + compensates
    await nextTick()

    // Compensation actually ran: scrollTop advanced by Σ(300−64) over
    // the 30 above-anchor buffer items.
    const expectedShift = ABOVE_ANCHOR_COUNT * (300 - 64)
    expect(el.scrollTop).toBe(6400 + expectedShift)

    // The browser fires a scroll event for the programmatic write.
    fireScrollEvent(el)
    await nextTick()

    const emits = scrollEmits(wrapper)
    // +2: the trigger scroll (user) + the follow-up event (programmatic).
    expect(emits.length).toBe(emitsAfterUserScroll + 2)
    const last = emits[emits.length - 1]!
    expect(last[3]).toBe(true)
    expect(last[0]).toBe(6400 + expectedShift)
    // The trigger scroll itself stays a user event.
    expect(emits[emitsAfterUserScroll]![3]).toBe(false)
    wrapper.unmount()
  })

  it('DOWNWARD compensation (content settles shorter) is also programmatic — the exact misread case', async () => {
    // The production failure: measured heights come in BELOW the estimate, compensation moves
    // scrollTop DOWN, and the old code read deltaTop<0 as "user scrolled up". The label must be
    // true so ChatView can exclude it from userScrolledUp.
    const { wrapper, el } = mountScroller(255)
    await nextTick()

    // Pass 1: above-anchor items measure at 300px.
    scroll(el, 6400)
    await nextTick()
    vi.advanceTimersByTime(60)
    mockChildHeights(el, 100, 300, 64)
    scroll(el, 6400)
    vi.advanceTimersByTime(60)
    await nextTick()
    const afterGrowth = el.scrollTop
    expect(afterGrowth).toBe(6400 + ABOVE_ANCHOR_COUNT * 236)
    fireScrollEvent(el) // browser event for the pass-1 write
    await nextTick()
    const emitsAfterGrowth = scrollEmits(wrapper).length

    // Pass 2: the same items settle SHORTER (markdown collapsed).
    mockChildHeights(el, 100, 100, 64)
    scroll(el, afterGrowth)
    vi.advanceTimersByTime(60)
    await nextTick()

    // scrollTop moved DOWN by Σ(100−300) — the old code's false
    // "user scrolled up" signal.
    const downShift = ABOVE_ANCHOR_COUNT * (100 - 300)
    expect(el.scrollTop).toBe(afterGrowth + downShift)

    fireScrollEvent(el)
    await nextTick()

    const emits = scrollEmits(wrapper)
    // +2: the trigger scroll (user) + the follow-up event (programmatic).
    expect(emits.length).toBe(emitsAfterGrowth + 2)
    const last = emits[emits.length - 1]!
    expect(last[3]).toBe(true)
    expect(last[0]).toBe(afterGrowth + downShift)
    wrapper.unmount()
  })

  it('the programmatic mark is consumed by exactly ONE scroll event', async () => {
    // One compensation write → exactly one labeled event; the NEXT
    // user-dispatched scroll must be false again (no flag leakage).
    const { wrapper, el } = mountScroller(255)
    await nextTick()

    scroll(el, 6400)
    await nextTick()
    vi.advanceTimersByTime(60)
    mockChildHeights(el, 100, 300, 64)
    scroll(el, 6400)
    vi.advanceTimersByTime(60)
    await nextTick()
    fireScrollEvent(el) // consumes the mark → true
    await nextTick()

    // Fresh user scroll after the compensation.
    scroll(el, el.scrollTop + 50)
    await nextTick()

    const emits = scrollEmits(wrapper)
    const last = emits[emits.length - 1]!
    expect(last[3]).toBe(false)
    wrapper.unmount()
  })
})

describe('ChatView handleVirtualScroll programmatic guard (static contract)', () => {
  it('userScrolledUp must exclude programmatic scroll events', async () => {
    const { readFileSync } = await import('node:fs')
    const { resolve } = await import('node:path')
    const { fileURLToPath } = await import('node:url')
    const here = fileURLToPath(import.meta.url)
    const path = resolve(here, '../../../components/views/ChatView.vue')
    const src = readFileSync(path, 'utf8')
    // The guard must not treat a programmatic compensation write as a
    // real upward gesture — otherwise isAtBottom flips false and the
    // auto-stick disengages for the rest of the stream (the gap bug).
    expect(src).toMatch(/userScrolledUp\s*=\s*!isProgrammatic\s*&&\s*deltaTop\s*<\s*0/)
  })

  it('handleVirtualScroll accepts the 4th isProgrammatic emit arg', async () => {
    const { readFileSync } = await import('node:fs')
    const { resolve } = await import('node:path')
    const { fileURLToPath } = await import('node:url')
    const here = fileURLToPath(import.meta.url)
    const path = resolve(here, '../../../components/views/ChatView.vue')
    const src = readFileSync(path, 'utf8')
    expect(src).toMatch(
      /handleVirtualScroll\s*=\s*\(\s*scrollTop:\s*number,\s*direction:\s*'up'\s*\|\s*'down',\s*target:\s*HTMLElement,\s*isProgrammatic/,
    )
  })

  it('VirtualScroller forwards isProgrammatic on the scroll emit', async () => {
    const { readFileSync } = await import('node:fs')
    const { resolve } = await import('node:path')
    const { fileURLToPath } = await import('node:url')
    const here = fileURLToPath(import.meta.url)
    const path = resolve(here, '../../VirtualScroller.vue')
    const src = readFileSync(path, 'utf8')
    // The emit must carry the consumed flag as the 4th arg.
    expect(src).toMatch(/emit\('scroll',\s*st,\s*dir[^,]*,\s*target,\s*isProgrammatic\)/)
    // The compensation write must be marked BEFORE the assignment.
    expect(src).toMatch(
      /markProgrammaticScroll\(\)\s*\n\s*containerRef\.value\.scrollTop\s*=\s*result\.newScrollTop/,
    )
  })
})
