/**
 * P1 performance helpers for VirtualScroller.vue
 * (task_1787551495337_9, "make virtual scroller more smooth").
 *
 * Pure functions/classes only — no DOM, no Vue imports — so every branch
 * is unit-testable without mounting (same convention as
 * virtualScrollerScrollAnchor.ts / virtualScrollerThreshold.ts).
 */

/**
 * Round a measured height to an integer pixel value ≥ 1.
 *
 * WHY: `offsetHeight` in Chromium can be fractional under sub-pixel
 * layout. Fractional stored heights re-quantize differently between our
 * prefix sums and the browser's own layout, producing ±1px spacer drift
 * that shows up as micro-jitter while scrolling. Integers make the
 * hysteresis dead-band (`HYSTERESIS_PX`) exact and the accumulated
 * heights stable across frames.
 *
 * Non-finite / non-positive inputs collapse to 1 (defense-in-depth —
 * the scroller already filters `h > 0` before measuring, but jsdom and
 * detached nodes can still hand back 0/NaN).
 */
export function quantizePx(value: number): number {
  if (!Number.isFinite(value) || value <= 0) return 1
  return Math.round(value)
}

/**
 * Running-median estimator for unmeasured item heights.
 *
 * WHY: ChatView passes a fixed `defaultItemHeight=64`, but real chat
 * bubbles are almost always taller (200–3000px). Every unmeasured item
 * is estimated at 64px, so spacers are systematically short until
 * measured and every measurement pass triggers anchor compensation.
 * Learning the running MEDIAN of measured heights gives far better
 * estimates for never-measured items → fewer wrong spacers → fewer
 * compensation shifts → smoother scroll.
 *
 * Median (not mean) so one giant code-block message can't skew the
 * estimate for everyone.
 *
 * Complexity: `observe()` is O(log n) search + O(n) splice where
 * n ≤ maxSamples (a small constant, default 64) — effectively O(1) per
 * call. `estimate()` is O(1).
 *
 * ── `freeze()` — why a moving estimate is dangerous (2026-10-12) ──────────
 *
 * The estimate is not a private detail of this class: the scroller multiplies
 * it by the number of items that have NEVER been rendered, because those items
 * have no measured height and take this value instead. So a 1px move here moves
 * the whole list's height model by `unmeasuredCount` px.
 *
 * That is fine while the reader is at the bottom, and it is a scroll-jump
 * machine while they are not. Measured on a 600-message chat, scrolling up
 * 100px at a time during an SSE stream (probe:
 * tests/functional_ui/chatview_stream_scroll_stability_ui_test.py):
 *
 *     pass #18: oldAnchorTop 116536 -> newAnchorTop 138771   (+22,235)
 *
 * Nothing was measured in that pass above the anchor — 561 never-rendered
 * items were simply re-estimated 41px higher, because the window had moved and
 * this estimator had sampled the rows that came with it. The scroller's anchor
 * compensation faithfully turned that rescale into a `scrollTop` write of
 * 138,880px, the browser clamped it against the sizer that had not re-rendered
 * yet, the reader was teleported, and the next pass computed −38,808 to undo it.
 * The user sees that as the transcript jumping up and down mid-stream.
 *
 * `freeze()` stops it at the source: `estimate()` keeps returning the value it
 * had at freeze time, so a placeholder can no longer move under a reader who is
 * looking at the rows above it. Accuracy is not lost — a rendered row is
 * MEASURED, and measurements always win (`itemHeights` on the scroller side) —
 * only the guess about rows the reader has not reached yet stops moving.
 */
export class AdaptiveItemHeightEstimator {
  /** Sorted sample store (ascending px). */
  private samples: number[] = []
  /** Observation-order FIFO — tracks which sample is oldest for eviction. */
  private order: number[] = []
  private readonly seed: number
  private readonly maxSamples: number
  /** Set by `freeze()`; `null` while the estimate is still allowed to move. */
  private frozen: number | null = null

  constructor(options?: { seed?: number; maxSamples?: number }) {
    const s = options?.seed
    this.seed = Number.isFinite(s) && (s as number) > 0 ? Math.round(s as number) : 100
    const m = options?.maxSamples
    this.maxSamples = Number.isFinite(m) && (m as number) > 0 ? Math.floor(m as number) : 64
  }

  /** Record one real measured height. Invalid values (non-finite,
   * non-positive) are ignored silently — callers already filter most of
   * these; double-filtering keeps the sample set clean regardless. */
  observe(heightPx: number): void {
    if (!Number.isFinite(heightPx) || heightPx <= 0) return
    const h = quantizePx(heightPx)

    // Binary search for insertion point (leftmost position where h fits).
    let lo = 0
    let hi = this.samples.length
    while (lo < hi) {
      const mid = (lo + hi) >> 1
      if ((this.samples[mid] ?? 0) < h) lo = mid + 1
      else hi = mid
    }
    this.samples.splice(lo, 0, h)
    this.order.push(h)

    // Rolling window: evict the OLDEST observation when over capacity.
    if (this.order.length > this.maxSamples) {
      const oldest = this.order.shift()
      if (oldest !== undefined) {
        const idx = this.samples.indexOf(oldest)
        if (idx !== -1) this.samples.splice(idx, 1)
      }
    }
  }

  /**
   * How many observations are currently held (0..`maxSamples`). Used by the
   * scroller to decide when the estimate is well-founded enough to freeze —
   * freezing the moment the window is full means the frozen value IS the live
   * median at that instant, so freezing itself moves nothing.
   */
  get sampleCount(): number {
    return this.samples.length
  }

  /** True once `freeze()` has been called and `reset()` has not. */
  get isFrozen(): boolean {
    return this.frozen !== null
  }

  /**
   * Stop `estimate()` from moving. The current value is kept forever (until
   * `reset()`), even as `observe()` keeps recording samples.
   *
   * Call this once the estimate is well-founded — see the class docstring for
   * the scroll jump a moving placeholder causes. Idempotent: freezing twice
   * keeps the FIRST frozen value, so a late caller cannot reopen the window.
   */
  freeze(): void {
    if (this.frozen !== null) return
    this.frozen = this.estimate()
  }

  /** Current best guess for an unmeasured item's height (integer px). */
  estimate(): number {
    if (this.frozen !== null) return this.frozen
    const n = this.samples.length
    if (n === 0) return this.seed
    const mid = n >> 1
    if (n % 2 === 1) return this.samples[mid] ?? this.seed
    const a = this.samples[mid - 1] ?? this.seed
    const b = this.samples[mid] ?? a
    return Math.round((a + b) / 2)
  }

  /** Forget everything — back to the seed (e.g. on items list swap). Also
   * unfreezes: a different list is a different height profile, and it must be
   * free to learn one before it freezes again. */
  reset(): void {
    this.samples = []
    this.order = []
    this.frozen = null
  }
}
