import { describe, it, expect } from 'vitest'
import { formatElapsedDuration, isWorkerStale, WORKER_STALE_SECONDS } from './elapsedDuration'

describe('formatElapsedDuration', () => {
  it('renders seconds below a minute', () => {
    expect(formatElapsedDuration(0)).toBe('0s')
    expect(formatElapsedDuration(999)).toBe('0s')
    expect(formatElapsedDuration(42_000)).toBe('42s')
    expect(formatElapsedDuration(59_000)).toBe('59s')
  })

  it('renders minutes with zero-padded seconds', () => {
    expect(formatElapsedDuration(60_000)).toBe('1m 00s')
    expect(formatElapsedDuration(252_000)).toBe('4m 12s')
    expect(formatElapsedDuration(3_599_000)).toBe('59m 59s')
  })

  it('renders hours with zero-padded minutes', () => {
    expect(formatElapsedDuration(3_600_000)).toBe('1h 00m')
    expect(formatElapsedDuration(3_840_000)).toBe('1h 04m')
    expect(formatElapsedDuration(86_399_000)).toBe('23h 59m')
  })

  it('renders days past 24 hours', () => {
    expect(formatElapsedDuration(86_400_000)).toBe('1d 00h')
    expect(formatElapsedDuration(194_400_000)).toBe('2d 06h')
  })

  it('returns empty for non-finite or negative input', () => {
    // Clock skew between the backend stamp and the browser clock is the realistic source; an empty chip is the honest rendering.
    expect(formatElapsedDuration(-1)).toBe('')
    expect(formatElapsedDuration(Number.NaN)).toBe('')
    expect(formatElapsedDuration(Number.POSITIVE_INFINITY)).toBe('')
  })

  it('matches the buckets SpawnSubAgent.vue already renders for sub-agents', () => {
    // The private formatElapsed there produced "12s" and "1m 03s"; the shared helper must not drift from what users already see.
    expect(formatElapsedDuration(12_000)).toBe('12s')
    expect(formatElapsedDuration(63_000)).toBe('1m 03s')
  })
})

describe('isWorkerStale', () => {
  const now = 1_800_000_000_000

  it('is false for a fresh heartbeat', () => {
    expect(isWorkerStale(now - 1_000, now)).toBe(false)
    expect(isWorkerStale(now - WORKER_STALE_SECONDS * 1000 + 1, now)).toBe(false)
  })

  it('is true at exactly the threshold', () => {
    expect(isWorkerStale(now - WORKER_STALE_SECONDS * 1000, now)).toBe(true)
  })

  it('is true well past the threshold', () => {
    expect(isWorkerStale(now - 600_000, now)).toBe(true)
  })

  it('sits below the 600s stale-worker cron reap', () => {
    // The UI must warn BEFORE the backend deletes the row, otherwise the amber state is never observable.
    expect(WORKER_STALE_SECONDS).toBeLessThan(600)
  })

  it('is false for non-finite input rather than throwing', () => {
    expect(isWorkerStale(Number.NaN, now)).toBe(false)
    expect(isWorkerStale(now, Number.NaN)).toBe(false)
  })
})
