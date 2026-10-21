import { describe, expect, it } from 'vitest'
import { computeSnapDelta } from '../useSnapGuides'

describe('computeSnapDelta', () => {
  const elements = [
    { id: 'a', x: 100, y: 100, width: 200, height: 100 },
    { id: 'b', x: 400, y: 100, width: 100, height: 100 },
  ]

  it('snaps left edge to another element\'s left edge', () => {
    // Drag element A from (100, 100) to (105, 100) — within 6px of
    // its own start position. No snap target within 6px on left.
    const result = computeSnapDelta(elements, 'a', 5, 0)
    expect(result.dx).toBe(0)  // already aligned to start
    expect(result.guides).toEqual([])
  })

  it('snaps right edge of moving element to left edge of nearby element', () => {
    // Element A's right edge starts at x=300. Element B's left edge
    // is at x=400. To snap A's right edge onto B's left edge, dx = 100.
    const result = computeSnapDelta(elements, 'a', 105, 0)
    expect(result.dx).toBe(100)
    expect(result.guides).toContainEqual({ axis: 'x', position: 400 })
  })

  it('snaps center H of moving element to center H of nearby element', () => {
    // Element A's center H starts at x=200. Element B's center H is
    // at x=450. To align, dx = 250.
    const result = computeSnapDelta(elements, 'a', 252, 0)
    expect(result.dx).toBe(250)
    expect(result.guides).toContainEqual({ axis: 'x', position: 450 })
  })

  it('does NOT snap to canvas center when no other element is nearby (canvas background removed)', () => {
    // The canvas-background feature was removed.
    const elementsNoNearby = [
      { id: 'a', x: 100, y: 100, width: 200, height: 100 },
    ]
    const result = computeSnapDelta(elementsNoNearby, 'a', 0, 0)
    expect(result.dx).toBe(0)
    expect(result.dy).toBe(0)
    expect(result.guides).toEqual([])
  })

  it('returns no snap when moving element is far from all targets', () => {
    const result = computeSnapDelta(elements, 'a', 50, 50)
    expect(result.dx).toBe(50)
    expect(result.dy).toBe(50)
    expect(result.guides).toEqual([])
  })

  it('applies 6px threshold — snap fires only when within 6 design-px of target', () => {
    // Element A right edge starts at x=300. Element B left edge at x=400.
    // dx = 95 → A's right edge ends up at x=395 (5px from B's left).
    // dx = 89 → A's right edge at x=389 (11px from B's left). NO snap.
    const snap1 = computeSnapDelta(elements, 'a', 95, 0)
    expect(snap1.dx).toBe(100)  // snapped
    const snap2 = computeSnapDelta(elements, 'a', 89, 0)
    expect(snap2.dx).toBe(89)   // not snapped
  })
})
