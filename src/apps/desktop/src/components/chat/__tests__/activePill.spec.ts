import { describe, it, expect } from 'vitest'
import { pickActivePillIndex, isPillGroup, estimateViewportEnd } from '../activePill'

const pills = [{ groupIndex: 0 }, { groupIndex: 3 }, { groupIndex: 7 }]

describe('pickActivePillIndex', () => {
  it('returns null above the first user message', () => {
    // rangeStart is an assistant/tool group before any user pill
    expect(pickActivePillIndex(pills.slice(1), 1)).toBe(null)
  })

  it('activates the pill at the bound index', () => {
    expect(pickActivePillIndex(pills, 0)).toBe(0)
    expect(pickActivePillIndex(pills, 3)).toBe(3)
  })

  it('sticks to the last passed pill while scrolling between pills', () => {
    expect(pickActivePillIndex(pills, 1)).toBe(0)
    expect(pickActivePillIndex(pills, 5)).toBe(3)
    expect(pickActivePillIndex(pills, 9)).toBe(7)
  })

  it('returns null for an empty rail', () => {
    expect(pickActivePillIndex([], 5)).toBe(null)
  })
})

describe('estimateViewportEnd', () => {
  it('returns end when the window reaches the list end (clamped, no overscan below)', () => {
    // At the bottom: rendered [60, 100] of 100 — viewport bottom IS 100.
    expect(estimateViewportEnd(60, 100, 100, 30)).toBe(100)
  })

  it('subtracts the buffer mid-list (overscan below the fold)', () => {
    // Rendered [10, 80] of 100 with buffer 30 — viewport bottom ≈ 50.
    expect(estimateViewportEnd(10, 80, 100, 30)).toBe(50)
  })

  it('never goes below start on tiny windows', () => {
    expect(estimateViewportEnd(0, 5, 100, 30)).toBe(0)
  })

  it('short chats (window renders from 0 to end) anchor at the end, not 0', () => {
    // THE reported bug: 8 groups all rendered [0, 8] — the old
    // range.start anchor lit pill 0 at the bottom; the compensated
    // anchor lights the last pill.
    const visEnd = estimateViewportEnd(0, 8, 8, 30)
    expect(pickActivePillIndex(pills, visEnd)).toBe(7)
  })
})

describe('isPillGroup', () => {
  it('keeps real user turns', () => {
    expect(isPillGroup('user', false)).toBe(true)
  })

  it('skips compaction envelopes', () => {
    expect(isPillGroup('user', true)).toBe(false)
  })

  it('skips non-user roles', () => {
    expect(isPillGroup('assistant', false)).toBe(false)
    expect(isPillGroup('tool', false)).toBe(false)
  })
})
