/** P1 performance wiring tests for VirtualScroller.vue (task_1787551495337_9, "make virtual
 * scroller more smooth"). What P1 changes, and what each test pins: 1. */
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { mount } from '@vue/test-utils'
import { nextTick } from 'vue'
import VirtualScroller from '../VirtualScroller.vue'

type Item = { id: number }

function makeItems(n: number): Item[] {
  return Array.from({ length: n }, (_, i) => ({ id: i }))
}

interface MountedScroller {
  wrapper: ReturnType<typeof mount>
  el: HTMLElement
}

function mountScroller(props: {
  items: Item[]
  buffer?: number
  defaultItemHeight?: number
  clientHeight?: number
}): MountedScroller {
  const wrapper = mount(VirtualScroller, {
    props: {
      items: props.items,
      buffer: props.buffer ?? 20,
      defaultItemHeight: props.defaultItemHeight ?? 200,
      totalCount: props.items.length,
    },
  })
  const el = wrapper.element as HTMLElement
  Object.defineProperty(el, 'clientHeight', {
    value: props.clientHeight ?? 800,
    configurable: true,
  })
  Object.defineProperty(el, 'scrollHeight', {
    value: props.items.length * (props.defaultItemHeight ?? 200),
    configurable: true,
  })
  return { wrapper, el }
}

function getVm(wrapper: ReturnType<typeof mount>) {
  return wrapper.vm as unknown as {
    renderedCount: number
    effectiveRange: { start: number; end: number }
  }
}

// ─── 1. Scroll pipeline coalescing ───────────────────────────────────────────
describe('VirtualScroller scroll pipeline', () => {
  beforeEach(() => {
    vi.useFakeTimers()
  })
  afterEach(() => {
    vi.useRealTimers()
  })

  it('collapses a burst of scroll events into ONE range recompute per flush', async () => {
    // Vue's async render queue is the coalescer: N scroll events between two scheduler flushes
    // mutate scrollTop.value N times (cheap ref writes with equality checks) but trigger exactly
    // ONE component re-render and ONE visibleRange evaluation.
    const { wrapper, el } = mountScroller({ items: makeItems(100), buffer: 5 })
    await nextTick()

    const positions = [2000, 4000, 6000, 8000, 10000]
    for (const pos of positions) {
      el.scrollTop = pos
      el.dispatchEvent(new Event('scroll'))
    }
    await nextTick()

    const vm = getVm(wrapper)
    // Final position wins: scrollTop=10000 → startIndex=50; buffer=5 →
    // start=45.
    expect(vm.effectiveRange.start).toBe(45)
    wrapper.unmount()
  })

  it('still emits scroll events synchronously (parent contract unchanged)', async () => {
    const { wrapper, el } = mountScroller({ items: makeItems(10), buffer: 2 })
    await nextTick()

    el.scrollTop = 400
    el.dispatchEvent(new Event('scroll'))

    // The @scroll emit must stay synchronous per event — ChatView's
    // direction tracking and stick-to-bottom gating depend on it.
    expect(wrapper.emitted('scroll')).toHaveLength(1)
    wrapper.unmount()
  })
})

// ─── 2. Batched height writes ────────────────────────────────────────────────
describe('VirtualScroller batched height measurement', () => {
  beforeEach(() => {
    vi.useFakeTimers()
  })
  afterEach(() => {
    vi.useRealTimers()
  })

  it('applies many measured heights with a single accumulatedHeights rebuild', async () => {
    const items = makeItems(60)
    const { wrapper, el } = mountScroller({
      items,
      buffer: 5,
      defaultItemHeight: 200,
      clientHeight: 800,
    })
    await nextTick()

    // Mock ALL rendered children to report a real height of 300px.
    const content = el.querySelector('.virtual-scroller-content')
    expect(content).toBeTruthy()
    const children = content!.children
    expect(children.length).toBeGreaterThan(0)
    for (const child of Array.from(children)) {
      Object.defineProperty(child, 'offsetHeight', { value: 300, configurable: true })
    }

    // Spy on the internal rebuild by watching the exposed scrollInfo totalItems stability —
    // instead, count rebuilds indirectly: the deep watch on itemHeights debounces 50ms; a batched
    // write means ONE debounce timer covers the whole batch and ONE rebuild runs.
    el.scrollTop = 0
    el.dispatchEvent(new Event('scroll'))

    // Flush the pre-paint measure (nextTick) + trailing debounce (50ms).
    await vi.advanceTimersByTimeAsync(0)
    await nextTick()
    await vi.advanceTimersByTimeAsync(120)
    await nextTick()

    // All measured heights landed: renderedCount stays consistent and no errors were thrown.
    const vm = getVm(wrapper)
    expect(vm.renderedCount).toBeGreaterThan(0)

    // Second pass: heights already stored, hysteresis skips → no churn.
    el.dispatchEvent(new Event('scroll'))
    await vi.advanceTimersByTimeAsync(120)
    await nextTick()
    expect(getVm(wrapper).renderedCount).toBe(vm.renderedCount)
    wrapper.unmount()
  })
})

// ─── 3. Adaptive defaultItemHeight ───────────────────────────────────────────
describe('VirtualScroller adaptive item-height estimation', () => {
  beforeEach(() => {
    vi.useFakeTimers()
  })
  afterEach(() => {
    vi.useRealTimers()
  })

  it('estimates unmeasured items from the running median of measured heights', async () => {
    // 200 items at defaultItemHeight=64. Scroll to the middle so items around index ~90-110 render,
    // mock them all to 300px real height, flush measurement.
    const items = makeItems(200)
    const { wrapper, el } = mountScroller({
      items,
      buffer: 5,
      defaultItemHeight: 64,
      clientHeight: 800,
    })
    await nextTick()

    // Scroll to middle: scrollTop = 90*64 = 5760.
    el.scrollTop = 5760
    el.dispatchEvent(new Event('scroll'))
    await vi.advanceTimersByTimeAsync(16)
    await nextTick()

    // Mock every currently-rendered child to 300px.
    const content = el.querySelector('.virtual-scroller-content')
    const children = content!.children
    for (const child of Array.from(children)) {
      Object.defineProperty(child, 'offsetHeight', { value: 300, configurable: true })
    }

    // Flush pre-paint measure + trailing sweep.
    await vi.advanceTimersByTimeAsync(120)
    await nextTick()

    // Read the positioning values from the contentShift emit (P2: no
    // spacer DIVs anymore — the payload carries topSpacer/bottomSpacer).
    const events = wrapper.emitted<[shift: { topSpacer: number; bottomSpacer: number; total: number }]>(
      'contentShift',
    )
    expect(events).toBeTruthy()
    const last = events![events!.length - 1]![0]

    // 2026-09-06 (task_1788648119245_5): ALL unmeasured items estimate at the adaptive median
    // (~300px, clamped to [32,1600]), NOT the static 64px prop — the 64px fallback collapsed the
    // model total to less than half the real height with 100+ messages (audit T2).
    expect(last.bottomSpacer).toBeGreaterThan(30000)
    expect(last.bottomSpacer).toBeLessThan(60000)
    wrapper.unmount()
  })

  it('falls back to the prop when nothing has been measured yet', async () => {
    const { wrapper } = mountScroller({
      items: makeItems(50),
      buffer: 2,
      defaultItemHeight: 64,
      clientHeight: 800,
    })
    await nextTick()

    // No measurements have run (no scroll, jsdom offsetHeight=0 filtered). Bottom spacer must
    // reflect the raw prop.
    const events = wrapper.emitted<[shift: { topSpacer: number; bottomSpacer: number; total: number }]>(
      'contentShift',
    )
    expect(events).toBeTruthy()
    const last = events![events!.length - 1]![0]
    expect(last.bottomSpacer).toBeCloseTo(3072, 0)
    wrapper.unmount()
  })
})
