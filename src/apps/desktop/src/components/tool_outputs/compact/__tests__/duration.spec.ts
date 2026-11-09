import { describe, it, expect } from 'vitest'
import { formatDuration } from '../duration'

describe('a run duration reads in the unit a human uses', () => {
  it('keeps milliseconds under a second', () => {
    expect(formatDuration(0)).toBe('0ms')
    expect(formatDuration(840)).toBe('840ms')
    expect(formatDuration(999)).toBe('999ms')
  })

  it('keeps tenths of a second under a minute', () => {
    expect(formatDuration(1000)).toBe('1.0s')
    expect(formatDuration(12_400)).toBe('12.4s')
    expect(formatDuration(59_400)).toBe('59.4s')
  })

  it('switches to minutes and seconds at exactly one minute', () => {
    expect(formatDuration(60_000)).toBe('1m 0s')
    expect(formatDuration(164_400)).toBe('2m 44s')
  })

  it('reads the report’s 3217.1s run as 53m 37s', () => {
    expect(formatDuration(3_217_100)).toBe('53m 37s')
  })

  it('switches to hours and minutes at exactly one hour', () => {
    expect(formatDuration(3_600_000)).toBe('1h 0m')
    expect(formatDuration(3_930_000)).toBe('1h 5m')
  })
})
