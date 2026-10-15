/**
 * Regression tests for the `buffer` prop semantics in VirtualScroller.
 *
 * Why this file exists:
 *   The user reported "I set `buffer=20` in props but the DOM has more
 *   than 20 items." Two issues were causing this:
 *
 *     1. A hardcoded `+ 200` pixel lookahead in `visibleRange` added
 *        items beyond what `buffer` controlled.
 *     2. `buffer` is per-side (20 above + 20 below), not total, and
 *        this was not visible from the parent.
 *
 *   These tests pin down the contract: the rendered count is exactly
 *   `2 * buffer + visibleCount` (or fewer at the edges of the list).
 *   If a future change adds another hidden overscan, the
 *   "renderedCount matches exactly 2*buffer + visible" test fails.
 */
import { describe, it, expect } from 'vitest'
import { mount } from '@vue/test-utils'
import { nextTick } from 'vue'
import VirtualScroller from '../VirtualScroller.vue'

/** Build a list of N items. Each item's `id` is its index, which is
 * useful for assertions on `data-vs-index` attributes. */
function makeItems(n: number): Array<{ id: number }> {
  return Array.from({ length: n }, (_, i) => ({ id: i }))
}

/** Mount a VirtualScroller with the given items and a known
 * container geometry. jsdom does not lay out, so we set
 * `clientHeight` / `scrollHeight` directly to make `onScroll`'s
 * geometry reads return realistic values. The default item height
 * of 200px matches ChatView's setting, which is the primary caller. */
function mountScroller(props: {
  items: Array<{ id: number }>
  buffer?: number
  defaultItemHeight?: number
  clientHeight?: number
}) {
  const wrapper = mount(VirtualScroller, {
    props: {
      items: props.items,
      buffer: props.buffer ?? 20,
      defaultItemHeight: props.defaultItemHeight ?? 200,
      totalCount: props.items.length,
    },
  })
  // Force a known container size so the visible-range math is deterministic in jsdom.
  // `clientHeight` is read every scroll, so the ref is updated to this value the first time
  // `onScroll` fires.
  const el = wrapper.element as HTMLElement
  Object.defineProperty(el, 'clientHeight', {
    value: props.clientHeight ?? 800,
    configurable: true,
  })
  Object.defineProperty(el, 'scrollHeight', {
    value: props.items.length * (props.defaultItemHeight ?? 200),
    configurable: true,
  })
  return wrapper
}

/** `defineExpose` auto-unwraps refs and computeds on the parent
 * instance, so `scroller.renderedCount` is already a plain number
 * (not a ref). This wrapper just types the access for the tests. */
function getRenderedCount(wrapper: ReturnType<typeof mountScroller>): number {
  return (wrapper.vm as unknown as { renderedCount: number }).renderedCount
}

describe('VirtualScroller buffer prop', () => {
  it('exposes renderedCount matching exactly 2*buffer + visible (no hidden overscan)', async () => {
    // 100 items, 200px each, 800px viewport → 4 visible. Scroll to the middle (scrollTop=10000 →
    // startIndex=50) so the buffer is on BOTH sides. buffer=20 → start=30, end=74, count=44. If the
    // hardcoded +200 overscan is still present, count is 45.
    const wrapper = mountScroller({
      items: makeItems(100),
      buffer: 20,
      defaultItemHeight: 200,
      clientHeight: 800,
    })
    await nextTick()
    const el = wrapper.element as HTMLElement
    el.scrollTop = 10000
    el.dispatchEvent(new Event('scroll'))
    await nextTick()

    expect(getRenderedCount(wrapper)).toBe(44)
  })

  it('counts buffer items on BOTH sides of the visible viewport (per-side, not total)', async () => {
    // 100 items, 200px each, 800px viewport → 4 visible. Scroll to the middle (scrollTop=10000 →
    // startIndex=50) so the buffer is on BOTH sides. buffer=5 → start=45, end=59, count=14. (No
    // 5-total surprise.)
    const wrapper = mountScroller({
      items: makeItems(100),
      buffer: 5,
      defaultItemHeight: 200,
      clientHeight: 800,
    })
    await nextTick()
    const el = wrapper.element as HTMLElement
    el.scrollTop = 10000
    el.dispatchEvent(new Event('scroll'))
    await nextTick()

    expect(getRenderedCount(wrapper)).toBe(14) // 2*5 + 4
  })

  it('clamps the rendered count at the top edge of the list (no negative start)', async () => {
    // Scrolled to top, 100 items, 200px each → first 4 visible.
    // buffer=20 → start would be -20, clamped to 0; end=24; count=24.
    const wrapper = mountScroller({
      items: makeItems(100),
      buffer: 20,
      defaultItemHeight: 200,
      clientHeight: 800,
    })
    await nextTick()
    const el = wrapper.element as HTMLElement
    el.scrollTop = 0
    el.dispatchEvent(new Event('scroll'))
    await nextTick()

    expect(getRenderedCount(wrapper)).toBe(24) // 4 visible + 20 below
  })

  it('clamps the rendered count at the bottom edge of the list (no over-render past end)', async () => {
    // Scrolled to the very bottom: startIndex = 96, endIndex = 100.
    // buffer=20 → start = 76, end clamped to 100; count=24.
    const wrapper = mountScroller({
      items: makeItems(100),
      buffer: 20,
      defaultItemHeight: 200,
      clientHeight: 800,
    })
    await nextTick()
    const el = wrapper.element as HTMLElement
    // 96 * 200 = 19200 (the start of the last 4 items).
    el.scrollTop = 19200
    el.dispatchEvent(new Event('scroll'))
    await nextTick()

    expect(getRenderedCount(wrapper)).toBe(24) // 20 above + 4 visible
  })

  it('renders zero items past the visible viewport when buffer=0 (no hidden overscan)', async () => {
    // The smoke test for the hardcoded-+200 bug: with buffer=0, the rendered count must be exactly
    // the visible count. If the +200 overscan is still there, the count is 5 (4 visible + 1
    // overscan item), which fails this test.
    const wrapper = mountScroller({
      items: makeItems(100),
      buffer: 0,
      defaultItemHeight: 200,
      clientHeight: 800,
    })
    await nextTick()
    ;(wrapper.element as HTMLElement).dispatchEvent(new Event('scroll'))
    await nextTick()

    expect(getRenderedCount(wrapper)).toBe(4) // exactly visible
  })
})
