/** The `git_pr_state` channel — both halves of its registration. The bug this exists for: merging
 * from the PR tab (MergeBox) recoloured the PR tab's own badge and nothing else. */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { createApp } from 'vue'

import { createUnifiedSseConnection } from '../api'
import * as sseClient from '../helpers/sseClient'
import {
  __dispatchSseBus,
  __resetSseBus,
  __setSseBusGlobalClient,
  installSseBus,
  useSseBus,
} from '../helpers/sseBus'
import type { SseClient, SseState, SseStateInfo } from '../helpers/sseClient'
import {
  clearPrStatusCache,
  fetchPrStatusCached,
  onPrStatusInvalidated,
  subscribePrStatusEvents,
} from '../helpers/prStatusCache'

const { getPrStatusMock } = vi.hoisted(() => ({ getPrStatusMock: vi.fn() }))

vi.mock('../api', async () => {
  const actual = await vi.importActual<typeof import('../api')>('../api')
  return { ...actual, getPrStatus: getPrStatusMock }
})

const MERGED = { action: 'merged', cwd: '/repo', branch: 'worktree/x' }

// ─── layer 1: the API layer's four registration places ────────────────────
describe('createUnifiedSseConnection: git_pr_state channel', () => {
  const spy = vi.spyOn(sseClient, 'createSseClient')
  let capturedOnEvent: ((raw: string, eventType: string) => void) | null = null
  let capturedOpts: sseClient.SseClientOptions | null = null

  beforeEach(() => {
    capturedOnEvent = null
    capturedOpts = null
    spy.mockImplementation(((opts: sseClient.SseClientOptions) => {
      capturedOnEvent = opts.onEvent
      capturedOpts = opts
      return {
        close: vi.fn(),
        reconnect: vi.fn(),
        getState: () => 'open' as const,
        onStateChange: () => () => {},
      }
    }) as unknown as typeof sseClient.createSseClient)
  })

  afterEach(() => {
    spy.mockClear()
  })

  it('adds the git_pr_state channel token to the EventSource URL', () => {
    createUnifiedSseConnection({ channels: { gitPrState: vi.fn() } })

    expect(capturedOpts?.url).toContain('channels=git_pr_state')
  })

  it('pre-registers both granular wire names so the browser dispatches them', () => {
    createUnifiedSseConnection({ channels: { gitPrState: vi.fn() } })

    // A name missing here is dropped by EventSource before onEvent — which is
    // indistinguishable from a dead stream, and is exactly how the stale-colour
    // bug would come back for a merge in another tab.
    expect(capturedOpts?.additionalEventTypes).toContain('git_pr_state_merged')
    expect(capturedOpts?.additionalEventTypes).toContain('git_pr_state_closed')
  })

  it('routes git_pr_state_merged to the channel callback with the parsed payload', () => {
    const cb = vi.fn()
    createUnifiedSseConnection({ channels: { gitPrState: cb } })

    capturedOnEvent!(JSON.stringify(MERGED), 'git_pr_state_merged')

    expect(cb).toHaveBeenCalledTimes(1)
    expect(cb).toHaveBeenCalledWith(MERGED)
  })

  it('routes git_pr_state_closed to the same channel callback', () => {
    const cb = vi.fn()
    createUnifiedSseConnection({ channels: { gitPrState: cb } })

    const payload = { action: 'closed', cwd: '/repo', branch: 'worktree/y' }
    capturedOnEvent!(JSON.stringify(payload), 'git_pr_state_closed')

    expect(cb).toHaveBeenCalledTimes(1)
    expect(cb).toHaveBeenCalledWith(payload)
  })

  it('ignores the event when the channel is not subscribed', () => {
    // No `gitPrState` channel → return early rather than fall through to the
    // default-message buffer (which would corrupt the next unnamed event).
    const workersCb = vi.fn()
    createUnifiedSseConnection({ channels: { workers: workersCb } })

    expect(() => capturedOnEvent!(JSON.stringify(MERGED), 'git_pr_state_merged')).not.toThrow()
    expect(workersCb).not.toHaveBeenCalled()
  })

  it('an unparseable body is logged, not thrown', () => {
    const errSpy = vi.spyOn(console, 'error').mockImplementation(() => {})
    const cb = vi.fn()
    createUnifiedSseConnection({ channels: { gitPrState: cb } })

    expect(() => capturedOnEvent!('not json', 'git_pr_state_merged')).not.toThrow()
    expect(cb).not.toHaveBeenCalled()
    expect(errSpy).toHaveBeenCalled()
    errSpy.mockRestore()
  })
})

// ─── layer 2: the bus → cache bridge ──────────────────────────────────────
function makeStubClient(initial: SseState): SseClient {
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const stub: any = {
    close: vi.fn(),
    reconnect: vi.fn(),
    getState: () => stub._state,
    onStateChange: (_cb: (s: SseState, info: SseStateInfo) => void) => () => {},
  }
  stub._state = initial
  return stub as SseClient
}

describe('git_pr_state → prStatusCache bridge', () => {
  let off: (() => void) | null = null
  let offSubscriber: (() => void) | null = null

  beforeEach(() => {
    clearPrStatusCache()
    vi.clearAllMocks()
    __resetSseBus()
    installSseBus(createApp({}))
    __setSseBusGlobalClient(makeStubClient('connecting'))
    off = subscribePrStatusEvents(useSseBus())
  })

  afterEach(() => {
    off?.()
    off = null
    offSubscriber?.()
    offSubscriber = null
    __resetSseBus()
    vi.restoreAllMocks()
  })

  it('drops the cached PR status for the branch it names, so the badges re-read', async () => {
    getPrStatusMock.mockResolvedValue({ status: 'open', state: 'OPEN' })
    await expect(fetchPrStatusCached(MERGED.cwd, MERGED.branch)).resolves.toBe('open')
    expect(getPrStatusMock).toHaveBeenCalledTimes(1)

    // A badge, standing in for ChatsList's row / WorkspaceItemTaskCard's badge.
    const badge = vi.fn()
    offSubscriber = onPrStatusInvalidated(badge)

    __dispatchSseBus('gitPrState', { action: 'merged', cwd: MERGED.cwd, branch: MERGED.branch })

    // Both halves of the fix, on one event: the badge is told to re-read…
    expect(badge).toHaveBeenCalledWith({ cwd: MERGED.cwd, branch: MERGED.branch })
    // …and the cache entry it would have re-read is gone, so the re-read sees
    // the merge instead of the 60s-stale `open`.
    getPrStatusMock.mockResolvedValue({ status: 'merged', state: 'MERGED' })
    await expect(fetchPrStatusCached(MERGED.cwd, MERGED.branch)).resolves.toBe('merged')
    expect(getPrStatusMock).toHaveBeenCalledTimes(2)
  })

  it('leaves another branch cached — the event is filtered, not a flush', async () => {
    getPrStatusMock.mockResolvedValue({ status: 'open', state: 'OPEN' })
    await fetchPrStatusCached('/other', 'worktree/y')

    __dispatchSseBus('gitPrState', { action: 'merged', cwd: MERGED.cwd, branch: MERGED.branch })

    getPrStatusMock.mockResolvedValue({ status: 'merged', state: 'MERGED' })
    await expect(fetchPrStatusCached('/other', 'worktree/y')).resolves.toBe('open')
    expect(getPrStatusMock).toHaveBeenCalledTimes(1)
  })
})
