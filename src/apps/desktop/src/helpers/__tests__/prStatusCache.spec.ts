/**  * Behavioural tests for the shared PR-status cache (kanban git icon). The board mounts ~140 cards
 * at once; without dedupe every card fired its own `gh pr view`. These tests lock in: in-flight
 * dedupe, TTL caching, retry-on-transient, no-retry-on-404, and fail-silent ''. */
import { describe, expect, it, beforeEach, afterEach, vi } from 'vitest'
import { ApiError } from '@/api'
import { fetchPrStatusCached, fetchPrStatusFullCached, clearPrStatusCache } from '../prStatusCache'

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

describe('prStatusCache', () => {
  beforeEach(() => {
    clearPrStatusCache()
    vi.clearAllMocks()
    vi.spyOn(console, 'warn').mockImplementation(() => {})
  })

  afterEach(() => {
    vi.restoreAllMocks()
    vi.useRealTimers()
  })

  it('resolves the lowercase status', async () => {
    getPrStatusMock.mockResolvedValue({ status: 'MERGED', state: 'MERGED' })
    await expect(fetchPrStatusCached('/repo', 'feature/x')).resolves.toBe('merged')
  })

  it('falls back to state when status is empty', async () => {
    getPrStatusMock.mockResolvedValue({ status: '', state: 'CLOSED' })
    await expect(fetchPrStatusCached('/repo', 'feature/x')).resolves.toBe('closed')
  })

  it('dedupes concurrent callers for the same branch', async () => {
    getPrStatusMock.mockResolvedValue({ status: 'open', state: 'OPEN' })
    const [a, b] = await Promise.all([
      fetchPrStatusCached('/repo', 'feature/x'),
      fetchPrStatusCached('/repo', 'feature/x'),
    ])
    expect(a).toBe('open')
    expect(b).toBe('open')
    expect(getPrStatusMock).toHaveBeenCalledTimes(1)
  })

  it('caches sequential calls within the TTL', async () => {
    getPrStatusMock.mockResolvedValue({ status: 'open', state: 'OPEN' })
    await fetchPrStatusCached('/repo', 'feature/x')
    await fetchPrStatusCached('/repo', 'feature/x')
    expect(getPrStatusMock).toHaveBeenCalledTimes(1)
  })

  it('refetches after the TTL expires', async () => {
    vi.useFakeTimers()
    vi.setSystemTime(new Date('2026-09-21T10:00:00Z'))
    getPrStatusMock.mockResolvedValue({ status: 'open', state: 'OPEN' })
    await fetchPrStatusCached('/repo', 'feature/x')
    vi.setSystemTime(new Date('2026-09-21T10:01:01Z'))
    await fetchPrStatusCached('/repo', 'feature/x')
    expect(getPrStatusMock).toHaveBeenCalledTimes(2)
  })

  it('retries a transient failure and then succeeds', async () => {
    getPrStatusMock
      .mockRejectedValueOnce(new ApiError(502, 'Bad Gateway', ''))
      .mockResolvedValueOnce({ status: 'merged', state: 'MERGED' })
    await expect(fetchPrStatusCached('/repo', 'feature/x')).resolves.toBe('merged')
    expect(getPrStatusMock).toHaveBeenCalledTimes(2)
  })

  it('does not retry a 404 (no PR for the branch)', async () => {
    getPrStatusMock.mockRejectedValue(new ApiError(404, 'Not Found', ''))
    await expect(fetchPrStatusCached('/repo', 'main')).resolves.toBe('')
    expect(getPrStatusMock).toHaveBeenCalledTimes(1)
  })

  it('resolves fail-silent after exhausting retries', async () => {
    getPrStatusMock.mockRejectedValue(new ApiError(500, 'Server Error', ''))
    await expect(fetchPrStatusCached('/repo', 'feature/x')).resolves.toBe('')
    expect(getPrStatusMock).toHaveBeenCalledTimes(3)
    expect(console.warn).toHaveBeenCalled()
  })

  it('skips the fetch when cwd or branch is empty', async () => {
    await expect(fetchPrStatusCached('', 'feature/x')).resolves.toBe('')
    await expect(fetchPrStatusCached('/repo', '')).resolves.toBe('')
    expect(getPrStatusMock).not.toHaveBeenCalled()
  })

  it('does not ask the forge again for ten minutes when the branch has no PR', async () => {
    vi.useFakeTimers()
    vi.setSystemTime(new Date('2026-09-21T10:00:00Z'))
    getPrStatusMock.mockResolvedValue({ has_pr: false, reason: 'no_pr', status: '', state: '' })

    await fetchPrStatusCached('/repo', 'main')
    vi.setSystemTime(new Date('2026-09-21T10:09:00Z'))
    await fetchPrStatusCached('/repo', 'main')
    expect(getPrStatusMock).toHaveBeenCalledTimes(1)

    vi.setSystemTime(new Date('2026-09-21T10:11:00Z'))
    await fetchPrStatusCached('/repo', 'main')
    expect(getPrStatusMock).toHaveBeenCalledTimes(2)
  })

  it('does not ask the forge again for ten minutes once the PR is merged', async () => {
    vi.useFakeTimers()
    vi.setSystemTime(new Date('2026-09-21T10:00:00Z'))
    getPrStatusMock.mockResolvedValue({ has_pr: true, status: 'merged', state: 'MERGED' })

    await fetchPrStatusCached('/repo', 'feature/x')
    vi.setSystemTime(new Date('2026-09-21T10:09:00Z'))
    await expect(fetchPrStatusCached('/repo', 'feature/x')).resolves.toBe('merged')
    expect(getPrStatusMock).toHaveBeenCalledTimes(1)
  })

  it('reports hasPr true for a server that answers without the flag', async () => {
    getPrStatusMock.mockResolvedValue({ status: 'open', state: 'OPEN' })
    const info = await fetchPrStatusFullCached('/repo', 'feature/x')
    expect(info.hasPr).toBe(true)
    expect(info.status).toBe('open')
  })

  it('reports hasPr false and stays quiet when an older server answers 404', async () => {
    getPrStatusMock.mockRejectedValue(new ApiError(404, 'Not Found', ''))
    const info = await fetchPrStatusFullCached('/repo', 'main')
    expect(info.hasPr).toBe(false)
    expect(info.status).toBe('')
    expect(console.warn).not.toHaveBeenCalled()
  })

  it('reports hasPr unknown rather than false when the fetch kept failing', async () => {
    getPrStatusMock.mockRejectedValue(new ApiError(500, 'Server Error', ''))
    const info = await fetchPrStatusFullCached('/repo', 'feature/x')
    expect(info.hasPr).toBeNull()
  })
})
