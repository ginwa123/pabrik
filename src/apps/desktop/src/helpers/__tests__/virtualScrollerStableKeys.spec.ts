/** Regression tests for the stable-key height cache (2026-08-26, follow-up to PR #349). Bug:
 * heights were keyed by ARRAY INDEX. ChatView renders `messageGroups` — a computed that
 * re-merges/re-filters on every SSE event. */
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { mount } from '@vue/test-utils'
import { nextTick } from 'vue'
import VirtualScroller from '../VirtualScroller.vue'

interface Item {
  id: string
  label: string
}

function mkItems(n: number, prefix = ''): Item[] {
  return Array.from({ length: n }, (_, i) => ({ id: `${prefix}${i}`, label: `item-${prefix}${i}` }))
}

function mountKeyed(n: number) {
  const wrapper = mount(VirtualScroller, {
    props: {
      items: mkItems(n),
      buffer: 30,
      defaultItemHeight: 64,
      totalCount: n,
      itemKey: (item: unknown) => (item as Item).id,
      // These tests assert the height model itself. The tail cap has its own
      // spec and may intentionally hold the rendered sizer within hysteresis.
      maxTailGap: 0,
    },
  })
  const el = wrapper.element as HTMLElement
  Object.defineProperty(el, 'clientHeight', { value: 800, configurable: true })
  Object.defineProperty(el, 'scrollHeight', { value: n * 64, configurable: true })
  return { wrapper, el }
}

function scroll(el: HTMLElement, top: number) {
  el.scrollTop = top
  el.dispatchEvent(new Event('scroll'))
}

function sizerTotal(el: HTMLElement): number {
  const sizer = el.querySelector('.virtual-scroller-sizer') as HTMLElement
  return parseFloat(sizer.style.height)
}

describe('VirtualScroller stable-key height cache', () => {
  beforeEach(() => vi.useFakeTimers())
  afterEach(() => vi.useRealTimers())

  it('a measured item keeps its height after an index shift (regroup simulation)', async () => {
    // 20 items, all measured at DISTINCT heights. Then the parent PREPENDS 2 items (the
    // messageGroups regroup case: a new group inserted at the front shifts every later index).
    const { wrapper, el } = mountKeyed(20)
    await nextTick()

    // Measure everything at distinct heights: item i → 100 + i*10 px.
    const content = el.querySelector('.virtual-scroller-content')!
    const items = mkItems(20)
    for (const child of Array.from(content.children)) {
      const idx = Number((child as HTMLElement).getAttribute('data-vs-index'))
      Object.defineProperty(child, 'offsetHeight', {
        value: 100 + idx * 10,
        configurable: true,
      })
    }
    scroll(el, 0)
    vi.advanceTimersByTime(120)
    await nextTick()
    const totalBefore = sizerTotal(el)
    let expected = 0
    for (let i = 0; i < 20; i++) expected += 100 + i * 10
    expect(totalBefore).toBe(expected)

    // Prepend 2 NEW items (ids "a0", "a1") — every old item's index
    // shifts by +2. This is the exact mutation that corrupted the
    // index-keyed cache.
    const newItems = [...mkItems(2, 'a'), ...items]
    await wrapper.setProps({ items: newItems, totalCount: 22 })
    await nextTick()

    // Mock the new items' heights (they're unmeasured → estimate 64)
    // and re-measure. Old items keep their stored heights.
    const content2 = el.querySelector('.virtual-scroller-content')!
    for (const child of Array.from(content2.children)) {
      const idx = Number((child as HTMLElement).getAttribute('data-vs-index'))
      const id = newItems[idx]!.id
      const h = id.startsWith('a') ? 64 : 100 + Number(id) * 10
      Object.defineProperty(child, 'offsetHeight', { value: h, configurable: true })
    }
    scroll(el, 0)
    vi.advanceTimersByTime(120)
    await nextTick()

    // Sizer must equal Σ(old items' own heights) + Σ(new items' 64px).
    // With index-keyed heights the old items' heights would have been
    // attributed to the wrong rows and the total would differ.
    let expectedAfter = 2 * 64
    for (let i = 0; i < 20; i++) expectedAfter += 100 + i * 10
    expect(sizerTotal(el)).toBe(expectedAfter)
    wrapper.unmount()
  })

  it('DOM nodes are keyed by itemKey (v-for reuse across shifts)', async () => {
    const { wrapper, el } = mountKeyed(5)
    await nextTick()
    const content = el.querySelector('.virtual-scroller-content')!
    const firstNodeBefore = content.children[0]

    // Prepend 2 items: with :key="itemKey(item)" the node rendering
    // item "0" is REUSED (same DOM node), not destroyed/recreated.
    await wrapper.setProps({ items: [...mkItems(2, 'a'), ...mkItems(5)] })
    await nextTick()

    const content2 = el.querySelector('.virtual-scroller-content')!
    // The node that was item "0" (index 0) is now item "a0"; the node
    // for item "0" moved to index 2 — and it must be the SAME node.
    const nodeForItem0 = content2.children[2]
    expect(nodeForItem0).toBe(firstNodeBefore)
    wrapper.unmount()
  })

  it('default (no itemKey) keeps the historical index-keyed behavior', async () => {
    const wrapper = mount(VirtualScroller, {
      props: { items: mkItems(10), buffer: 30, defaultItemHeight: 64 },
    })
    const el = wrapper.element as HTMLElement
    Object.defineProperty(el, 'clientHeight', { value: 800, configurable: true })
    Object.defineProperty(el, 'scrollHeight', { value: 10 * 64, configurable: true })
    await nextTick()

    const content = el.querySelector('.virtual-scroller-content')!
    for (const child of Array.from(content.children)) {
      Object.defineProperty(child, 'offsetHeight', { value: 64, configurable: true })
    }
    scroll(el, 0)
    vi.advanceTimersByTime(120)
    await nextTick()
    expect(sizerTotal(el)).toBe(10 * 64)
    wrapper.unmount()
  })

  it('scrollToBottom targets the REAL content bottom when the model overshoots (blank-viewport fix)', async () => {
    // The user's screenshot: sizer 29389px but the real rendered content was far shorter —
    // stick-to-bottom computed from scrollHeight landed PAST the last row into blank space. With
    // the real-bottom override, the stick targets topSpacer + rendered content height instead.
    const { wrapper, el } = mountKeyed(20)
    await nextTick()

    // Measure all items at 64px → model total = 1280 (matches reality).
    const content = el.querySelector('.virtual-scroller-content')!
    for (const child of Array.from(content.children)) {
      Object.defineProperty(child, 'offsetHeight', { value: 64, configurable: true })
    }
    scroll(el, 0)
    vi.advanceTimersByTime(120)
    await nextTick()

    // NOW the model overshoots: the sizer binding says 29389 (stale model) while the real rendered
    // content is only 20×64=1280. jsdom: scrollHeight is whatever we define it to be — set it to
    // the phantom value the browser would report from the inflated sizer.
    Object.defineProperty(el, 'scrollHeight', { value: 29389, configurable: true })
    Object.defineProperty(content, 'offsetHeight', { value: 20 * 64, configurable: true })
    // jsdom has no scrollTo; stub it to capture the target.
    let capturedTop = -1
    ;(el as unknown as { scrollTo: (o: { top: number }) => void }).scrollTo = (o) => {
      capturedTop = o.top
    }

    const vm = wrapper.vm as unknown as { scrollToBottom: (b?: ScrollBehavior) => void }
    vm.scrollToBottom('auto')

    // The stick must target the REAL bottom (1280 − 800 = 480), NOT
    // the phantom model bottom (29389 − 800 = 28589).
    expect(capturedTop).toBe(20 * 64 - 800)
    wrapper.unmount()
  })

  it('scrollToBottom falls back to scrollHeight when the model matches reality', async () => {
    const { wrapper, el } = mountKeyed(20)
    await nextTick()

    const content = el.querySelector('.virtual-scroller-content')!
    for (const child of Array.from(content.children)) {
      Object.defineProperty(child, 'offsetHeight', { value: 64, configurable: true })
    }
    scroll(el, 0)
    vi.advanceTimersByTime(120)
    await nextTick()

    // Model agrees with reality: scrollHeight = 1280. Mock the content
    // div's height too (jsdom does no layout).
    Object.defineProperty(el, 'scrollHeight', { value: 20 * 64, configurable: true })
    Object.defineProperty(content, 'offsetHeight', { value: 20 * 64, configurable: true })
    let capturedTop = -1
    ;(el as unknown as { scrollTo: (o: { top: number }) => void }).scrollTo = (o) => {
      capturedTop = o.top
    }

    const vm = wrapper.vm as unknown as { scrollToBottom: (b?: ScrollBehavior) => void }
    vm.scrollToBottom('auto')
    expect(capturedTop).toBe(20 * 64 - 800)
    wrapper.unmount()
  })
})
