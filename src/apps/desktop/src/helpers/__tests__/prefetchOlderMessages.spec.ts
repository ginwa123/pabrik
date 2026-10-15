/** Unit tests for the older-history prefetch decision (task_1789505423062_0). Pure-function
 * coverage only — no DOM, no Vue. */
/** The wire-level proof that the prefetch actually fires before the scroll reaches the top lives in
 * the functional UI test (`tests/functional_ui/chatview_lazy_prefetch_ui_test.py`), and the
 * ChatView wiring is pinned by `ChatView.lazyPrefetch.spec.ts`. */

import { describe, it, expect } from 'vitest'
import {
  ARM_RADIUS_FLOOR_PX,
  ARM_RADIUS_RATIO,
  FETCH_SAMPLE_MAX_MS,
  FETCH_SAMPLE_MIN_MS,
  PREFETCH_SAMPLE_INIT_MS,
  armRadiusPx,
  decidePrefetchOlder,
  nextFetchEstimate,
  type PrefetchInput,
} from '../prefetchOlderMessages'
import { computeLoadMoreThreshold } from '../virtualScrollerThreshold'

/** A decision input that arms on the margin, so each test overrides one field. */
function input(overrides: Partial<PrefetchInput> = {}): PrefetchInput {
  return {
    distanceFromTop: 900,
    armRadiusPx: armRadiusPx(900), // 1350
    hasMore: true,
    isLoading: false,
    isCommitting: false,
    isPrefetching: false,
    hasBufferedPage: false,
    isPreservingScroll: false,
    sessionId: 'sess-1',
    backoffActive: false,
    ...overrides,
  }
}

describe('armRadiusPx', () => {
  it('uses the proportional radius on a normal viewport (1.5 × 900 = 1350)', () => {
    expect(armRadiusPx(900)).toBe(1350)
  })

  it('uses the absolute floor on a small viewport (1.5 × 300 = 450 < 800)', () => {
    expect(armRadiusPx(300)).toBe(ARM_RADIUS_FLOOR_PX)
  })

  it('falls back to the floor on a 0×0 container (initial-mount flicker)', () => {
    expect(armRadiusPx(0)).toBe(ARM_RADIUS_FLOOR_PX)
  })

  it('falls back to the floor when containerHeight is NaN or negative', () => {
    expect(armRadiusPx(Number.NaN)).toBe(ARM_RADIUS_FLOOR_PX)
    expect(armRadiusPx(-100)).toBe(ARM_RADIUS_FLOOR_PX)
  })

  it('is always strictly larger than the VirtualScroller commit band', () => {
    // The core invariant of the design: the arm fires BEFORE the band the
    // scroller commits in, at every viewport height. If this ever fails, the
    // buffered page cannot be ready in time and the prefetch is pointless.
    for (const h of [0, 100, 200, 400, 800, 1440, 3000]) {
      const commitBand = computeLoadMoreThreshold(200, 0.5, h)
      expect(armRadiusPx(h)).toBeGreaterThan(commitBand)
    }
  })

  it('hard-codes the ratio above the scroller commit ratio', () => {
    // ARM_RADIUS_RATIO must stay > loadMoreThresholdRatio (0.5) so the
    // proportional term cannot invert the invariant above.
    expect(ARM_RADIUS_RATIO).toBeGreaterThan(0.5)
  })
})

describe('nextFetchEstimate', () => {
  it('blends from the cold-start estimate when the previous value is unusable', () => {
    // prev unusable → the cold-start estimate stands in for prev, then the
    // sample is blended in: 220 × 0.6 + 200 × 0.4 = 212.
    expect(nextFetchEstimate(0, 200)).toBeCloseTo(PREFETCH_SAMPLE_INIT_MS * 0.6 + 200 * 0.4, 5)
    expect(nextFetchEstimate(Number.NaN, 200)).toBeCloseTo(
      PREFETCH_SAMPLE_INIT_MS * 0.6 + 200 * 0.4,
      5,
    )
  })

  it('moves toward a measured sample (EMA)', () => {
    // prev 220, sample 120, alpha 0.4 → 220*0.6 + 120*0.4 = 180
    expect(nextFetchEstimate(220, 120)).toBeCloseTo(180, 5)
  })

  it('ignores non-finite and non-positive measurements', () => {
    expect(nextFetchEstimate(220, Number.NaN)).toBe(220)
    expect(nextFetchEstimate(220, 0)).toBe(220)
    expect(nextFetchEstimate(220, -5)).toBe(220)
  })

  it('clamps a single sample to [FETCH_SAMPLE_MIN_MS, FETCH_SAMPLE_MAX_MS]', () => {
    // A 5 ms sample (cached/localhost) must not collapse the estimate.
    const fast = nextFetchEstimate(220, 5)
    expect(fast).toBeCloseTo(220 * 0.6 + FETCH_SAMPLE_MIN_MS * 0.4, 5)
    // A 10 s sample (cold DB) must not balloon it.
    const slow = nextFetchEstimate(220, 10_000)
    expect(slow).toBeCloseTo(220 * 0.6 + FETCH_SAMPLE_MAX_MS * 0.4, 5)
  })
})

describe('decidePrefetchOlder — margin trigger', () => {
  it('arms when the user is inside the arm radius', () => {
    const d = decidePrefetchOlder(input({ distanceFromTop: 900 }))
    expect(d.arm).toBe(true)
    expect(d.trigger).toBe('margin')
    expect(d.reachPx).toBe(1350)
    expect(d.skip).toBeUndefined()
  })

  it('arms exactly at the radius (inclusive boundary)', () => {
    const d = decidePrefetchOlder(input({ distanceFromTop: 1350 }))
    expect(d.arm).toBe(true)
  })

  it('does not arm one pixel past the radius', () => {
    const d = decidePrefetchOlder(input({ distanceFromTop: 1351 }))
    expect(d.arm).toBe(false)
    expect(d.skip).toBe('not-close-enough')
  })

  it('arms on a non-scrollable-sized viewport via the absolute floor', () => {
    const d = decidePrefetchOlder({
      ...input(),
      armRadiusPx: armRadiusPx(300),
      distanceFromTop: 700,
    })
    expect(d.arm).toBe(true)
    expect(d.trigger).toBe('margin')
  })

  it('treats a NaN distance as 0 (already at the top → still arms)', () => {
    const d = decidePrefetchOlder(input({ distanceFromTop: Number.NaN }))
    expect(d.arm).toBe(true)
  })
})

describe('decidePrefetchOlder — terminal skips', () => {
  const cases: Array<[string, Partial<PrefetchInput>, string]> = [
    ['no session', { sessionId: null }, 'no-session'],
    ['no more messages', { hasMore: false }, 'no-more-messages'],
    ['page already buffered', { hasBufferedPage: true }, 'already-buffered'],
    ['arm already in flight', { isPrefetching: true }, 'already-fetching'],
    ['initial load in flight', { isLoading: true }, 'initial-load'],
    ['commit in flight', { isCommitting: true }, 'committing'],
    ['scroller mid-preserve', { isPreservingScroll: true }, 'preserving'],
    ['backoff window open', { backoffActive: true }, 'backoff'],
  ]

  for (const [name, override, expected] of cases) {
    it(`skips with '${expected}' when ${name}`, () => {
      const d = decidePrefetchOlder(input(override))
      expect(d.arm).toBe(false)
      expect(d.skip).toBe(expected)
      expect(d.trigger).toBe('none')
    })
  }

  it('prioritises no-session over every other condition', () => {
    const d = decidePrefetchOlder(
      input({ sessionId: null, hasMore: false, hasBufferedPage: true, isLoading: true }),
    )
    expect(d.skip).toBe('no-session')
  })

  it('prioritises no-more-messages over an in-flight arm', () => {
    const d = decidePrefetchOlder(input({ hasMore: false, isPrefetching: true }))
    expect(d.skip).toBe('no-more-messages')
  })

  it('never arms while a commit is in flight, even inside the radius', () => {
    const d = decidePrefetchOlder(input({ distanceFromTop: 0, isCommitting: true }))
    expect(d.arm).toBe(false)
  })
})

describe('decidePrefetchOlder — velocity term (Phase 2 hook, disabled in v1)', () => {
  it('is inert when velocity/estimate are absent (v1 passes neither)', () => {
    const d = decidePrefetchOlder(input({ distanceFromTop: 900 }))
    expect(d.trigger).toBe('margin')
    expect(d.timeToTopMs).toBe(Infinity)
  })

  it('arms from beyond the margin when travel time beats the fetch budget', () => {
    // 10 px/ms (very fast fling), 2000 px from the top → 200 ms to arrive;
    // the fetch budget is 220 + 80 = 300 ms. 2000 px is BEYOND the margin
    // (1350), so only the velocity term can arm here.
    const d = decidePrefetchOlder(
      input({
        distanceFromTop: 2000,
        velocityPxPerMs: 10,
        estimatedFetchMs: 220,
        safetyMs: 80,
      }),
    )
    expect(d.arm).toBe(true)
    expect(d.trigger).toBe('velocity')
    expect(d.reachPx).toBe(3000) // 10 × (220 + 80)
    expect(d.timeToTopMs).toBeCloseTo(200, 5)
  })

  it('does not arm on velocity alone when travel time exceeds the budget', () => {
    // 3 px/ms, 2000 px from the top → 667 ms to arrive; the fetch budget is
    // 300 ms. The user has plenty of time, and 2000 > margin → no arm.
    const d = decidePrefetchOlder(
      input({
        distanceFromTop: 2000,
        velocityPxPerMs: 3,
        estimatedFetchMs: 220,
        safetyMs: 80,
      }),
    )
    expect(d.arm).toBe(false)
    expect(d.skip).toBe('not-close-enough')
  })

  it('ignores a negative or non-finite velocity', () => {
    const d = decidePrefetchOlder(
      input({ distanceFromTop: 5000, velocityPxPerMs: -3, estimatedFetchMs: 220, safetyMs: 80 }),
    )
    expect(d.arm).toBe(false)
    const nan = decidePrefetchOlder(
      input({
        distanceFromTop: 5000,
        velocityPxPerMs: Number.NaN,
        estimatedFetchMs: 220,
        safetyMs: 80,
      }),
    )
    expect(nan.arm).toBe(false)
  })

  it('falls through to the margin when the velocity term says no', () => {
    const d = decidePrefetchOlder(
      input({ distanceFromTop: 1200, velocityPxPerMs: 0.01, estimatedFetchMs: 220, safetyMs: 80 }),
    )
    expect(d.arm).toBe(true)
    expect(d.trigger).toBe('margin')
  })
})
