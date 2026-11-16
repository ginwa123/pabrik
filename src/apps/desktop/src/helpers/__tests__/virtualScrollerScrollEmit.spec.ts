/** Regression tests for the `scroll` emit on VirtualScroller. */
import { describe, it, expect } from 'vitest'
import { mount } from '@vue/test-utils'
import { nextTick } from 'vue'
import VirtualScroller from '../VirtualScroller.vue'

/** Mount a VirtualScroller with one item. */
function mountScroller() {
  return mount(VirtualScroller, {
    props: {
      items: [{ id: 'a' }],
      defaultItemHeight: 200,
      // Disable lazy-load thresholds so the test doesn't have to know about the threshold logic — the loadMore debounce is off the critical path for this test.
      loadMoreThreshold: 200,
      loadMoreThresholdRatio: 0.5,
    },
  })
}

/** Dispatch a real scroll event on the scroller's root element with a known `scrollTop`. jsdom does not lay out, so we set the layout-affecting properties … */
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

    // `wrapper.emitted('scroll')` returns an array of arrays — one entry per emit, each entry being the args.
    const emits = wrapper.emitted('scroll')
    expect(emits).toBeDefined()
    expect(emits).toHaveLength(1)

    const args = emits![0]!
    // Arg 0: scrollTop (number)
    expect(typeof args[0]).toBe('number')
    // Arg 1: direction ('up' | 'down')
    expect(['up', 'down']).toContain(args[1])
    // Arg 2: the actual DOM element that dispatched the scroll.
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

    // Every call's third arg must be the current element — not a stale ref, not a cached value, not null.
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
    // Regression guard: if a future change to `onScroll` ever accidentally short-circuits before the `emit` call (e.g. an early return when target is null), this …
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
