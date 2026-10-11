/**
 * Regression tests for VirtualScroller scroll-anchor compensation.
 *
 * Why this file exists:
 *   The user reported "when chatview have long chat messages, the view
 *   its kind of jumping" — and again, years of commits later, as
 *   "virtual scroller not smooth, feels like jumping … when data is
 *   many with many different height".
 *
 *   The scroller positions its rendered window at MODEL coordinates
 *   (`topSpacer = accumulatedHeights[start]`, estimates + measurements)
 *   while the content inside lays out with REAL heights. CSS scroll
 *   anchoring is disabled (`overflow-anchor: none`, needed for the
 *   older ratcheting bug), so whenever the model changes above the
 *   viewport the scroller must adjust scrollTop itself or the content
 *   under the viewport teleports.
 *
 *   v1 of the compensation summed per-measurement deltas with
 *   `baseline = oldHeight ?? defaultItemHeight`. Two failure modes
 *   survived review until 2026-09-23:
 *
 *     A. WRONG BASELINE — the model does not estimate unmeasured items
 *        with the static prop (64px) but with the adaptive running
 *        MEDIAN (200-600px in real chats). Every first measurement
 *        above the viewport over-compensated by (median − 64) px;
 *        with buffer=30 those errors stacked into thousands of px of
 *        wrong scrollTop while scrolling up through history.
 *
 *     B. UNCOMPENSATED ESTIMATE DRIFT — `observe()` feeds the
 *        estimator INSIDE a pass, so the median can move between
 *        rebuilds; every UNMEASURED item's contribution above the
 *        viewport shifts with it and v1 had no measurement entry for
 *        it (a pure teleport — e.g. the first SSE-driven remeasure).
 *
 *   v2 compensates the ANCHOR's prefix-sum delta
 *   (`newAnchorTop − oldAnchorTop`), which by construction covers
 *   exactly the items strictly above the viewport top — measured or
 *   not — and never the anchor itself. The pure helper
 *   (`virtualScrollerScrollAnchor.ts`) carries the math; integration
 *   tests drive the mounted component end-to-end (mocked offsetHeight,
 *   fake timers) to pin the wiring and the measure cadence.
 */
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

  // ── The at-bottom target ────────────────────────────────────────────────
  //
  // A reader at the bottom is not anchored to anything: they are reading the
  // newest content, and a remeasure pass is exactly what just resized it.
  // These are the numbers from the recorded browser capture that motivated the
  // branch (tests/functional_ui/chatview_at_bottom_stick_ui_test.py,
  // test_a_large_remeasure_does_not_yank_an_at_bottom_reader): a long chat
  // whose window expanded 34 → 66 rows produced a −15,900px prefix delta and
  // dragged the reader that far up, which ChatView read as leaving the bottom
  // and which disarmed the auto-stick for every remaining chunk.

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
    // The helper is not entitled to judge whether the reader is at the bottom —
    // that is the caller's read of the live DOM, and it passes `atBottomTarget`
    // only when the answer was yes. Omitting it must give exactly the
    // pre-existing anchor behaviour, which is what holds a reader 4000px up in
    // the history still while the model above them is corrected.
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
    // THE regression (2026-10-10). This used to assert the opposite — that a
    // `shiftPx === 0` pass writes nothing even at the bottom — and that ordering
    // is what stranded bottom readers mid-stream.
    //
    // Measured in a real browser: EVERY pass of a streaming turn had
    // `shiftPx === 0`, because content grows AT/AFTER the anchor (so the prefix
    // is unchanged) and the rendered window shifts with the anchor index (so the
    // prefix at the anchor is unchanged too). With the bottom branch ordered
    // after the early return, `atBottomTarget` was computed and then discarded,
    // and the only thing re-pinning a bottom reader was ChatView's separate
    // `scrollToBottom()` call. When that lost the race with the measure pass —
    // timing dependent, hence macOS-only — the reader was left where the last
    // successful pin put them while the bottom had moved on.
    //
    // The anchor path exists to hold a scrolled-up reader STILL. A bottom reader
    // has no anchor to hold; they need re-pinning whenever the bottom moved.
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
    // THE guard on the fix above. The first attempt re-pinned whenever the
    // target differed, and it regressed the send-from-history follow: a pass
    // with `shiftPx = 1666` (a batch of rows above the viewport measured for the
    // first time) and `atBottomTarget = 22800` against `prevScrollTop = 22987`
    // wrote a position 187px ABOVE the reader and stranded them 1833px short.
    //
    // `atBottomTarget` is read after the model rebuild but before the DOM
    // re-renders, so when the prefix moved it is derived from a topSpacer and a
    // content height that never existed together. Only a pass that moved nothing
    // above the anchor has a trustworthy target.
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
    // A degenerate short-list case: the whole transcript fits, so the bottom IS
    // the top. `bottomScrollTop()` cannot actually return a negative number
    // (`Math.max(0, …)` on both of its paths), so the target here is 0 rather
    // than the -30 this test used to assert — but the clamp still has to hold,
    // because `Math.max(0, atBottomTarget)` is what keeps a 0 target from
    // becoming a negative scrollTop write.
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
})

// ─── Integration tests (mounted component) ───────────────────────────────────

/**
 * Mount a scroller with N items at the ChatView-like settings
 * (defaultItemHeight 64, buffer 30) and a fixed 800px viewport.
 */
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
  // A static `n * 64` does not move as items are measured, and that breaks any
  // at-bottom predicate reading it: `VirtualScroller.bottomScrollTop()` is
  // `scrollHeight - clientHeight` off the real-bottom override, so a reader
  // deep in a long chat (scrollTop 40000 of a ~102,000px model) would be
  // judged "at the bottom" the moment their scrollTop passed the stale total.
  // Read the sizer so the fixture tracks the height model the way the DOM does.
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

/**
 * Dispatch a scroll event WITHOUT moving the viewport — for "the user
 * keeps scrolling and the position genuinely didn't change" (a real
 * repeated event reports the current, already-compensated position;
 * writing `el.scrollTop` here would manually undo the compensation the
 * test is trying to observe).
 */
function dispatchScroll(el: HTMLElement) {
  el.dispatchEvent(new Event('scroll'))
}

/**
 * Give the rendered children fake offsetHeights: `tallPx` for items
 * above `anchorIndex`, `estimatePx` for the rest. Returns the expected
 * compensation total for the above-anchor set. Pass `onlyIndex` to
 * make exactly ONE above-anchor item tall (the "single long message"
 * case); the rest keep the estimate.
 */
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

    // Simulate the layout settling: every above-anchor buffer item is
    // really 300px tall (markdown paragraph), visible items stay 64px.
    // NOTE: the scroll we just dispatched scheduled measureItems with
    // offsetHeight still 0 everywhere (h>0 filter skips) — flush it first.
    vi.advanceTimersByTime(60)
    const expectedShift = mockChildHeights(el, 100, 300, 64)

    // Next scroll event schedules the measure pass that sees the mocks.
    scroll(el, 6400)
    vi.advanceTimersByTime(60)
    await nextTick()

    // scrollTop must have advanced by exactly Σ(300−64) so the same
    // content remains under the viewport top edge. (The estimator
    // median stays 64 here — the mock heights straddle it — so the
    // prefix delta equals the per-item sum.)
    expect(el.scrollTop).toBe(before + expectedShift)
    wrapper.unmount()
  })

  it('baselines first measurements on the MODEL estimate (median), not defaultItemHeight', async () => {
    // Regression for failure mode A: the model estimates unmeasured
    // items with the adaptive median — once the median has learned
    // 400px, the static 64px prop no longer describes anything. First
    // measurements above the anchor must be compensated against the
    // 400px model contribution (plus the in-pass estimator drift),
    // NOT against 64px.
    const { wrapper, el } = mountScroller(255)
    await nextTick()

    // Phase 1 — teach the estimator a 400px profile. Measure the first
    // window (indices 0..31) at 400px: anchor is 0 so no compensation
    // runs (prefix(0) = 0), stored heights land, median becomes 400,
    // and every unmeasured item now contributes 400px to the model.
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

    // Ground truth for prefix(100) AFTER the pass:
    //   0..42   stored 400 (phase 1 measured the full pre-measure
    //           window — at that point estimates were still the 64px
    //           seed, so the 800px viewport rendered 43 items)  = 17200
    //   43..69  unmeasured, median is now 700                = 18900
    //   70..99  first-measured at 700                         = 21000
    //   total   = 57100, old prefix = 400 × 100 = 40000 → shift 17100.
    // v1 would have computed Σ(700−64) over 70..99 = 19080 — wrong
    // baseline AND blind to the unmeasured drift (43..69).
    expect(el.scrollTop).toBe(57100)
    wrapper.unmount()
  })

  // ── The bottom is not an anchor ────────────────────────────────────────
  //
  // The report: with many messages and a long response the chat stops
  // auto-scrolling to the bottom. Mechanism: the reader is at the bottom, the
  // window expands as the long response grows, a batch of rows above the anchor
  // measures for the first time, the prefix delta runs to thousands of px, and
  // the compensation writes scrollTop that far UP. ChatView reads that write —
  // programmatic or not — as "the user left the bottom", the stick disarms, and
  // every remaining chunk lands off-screen.
  //
  // The reader at the bottom has no view to preserve, so the pass must
  // re-target them at the bottom instead of around the anchor.

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

    // Now the pass that used to strand them: every row above the anchor
    // measures far SHORTER than the 400px the model had reserved, so the
    // prefix above the anchor collapses and the anchor rule would subtract
    // ~15,900px from scrollTop.
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
    // The residual jump (task_1787496087806_6 follow-up): when ONE long
    // message scrolls into the top buffer, Vue renders it in one commit
    // — topSpacer shrinks by the 64px estimate while ~3000px of real
    // content takes its place → content under the viewport shifts
    // immediately at RENDER time. The debounced measureItems only
    // compensates ≤50ms LATER, so the user sees a down-up bounce.
    //
    // Fix contract: a watcher on rendered-range change must run
    // measureItems inside nextTick (pre-paint), so render + compensation
    // land in the SAME frame. This test asserts the correction WITHOUT
    // advancing timers — if compensation needed the 50ms debounce, this
    // fails.
    const { wrapper, el } = mountScroller(255)
    await nextTick()

    scroll(el, 6400) // anchor = item 100
    await nextTick()
    vi.advanceTimersByTime(60) // flush initial measure pass

    // Simulate scrolling UP so a new tall item enters the TOP buffer:
    // move the viewport up by exactly two estimate-slots (128px). The
    // visibleRange recomputes; item 97 renders above the viewport with
    // mocked offsetHeight=3000 (the "one long message"). All other
    // buffer items keep the 64px estimate.
    //
    // The tall item MUST sit strictly above the anchor (97 < 98): the
    // anchor rule compensates only indices strictly above the viewport
    // start — growth at/below the anchor is real content and flows
    // through uncompensated (see 'is a no-op when the prefix is
    // unchanged' above).
    mockChildHeights(el, 100, 3000, 64, 97)
    el.scrollTop = 6400 - 128
    el.dispatchEvent(new Event('scroll'))
    await nextTick() // Vue commits the new window incl. item 97

    // NO vi.advanceTimersByTime here — the correction must already be
    // applied synchronously within the pre-paint tick. Final position =
    // user's own −128px scroll (preserved) + item 97's growth (+2936)
    // (compensated) = 6272 + 2936. The estimator median stays 64
    // (one 3000px sample among ~70×64), so prefix delta = 3000 − 64.
    expect(el.scrollTop).toBe(6400 - 128 + (3000 - 64))
    wrapper.unmount()
  })

  it('keeps measuring during sustained scrolling (trailing timer must not starve)', async () => {
    // Failure mode D: the 50ms measure debounce used to CLEAR+REARM on
    // every scroll event, so while scroll events kept arriving faster
    // than 50ms apart it never fired — all pending corrections then
    // landed in one lump when the gesture stopped (the "scroll, then
    // it jumps" feel). The scheduler must be max-wait: armed once,
    // fired at the deadline regardless of later events.
    const { wrapper, el } = mountScroller(255)
    await nextTick()

    scroll(el, 6400)
    await nextTick()
    vi.advanceTimersByTime(60) // flush pre-paint + debounce passes (h=0 → no-op)
    vi.advanceTimersByTime(50) // consume the mount-time measure timer (unmocked → no-op)

    const expectedShift = mockChildHeights(el, 100, 300, 64) // 30 × 236

    // Sustained scrolling: events every 40ms — always inside the 50ms
    // window, so a reset-per-event scheduler would never fire. Dispatch
    // WITHOUT rewriting scrollTop (see dispatchScroll): the position
    // genuinely did not change, and writing it would manually undo the
    // compensation this test observes.
    dispatchScroll(el)
    vi.advanceTimersByTime(40)
    dispatchScroll(el)
    vi.advanceTimersByTime(40) // past firstEvent+50: the measure must have run

    expect(el.scrollTop).toBe(6400 + expectedShift)
    wrapper.unmount()
  })
})
