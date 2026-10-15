/**  * Unit tests for `formatCompactTokens` (helpers/formatCompact.ts) — the compact number readout used
 * by the ChatView V1 composer toolbar's token status (`82,679 → 82.7k`). Exact numbers stay in the
 * tooltip; this only covers the shortened display form. */
import { describe, expect, it } from 'vitest'
import { formatCompactTokens } from '@/helpers/formatCompact'

describe('formatCompactTokens', () => {
  it('passes values under 1,000 through unchanged', () => {
    expect(formatCompactTokens(0)).toBe('0')
    expect(formatCompactTokens(42)).toBe('42')
    expect(formatCompactTokens(999)).toBe('999')
  })

  it('formats thousands with one decimal below 100k', () => {
    expect(formatCompactTokens(1000)).toBe('1k')
    expect(formatCompactTokens(82679)).toBe('82.7k')
    expect(formatCompactTokens(99999)).toBe('100k')
  })

  it('formats thousands as integers at/above 100k', () => {
    expect(formatCompactTokens(100000)).toBe('100k')
    expect(formatCompactTokens(900000)).toBe('900k')
  })

  it('formats millions', () => {
    expect(formatCompactTokens(1500000)).toBe('1.5M')
    expect(formatCompactTokens(200000000)).toBe('200M')
  })
})
