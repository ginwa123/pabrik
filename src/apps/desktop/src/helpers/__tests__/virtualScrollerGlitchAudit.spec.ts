/** Regression specs for the many-messages glitch audit (task_1788648119245_5: bounce / tall gap /
 * blank / shrink). Three independent failure mechanisms, one spec each: T1 — sizer must be
 * position-independent. */
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

function mountScroller(n: number, opts?: { buffer?: number }) {
  const wrapper = mount(VirtualScroller, {
    props: {
      items: mkItems(n),
      buffer: opts?.buffer ?? 5,
      defaultItemHeight: 64,
      totalCount: n,
      itemKey: (item: unknown) => (item as Item).id,
    },
  })
  const el = wrapper.element as HTMLElement
  Object.defineProperty(el, 'clientHeight', { value: 800, configurable: true })
  Object.defineProperty(el, 'scrollHeight', { value: 100000, configurable: true })
  return { wrapper, el }
}

function scroll(el: HTMLElement, top: number) {
  el.scrollTop = top
  el.dispatchEvent(new Event('scroll'))
}

/** Mock every currently-rendered child's offsetHeight. */
function mockAllChildren(el: HTMLElement, h: number) {
  const content = el.querySelector('.virtual-scroller-content')
  if (!content) throw new Error('.virtual-scroller-content not found')
  for (const child of Array.from(content.children)) {
    Object.defineProperty(child, 'offsetHeight', { value: h, configurable: true })
  }
}

function sizerTotal(el: HTMLElement): number {
  const sizer = el.querySelector('.virtual-scroller-sizer') as HTMLElement
  return parseFloat(sizer.style.height)
}

function modelTotalOf(wrapper: { vm: unknown }): number {
  return (wrapper.vm as unknown as { modelTotal: number }).modelTotal
}

describe('VirtualScroller many-messages glitch audit', () => {
  beforeEach(() => vi.useFakeTimers())
  afterEach(() => vi.useRealTimers())

  it('T1: settled sizer equals modelTotal at the bottom (no stale-window expand)', async () => {
    // jsdom reports offsetHeight 0 (no layout), so the content div's template-ref measurement would
    // stay 0 and the at-bottom expand path could never trigger in-test.
    const protoDesc = Object.getOwnPropertyDescriptor(HTMLElement.prototype, 'offsetHeight')
    Object.defineProperty(HTMLElement.prototype, 'offsetHeight', {
      configurable: true,
      get(this: HTMLElement) {
        if (this.classList?.contains('virtual-scroller-content')) return 43000
        return 0
      },
    })
    try {
      const { wrapper, el } = mountScroller(60)
      await nextTick()

      // First window measures at 1000px; the content div reports 43000
      // (stale from here on — the div element is never replaced).
      mockAllChildren(el, 1000)
      scroll(el, 0)
      vi.advanceTimersByTime(150)
      await nextTick()

      // Jump to the bottom: new window renders SHORT (100px) items.
      scroll(el, 1e7)
      await nextTick()
      mockAllChildren(el, 100)
      vi.advanceTimersByTime(150)
      await nextTick()

      const model = modelTotalOf(wrapper)
      const sizer = sizerTotal(el)
      // Old code: sizer = topSpacer + stale 43000 ≈ 3x the model.
      // Fixed code: sizer tracks the MODEL, independent of scrollTop.
      expect(Math.abs(sizer - model)).toBeLessThanOrEqual(50)
      wrapper.unmount()
    } finally {
      if (protoDesc) Object.defineProperty(HTMLElement.prototype, 'offsetHeight', protoDesc)
    }
  })

  it('T2: unmeasured tail is estimated at the learned median, not 64px', async () => {
    // Real chat bubbles ~400px; only a few windows get measured. The
    // sizer must converge near 100*400, not collapse to measured*400
    // + unmeasured*64.
    const { wrapper, el } = mountScroller(100)
    await nextTick()

    for (const top of [0, 5000, 1e7]) {
      scroll(el, top)
      await nextTick()
      mockAllChildren(el, 400)
      vi.advanceTimersByTime(150)
      await nextTick()
    }

    const sizer = sizerTotal(el)
    expect(sizer).toBeGreaterThan(40000 * 0.9)
    expect(sizer).toBeLessThan(40000 * 1.1)
    wrapper.unmount()
  })

  it('T3: rekeyHeight transfers a measured height across an id swap', async () => {
    const { wrapper, el } = mountScroller(10)
    await nextTick()

    // Measure item '0' tall (500px), everything else 64px.
    await nextTick()
    const content = el.querySelector('.virtual-scroller-content')!
    for (const child of Array.from(content.children)) {
      const idx = Number((child as HTMLElement).getAttribute('data-vs-index'))
      Object.defineProperty(child, 'offsetHeight', {
        value: idx === 0 ? 500 : 64,
        configurable: true,
      })
    }
    scroll(el, 0)
    vi.advanceTimersByTime(150)
    await nextTick()

    // Streaming→DB swap: the row keeps its height under a new key.
    const vm = wrapper.vm as unknown as {
      rekeyHeight: (oldKey: string, newKey: string) => boolean
    }
    expect(typeof vm.rekeyHeight).toBe('function')
    expect(vm.rekeyHeight('0', 'db-1')).toBe(true)

    // Swap the items array (id '0' → 'db-1' at index 0) and re-settle.
    const items = mkItems(10)
    items[0] = { id: 'db-1', label: 'item-db-1' }
    await wrapper.setProps({ items })
    await nextTick()
    mockAllChildren(el, 64)
    // Re-apply the tall height to the swapped row's node.
    const content2 = el.querySelector('.virtual-scroller-content')!
    for (const child of Array.from(content2.children)) {
      const idx = Number((child as HTMLElement).getAttribute('data-vs-index'))
      if (idx === 0) {
        Object.defineProperty(child, 'offsetHeight', { value: 500, configurable: true })
      }
    }
    scroll(el, 0)
    vi.advanceTimersByTime(150)
    await nextTick()

    // The transferred height survives: sizer still contains the 500px row
    // (500 + 9*64 = 1076), not a collapsed 10*64 = 640.
    expect(sizerTotal(el)).toBe(500 + 9 * 64)
    wrapper.unmount()
  })

  it('T4: a settled measure pass writes scrollTop zero times (no redundant compensation)', async () => {
    // Anchor compensation writes container.scrollTop directly; each write fires a native scroll
    // event into ChatView's isAtBottom machine. A second measure pass with no DOM changes must find
    // nothing to do (changed=false early return) and write zero times.
    const { wrapper, el } = mountScroller(255)
    await nextTick()

    scroll(el, 6400)
    await nextTick()
    mockAllChildren(el, 300)
    vi.advanceTimersByTime(120)
    await nextTick()

    let writes = 0
    let backing = el.scrollTop
    Object.defineProperty(el, 'scrollTop', {
      configurable: true,
      get: () => backing,
      set: (v: number) => {
        writes += 1
        backing = v
      },
    })

    backing = 6400
    el.dispatchEvent(new Event('scroll'))
    writes = 0
    vi.advanceTimersByTime(120)
    await nextTick()
    expect(writes).toBe(0)
    wrapper.unmount()
  })
})
