/** Tail-estimation contract (2026-09-06, task_1788648119245_5). History: this file once pinned the
 * "tail at static 64px" contract (gap-below-last-message fix) — the median was blamed for extending
 * the sizer past a fresh streaming bubble. */
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { mount } from '@vue/test-utils'
import { nextTick } from 'vue'
import VirtualScroller from '../VirtualScroller.vue'

describe('VirtualScroller tail estimation (no gap below last message)', () => {
  beforeEach(() => {
    vi.useFakeTimers()
  })
  afterEach(() => {
    vi.useRealTimers()
  })

  function mountScroller(n: number) {
    const items = Array.from({ length: n }, (_, i) => ({ id: i }))
    const wrapper = mount(VirtualScroller, {
      props: { items, buffer: 5, defaultItemHeight: 64, totalCount: n },
    })
    const el = wrapper.element as HTMLElement
    Object.defineProperty(el, 'clientHeight', { value: 800, configurable: true })
    Object.defineProperty(el, 'scrollHeight', { value: n * 64, configurable: true })
    return { wrapper, el }
  }

  it('estimates appended tail items at the learned median (no shrink)', async () => {
    // 100 items. Scroll to the middle (index ~50), measure them all at 300px → estimator median =
    // 300. Then APPEND a new item (the streaming message) at the end. It is unmeasured AND after
    // the last measured index (~59) → must estimate at 64, not 300.
    const { wrapper, el } = mountScroller(100)
    await nextTick()

    el.scrollTop = 50 * 64 // 3200 → startIndex=50
    el.dispatchEvent(new Event('scroll'))
    await vi.advanceTimersByTimeAsync(120)
    await nextTick()

    // Measure everything currently rendered at 300px.
    const content = el.querySelector('.virtual-scroller-content')!
    for (const child of Array.from(content.children)) {
      Object.defineProperty(child, 'offsetHeight', { value: 300, configurable: true })
    }
    el.dispatchEvent(new Event('scroll'))
    await vi.advanceTimersByTimeAsync(120)
    await nextTick()

    // Append the streaming message.
    await wrapper.setProps({ items: [...Array.from({ length: 100 }, (_, i) => ({ id: i })), { id: 100 }], totalCount: 101 })
    await nextTick()

    // Median-300 backs every unmeasured item: 23 measured at 300 plus 78 unmeasured (incl. the
    // appended streaming row) at median 300 = 101*300 = 30300. The old 23*300+78*64=11892 collapsed
    // the sizer to under half the real height (the shrink symptom).
    const sizer = el.querySelector('.virtual-scroller-sizer') as HTMLElement
    const total = parseFloat(sizer.style.height)
    expect(total).toBe(101 * 300)
    wrapper.unmount()
  })

  it('estimates unmeasured history AND tail at the learned median', async () => {
    // The P1 win must survive: unmeasured history items BEFORE the last measured index estimate at
    // the median, while only the TAIL (after the last measured index) falls back to the prop.
    const { wrapper, el } = mountScroller(200)
    await nextTick()

    el.scrollTop = 90 * 64
    el.dispatchEvent(new Event('scroll'))
    await vi.advanceTimersByTimeAsync(120)
    await nextTick()

    const content = el.querySelector('.virtual-scroller-content')!
    for (const child of Array.from(content.children)) {
      Object.defineProperty(child, 'offsetHeight', { value: 300, configurable: true })
    }
    el.dispatchEvent(new Event('scroll'))
    await vi.advanceTimersByTimeAsync(120)
    await nextTick()

    const sizer = el.querySelector('.virtual-scroller-sizer') as HTMLElement
    const total = parseFloat(sizer.style.height)
    expect(total).toBe(200 * 300)
    wrapper.unmount()
  })
})
