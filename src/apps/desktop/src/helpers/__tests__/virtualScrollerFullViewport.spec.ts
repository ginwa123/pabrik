/** Full-viewport content-window specs for VirtualScroller.vue. Symptom: with many messages,
 * scrolling to the bottom shrinks the `.virtual-scroller-content` div to half (or less) of the chat
 * height, leaving blank sizer below it. */

/** Mechanism: `visibleRange` covers the viewport in MODEL space (estimates), but the real DOM can
 * be much shorter when estimates overshoot reality — a tail of short tool-card groups against a
 * ~400px running median, plus up to HYSTERESIS_PX of residue per item that never corrects. */

/** The content div is only as tall as its rendered children, so it renders short. Fix pinned here:
 * the content window carries `min-height: <containerHeight>px`, so its box is never shorter than
 * one viewport — at the bottom, in the middle, and for short lists. */

/** The content is absolutely positioned (out of flow) and measureItems reads child heights, so the
 * min-height never feeds back into the sizer model or the compensation loop. */
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { mount } from '@vue/test-utils'
import { nextTick } from 'vue'
import VirtualScroller from '../VirtualScroller.vue'

type Item = { id: string }

function makeItems(n: number): Item[] {
  return Array.from({ length: n }, (_, i) => ({ id: `item-${i}` }))
}

function mountScroller(n: number, opts?: { buffer?: number; clientHeight?: number }) {
  const wrapper = mount(VirtualScroller, {
    props: {
      items: makeItems(n),
      buffer: opts?.buffer ?? 5,
      defaultItemHeight: 64,
      totalCount: n,
      itemKey: (item: unknown) => (item as Item).id,
    },
  })
  const el = wrapper.element as HTMLElement
  Object.defineProperty(el, 'clientHeight', {
    value: opts?.clientHeight ?? 800,
    configurable: true,
  })
  Object.defineProperty(el, 'scrollHeight', { value: 100000, configurable: true })
  return { wrapper, el }
}

function contentMinHeight(el: HTMLElement): string {
  const content = el.querySelector('.virtual-scroller-content') as HTMLElement | null
  if (!content) throw new Error('.virtual-scroller-content not found')
  return content.style.minHeight
}

describe('VirtualScroller full-viewport content window', () => {
  it('content min-height equals the viewport after scrolling to the bottom', async () => {
    const { wrapper, el } = mountScroller(400, { buffer: 30 })
    await nextTick()

    // Dispatch a scroll so onScroll syncs containerHeight from clientHeight.
    el.scrollTop = 50000
    el.dispatchEvent(new Event('scroll'))
    await nextTick()

    expect(contentMinHeight(el)).toBe('800px')
    // The tail window still reaches the last item.
    const vm = wrapper.vm as unknown as { effectiveRange: { start: number; end: number } }
    expect(vm.effectiveRange.end).toBe(400)
    wrapper.unmount()
  })

  it('content min-height tracks the viewport in the middle of a long list', async () => {
    const { wrapper, el } = mountScroller(400, { buffer: 30 })
    await nextTick()

    el.scrollTop = 12000
    el.dispatchEvent(new Event('scroll'))
    await nextTick()

    expect(contentMinHeight(el)).toBe('800px')
    wrapper.unmount()
  })

  it('short list: content still spans the full viewport height', async () => {
    const { wrapper, el } = mountScroller(3, { buffer: 30 })
    await nextTick()

    el.scrollTop = 0
    el.dispatchEvent(new Event('scroll'))
    await nextTick()

    // 3 × 64px of real content would be 192px — the box must still be 800px.
    expect(contentMinHeight(el)).toBe('800px')
    wrapper.unmount()
  })

  it('no bogus 0px clamp before the container has a size (mount flicker)', async () => {
    // clientHeight 0: the 0×0 first-paint flicker. min-height must be
    // absent, not "0px" (which would collapse the window to nothing).
    const { wrapper, el } = mountScroller(100, { buffer: 5, clientHeight: 0 })
    await nextTick()

    expect(contentMinHeight(el)).toBe('')
    wrapper.unmount()
  })

  it('transform positioning is untouched by the min-height', async () => {
    const { wrapper, el } = mountScroller(100, { buffer: 5 })
    await nextTick()

    el.scrollTop = 3200
    el.dispatchEvent(new Event('scroll'))
    await nextTick()

    const content = el.querySelector('.virtual-scroller-content') as HTMLElement
    // scrollTop=3200 → startIndex=50 (3200/64) → start=45 →
    // topSpacer = 45 × 64 = 2880.
    expect(content.style.transform).toBe('translate3d(0px, 2880px, 0px)')
    expect(content.style.minHeight).toBe('800px')
    wrapper.unmount()
  })
})

/** Two-tier hysteresis: the sizer must converge to the real content bottom instead of parking up to
 * HYSTERESIS_PX (50) per item too tall — the persistent blank gap below the last message at max
 * scroll (sizer 40383px vs content bottom ~37095px in the report). */

/** Setup pins the estimator out of the picture: 20 items with buffer=30 means the whole list is
 * always rendered, so after the first measure pass every item has a REAL stored height and no
 * estimates remain. modelTotal assertions are then exact. */
describe('VirtualScroller two-tier measurement dead-band', () => {
  beforeEach(() => vi.useFakeTimers())
  afterEach(() => vi.useRealTimers())

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

  function modelTotalOf(wrapper: { vm: unknown }): number {
    return (wrapper.vm as unknown as { modelTotal: number }).modelTotal
  }

  async function measureAtTop(el: HTMLElement, h: number) {
    el.scrollTop = 0
    el.dispatchEvent(new Event('scroll'))
    mockAllChildren(el, h)
    vi.advanceTimersByTime(150)
    await nextTick()
  }

  it('at/below-viewport re-measurement writes exact (no 50px dead-band)', async () => {
    const { wrapper, el } = mountFullList()
    await nextTick()

    // First pass: all 20 items measured at 100px.
    await measureAtTop(el, 100)
    expect(modelTotalOf(wrapper)).toBe(2000)

    // Second pass 30px taller — under the 50px dead-band, but every
    // item is at/below the anchor (scrollTop=0 → anchor=0), so the
    // exact tier admits it. Old behavior parked the model at 2000.
    await measureAtTop(el, 130)
    expect(modelTotalOf(wrapper)).toBe(2600)
    wrapper.unmount()
  })

  it('strictly-above-viewport re-measurement keeps the 50px dead-band', async () => {
    const { wrapper, el } = mountFullList()
    await nextTick()

    await measureAtTop(el, 100)
    expect(modelTotalOf(wrapper)).toBe(2000)
    await measureAtTop(el, 130)
    expect(modelTotalOf(wrapper)).toBe(2600)

    // Scroll to the bottom: anchor = last index (19). Re-measure 20px taller — under the dead-band.
    // Items 0..18 sit strictly above the anchor and must NOT move; item 19 (at the anchor) takes
    // the exact tier.
    el.scrollTop = 1e7
    el.dispatchEvent(new Event('scroll'))
    mockAllChildren(el, 150)
    vi.advanceTimersByTime(150)
    await nextTick()

    expect(modelTotalOf(wrapper)).toBe(19 * 130 + 150)
    wrapper.unmount()
  })
})
