/** Conflict-flag tests for the shared PR-status cache.
 * Contract: `fetchPrConflictCached` is true only for CONFLICTING/DIRTY —
 * quiet (false) for mergeable, unknown, or failed fetches. The string
 * contract of `fetchPrStatusCached` is unchanged (backward-compat). */
import { describe, expect, it, beforeEach, afterEach, vi } from 'vitest'
import { ApiError } from '@/api'
import {
  fetchPrStatusCached,
  fetchPrStatusFullCached,
  fetchPrConflictCached,
  isPrConflictValue,
  clearPrStatusCache,
} from '../prStatusCache'

const { getPrStatusMock } = vi.hoisted(() => ({
  getPrStatusMock: vi.fn(),
}))

vi.mock('@/api', async () => {
  const actual = await vi.importActual<typeof import('@/api')>('@/api')
  return {
    ...actual,
    getPrStatus: getPrStatusMock,
  }
})

describe('prStatusCache conflict flag', () => {
  beforeEach(() => {
    clearPrStatusCache()
    vi.clearAllMocks()
    vi.spyOn(console, 'warn').mockImplementation(() => {})
  })

  afterEach(() => {
    vi.restoreAllMocks()
    vi.useRealTimers()
  })

  it('isPrConflictValue is true for CONFLICTING (any case)', () => {
    expect(isPrConflictValue('CONFLICTING', '')).toBe(true)
    expect(isPrConflictValue('conflicting', 'dirty')).toBe(true)
  })

  it('isPrConflictValue is true for DIRTY merge_state', () => {
    expect(isPrConflictValue('', 'DIRTY')).toBe(true)
    expect(isPrConflictValue('UNKNOWN', 'DIRTY')).toBe(true)
  })

  it('isPrConflictValue is false for mergeable/unknown/empty', () => {
    expect(isPrConflictValue('MERGEABLE', 'CLEAN')).toBe(false)
    expect(isPrConflictValue('UNKNOWN', 'UNKNOWN')).toBe(false)
    expect(isPrConflictValue('', '')).toBe(false)
  })

  it('fetchPrConflictCached resolves true when the PR conflicts', async () => {
    getPrStatusMock.mockResolvedValue({
      status: 'open',
      state: 'OPEN',
      mergeable: 'CONFLICTING',
      merge_state: 'DIRTY',
    })
    await expect(fetchPrConflictCached('/repo', 'feature/x')).resolves.toBe(true)
  })

  it('fetchPrConflictCached resolves false when the PR is mergeable', async () => {
    getPrStatusMock.mockResolvedValue({
      status: 'open',
      state: 'OPEN',
      mergeable: 'MERGEABLE',
      merge_state: 'CLEAN',
    })
    await expect(fetchPrConflictCached('/repo', 'feature/x')).resolves.toBe(false)
  })

  it('fetchPrConflictCached resolves false when mergeable is unknown', async () => {
    getPrStatusMock.mockResolvedValue({
      status: 'open',
      state: 'OPEN',
      mergeable: '',
      merge_state: '',
    })
    await expect(fetchPrConflictCached('/repo', 'feature/x')).resolves.toBe(false)
  })

  it('fetchPrConflictCached resolves false when the fetch fails', async () => {
    getPrStatusMock.mockRejectedValue(new ApiError(500, 'Server Error', ''))
    await expect(fetchPrConflictCached('/repo', 'feature/x')).resolves.toBe(false)
  })

  it('fetchPrStatusFullCached returns status plus the mergeable flag', async () => {
    getPrStatusMock.mockResolvedValue({
      status: 'open',
      state: 'OPEN',
      mergeable: 'CONFLICTING',
      merge_state: 'DIRTY',
    })
    await expect(fetchPrStatusFullCached('/repo', 'feature/x')).resolves.toMatchObject({
      status: 'open',
      mergeable: 'CONFLICTING',
      merge_state: 'DIRTY',
    })
  })

  it('fetchPrStatusCached keeps its string contract (conflict does not leak into status)', async () => {
    getPrStatusMock.mockResolvedValue({
      status: 'open',
      state: 'OPEN',
      mergeable: 'CONFLICTING',
      merge_state: 'DIRTY',
    })
    await expect(fetchPrStatusCached('/repo', 'feature/x')).resolves.toBe('open')
  })

  it('status and conflict share one cached fetch (no extra gh call)', async () => {
    getPrStatusMock.mockResolvedValue({
      status: 'open',
      state: 'OPEN',
      mergeable: 'MERGEABLE',
      merge_state: 'CLEAN',
    })
    await fetchPrStatusCached('/repo', 'feature/x')
    await fetchPrConflictCached('/repo', 'feature/x')
    expect(getPrStatusMock).toHaveBeenCalledTimes(1)
  })
})
