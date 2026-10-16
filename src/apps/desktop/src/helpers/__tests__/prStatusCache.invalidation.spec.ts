/** Invalidation tests for the shared PR-status cache. */
import { describe, expect, it, beforeEach, afterEach, vi } from 'vitest'
import {
  fetchPrStatusCached,
  invalidatePrStatus,
  clearPrStatusCache,
  onPrStatusInvalidated,
} from '../prStatusCache'

const { getPrStatusMock } = vi.hoisted(() => ({ getPrStatusMock: vi.fn() }))

vi.mock('@/api', async () => {
  const actual = await vi.importActual<typeof import('@/api')>('@/api')
  return { ...actual, getPrStatus: getPrStatusMock }
})

const open = { status: 'open', state: 'OPEN', mergeable: 'MERGEABLE', merge_state: 'CLEAN' }
const merged = { status: 'merged', state: 'MERGED', mergeable: '', merge_state: '' }

describe('prStatusCache invalidation', () => {
  beforeEach(() => {
    clearPrStatusCache()
    vi.clearAllMocks()
    getPrStatusMock.mockResolvedValue(open)
  })

  afterEach(() => {
    vi.restoreAllMocks()
  })

  it('drops the cached answer so the next read re-asks the forge', async () => {
    await expect(fetchPrStatusCached('/repo', 'worktree/x')).resolves.toBe('open')
    // Second read is served from the cache — no second forge call.
    await expect(fetchPrStatusCached('/repo', 'worktree/x')).resolves.toBe('open')
    expect(getPrStatusMock).toHaveBeenCalledTimes(1)

    invalidatePrStatus('/repo', 'worktree/x')

    getPrStatusMock.mockResolvedValue(merged)
    await expect(fetchPrStatusCached('/repo', 'worktree/x')).resolves.toBe('merged')
    expect(getPrStatusMock).toHaveBeenCalledTimes(2)
  })

  it('drops a provider-keyed entry as well as the provider-less one', async () => {
    // The regression that made the old invalidation a no-op: the board's PR list passed the
    // provider it had just learned (`github`) while every badge had asked with no provider, so the
    // stale entry survived in exactly the case the call existed for. Both key shapes must go.
    await fetchPrStatusCached('/repo', 'worktree/x', 'github')
    await fetchPrStatusCached('/repo', 'worktree/y')
    expect(getPrStatusMock).toHaveBeenCalledTimes(2)

    invalidatePrStatus('/repo', 'worktree/x')
    invalidatePrStatus('/repo', 'worktree/y')

    getPrStatusMock.mockResolvedValue(merged)
    await expect(fetchPrStatusCached('/repo', 'worktree/x', 'github')).resolves.toBe('merged')
    await expect(fetchPrStatusCached('/repo', 'worktree/y')).resolves.toBe('merged')
    expect(getPrStatusMock).toHaveBeenCalledTimes(4)
  })

  it('leaves other branches cached, and never confuses a prefix branch', async () => {
    // A ref name may not contain `:`, which is what `cwd::branch::` relies on.
    await fetchPrStatusCached('/repo', 'feature')
    await fetchPrStatusCached('/repo', 'feature/x')
    await fetchPrStatusCached('/other', 'feature')
    expect(getPrStatusMock).toHaveBeenCalledTimes(3)

    invalidatePrStatus('/repo', 'feature')

    // `feature/x` in the same repo and `feature` in another repo keep their
    // cached answers: the invalidation is precise, not a flush.
    getPrStatusMock.mockResolvedValue(merged)
    await expect(fetchPrStatusCached('/repo', 'feature/x')).resolves.toBe('open')
    await expect(fetchPrStatusCached('/other', 'feature')).resolves.toBe('open')
    expect(getPrStatusMock).toHaveBeenCalledTimes(3)

    // …while the invalidated pair really is re-asked.
    await expect(fetchPrStatusCached('/repo', 'feature')).resolves.toBe('merged')
    expect(getPrStatusMock).toHaveBeenCalledTimes(4)
  })

  it('calls every registered badge back with the pair that moved', () => {
    const a = vi.fn()
    const b = vi.fn()
    const offA = onPrStatusInvalidated(a)
    const offB = onPrStatusInvalidated(b)

    invalidatePrStatus('/repo', 'worktree/x')

    // This callback IS the "re-read" signal: a badge cannot observe a Map
    // deletion, so the producer tells it, with the pair it holds.
    expect(a).toHaveBeenCalledWith({ cwd: '/repo', branch: 'worktree/x' })
    expect(b).toHaveBeenCalledWith({ cwd: '/repo', branch: 'worktree/x' })

    // The unsubscribe handle really unsubscribes — a card that unmounts must
    // not keep reloading.
    offA()
    invalidatePrStatus('/repo', 'worktree/x')
    expect(a).toHaveBeenCalledTimes(1)
    expect(b).toHaveBeenCalledTimes(2)
    offB()
  })

  it('a throwing subscriber does not stop the others', () => {
    const errSpy = vi.spyOn(console, 'error').mockImplementation(() => {})
    const bad = onPrStatusInvalidated(() => {
      throw new Error('buggy badge')
    })
    const good = vi.fn()
    const off = onPrStatusInvalidated(good)

    expect(() => invalidatePrStatus('/repo', 'worktree/x')).not.toThrow()
    expect(good).toHaveBeenCalledTimes(1)
    expect(errSpy).toHaveBeenCalled()

    bad()
    off()
    errSpy.mockRestore()
  })

  it('does nothing — and notifies nobody — without a cwd or a branch', () => {
    const cb = vi.fn()
    const off = onPrStatusInvalidated(cb)
    invalidatePrStatus('', 'worktree/x')
    invalidatePrStatus('/repo', '')
    expect(cb).not.toHaveBeenCalled()
    off()
  })

  it('a fetch that lands after an invalidation does not repopulate the cache', async () => {
    // Deleting the in-flight slot is not enough on its own: the pending
    // promise's own continuation would write the pre-mutation answer straight
    // back into the cache and the badge would render `open` forever.
    let resolveFetch!: (v: unknown) => void
    getPrStatusMock.mockReturnValue(
      new Promise((resolve) => {
        resolveFetch = resolve
      }),
    )
    const inFlight = fetchPrStatusCached('/repo', 'worktree/x')

    invalidatePrStatus('/repo', 'worktree/x')

    resolveFetch(open)
    // The caller that started the fetch still gets the answer it asked for…
    await expect(inFlight).resolves.toBe('open')

    // …but the next reader must not be served that stale answer.
    getPrStatusMock.mockResolvedValue(merged)
    await expect(fetchPrStatusCached('/repo', 'worktree/x')).resolves.toBe('merged')
    expect(getPrStatusMock).toHaveBeenCalledTimes(2)
  })
})
