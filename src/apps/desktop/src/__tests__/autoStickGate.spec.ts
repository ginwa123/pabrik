import { describe, it, expect } from 'vitest'

import { isAutoStickActive, AUTO_STICK_GATE_MS } from '../helpers/autoStickGate'

describe('isAutoStickActive', () => {
  it('returns false when the user is not at the bottom', () => {
    // Even if the auto-stick just fired, a scrolled-up user is safe to
    // prepend for — the stick isn't engaged, no fight is possible.
    const now = 1_000_000
    expect(isAutoStickActive(now - 10, now, false)).toBe(false)
  })

  it('returns false when lastAutoStickAt is 0 (never fired)', () => {
    // Fresh mount, no auto-stick has run yet — gate is inactive.
    // Important so the very first `loadMore` after mount isn't blocked.
    const now = 1_000_000
    expect(isAutoStickActive(0, now, true)).toBe(false)
  })

  it('returns true when both gates are met (recent + at bottom)', () => {
    const now = 1_000_000
    expect(isAutoStickActive(now - 100, now, true)).toBe(true)
  })

  it('returns true at exactly the boundary minus 1ms', () => {
    // Off-by-one guard: the gate is `<` (strict less-than), so a timestamp
    // exactly AUTO_STICK_GATE_MS in the past is still inside the window.
    const now = 1_000_000
    expect(isAutoStickActive(now - (AUTO_STICK_GATE_MS - 1), now, true)).toBe(true)
  })

  it('returns false at exactly the boundary (the strict-less-than edge)', () => {
    // At the boundary, the timestamp is "old" — gate lifts.
    const now = 1_000_000
    expect(isAutoStickActive(now - AUTO_STICK_GATE_MS, now, true)).toBe(false)
  })

  it('returns false well past the gate window', () => {
    const now = 1_000_000
    expect(isAutoStickActive(now - 5000, now, true)).toBe(false)
  })

  it('treats a future timestamp as still active (clock skew safety)', () => {
    // If the timer fires slightly before Date.now() is read (rare but possible with throttled
    // setTimeout), a negative delta is still "active" — better to over-suppress than to let a
    // prepend fight a stick that's about to fire.
    const now = 1_000_000
    expect(isAutoStickActive(now + 50, now, true)).toBe(true)
  })
})

describe('AUTO_STICK_GATE_MS', () => {
  it('is a positive number exported for log/UX visibility', () => {
    // The threshold is logged in every `load-more-suppressed` line so
    // operators can see what value was active. Must be a real number
    // (not a string or undefined) so it formats correctly.
    expect(typeof AUTO_STICK_GATE_MS).toBe('number')
    expect(AUTO_STICK_GATE_MS).toBeGreaterThan(0)
  })

  it('is at least 100ms (shorter would over-suppress during slow streams)', () => {
    // Floor: anything <100ms would re-suppress on every animation frame
    // even when the model isn't actively emitting, defeating the
    // "let the user read history" purpose.
    expect(AUTO_STICK_GATE_MS).toBeGreaterThanOrEqual(100)
  })

  it('is at most 5s (longer would over-suppress after a chunk ends)', () => {
    // Ceiling: anything >5s would keep loadMore blocked long after the
    // LLM has finished a single chunk, making pagination feel broken.
    expect(AUTO_STICK_GATE_MS).toBeLessThanOrEqual(5_000)
  })
})
