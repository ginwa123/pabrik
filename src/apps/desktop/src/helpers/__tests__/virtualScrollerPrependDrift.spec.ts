/** Regression test: sizer drift over a long chat with loadMore prepends. */
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { mount } from '@vue/test-utils'
import { nextTick } from 'vue'
import VirtualScroller from '../VirtualScroller.vue'

// Bimodal "real" heights: tool rows 24px, bubbles 100-400px.
function realHeight(index: number): number {
  if (index % 5 === 0) return 24
  return 100 + (index % 7) * 50
}

function mk(n: number, offset = 0) {
  return Array.from({ length: n }, (_, i) => ({ id: offset + i }))
}

describe('VirtualScroller prepend height remap (100-message lifecycle)', () => {
  beforeEach(() => vi.useFakeTimers())
  afterEach(() => vi.useRealTimers())

  it('sizer converges to Σ real heights through scroll + prepend + append', async () => {
    const wrapper = mount(VirtualScroller, {
      props: {
        items: mk(20),
        buffer: 30,
        defaultItemHeight: 64,
        totalCount: 0,
        loadMoreAtTop: true,
      },
    })
    const el = wrapper.element as HTMLElement
    Object.defineProperty(el, 'clientHeight', { value: 800, configurable: true })
    // In a real browser the container's `scrollHeight` IS the sizer's height.
    const sizerEl = () => el.querySelector('.virtual-scroller-sizer') as HTMLElement
    Object.defineProperty(el, 'scrollHeight', {
      configurable: true,
      get(): number {
        const modelled = parseFloat(sizerEl()?.style.height ?? '')
        return Number.isFinite(modelled) && modelled > 0 ? modelled : 20 * 64
      },
    })
    await nextTick()

    const setRealHeights = () => {
      const content = el.querySelector('.virtual-scroller-content')!
      for (const child of Array.from(content.children)) {
        const idx = Number((child as HTMLElement).getAttribute('data-vs-index'))
        Object.defineProperty(child, 'offsetHeight', { value: realHeight(idx), configurable: true })
      }
    }
    const flushMeasure = async () => {
      el.dispatchEvent(new Event('scroll'))
      await vi.advanceTimersByTimeAsync(120)
      await nextTick()
    }
    const sizerTotal = () =>
      parseFloat((el.querySelector('.virtual-scroller-sizer') as HTMLElement).style.height)

    // Phase 1: initial measure (window covers all 20 with buffer=30).
    el.scrollTop = 20 * 64
    await nextTick()
    setRealHeights()
    await flushMeasure()

    // Phase 2: loadMore prepend — real app calls beginPreserve(N) before mutating the array and
    // endPreserve() after. endPreserve awaits rAF internally; under fake timers we fire-and-forget
    // it and advance the clock so its internal awaits resolve.
    const vm = wrapper.vm as unknown as {
      beginPreserve: (n: number) => void
      endPreserve: () => Promise<void>
    }
    vm.beginPreserve(20)
    await wrapper.setProps({ items: [...mk(20, 100), ...mk(20)] })
    await nextTick()
    setRealHeights()
    await flushMeasure()
    const preserving = vm.endPreserve()
    await vi.advanceTimersByTimeAsync(100)
    await nextTick()
    await preserving
    await nextTick()

    // Phase 3: streaming appends at the bottom.
    for (let i = 1; i <= 3; i++) {
      await wrapper.setProps({ items: [...mk(20, 100), ...mk(20), ...mk(i, 20)] })
      await nextTick()
      setRealHeights()
      await flushMeasure()
    }

    // FINAL: 43 items at indices 0..42. Heights stored through the prepend must still describe
    // their own items, so the sizer equals Σ realHeight(i) for i in 0..42 — measured ones exactly,
    // unmeasured ones within estimate tolerance.
    let expected = 0
    for (let i = 0; i < 43; i++) expected += realHeight(i)
    const total = sizerTotal()
    expect(Math.abs(total - expected)).toBeLessThanOrEqual(expected * 0.05)
    wrapper.unmount()
  })

  it('a prepended item keeps its own measured height (stable-key cache, no remap needed)', async () => {
    // Focused unit — UPDATED for the stable-key cache (2026-08-26). The old design remapped index
    // keys by +N inside beginPreserve; the new design keys heights by itemKey, so heights travel
    // with their items automatically and the remap is gone.
    const wrapper = mount(VirtualScroller, {
      props: {
        items: mk(3),
        buffer: 10,
        defaultItemHeight: 64,
        totalCount: 0,
        itemKey: (item: unknown) => String((item as { id: number }).id),
      },
    })
    const el = wrapper.element as HTMLElement
    Object.defineProperty(el, 'clientHeight', { value: 800, configurable: true })
    Object.defineProperty(el, 'scrollHeight', { value: 3 * 64, configurable: true })
    await nextTick()

    const content = el.querySelector('.virtual-scroller-content')!
    const heights = [100, 200, 300]
    for (const child of Array.from(content.children)) {
      const idx = Number((child as HTMLElement).getAttribute('data-vs-index'))
      Object.defineProperty(child, 'offsetHeight', { value: heights[idx], configurable: true })
    }
    el.dispatchEvent(new Event('scroll'))
    await vi.advanceTimersByTimeAsync(120)
    await nextTick()

    // Pre-prepend: acc[3] = 100+200+300 = 600.
    expect(
      parseFloat((el.querySelector('.virtual-scroller-sizer') as HTMLElement).style.height),
    ).toBe(600)

    const vm = wrapper.vm as unknown as { beginPreserve: (n: number) => void }
    vm.beginPreserve(2)
    await nextTick()
    // Stable keys: heights are untouched by beginPreserve — the sizer stays 600 (the heights still
    // describe their own items). The corruption the old remap guarded against is now impossible by
    // construction.
    expect(
      parseFloat((el.querySelector('.virtual-scroller-sizer') as HTMLElement).style.height),
    ).toBe(600)
    wrapper.unmount()
  })
})
