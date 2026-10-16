/** Regression tests for VirtualScroller scroll-anchor compensation. */
import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { mount } from '@vue/test-utils'
import { nextTick } from 'vue'
import VirtualScroller from '../VirtualScroller.vue'
import { computeAnchorCompensation } from '../virtualScrollerScrollAnchor'

// ─── Pure helper tests ────────────────────────────────────────────────────────
describe('computeAnchorCompensation', () => {
  const base = {
    anchorIndex: 50,
    prevScrollTop: 3200, // model prefix at the anchor before the pass
  }

  it('shifts scrollTop by the anchor prefix delta (content above grew)', () => {
    // Everything strictly above index 50 grew 640px in the model —
    // real-height writes and estimate refreshes alike.
    const result = computeAnchorCompensation({
      ...base,
      oldAnchorTop: 3200,
      newAnchorTop: 3200 + 640,
    })
    expect(result.shiftPx).toBe(640)
    expect(result.newScrollTop).toBe(3840)
    expect(result.clamped).toBe(false)
  })

  it('shifts scrollTop down when content above shrank', () => {
    const result = computeAnchorCompensation({
      ...base,
      oldAnchorTop: 3200,
      newAnchorTop: 2880,
    })
    expect(result.shiftPx).toBe(-320)
    expect(result.newScrollTop).toBe(2880)
    expect(result.clamped).toBe(false)
  })

  it('is a no-op when the prefix is unchanged (writes at/below the anchor)', () => {
    // Height changes AT or AFTER the anchor never appear in
    // prefix(anchor) — visible-window growth must flow through
    // uncompensated. Exercised by passing identical tops.
    const result = computeAnchorCompensation({
      ...base,
      oldAnchorTop: 3200,
      newAnchorTop: 3200,
    })
    expect(result.shiftPx).toBe(0)
    expect(result.newScrollTop).toBe(3200)
    expect(result.clamped).toBe(false)
  })

  it('clamps at zero when the correction would go negative', () => {
    const result = computeAnchorCompensation({
      ...base,
      anchorIndex: 5,
      prevScrollTop: 100,
      oldAnchorTop: 6400,
      newAnchorTop: 5910, // −490
    })
    expect(result.shiftPx).toBe(-490)
    expect(result.clamped).toBe(true)
    expect(result.newScrollTop).toBe(0)
  })

  it('handles negative anchorIndex (empty/unmounted list) as no-op', () => {
    const result = computeAnchorCompensation({
      ...base,
      anchorIndex: -1,
      oldAnchorTop: 0,
      newAnchorTop: 900,
    })
    expect(result.shiftPx).toBe(0)
    expect(result.newScrollTop).toBe(base.prevScrollTop)
    expect(result.clamped).toBe(false)
  })

  it('treats non-finite tops as a no-op (defensive)', () => {
    const result = computeAnchorCompensation({
      ...base,
      oldAnchorTop: Number.NaN,
      newAnchorTop: 4000,
    })
    expect(result.shiftPx).toBe(0)
    expect(result.newScrollTop).toBe(base.prevScrollTop)
  })

  // ── The at-bottom target ──────────────────────────────────────────────── A reader at the bottom
  // is not anchored to anything: they are reading the newest content, and a remeasure pass is
  // exactly what just resized it.
  it('targets the bottom, not the anchor, when the reader was at the bottom', () => {
    const result = computeAnchorCompensation({
      ...base,
      // The reader was parked at the bottom: scrollTop 96000.
      prevScrollTop: 96000,
      oldAnchorTop: 96000,
      newAnchorTop: 96000 - 15900, // the model above the anchor shrank
      atBottomTarget: 96868, // the bottom edge AFTER the pass
    })
    expect(result.target).toBe('bottom')
    // The model delta is still reported — it was absorbed, not ignored.
    expect(result.shiftPx).toBe(-15900)
    // …but the reader is left ON the bottom, not 15,900px above it. The
    // anchor rule would have written 80100 here.
    expect(result.newScrollTop).toBe(96868)
    expect(result.clamped).toBe(false)
  })

  it('keeps the reader on the bottom when the model above the anchor GREW', () => {
    const result = computeAnchorCompensation({
      ...base,
      prevScrollTop: 96000,
      oldAnchorTop: 96000,
      newAnchorTop: 96000 + 2400,
      atBottomTarget: 98400,
    })
    expect(result.target).toBe('bottom')
    expect(result.shiftPx).toBe(2400)
    expect(result.newScrollTop).toBe(98400)
  })

  it('still uses the anchor when no bottom target is passed', () => {
    // The helper is not entitled to judge whether the reader is at the bottom — that is the
    // caller's read of the live DOM, and it passes `atBottomTarget` only when the answer was yes.
    const result = computeAnchorCompensation({
      ...base,
      prevScrollTop: 5000,
      oldAnchorTop: 5000,
      newAnchorTop: 4400,
    })
    expect(result.target).toBe('anchor')
    expect(result.shiftPx).toBe(-600)
    expect(result.newScrollTop).toBe(4400)
  })

  it('omitting atBottomTarget keeps the pre-existing anchor behaviour', () => {
    // Guards the "we changed the default" failure mode: every caller that does
    // not opt in must get exactly what it got before the branch existed.
    const result = computeAnchorCompensation({
      ...base,
      oldAnchorTop: 3200,
      newAnchorTop: 3840,
    })
    expect(result.target).toBe('anchor')
    expect(result.newScrollTop).toBe(3840)
  })

  it('a no-op prefix delta still re-pins a bottom reader whose bottom moved', () => {
    // THE regression (2026-10-10). This used to assert the opposite — that a `shiftPx === 0` pass
    // writes nothing even at the bottom — and that ordering is what stranded bottom readers
    // mid-stream.
    const result = computeAnchorCompensation({
      ...base,
      prevScrollTop: 96000,
      oldAnchorTop: 96000,
      newAnchorTop: 96000,
      atBottomTarget: 96868,
    })
    expect(result.shiftPx).toBe(0)
    expect(result.newScrollTop).toBe(96868)
    expect(result.target).toBe('bottom')
  })

  it('a no-op prefix delta writes nothing when the bottom has not moved either', () => {
    // The cost guard: a settled bottom reader must not be nudged. Without it
    // every measure pass would write scrollTop, re-firing the scroll event and
    // re-running the whole decision — the blinking-loop shape.
    const result = computeAnchorCompensation({
      ...base,
      prevScrollTop: 96000,
      oldAnchorTop: 96000,
      newAnchorTop: 96000,
      atBottomTarget: 96000,
    })
    expect(result.shiftPx).toBe(0)
    expect(result.newScrollTop).toBe(96000)
    expect(result.target).toBe('anchor')
  })

  it('a moved prefix keeps the compensation path — the re-pin must not fire', () => {
    // THE guard on the fix above.
    const result = computeAnchorCompensation({
      ...base,
      prevScrollTop: 22987,
      oldAnchorTop: 21321,
      newAnchorTop: 22987,
      atBottomTarget: 22800,
    })
    expect(result.shiftPx).toBe(1666)
    // Compensated around the anchor, NOT re-pinned to the (stale) bottom.
    expect(result.target).toBe('anchor')
    expect(result.newScrollTop).toBe(22987 + 1666)
  })

  it('a scrolled-up reader is still never re-pinned by a no-op pass', () => {
    // The other half of the contract: no `atBottomTarget` means the caller says
    // the reader is not at the bottom, so the anchor behaviour is untouched.
    const result = computeAnchorCompensation({
      ...base,
      prevScrollTop: 40000,
      oldAnchorTop: 40000,
      newAnchorTop: 40000,
    })
    expect(result.shiftPx).toBe(0)
    expect(result.newScrollTop).toBe(40000)
    expect(result.target).toBe('anchor')
  })

  it('clamps a bottom target at 0 rather than scrolling above the top', () => {
    // A degenerate short-list case: the whole transcript fits, so the bottom IS the top.
    const result = computeAnchorCompensation({
      ...base,
      prevScrollTop: 0,
      oldAnchorTop: 0,
      newAnchorTop: 0,
      atBottomTarget: 0,
    })
    expect(result.target).toBe('anchor')
    expect(result.newScrollTop).toBe(0)
  })

  it('never writes a negative scrollTop even if a caller passes a negative target', () => {
    // Belt-and-braces on the same clamp, exercised through the path that does
    // reach `Math.max(0, …)`: a target below 0 with a reader already at 0.
    const result = computeAnchorCompensation({
      ...base,
      prevScrollTop: 0,
      oldAnchorTop: 0,
      newAnchorTop: 500,
      atBottomTarget: 0,
    })
    expect(result.newScrollTop).toBeGreaterThanOrEqual(0)
  })

  // ── maxScrollTop: bound the target to the range the DOM can reach ───────── `measureItems`
  // rebuilds the model and writes scrollTop in ONE synchronous pass, while the sizer is a `:style`
  // binding Vue applies on its next render.
  it('cuts a target that exceeds the reachable range and says so', () => {
    const result = computeAnchorCompensation({
      ...base,
      prevScrollTop: 90_000,
      oldAnchorTop: 90_000,
      newAnchorTop: 112_235,
      maxScrollTop: 120_074,
    })
    expect(result.shiftPx).toBe(22_235)
    expect(result.newScrollTop).toBe(112_235) // 90_000 + 22_235, inside the range
    expect(result.clampedToMax).toBe(false)

    const beyond = computeAnchorCompensation({
      ...base,
      prevScrollTop: 116_645,
      oldAnchorTop: 116_536,
      newAnchorTop: 138_771,
      maxScrollTop: 120_074,
    })
    expect(beyond.shiftPx).toBe(22_235)
    expect(beyond.newScrollTop).toBe(120_074)
    expect(beyond.clampedToMax).toBe(true)
  })

  it('leaves the target alone when no bound is supplied', () => {
    const result = computeAnchorCompensation({
      ...base,
      prevScrollTop: 100,
      oldAnchorTop: 100,
      newAnchorTop: 200,
    })
    expect(result.newScrollTop).toBe(200)
    expect(result.clampedToMax).toBe(false)
  })

  it('bounds the at-bottom re-pin too, and reports which rule was used', () => {
    const result = computeAnchorCompensation({
      ...base,
      prevScrollTop: 100,
      oldAnchorTop: 100,
      newAnchorTop: 100,
      atBottomTarget: 5000,
      maxScrollTop: 1200,
    })
    expect(result.target).toBe('bottom')
    expect(result.newScrollTop).toBe(1200)
    expect(result.clampedToMax).toBe(true)
  })

  it('treats a non-finite bound as unbounded and a negative one as 0', () => {
    const unbounded = computeAnchorCompensation({
      ...base,
      prevScrollTop: 100,
      oldAnchorTop: 100,
      newAnchorTop: 900,
      maxScrollTop: NaN,
    })
    expect(unbounded.newScrollTop).toBe(900)
    expect(unbounded.clampedToMax).toBe(false)

    const zero = computeAnchorCompensation({
      ...base,
      prevScrollTop: 100,
      oldAnchorTop: 100,
      newAnchorTop: 900,
      maxScrollTop: -50,
    })
    expect(zero.newScrollTop).toBe(0)
    expect(zero.clampedToMax).toBe(true)
  })

  it('does not flag a bound when the target already sits on it', () => {
    const result = computeAnchorCompensation({
      ...base,
      prevScrollTop: 100,
      oldAnchorTop: 100,
      newAnchorTop: 900,
      maxScrollTop: 900,
    })
    expect(result.newScrollTop).toBe(900)
    expect(result.clampedToMax).toBe(false)
  })
})

// ─── Integration tests (mounted component) ───────────────────────────────────
/** Mount a scroller with N items at the ChatView-like settings
 * (defaultItemHeight 64, buffer 30) and a fixed 800px viewport. */
function mountScroller(n: number) {
  const items = Array.from({ length: n }, (_, i) => ({ id: i }))
  const wrapper = mount(VirtualScroller, {
    props: {
      items,
      buffer: 30,
      defaultItemHeight: 64,
      totalCount: n,
      loadMoreAtTop: true,
    },
  })
  const el = wrapper.element as HTMLElement
  Object.defineProperty(el, 'clientHeight', { value: 800, configurable: true })
  // In a real browser the container's `scrollHeight` IS the sizer's height.
  const sizer = el.querySelector('.virtual-scroller-sizer') as HTMLElement | null
  Object.defineProperty(el, 'scrollHeight', {
    configurable: true,
    get(): number {
      const modelled = sizer ? Number.parseFloat(sizer.style.height) : 0
      return modelled > 0 ? modelled : n * 64
    },
  })
  return { wrapper, el }
}

/** Dispatch a scroll event; onScroll reads el.scrollTop synchronously. */
function scroll(el: HTMLElement, top: number) {
  el.scrollTop = top
  el.dispatchEvent(new Event('scroll'))
}

/** Dispatch a scroll event WITHOUT moving the viewport — for "the user keeps scrolling and the
 * position genuinely didn't change" (a real repeated event reports the current, already-compensated
 * position. */
function dispatchScroll(el: HTMLElement) {
  el.dispatchEvent(new Event('scroll'))
}

/** Give the rendered children fake offsetHeights: `tallPx` for items above `anchorIndex`,
 * `estimatePx` for the rest. Returns the expected compensation total for the above-anchor set. */
function mockChildHeights(
  el: HTMLElement,
  anchorIndex: number,
  tallPx: number,
  estimatePx: number,
  onlyIndex?: number,
): number {
  const content = el.querySelector('.virtual-scroller-content')
  if (!content) throw new Error('.virtual-scroller-content not found')
  let expectedShift = 0
  for (const child of Array.from(content.children)) {
    const idx = Number((child as HTMLElement).getAttribute('data-vs-index'))
    const isAbove = idx < anchorIndex
    const h = isAbove && (onlyIndex === undefined || idx === onlyIndex) ? tallPx : estimatePx
    Object.defineProperty(child, 'offsetHeight', { value: h, configurable: true })
    if (isAbove && h !== estimatePx) expectedShift += h - estimatePx
  }
  return expectedShift
}

/** Mock EVERY rendered child to one height. */
function mockAllChildren(el: HTMLElement, h: number) {
  const content = el.querySelector('.virtual-scroller-content')
  if (!content) throw new Error('.virtual-scroller-content not found')
  for (const child of Array.from(content.children)) {
    Object.defineProperty(child, 'offsetHeight', { value: h, configurable: true })
  }
}

describe('VirtualScroller measurement anchor compensation', () => {
  beforeEach(() => {
    vi.useFakeTimers()
  })
  afterEach(() => {
    vi.useRealTimers()
  })

  it('keeps content stationary when items above the viewport are measured taller', async () => {
    const { wrapper, el } = mountScroller(255)
    await nextTick()

    // Scroll to the middle: 100 items × 64px = 6400. With all-equal
    // estimates, findStartIndex() → 100.
    scroll(el, 6400)
    await nextTick()
    const before = el.scrollTop

    // Simulate the layout settling: every above-anchor buffer item is really 300px tall (markdown
    // paragraph), visible items stay 64px. NOTE: the scroll we just dispatched scheduled
    // measureItems with offsetHeight still 0 everywhere (h>0 filter skips) — flush it first.
    vi.advanceTimersByTime(60)
    const expectedShift = mockChildHeights(el, 100, 300, 64)

    // Next scroll event schedules the measure pass that sees the mocks.
    scroll(el, 6400)
    vi.advanceTimersByTime(60)
    await nextTick()

    // scrollTop must have advanced by exactly Σ(300−64) so the same content remains under the
    // viewport top edge. (The estimator median stays 64 here — the mock heights straddle it — so
    // the prefix delta equals the per-item sum.)
    expect(el.scrollTop).toBe(before + expectedShift)
    wrapper.unmount()
  })

  it('baselines first measurements on the MODEL estimate (median), not defaultItemHeight', async () => {
    // Regression for failure mode A: the model estimates unmeasured items with the adaptive median
    // — once the median has learned 400px, the static 64px prop no longer describes anything.
    const { wrapper, el } = mountScroller(255)
    await nextTick()

    // Phase 1 — teach the estimator a 400px profile. Measure the first window (indices 0..31) at
    // 400px: anchor is 0 so no compensation runs (prefix(0) = 0), stored heights land, median
    // becomes 400, and every unmeasured item now contributes 400px to the model.
    scroll(el, 0)
    await nextTick()
    vi.advanceTimersByTime(60) // flush pre-debounce measure (offsetHeight 0 → no-op)
    mockAllChildren(el, 400)
    scroll(el, 0)
    vi.advanceTimersByTime(60) // phase-1 measure pass
    await nextTick()
    expect(el.scrollTop).toBe(0)

    // Phase 2 — jump into virgin history: scrollTop 40000 → anchor 100
    // (uniform 400px model), buffer window 70..131. Render first, then
    // mock the fresh children to 700px, then arm the measure pass.
    scroll(el, 40000)
    await nextTick() // render + pre-paint measure (fresh children: h=0 → no-op)
    vi.advanceTimersByTime(60) // trailing debounce (still h=0 → no-op)
    mockAllChildren(el, 700)
    scroll(el, 40000)
    vi.advanceTimersByTime(60)
    await nextTick()

    // Ground truth for prefix(100) AFTER the pass: 0..42   stored 400 (phase 1 measured the full
    // pre-measure window.
    expect(el.scrollTop).toBe(57100)
    wrapper.unmount()
  })

  // ── The bottom is not an anchor ──────────────────────────────────────── The report: with many
  // messages and a long response the chat stops auto-scrolling to the bottom.
  it('keeps a reader AT THE BOTTOM on the bottom when the model above the anchor shifts', async () => {
    const { wrapper, el } = mountScroller(255)
    const vm = wrapper.vm as unknown as {
      bottomScrollTop: () => number
      remeasure: () => void
    }
    await nextTick()

    // Teach the estimator a 400px profile so the model is realistically tall
    // (~102,000px) and a prefix correction is measured in thousands of px —
    // the scale the bug needs. Phase 1 measures the first window at 400px.
    scroll(el, 0)
    await nextTick()
    vi.advanceTimersByTime(60)
    mockAllChildren(el, 400)
    scroll(el, 0)
    vi.advanceTimersByTime(60)
    await nextTick()

    // Park the reader on the app's own bottom (the same number
    // `scrollToBottom` writes and ChatView's `isAtBottom` is measured
    // against), and let the settle land.
    const bottom = vm.bottomScrollTop()
    scroll(el, bottom)
    await nextTick()
    vi.advanceTimersByTime(60)
    await nextTick()
    expect(el.scrollTop).toBe(bottom)
    expect(bottom).toBeGreaterThan(50000) // precondition: a long chat

    // Now the pass that used to strand them: every row above the anchor measures far SHORTER than
    // the 400px the model had reserved, so the prefix above the anchor collapses and the anchor
    // rule would subtract ~15,900px from scrollTop.
    mockAllChildren(el, 100)
    scroll(el, bottom)
    vi.advanceTimersByTime(60)
    await nextTick()

    const after = el.scrollTop
    const nowBottom = vm.bottomScrollTop()
    console.log(
      `[at-bottom-anchor] bottom=${bottom} after=${after} nowBottom=${nowBottom} delta=${
        nowBottom - after
      }`,
    )
    expect(nowBottom - after).toBeLessThanOrEqual(10)
    wrapper.unmount()
  })

  it('still compensates around the anchor for a reader in the history', async () => {
    // The other half, and the reason the anchor pass exists: the new branch
    // must not make a reader 40,000px up drift when the model above them is
    // corrected. Same setup, opposite position.
    const { wrapper, el } = mountScroller(255)
    await nextTick()

    scroll(el, 0)
    await nextTick()
    vi.advanceTimersByTime(60)
    mockAllChildren(el, 400)
    scroll(el, 0)
    vi.advanceTimersByTime(60)
    await nextTick()

    // Deep in the history, far from the bottom.
    scroll(el, 40000)
    await nextTick()
    vi.advanceTimersByTime(60)
    mockAllChildren(el, 400)
    scroll(el, 40000)
    vi.advanceTimersByTime(60)
    await nextTick()
    const before = el.scrollTop

    // Rows above the anchor get shorter; the reader must ride the correction
    // rather than jump.
    mockAllChildren(el, 250)
    scroll(el, before)
    vi.advanceTimersByTime(60)
    await nextTick()

    console.log(`[history-anchor] before=${before} after=${el.scrollTop}`)
    // They moved (the model above them shrank) but stayed nowhere near the
    // bottom — which is the whole point: the anchor rule owns this reader.
    expect(el.scrollTop).toBeLessThan(before)
    expect(el.scrollTop).toBeLessThan(40000)
    wrapper.unmount()
  })

  it('does NOT compensate while a preserve window is active', async () => {
    const { wrapper, el } = mountScroller(255)
    await nextTick()

    scroll(el, 6400)
    await nextTick()
    vi.advanceTimersByTime(60)

    // Open a preserve window (as handleLoadMore does around a prepend).
    const vm = wrapper.vm as unknown as {
      beginPreserve: (n: number) => void
      isPreservingScroll: boolean
    }
    vm.beginPreserve(1)
    expect(vm.isPreservingScroll).toBe(true)

    const before = el.scrollTop
    mockChildHeights(el, 100, 300, 64)
    scroll(el, 6400)
    vi.advanceTimersByTime(60)
    await nextTick()

    // Heights were recorded (model updated) but scrollTop untouched —
    // endPreserve owns scroll restoration during prepends.
    expect(el.scrollTop).toBe(before)
    wrapper.unmount()
  })

  it('corrects a tall item rendering above the viewport PRE-PAINT (no timer advance)', async () => {
    // The residual jump (task_1787496087806_6 follow-up): when ONE long message scrolls into the
    // top buffer, Vue renders it in one commit.
    const { wrapper, el } = mountScroller(255)
    await nextTick()

    scroll(el, 6400) // anchor = item 100
    await nextTick()
    vi.advanceTimersByTime(60) // flush initial measure pass

    // Simulate scrolling UP so a new tall item enters the TOP buffer: move the viewport up by
    // exactly two estimate-slots (128px). The visibleRange recomputes; item 97 renders above the
    // viewport with mocked offsetHeight=3000 (the "one long message").
    mockChildHeights(el, 100, 3000, 64, 97)
    el.scrollTop = 6400 - 128
    el.dispatchEvent(new Event('scroll'))
    await nextTick() // Vue commits the new window incl. item 97

    // NO vi.advanceTimersByTime here — the correction must already be applied synchronously within
    // the pre-paint tick. Final position = user's own −128px scroll (preserved) + item 97's growth
    // (+2936) (compensated) = 6272 + 2936.
    expect(el.scrollTop).toBe(6400 - 128 + (3000 - 64))
    wrapper.unmount()
  })

  it('keeps measuring during sustained scrolling (trailing timer must not starve)', async () => {
    // Failure mode D: the 50ms measure debounce used to CLEAR+REARM on every scroll event, so while
    // scroll events kept arriving faster than 50ms apart it never fired — all pending corrections
    // then landed in one lump when the gesture stopped (the "scroll, then it jumps" feel).
    const { wrapper, el } = mountScroller(255)
    await nextTick()

    scroll(el, 6400)
    await nextTick()
    vi.advanceTimersByTime(60) // flush pre-paint + debounce passes (h=0 → no-op)
    vi.advanceTimersByTime(50) // consume the mount-time measure timer (unmocked → no-op)

    const expectedShift = mockChildHeights(el, 100, 300, 64) // 30 × 236

    // Sustained scrolling: events every 40ms — always inside the 50ms window, so a reset-per-event
    // scheduler would never fire.
    dispatchScroll(el)
    vi.advanceTimersByTime(40)
    dispatchScroll(el)
    vi.advanceTimersByTime(40) // past firstEvent+50: the measure must have run

    expect(el.scrollTop).toBe(6400 + expectedShift)
    wrapper.unmount()
  })
})
