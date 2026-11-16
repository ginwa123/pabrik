import { describe, it, expect } from 'vitest'
import { computeLoadMoreThreshold } from '../virtualScrollerThreshold'

describe('computeLoadMoreThreshold', () => {
  it('uses the proportional value when it exceeds the absolute floor (normal viewport)', () => {
    // 1000px viewport, 0.5 ratio → 500px proportional, floor 200px → 500px wins
    expect(computeLoadMoreThreshold(200, 0.5, 1000)).toBe(500)
  })

  it('scales up on large viewports (1500px → 750px)', () => {
    // 1500 * 0.5 = 750, floor 200 → 750 wins
    expect(computeLoadMoreThreshold(200, 0.5, 1500)).toBe(750)
  })

  it('falls back to the floor on tiny viewports (300px < 200 / 0.5)', () => {
    // 300 * 0.5 = 150, floor 200 → 200 wins (the floor protects small viewports)
    expect(computeLoadMoreThreshold(200, 0.5, 300)).toBe(200)
  })

  it('falls back to the floor on a 0×0 container (initial-mount flicker)', () => {
    // Real DOM event: the container reads 0×0 for one frame after mount.
    expect(computeLoadMoreThreshold(200, 0.5, 0)).toBe(200)
  })

  it('falls back to the floor when containerHeight is NaN', () => {
    expect(computeLoadMoreThreshold(200, 0.5, Number.NaN)).toBe(200)
  })

  it('falls back to the floor when containerHeight is negative', () => {
    // Defensive: a stale or malformed DOM read should never produce a negative threshold.
    expect(computeLoadMoreThreshold(200, 0.5, -100)).toBe(200)
  })

  it('falls back to the floor when the ratio is 0 (prop disabled)', () => {
    // A consumer can pass 0 to opt out of the proportional mode entirely.
    expect(computeLoadMoreThreshold(200, 0, 1000)).toBe(200)
  })

  it('falls back to the floor when the ratio is NaN', () => {
    expect(computeLoadMoreThreshold(200, Number.NaN, 1000)).toBe(200)
  })

  it('honors a custom absolute floor (e.g. 400px)', () => {
    // A consumer raising the floor for slow APIs should still get the proportional bonus layered on top.
    expect(computeLoadMoreThreshold(400, 0.5, 1000)).toBe(500) // max(400, 500)
    expect(computeLoadMoreThreshold(400, 0.5, 300)).toBe(400)  // max(400, 150)
  })

  it('uses a defensive default of 200px when the floor itself is NaN', () => {
    // A malformed prop value must not produce NaN downstream.
    expect(computeLoadMoreThreshold(Number.NaN, 0.5, 1000)).toBe(500)
  })
})
