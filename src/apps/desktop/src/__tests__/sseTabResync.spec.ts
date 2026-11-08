import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { createApp } from 'vue'

import { installSseBus, __resetSseBus } from '../helpers/sseBus'
import { createTabChannel } from '../helpers/sseTabChannel'
import type { SseClient, SseState, SseStateInfo } from '../helpers/sseClient'
import * as api from '../api'
import { FakeTabChannelHub, fakeForeignLeader, settle, waitFor } from './fakes/fakeTabChannel'

const NAME = 'resync-test-bus'

function makeStubClient(initial: SseState = 'connecting'): SseClient {
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const stub: any = {
    close: vi.fn(),
    reconnect: vi.fn(),
    getState: () => stub._state,
    onStateChange: (cb: (s: SseState, info: SseStateInfo) => void) => {
      stub.__stateListeners.push(cb)
      return () => {
        const i = stub.__stateListeners.indexOf(cb)
        if (i >= 0) stub.__stateListeners.splice(i, 1)
      }
    },
  }
  stub._state = initial
  stub.__stateListeners = [] as Array<(s: SseState, info: SseStateInfo) => void>
  return stub as SseClient
}

function fireVisibilityChange(): void {
  document.dispatchEvent(new Event('visibilitychange'))
}

describe('sseTabChannel resync — a window that may have missed events refreshes', () => {
  let hub: FakeTabChannelHub

  beforeEach(() => {
    hub = new FakeTabChannelHub()
  })

  afterEach(() => {
    vi.restoreAllMocks()
  })

  function makeTab(overrides: Record<string, unknown> = {}) {
    const onResync = vi.fn()
    const tab = createTabChannel({
      channelName: NAME,
      heartbeatMs: 20,
      leaderTimeoutMs: 60,
      electionJitterMs: 5,
      hiddenTakeoverDelayMs: 40,
      resyncAfterHiddenMs: 30,
      resyncMinGapMs: 1000, // large by default so only explicit tests see coalescing
      channelFactory: hub.create,
      isVisible: () => true,
      onBecomeLeader: vi.fn(),
      onLoseLeadership: vi.fn(),
      onRemoteEvent: vi.fn(),
      onRemoteState: vi.fn(),
      onRemoteReconnect: vi.fn(),
      onResync,
      ...overrides,
    })
    return { tab, onResync }
  }

  it('signals a resync when this window TAKES OVER the connection', async () => {
    const foreign = fakeForeignLeader(hub, NAME)
    const a = makeTab()
    a.tab.start()
    await settle(60)
    expect(a.tab.isLeader()).toBe(false)
    a.onResync.mockClear()

    foreign.stop()
    // Poll instead of a fixed sleep: the leader timeout is 60ms, and a loaded
    // CI runner drifts past a 120ms budget (observed twice on 2026-11-08).
    await waitFor(() => a.tab.isLeader())

    expect(a.tab.isLeader()).toBe(true)
    expect(a.onResync).toHaveBeenCalledTimes(1)
    expect(String(a.onResync.mock.calls[0]![0])).toMatch(/leader/)
  })

  it('signals a resync when returning from a LONG hidden period', async () => {
    let visible = true
    // Small coalescing gap: the initial `becomeLeader` already emitted a resync,
    // and we want THIS trigger to be observable on its own.
    const a = makeTab({ isVisible: () => visible, resyncMinGapMs: 5 })
    a.tab.start()
    await settle(40)
    a.onResync.mockClear()

    visible = false
    fireVisibilityChange()
    await settle(50) // longer than resyncAfterHiddenMs (30)
    visible = true
    fireVisibilityChange()
    await waitFor(() => a.onResync.mock.calls.length >= 1)

    expect(a.onResync).toHaveBeenCalledTimes(1)
    expect(String(a.onResync.mock.calls[0]![0])).toMatch(/hidden/)
  })

  it('does NOT resync for a quick alt-tab', async () => {
    let visible = true
    const a = makeTab({ isVisible: () => visible })
    a.tab.start()
    await settle(40)
    a.onResync.mockClear()

    visible = false
    fireVisibilityChange()
    visible = true // back within the threshold
    fireVisibilityChange()
    await settle(10)

    expect(a.onResync).not.toHaveBeenCalled()
  })

  it('coalesces a takeover resync with an immediate visibility resync', async () => {
    const foreign = fakeForeignLeader(hub, NAME)
    let visible = true
    const a = makeTab({ isVisible: () => visible })
    a.tab.start()
    await settle(60)
    foreign.stop()
    await settle(120) // takeover → resync #1
    visible = false
    fireVisibilityChange()
    await settle(50) // > resyncAfterHiddenMs
    visible = true
    fireVisibilityChange() // would be resync #2, suppressed by resyncMinGapMs
    await settle(10)

    expect(a.onResync).toHaveBeenCalledTimes(1)
  })

  it('a listener that throws cannot break the coordinator', async () => {
    const onResync = vi.fn(() => {
      throw new Error('boom')
    })
    const a = makeTab({ onResync })
    a.tab.start()
    await settle(40)

    expect(onResync).toHaveBeenCalled()
    expect(a.tab.isLeader()).toBe(true) // still running
  })
})

describe('sseBus resync plumbing', () => {
  let hub: FakeTabChannelHub
  let spy: ReturnType<typeof vi.spyOn>

  beforeEach(() => {
    __resetSseBus()
    hub = new FakeTabChannelHub()
    spy = vi.spyOn(api, 'createUnifiedSseConnection')
  })

  afterEach(() => {
    __resetSseBus()
    vi.restoreAllMocks()
  })

  it('notifies onResync subscribers when this tab becomes the leader', async () => {
    const foreign = fakeForeignLeader(hub, NAME)
    spy.mockReturnValue(makeStubClient())
    const bus = installSseBus(createApp({}), {
      tabSharing: 'on',
      channelFactory: hub.create,
      tabChannelOptions: {
        channelName: NAME,
        heartbeatMs: 20,
        leaderTimeoutMs: 60,
        electionJitterMs: 5,
        hiddenTakeoverDelayMs: 40,
        isVisible: () => true,
      },
    })
    const seen: string[] = []
    const off = bus.onResync?.((reason) => seen.push(reason))

    foreign.stop()
    await settle(140)

    expect(seen.length).toBeGreaterThanOrEqual(1)
    expect(seen[0]).toMatch(/leader/)
    off?.()
    spy.mockRestore()
  })

  it('unsubscribing stops resync delivery', async () => {
    const foreign = fakeForeignLeader(hub, NAME)
    spy.mockReturnValue(makeStubClient())
    const bus = installSseBus(createApp({}), {
      tabSharing: 'on',
      channelFactory: hub.create,
      tabChannelOptions: {
        channelName: NAME,
        heartbeatMs: 20,
        leaderTimeoutMs: 60,
        electionJitterMs: 5,
      },
    })
    const cb = vi.fn()
    const off = bus.onResync?.(cb)
    off?.()

    foreign.stop()
    await settle(140)

    expect(cb).not.toHaveBeenCalled()
    spy.mockRestore()
  })

  it('with sharing OFF the signal never fires (a solo tab misses nothing)', async () => {
    spy.mockReturnValue(makeStubClient())
    const bus = installSseBus(createApp({}), { tabSharing: 'off' })

    const cb = vi.fn()
    const off = bus.onResync?.(cb)
    expect(typeof off).toBe('function')

    // Nothing to fire it: no channel traffic exists on this path.
    expect(hub.ofKind('event')).toHaveLength(0)
    expect(cb).not.toHaveBeenCalled()
    off?.()
    spy.mockRestore()
  })
})
