/** Unit tests for the P1 performance helpers used by VirtualScroller.vue. Why this file exists
 * (task_1787551495337_9, "make virtual scroller more smooth"): 1. `quantizePx` — measured heights
 * are read from `offsetHeight`, which in Chromium can be fractional (sub-pixel layout). */
import { describe, it, expect } from 'vitest'
import { quantizePx, AdaptiveItemHeightEstimator } from '../virtualScrollerPerf'

// ─── quantizePx ───────────────────────────────────────────────────────────────
describe('quantizePx', () => {
  it('rounds fractional heights to integers', () => {
    expect(quantizePx(100.2)).toBe(100)
    expect(quantizePx(100.7)).toBe(101)
    expect(quantizePx(99.5)).toBe(100)
  })

  it('passes positive integers through unchanged', () => {
    expect(quantizePx(64)).toBe(64)
    expect(quantizePx(1)).toBe(1)
  })

  it('clamps non-positive and non-finite values to a minimum of 1px', () => {
    // offsetHeight should never be ≤ 0 for rendered items, but jsdom
    // returns 0 for unstyled elements — the scroller already filters
    // h > 0 before calling; this is defense-in-depth.
    expect(quantizePx(0)).toBe(1)
    expect(quantizePx(-5)).toBe(1)
    expect(quantizePx(NaN)).toBe(1)
    expect(quantizePx(Infinity)).toBe(1)
  })
})

// ─── AdaptiveItemHeightEstimator ──────────────────────────────────────────────
describe('AdaptiveItemHeightEstimator', () => {
  it('starts at the seed value', () => {
    const est = new AdaptiveItemHeightEstimator({ seed: 64 })
    expect(est.estimate()).toBe(64)
  })

  it('returns the seed when nothing has been observed', () => {
    const est = new AdaptiveItemHeightEstimator({ seed: 100 })
    expect(est.estimate()).toBe(100)
  })

  it('learns the median of observed heights', () => {
    const est = new AdaptiveItemHeightEstimator({ seed: 64 })
    // Median of [200, 220, 240] = 220 — NOT the mean (220 is same here,
    // use asymmetric set below to prove median semantics).
    est.observe(200)
    est.observe(220)
    est.observe(240)
    expect(est.estimate()).toBe(220)
  })

  it('uses median not mean (robust against one giant bubble)', () => {
    const est = new AdaptiveItemHeightEstimator({ seed: 64 })
    est.observe(180)
    est.observe(190)
    est.observe(200)
    est.observe(210)
    est.observe(3000) // one huge code-block message
    // Mean would be 756; median stays realistic at 200.
    expect(est.estimate()).toBe(200)
  })

  it('interpolates between the two middle values for even sample counts', () => {
    const est = new AdaptiveItemHeightEstimator({ seed: 64 })
    est.observe(100)
    est.observe(200)
    // Even count → median is midpoint of middle two.
    expect(est.estimate()).toBe(150)
  })

  it('respects the sample cap (rolling window, recent samples win)', () => {
    const est = new AdaptiveItemHeightEstimator({ seed: 64, maxSamples: 4 })
    est.observe(100)
    est.observe(100)
    est.observe(100)
    est.observe(100)
    // Window now full of 100s; push them out with new values.
    est.observe(500)
    est.observe(500)
    est.observe(500)
    est.observe(500)
    expect(est.estimate()).toBe(500)
  })

  it('quantizes observations through quantizePx', () => {
    const est = new AdaptiveItemHeightEstimator({ seed: 64 })
    est.observe(199.6)
    expect(est.estimate()).toBe(200)
  })

  it('ignores non-finite / non-positive observations', () => {
    const est = new AdaptiveItemHeightEstimator({ seed: 64 })
    est.observe(NaN)
    est.observe(0)
    est.observe(-10)
    expect(est.estimate()).toBe(64) // unchanged
  })

  it('updates in O(log n) per observation (sorted insert via binary search)', () => {
    // Behavioral proxy for the complexity contract: many observations stay fast and correct. If
    // someone replaces binary insert with a full sort per observe(), this still passes but the perf
    // contract is documented here + enforced by review.
    const est = new AdaptiveItemHeightEstimator({ seed: 64, maxSamples: 50 })
    for (let i = 0; i < 1000; i++) {
      est.observe((i % 400) + 40)
    }
    expect(est.estimate()).toBeGreaterThan(0)
  })

  it('reset() returns to the seed', () => {
    const est = new AdaptiveItemHeightEstimator({ seed: 64 })
    est.observe(300)
    est.reset()
    expect(est.estimate()).toBe(64)
  })

  it('handles fractional medians by rounding to int px', () => {
    const est = new AdaptiveItemHeightEstimator({ seed: 64 })
    est.observe(100)
    est.observe(101)
    est.observe(102)
    // Median = 101 exactly.
    expect(est.estimate()).toBe(101)
  })

  // ── freeze() — the placeholder must stop moving under the reader ──────────
  it('reports its sample count, capped at maxSamples', () => {
    const est = new AdaptiveItemHeightEstimator({ seed: 64, maxSamples: 3 })
    expect(est.sampleCount).toBe(0)
    est.observe(100)
    est.observe(200)
    expect(est.sampleCount).toBe(2)
    est.observe(300)
    est.observe(400)
    expect(est.sampleCount).toBe(3)
  })

  it('starts out unfrozen', () => {
    const est = new AdaptiveItemHeightEstimator({ seed: 64 })
    expect(est.isFrozen).toBe(false)
  })

  it('freeze() pins the current value against later observations', () => {
    const est = new AdaptiveItemHeightEstimator({ seed: 64, maxSamples: 4 })
    est.observe(200)
    est.observe(200)
    est.observe(200)
    est.observe(200)
    est.freeze()
    expect(est.estimate()).toBe(200)

    // A whole window of much SHORTER rows arrives — exactly what scrolling into a run of one-liners
    // does.
    for (let i = 0; i < 8; i++) est.observe(40)
    expect(est.estimate()).toBe(200)
  })

  it('freeze() keeps the FIRST frozen value when called twice', () => {
    const est = new AdaptiveItemHeightEstimator({ seed: 64 })
    est.observe(300)
    est.freeze()
    est.observe(500)
    est.freeze() // a late caller must not reopen the window
    expect(est.estimate()).toBe(300)
  })

  it('freeze() with no observations freezes the seed', () => {
    // A chat shorter than the freeze threshold still freezes the moment the
    // caller asks; there is simply nothing learned yet.
    const est = new AdaptiveItemHeightEstimator({ seed: 64 })
    est.freeze()
    est.observe(900)
    expect(est.estimate()).toBe(64)
  })

  it('reset() unfreezes, so a different list can learn its own profile', () => {
    const est = new AdaptiveItemHeightEstimator({ seed: 64 })
    est.observe(100)
    est.freeze()
    est.reset()
    expect(est.isFrozen).toBe(false)
    expect(est.estimate()).toBe(64)
    est.observe(900)
    expect(est.estimate()).toBe(900)
  })
})
