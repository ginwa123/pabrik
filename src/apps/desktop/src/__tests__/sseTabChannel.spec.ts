import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

import { createTabChannel, type TabChannel, type TabChannelOptions } from '../helpers/sseTabChannel'
import { FakeTabChannelHub, fakeForeignLeader, settle, waitFor } from './fakes/fakeTabChannel'

const NAME = 'test-sse-bus'

/** Fast timings so the election logic is observable without slow tests. */
const TIMINGS = {
  heartbeatMs: 20,
  leaderTimeoutMs: 60,
  electionJitterMs: 5,
  hiddenTakeoverDelayMs: 40,
}

interface TabHarness {
  tab: TabChannel
  becameLeader: ReturnType<typeof vi.fn>
  lostLeadership: ReturnType<typeof vi.fn>
  remoteEvent: ReturnType<typeof vi.fn>
  remoteState: ReturnType<typeof vi.fn>
  remoteReconnect: ReturnType<typeof vi.fn>
  roles: string[]
}

function makeTab(
  hub: FakeTabChannelHub,
  overrides: Partial<TabChannelOptions> = {},
): TabHarness {
  const becameLeader = vi.fn()
  const lostLeadership = vi.fn()
  const remoteEvent = vi.fn()
  const remoteState = vi.fn()
  const remoteReconnect = vi.fn()
  const roles: string[] = []
  const tab = createTabChannel({
    channelName: NAME,
    ...TIMINGS,
    channelFactory: hub.create,
    isVisible: () => true,
    onBecomeLeader: becameLeader,
    onLoseLeadership: lostLeadership,
    onRemoteEvent: remoteEvent,
    onRemoteState: remoteState,
    onRemoteReconnect: remoteReconnect,
    onRoleChange: (r) => roles.push(r),
    ...overrides,
  })
  return { tab, becameLeader, lostLeadership, remoteEvent, remoteState, remoteReconnect, roles }
}

describe('sseTabChannel — one connection per browser profile', () => {
  let hub: FakeTabChannelHub

  beforeEach(() => {
    hub = new FakeTabChannelHub()
  })

  afterEach(() => {
    vi.restoreAllMocks()
  })

  it('a single tab becomes the leader and opens the connection', async () => {
    const a = makeTab(hub)
    a.tab.start()
    await settle(40)

    expect(a.becameLeader).toHaveBeenCalledTimes(1)
    expect(a.tab.isLeader()).toBe(true)
    expect(a.roles).toEqual(['leader'])
  })

  it('a second tab joins as a follower and opens NOTHING', async () => {
    const a = makeTab(hub)
    a.tab.start()
    await settle(40)

    const b = makeTab(hub)
    b.tab.start()
    await settle(60)

    expect(a.tab.isLeader()).toBe(true)
    expect(b.tab.isLeader()).toBe(false)
    // The whole point: only ONE tab ever opens a connection.
    expect(b.becameLeader).not.toHaveBeenCalled()
    expect(a.becameLeader).toHaveBeenCalledTimes(1)
  })

  it("the leader forwards its events to the followers", async () => {
    const a = makeTab(hub)
    a.tab.start()
    await settle(40)
    const b = makeTab(hub)
    b.tab.start()
    await settle(60)

    a.tab.broadcastEvent('session', { id: 's_1', action: 'created' })
    await settle(10)

    expect(b.remoteEvent).toHaveBeenCalledWith('session', { id: 's_1', action: 'created' })
    // And the leader does not deliver its own event twice.
    expect(a.remoteEvent).not.toHaveBeenCalled()
  })

  it('the leader broadcasts state so follower badges tell the truth', async () => {
    const a = makeTab(hub)
    a.tab.start()
    await settle(40)
    const b = makeTab(hub)
    b.tab.start()
    await settle(60)

    a.tab.broadcastState('open')
    await settle(10)

    expect(b.remoteState).toHaveBeenCalledWith('open')
  })

  it('a follower can ask the leader to reconnect', async () => {
    const a = makeTab(hub)
    a.tab.start()
    await settle(40)
    const b = makeTab(hub)
    b.tab.start()
    await settle(60)

    b.tab.requestReconnect()
    await settle(10)

    expect(a.remoteReconnect).toHaveBeenCalledTimes(1)
    // ...and the leader never asks itself over the wire.
    a.tab.requestReconnect()
    expect(a.remoteReconnect).toHaveBeenCalledTimes(2)
  })

  it('closing the leader hands leadership to a remaining tab', async () => {
    const a = makeTab(hub)
    a.tab.start()
    await settle(40)
    const b = makeTab(hub)
    b.tab.start()
    await settle(60)
    expect(b.becameLeader).not.toHaveBeenCalled()

    a.tab.close()
    await waitFor(() => b.tab.isLeader()) // `down` → jittered claim by b

    expect(b.tab.isLeader()).toBe(true)
    expect(b.becameLeader).toHaveBeenCalledTimes(1)
  })

  it('a tab that vanishes WITHOUT a `down` is replaced after the timeout', async () => {
    const a = makeTab(hub)
    a.tab.start()
    await settle(40)
    const b = makeTab(hub)
    b.tab.start()
    await settle(60)
    expect(b.tab.isLeader()).toBe(false)

    // Kill the leader's channel from under it: no `down` message, no heartbeats.
    hub.kill(hub.members(NAME)[0]!)
    await waitFor(() => b.tab.isLeader())

    expect(b.tab.isLeader()).toBe(true)
    expect(b.becameLeader).toHaveBeenCalledTimes(1)
  })

  it('a VISIBLE tab preempts a HIDDEN leader (hidden tabs get throttled)', async () => {
    // The hidden tab starts first, so it wins the initial election.
    const hidden = makeTab(hub, { isVisible: () => false })
    hidden.tab.start()
    await settle(40)
    expect(hidden.tab.isLeader()).toBe(true)

    const visible = makeTab(hub, { isVisible: () => true })
    visible.tab.start()
    await settle(60)

    expect(visible.tab.isLeader()).toBe(true)
    expect(hidden.tab.isLeader()).toBe(false)
    expect(hidden.lostLeadership).toHaveBeenCalledTimes(1)
  })

  it('a HIDDEN follower does not take over on a heartbeat timeout', async () => {
    const a = makeTab(hub, { isVisible: () => false })
    a.tab.start()
    await settle(40)
    expect(a.tab.isLeader()).toBe(true)

    const hiddenFollower = makeTab(hub, { isVisible: () => false })
    hiddenFollower.tab.start()
    await settle(60)

    hub.kill(hub.members(NAME)[0]!)
    // Long past the timeout: a throttled hidden tab must not become the source of truth for the others.
    await settle(TIMINGS.leaderTimeoutMs * 3)

    expect(hiddenFollower.tab.isLeader()).toBe(false)
  })

  it('two tabs that start simultaneously converge on ONE leader', async () => {
    const a = makeTab(hub)
    const b = makeTab(hub)
    a.tab.start()
    b.tab.start()
    await settle(80)

    expect([a, b].filter((t) => t.tab.isLeader())).toHaveLength(1)
    // ...and it must stay converged (a tie that re-claims would flap).
    await settle(80)
    expect([a, b].filter((t) => t.tab.isLeader())).toHaveLength(1)
  })

  it('falls back to a solo connection when BroadcastChannel is unavailable', async () => {
    const a = makeTab(hub, {
      channelFactory: () => {
        throw new Error('BroadcastChannel is not defined')
      },
    })
    a.tab.start()

    expect(a.tab.isLeader()).toBe(true)
    expect(a.becameLeader).toHaveBeenCalledTimes(1)
  })

  it('a follower that never hears from anyone becomes the leader', async () => {
    // A stale `here` from a tab that is already gone must not park us forever.
    const ghost = fakeForeignLeader(hub, NAME)
    const a = makeTab(hub)
    a.tab.start()
    await settle(40)
    expect(a.tab.isLeader()).toBe(false)

    ghost.stop()
    await waitFor(() => a.tab.isLeader())

    expect(a.tab.isLeader()).toBe(true)
  })

  it('close() stops heartbeats and leaves the channel', async () => {
    const a = makeTab(hub)
    a.tab.start()
    await settle(40)
    const before = hub.ofKind('beat').length

    a.tab.close()
    await settle(60)

    // No further heartbeats after close.
    expect(hub.ofKind('beat').length).toBe(before)
    expect(hub.members(NAME)).toHaveLength(0)
  })
})
