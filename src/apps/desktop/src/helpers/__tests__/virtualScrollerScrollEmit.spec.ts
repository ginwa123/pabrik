/** Regression tests for the `scroll` emit on VirtualScroller. */
/** Why this file exists: The original `scroll` emit signature was [scrollTop: number, direction:
 * 'up' | 'down'] ChatView's `handleVirtualScroll` then walked
 * `virtualScrollerRef.value?.containerRef.value` to recover the actual DOM element. */
/** That ref chain races during mount / remount (chat switch, initial mount, v-if toggle), which
 * produced a steady stream of `[scroll#N WARN] ⚠NO-CONTAINER` lines in the dev console and silently
 * skipped the geometry reads inside `handleVirtualScroll`. */
/** The fix: the `scroll` emit now includes the event target as a third argument, so the parent
 * handler can use `e.target` directly. `e.target` is the element that dispatched the scroll event,
 * so the browser guarantees it exists for the lifetime of the handler. */
/** These tests guard the emit signature and the `e.target` → `scroll` payload plumbing. If a future
 * change drops the target from the emit, ChatView's `handleVirtualScroll` will silently regress to
 * "container ref is always null", which would be hard to spot without these tests. */
import { describe, it, expect } from 'vitest'
import { mount } from '@vue/test-utils'
import { nextTick } from 'vue'
import VirtualScroller from '../VirtualScroller.vue'

/**  * Mount a VirtualScroller with one item. The item content doesn't matter for these tests — we're
 * driving scroll events directly on the root element. */
function mountScroller() {
  return mount(VirtualScroller, {
    props: {
      items: [{ id: 'a' }],
      defaultItemHeight: 200,
      // Disable lazy-load thresholds so the test doesn't have to
      // know about the threshold logic — the loadMore debounce is
      // off the critical path for this test.
      loadMoreThreshold: 200,
      loadMoreThresholdRatio: 0.5,
    },
  })
}

/**  * Dispatch a real scroll event on the scroller's root element with a known `scrollTop`. jsdom does
 * not lay out, so we set the layout-affecting properties explicitly so the geometry reads in
 * `onScroll` (target.clientHeight, target.scrollHeight) return realistic values. */
function dispatchScroll(wrapper: ReturnType<typeof mountScroller>, scrollTop: number) {
  const el = wrapper.element as HTMLElement
  Object.defineProperty(el, 'clientHeight', { value: 800, configurable: true })
  Object.defineProperty(el, 'scrollHeight', { value: 2000, configurable: true })
  el.scrollTop = scrollTop
  el.dispatchEvent(new Event('scroll'))
}

describe('VirtualScroller scroll emit', () => {
  it('passes e.target as the third emit argument on the very first scroll', async () => {
    const wrapper = mountScroller()
    await nextTick()

    dispatchScroll(wrapper, 0)
    await nextTick()

    // `wrapper.emitted('scroll')` returns an array of arrays — one entry per emit, each entry being
    // the args. We expect exactly one emit for the one scroll we dispatched.
    const emits = wrapper.emitted('scroll')
    expect(emits).toBeDefined()
    expect(emits).toHaveLength(1)

    const args = emits![0]!
    // Arg 0: scrollTop (number)
    expect(typeof args[0]).toBe('number')
    // Arg 1: direction ('up' | 'down')
    expect(['up', 'down']).toContain(args[1])
    // Arg 2: the actual DOM element that dispatched the scroll. The browser guarantees `e.target`
    // is non-null while the event is being dispatched — so the third emit argument must be the same
    // HTMLElement we just scrolled.
    expect(args[2]).toBe(wrapper.element)
    expect(args[2]).toBeInstanceOf(HTMLElement)
  })

  it('uses the target element on every subsequent scroll event, not a cached one', async () => {
    const wrapper = mountScroller()
    await nextTick()

    dispatchScroll(wrapper, 100)
    dispatchScroll(wrapper, 200)
    dispatchScroll(wrapper, 300)
    await nextTick()

    const emits = wrapper.emitted('scroll')
    expect(emits).toBeDefined()
    expect(emits).toHaveLength(3)

    // Every call's third arg must be the current element — not a stale ref, not a cached value, not
    // null. The element identity check is the key invariant: the handler is expected to pass the
    // LIVE element on every emit.
    expect(emits![0]![2]).toBe(wrapper.element)
    expect(emits![1]![2]).toBe(wrapper.element)
    expect(emits![2]![2]).toBe(wrapper.element)
  })

  it('reports the correct direction based on scrollTop delta', async () => {
    const wrapper = mountScroller()
    await nextTick()

    dispatchScroll(wrapper, 100) // initial: st went 0 → 100, dir='down'
    dispatchScroll(wrapper, 50)  // st went 100 → 50,  dir='up'
    dispatchScroll(wrapper, 200) // st went 50 → 200,  dir='down'
    await nextTick()

    const emits = wrapper.emitted('scroll')
    expect(emits).toBeDefined()
    expect(emits).toHaveLength(3)
    expect(emits![0]![1]).toBe('down')
    expect(emits![1]![1]).toBe('up')
    expect(emits![2]![1]).toBe('down')
  })

  it('reports the actual scrollTop value in the first emit arg', async () => {
    // Regression guard: if a future change to `onScroll` ever accidentally short-circuits before
    // the `emit` call (e.g. an early return when target is null), this test catches it by asserting
    // the value reaches the parent.
    const wrapper = mountScroller()
    await nextTick()

    dispatchScroll(wrapper, 150)
    await nextTick()

    const emits = wrapper.emitted('scroll')
    expect(emits).toBeDefined()
    expect(emits).toHaveLength(1)
    expect(emits![0]![0]).toBe(150)
  })
})
