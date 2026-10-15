/**
 * Tail-gap cap (task_1790236655228_2) — "the gap is too long".
 *
 * The sizer height is a MODEL number (Σ measured/estimated row heights).
 * Unmeasured rows are estimated from the running median of the measured
 * ones, so a tail of short rows inherits a tall median and the model can
 * reserve thousands of px of empty sizer BELOW the real content. The user
 * screenshot: `virtual-scroller-sizer 26796px`, `content translate3d(0,
 * 23406px)`, `min-height 708px` → ~2682px of scrollable blank below the
 * last row.
 *
 * Contract under test: while the rendered window covers the LAST item, the
 * sizer must never exceed (measured content bottom + maxTailGap); and the
 * cap must lift once the window is away from the tail so rows appended
 * below can still be reached.
 *
 * jsdom has no layout, so child heights are mocked (the same idiom the
 * other virtualScroller specs use). Rows left at the jsdom default height
 * of 0 model the real failure mode: a row the scroller cannot measure, so
 * the model keeps its (median) estimate for it forever.
 */
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { mount, type ComponentMountingOptions } from '@vue/test-utils'
import { nextTick } from 'vue'
import VirtualScroller from '../VirtualScroller.vue'

type Item = { id: string }

const BUFFER = 30
const N = 120
const CONTENT = '.virtual-scroller-content'

function mkItems(n = N): Item[] {
  return Array.from({ length: n }, (_, i) => ({ id: `item-${i}` }))
}

function mountScroller(opts?: { n?: number; maxTailGap?: number }) {
  const n = opts?.n ?? N
  const props: NonNullable<ComponentMountingOptions<typeof VirtualScroller>['props']> = {
    items: mkItems(n),
    buffer: BUFFER,
    defaultItemHeight: 64,
    totalCount: n,
    itemKey: (item: unknown) => (item as Item).id,
  }
  if (opts?.maxTailGap !== undefined) props.maxTailGap = opts.maxTailGap
  const wrapper = mount(VirtualScroller, { props })
  const el = wrapper.element as HTMLElement
  Object.defineProperty(el, 'clientHeight', { value: 800, configurable: true })
  Object.defineProperty(el, 'scrollHeight', { value: 100000, configurable: true })
  return { wrapper, el }
}

function contentEl(el: HTMLElement): HTMLElement {
  const c = el.querySelector(CONTENT) as HTMLElement | null
  if (!c) throw new Error('content box not found')
  return c
}

function sizerTotal(el: HTMLElement): number {
  const sizer = el.querySelector('.virtual-scroller-sizer') as HTMLElement | null
  if (!sizer) throw new Error('sizer not found')
  return parseFloat(sizer.style.height) || 0
}

function modelTotalOf(wrapper: { vm: unknown }): number {
  return (wrapper.vm as unknown as { modelTotal: number }).modelTotal
}

function tailBottomOf(wrapper: { vm: unknown }): number {
  return (wrapper.vm as unknown as { tailContentBottom: number }).tailContentBottom
}

function scroll(el: HTMLElement, top: number): void {
  el.scrollTop = top
  el.dispatchEvent(new Event('scroll'))
}

/** Mock the currently rendered rows: `heightFor(dataVsIndex) | null` → skip. */
function mockChildren(el: HTMLElement, heightFor: (index: number) => number | null): number {
  let sum = 0
  for (const child of Array.from(contentEl(el).children)) {
    const idx = Number((child as HTMLElement).getAttribute('data-vs-index'))
    const h = heightFor(idx)
    if (h === null) continue
    Object.defineProperty(child, 'offsetHeight', { value: h, configurable: true })
    sum += h
  }
  return sum
}

function renderedIndices(el: HTMLElement): number[] {
  return Array.from(contentEl(el).children).map((c) =>
    Number((c as HTMLElement).getAttribute('data-vs-index')),
  )
}

/** The invariant the cap guarantees: the sizer never reserves more room
 * below the MEASURED content bottom than `maxTailGap`. */
function expectCapHolds(el: HTMLElement, gap = 100, slack = 2): void {
  const sizer = sizerTotal(el)
  const content = contentEl(el)
  const m = /translate3d\(0px,\s*([-\d.]+)px/.exec(content.style.transform || '')
  const topSpacer = m?.[1] !== undefined ? parseFloat(m[1]) : NaN
  const childrenSum = Array.from(content.children).reduce(
    (acc, c) => acc + ((c as HTMLElement).offsetHeight || 0),
    0,
  )
  const measuredBottom = topSpacer + childrenSum
  expect(sizer).toBeLessThanOrEqual(measuredBottom + gap + slack)
}

describe('VirtualScroller tail-gap cap', () => {
  beforeEach(() => {
    vi.useFakeTimers()
  })
  afterEach(() => {
    vi.useRealTimers()
  })

  /** Build the reported state: a tall median learned from the top window,
   * then a tail whose rows the DOM cannot measure (height 0) — so the
   * model keeps the median estimate for every one of them. */
  async function mountOvershootingTail(maxTailGap?: number) {
    const mounted = mountScroller(maxTailGap === undefined ? undefined : { maxTailGap })
    const { wrapper, el } = mounted
    await nextTick()

    // Learn a tall median (400px) from the first window.
    mockChildren(el, () => 400)
    scroll(el, 0)
    vi.advanceTimersByTime(150)
    await nextTick()
    expect(modelTotalOf(wrapper)).toBe(N * 400)

    // Jump to the tail: rows past the viewport keep the 400px estimate,
    // most of them unmeasurable (height 0) — the phantom region.
    scroll(el, 1e7)
    await nextTick()
    const tailIndices = renderedIndices(el)
    const lastTwo = new Set(tailIndices.slice(-2))
    mockChildren(el, (idx) => (lastTwo.has(idx) ? 400 : 0))
    vi.advanceTimersByTime(150)
    await nextTick()

    return { wrapper, el }
  }

  it('caps the sizer at the measured content bottom + maxTailGap', async () => {
    const { wrapper, el } = await mountOvershootingTail()

    const modelTotal = modelTotalOf(wrapper)
    const bottom = tailBottomOf(wrapper)
    const sizer = sizerTotal(el)

    // The model still reserves the full (over-)estimate…
    expect(modelTotal).toBe(N * 400)
    // …but the rendered sizer must stop `maxTailGap` past the measured
    // bottom of the rows actually in the DOM.
    expect(bottom).toBeGreaterThan(0)
    expect(sizer).toBe(bottom + 100)
    expect(sizer).toBeLessThan(modelTotal)
    expectCapHolds(el)
    wrapper.unmount()
  })

  it('honours a custom maxTailGap', async () => {
    const { wrapper, el } = await mountOvershootingTail(120)
    expect(sizerTotal(el)).toBe(tailBottomOf(wrapper) + 120)
    expectCapHolds(el, 120)
    wrapper.unmount()
  })

  it('maxTailGap=0 disables the cap (sizer stays the model total)', async () => {
    const { wrapper, el } = await mountOvershootingTail(0)
    expect(sizerTotal(el)).toBe(modelTotalOf(wrapper))
    wrapper.unmount()
  })

  it('lifts the cap when the window moves away from the tail', async () => {
    const { wrapper, el } = await mountOvershootingTail()
    expect(sizerTotal(el)).toBeLessThan(modelTotalOf(wrapper))

    // Scroll back into history: `end < items.length - buffer` → the cap
    // releases, so rows appended below stay reachable.
    scroll(el, 1000)
    vi.advanceTimersByTime(150)
    await nextTick()
    expect(renderedIndices(el).at(-1)).toBeLessThan(N - 1)
    expect(sizerTotal(el)).toBe(modelTotalOf(wrapper))
    wrapper.unmount()
  })

  it('re-records the measured bottom when the rendered window shifts', async () => {
    const { wrapper, el } = await mountOvershootingTail()
    const before = tailBottomOf(wrapper)

    // Same tail window, now measurable: the recorded bottom must describe
    // the rows on screen NOW (measured bottom == window top + real rows),
    // not the previously recorded window (the PR #355 staleness bug).
    mockChildren(el, () => 200)
    vi.advanceTimersByTime(150)
    await nextTick()

    const content = contentEl(el)
    const m = /translate3d\(0px,\s*([-\d.]+)px/.exec(content.style.transform || '')
    const topSpacer = m?.[1] !== undefined ? parseFloat(m[1]) : 0
    const childrenSum = Array.from(content.children).reduce(
      (acc, c) => acc + ((c as HTMLElement).offsetHeight || 0),
      0,
    )
    expect(tailBottomOf(wrapper)).toBe(topSpacer + childrenSum)
    expect(tailBottomOf(wrapper)).not.toBe(before)
    expect(sizerTotal(el)).toBe(Math.min(modelTotalOf(wrapper), tailBottomOf(wrapper) + 100))
    wrapper.unmount()
  })

  it('keeps the last measured bottom when the window has no layout (fail-open)', async () => {
    const { wrapper, el } = await mountOvershootingTail()
    const before = tailBottomOf(wrapper)

    // A window in which nothing has laid out (height 0 everywhere) tells
    // us nothing about the real bottom: keep the previous measurement
    // instead of collapsing the sizer to the window top + maxTailGap.
    mockChildren(el, () => 0)
    vi.advanceTimersByTime(150)
    await nextTick()

    expect(tailBottomOf(wrapper)).toBe(before)
    expect(sizerTotal(el)).toBe(before + 100)
    wrapper.unmount()
  })

  it('never inflates the sizer above the model total', async () => {
    const { wrapper, el } = await mountOvershootingTail()
    // Rows taller than the model estimate cannot push the sizer past the
    // model: the cap is a min(), so the bounce/blow-up failure mode that
    // forced the PR #355 clamp out is impossible.
    mockChildren(el, () => 4000)
    vi.advanceTimersByTime(150)
    await nextTick()
    expect(sizerTotal(el)).toBeLessThanOrEqual(modelTotalOf(wrapper))
    wrapper.unmount()
  })
})
