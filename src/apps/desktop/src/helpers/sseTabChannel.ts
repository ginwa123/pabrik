// src/apps/desktop/src/helpers/sseTabChannel.ts
//
// Cross-tab coordination for the global SSE connection.
//
// PROBLEM: browsers cap HTTP/1.1 connections per origin at ~6. Every tab of the
// app used to open its OWN EventSource (the bus is per-window), so the 7th tab
// could not stream at all — and each open tab also consumed one of the slots the
// app's ordinary fetches need.
//
// SOLUTION: exactly ONE tab ("the leader") owns the EventSource; the others are
// "followers" and receive every dispatched event over a `BroadcastChannel`
// (structured-clone fan-out). One connection no matter how many tabs are open.
//
// Leadership rules (deterministic, no coordinator server):
//   * rank = (visible ? 1 : 0) then (older tab wins) then (tabId, lexicographic).
//     A visible tab always outranks a hidden one, because browsers throttle
//     timers *and* may pause an EventSource in a hidden tab.
//   * A tab claims leadership when it hears no leader for `leaderTimeoutMs`, when
//     it hears the leader step down (`down`), or when it becomes visible and the
//     current leader is hidden.
//   * Claim-first: a joining tab may briefly open its own connection, but as soon
//     as it hears a higher-ranked leader it steps down. Steady state is exactly
//     one connection; the overlap window is a task tick.
//   * A HIDDEN tab only takes over by explicit `down` (and only after a longer
//     delay), never on a heartbeat timeout — a throttled tab cannot serve the
//     others.
//
// This module is transport- and app-agnostic: it knows nothing about SSE
// payloads beyond "post it to the others" / "deliver it locally".

export interface TabChannelLike {
  postMessage(message: unknown): void
  addEventListener(type: 'message', listener: (event: { data: unknown }) => void): void
  removeEventListener(type: 'message', listener: (event: { data: unknown }) => void): void
  close(): void
}

export interface TabChannelOptions {
  /** Channel name; must be identical in every tab. */
  channelName?: string
  /** Stable-ish id for this tab (defaults to a random one). */
  tabId?: string
  /** Defaults to `document.visibilityState === 'visible'`. */
  isVisible?: () => boolean
  /** Leader heartbeat interval. */
  heartbeatMs?: number
  /** How long a follower waits before deciding the leader is gone. */
  leaderTimeoutMs?: number
  /** Random jitter ceiling applied before claiming (avoids claim stampedes). */
  electionJitterMs?: number
  /** Extra delay a HIDDEN tab waits before taking over after a `down`. */
  hiddenTakeoverDelayMs?: number
  /** Test seam: how to open the channel. Defaults to `new BroadcastChannel(...)`. */
  channelFactory?: (name: string) => TabChannelLike
  /** Called exactly once per leadership acquisition — open the EventSource here. */
  onBecomeLeader: () => void
  /** Called when leadership is lost — close the EventSource here. */
  onLoseLeadership: () => void
  /** An event forwarded by the leader (followers dispatch this locally). */
  onRemoteEvent: (channel: string, payload: unknown) => void
  /** The leader's connection state, so follower badges show the truth. */
  onRemoteState: (state: string) => void
  /** A follower asking the leader to reconnect. */
  onRemoteReconnect: () => void
  /**
   * A window that may have MISSED events should refresh its data:
   *   * it just became leader (the handover gap dropped events), or
   *   * it was hidden longer than `resyncAfterHiddenMs` and came back
   *     (background tabs get frozen/throttled and can miss deliveries).
   * Callers answer by re-fetching from the REST API — every tab can always do
   * that directly, independent of who holds the SSE connection. Coalesced by
   * `resyncMinGapMs` so switching windows does not stampede the API.
   */
  onResync?: (reason: string) => void
  /** Hidden-for-longer-than-this triggers a resync on return (default 5s). */
  resyncAfterHiddenMs?: number
  /** Minimum spacing between resyncs (default 5s). */
  resyncMinGapMs?: number
  /** Optional diagnostics. */
  onRoleChange?: (role: 'leader' | 'follower') => void
}

type Peer = { tabId: string; visible: boolean; startedAt: number }
type Msg =
  | ({ k: 'who' } & Peer)
  | ({ k: 'here' } & Peer)
  | ({ k: 'claim' } & Peer)
  | ({ k: 'beat' } & Peer)
  | { k: 'down'; tabId: string }
  | { k: 'state'; tabId: string; state: string }
  | { k: 'event'; tabId: string; channel: string; payload: unknown }
  | { k: 'reconnect'; tabId: string }

const DEFAULTS = {
  channelName: 'pabrik-sse-bus',
  heartbeatMs: 1000,
  leaderTimeoutMs: 3000,
  electionJitterMs: 250,
  hiddenTakeoverDelayMs: 3000,
  resyncAfterHiddenMs: 5000,
  resyncMinGapMs: 5000,
}

export interface TabChannel {
  /** True while this tab owns the connection. */
  isLeader(): boolean
  /** Begin participating (and possibly claim leadership). */
  start(): void
  /** Forward a locally-dispatched event to the followers. No-op when solo. */
  broadcastEvent(channel: string, payload: unknown): void
  /** Tell followers what the shared connection state is. */
  broadcastState(state: string): void
  /** Ask whoever is leading to reconnect (used by the "Retry" button). */
  requestReconnect(): void
  /** Stop participating and release leadership if held. Terminal. */
  close(): void
}

function randomTabId(): string {
  return `t_${Math.random().toString(36).slice(2, 10)}`
}

/** Create the coordinator. `start()` must be called once the caller's callbacks
 * are wired; everything after that is driven by channel messages and timers. */
export function createTabChannel(opts: TabChannelOptions): TabChannel {
  const channelName = opts.channelName ?? DEFAULTS.channelName
  const tabId = opts.tabId ?? randomTabId()
  const isVisible = opts.isVisible ?? (() => {
    // `document` is absent in some hosts (SSR/build); treat that as visible so a
    // single-window host always leads.
    const d = (globalThis as { document?: { visibilityState?: string } }).document
    return d?.visibilityState ? d.visibilityState === 'visible' : true
  })
  const heartbeatMs = opts.heartbeatMs ?? DEFAULTS.heartbeatMs
  const leaderTimeoutMs = opts.leaderTimeoutMs ?? DEFAULTS.leaderTimeoutMs
  const electionJitterMs = opts.electionJitterMs ?? DEFAULTS.electionJitterMs
  const hiddenTakeoverDelayMs = opts.hiddenTakeoverDelayMs ?? DEFAULTS.hiddenTakeoverDelayMs
  const resyncAfterHiddenMs = opts.resyncAfterHiddenMs ?? DEFAULTS.resyncAfterHiddenMs
  const resyncMinGapMs = opts.resyncMinGapMs ?? DEFAULTS.resyncMinGapMs

  const startedAt = Date.now()
  let leader = false
  let started = false
  let closed = false
  let lastLeaderBeatAt = 0
  let leaderVisible = false
  let leaderTabId: string | null = null

  let heartbeatTimer: ReturnType<typeof setInterval> | null = null
  let leaderWatchdog: ReturnType<typeof setTimeout> | null = null
  let claimTimer: ReturnType<typeof setTimeout> | null = null
  /** When this window last went hidden (null = visible), for resync decisions. */
  let hiddenSince: number | null = null
  let lastResyncAt = 0

  let channel: TabChannelLike | null = null
  let onMessage: ((event: { data: unknown }) => void) | null = null
  let onVisibility: (() => void) | null = null

  /** Total ordering for leadership. A single NUMERIC rank is not enough: two tabs
   * created in the same millisecond tie, and a tie never resolves - both keep
   * leading and the profile ends up with two connections (caught by
   * `sseTabChannel.spec.ts > two tabs that start simultaneously converge`). So
   * compare the tuple instead: visible beats hidden, then the older tab wins,
   * then tabId breaks the tie. */
  function outranksTheirs(peer: Peer): boolean {
    if (peer.visible !== isVisible()) return isVisible()
    if (peer.startedAt !== startedAt) return startedAt < peer.startedAt
    return tabId < peer.tabId
  }

  function myPeer(): Peer {
    return { tabId, visible: isVisible(), startedAt }
  }

  /** A hidden leader cannot serve a visible tab reliably (see preemption rules). */
  function shouldPreemptHiddenLeader(peer: Peer): boolean {
    return !peer.visible && isVisible() && outranksTheirs(peer)
  }

  function post(msg: Msg): void {
    if (closed || !channel) return
    try {
      channel.postMessage(msg)
    } catch {
      // A non-cloneable payload must never break the local path — the leader
      // still dispatches locally; followers just miss this one.
    }
  }

  /**
   * Tell the app it may be missing data. Two things cause that:
   *   * we just took over the connection — events during the handover gap were
   *     delivered to nobody;
   *   * we were hidden long enough for the browser to freeze/throttle us, so
   *     deliveries (and rendering) were skipped.
   * Routed through `onResync`, which the app answers by re-fetching from the API.
   * Coalesced: an alt-tab every second must not become an API stampede.
   */
  function maybeResync(reason: string): void {
    if (closed) return
    if (!opts.onResync) return
    const now = Date.now()
    if (now - lastResyncAt < resyncMinGapMs) return
    lastResyncAt = now
    try {
      opts.onResync(reason)
    } catch (e) {
      console.error('[sseTabChannel] onResync threw:', e)
    }
  }

  function becomeLeader(reason: string): void {
    if (closed || leader) return
    leader = true
    leaderTabId = tabId
    leaderVisible = isVisible()
    lastLeaderBeatAt = Date.now()
    post({ k: 'claim', ...myPeer() })
    startHeartbeat()
    opts.onRoleChange?.('leader')
    console.log(`[sseTabChannel] became leader (${reason})`)
    opts.onBecomeLeader()
    // The gap between the old leader's last event and our fresh connection is
    // invisible to everyone: ask the app to refresh what it shows.
    maybeResync(`became leader (${reason})`)
  }

  function stepDown(reason: string): void {
    if (closed || !leader) return
    leader = false
    stopHeartbeat()
    opts.onRoleChange?.('follower')
    console.log(`[sseTabChannel] stepped down (${reason})`)
    opts.onLoseLeadership()
  }

  function startHeartbeat(): void {
    stopHeartbeat()
    heartbeatTimer = setInterval(() => {
      post({ k: 'beat', ...myPeer() })
    }, heartbeatMs)
    // Node/browser: don't keep the process alive for a heartbeat.
    const t = heartbeatTimer as unknown as { unref?: () => void }
    t.unref?.()
  }

  function stopHeartbeat(): void {
    if (heartbeatTimer !== null) {
      clearInterval(heartbeatTimer)
      heartbeatTimer = null
    }
  }

  /** Arm the "the leader vanished without saying goodbye" watchdog. */
  function armLeaderWatchdog(): void {
    if (leaderWatchdog !== null) clearTimeout(leaderWatchdog)
    if (closed || leader) return
    // A HIDDEN tab must not take over on a timeout: browsers throttle its timers,
    // so it would be a worse leader than the one it replaced. It only takes over
    // on an explicit `down` (see `scheduleElection`).
    if (!isVisible()) return
    leaderWatchdog = setTimeout(() => {
      leaderWatchdog = null
      if (closed || leader) return
      if (Date.now() - lastLeaderBeatAt < leaderTimeoutMs) {
        armLeaderWatchdog()
        return
      }
      becomeLeader('leader timeout')
    }, leaderTimeoutMs)
  }

  /**
   * Claim after a jittered delay, so simultaneous candidates don't all win.
   *
   * `force` skips the "someone else may have claimed while we waited" re-check.
   * That re-check is right for a contested election, but WRONG for preemption: a
   * hidden leader keeps heartbeating every `heartbeatMs`, so the re-check always
   * saw a fresh beat and the visible tab never took over (caught by
   * `sseTabChannel.spec.ts > a VISIBLE tab preempts a HIDDEN leader`).
   */
  function scheduleElection(reason: string, force = false): void {
    if (closed || leader || claimTimer !== null) return
    const jitter = Math.random() * electionJitterMs
    const base = isVisible() ? 0 : hiddenTakeoverDelayMs
    claimTimer = setTimeout(() => {
      claimTimer = null
      if (closed || leader) return
      // Someone else may have claimed while we waited (contested election only).
      if (!force && Date.now() - lastLeaderBeatAt < heartbeatMs * 2 && leaderTabId !== tabId) {
        armLeaderWatchdog()
        return
      }
      becomeLeader(reason)
    }, base + jitter)
  }

  function handle(msg: Msg): void {
    if (closed) return
    if (typeof msg !== 'object' || msg === null || typeof (msg as { k?: unknown }).k !== 'string') return
    if ((msg as { tabId?: string }).tabId === tabId) return // our own echo (defensive)

    switch (msg.k) {
      case 'who':
        // Someone is looking for a leader. Answer only if we ARE one.
        if (leader) post({ k: 'here', ...myPeer() })
        return
      case 'here':
      case 'beat':
      case 'claim': {
        const peer: Peer = { tabId: msg.tabId, visible: msg.visible, startedAt: msg.startedAt }
        lastLeaderBeatAt = Date.now()
        leaderVisible = peer.visible
        leaderTabId = peer.tabId
        if (leader) {
          // Two leaders (or an outranking newcomer): the loser steps down so the
          // profile converges on exactly one connection.
          if (outranksTheirs(peer)) {
            post({ k: 'here', ...myPeer() })
          } else {
            stepDown(`outranked by tab ${peer.tabId} (visible=${peer.visible})`)
          }
          return
        }
        // A visible tab takes over from a hidden leader: browsers throttle hidden
        // tabs, so leaving a stale hidden leader in charge stalls the whole
        // profile. Without this, a visible tab that JOINS while a hidden tab leads
        // would never claim (only the visibilitychange path did).
        if (shouldPreemptHiddenLeader(peer)) {
          scheduleElection('visible tab preempting hidden leader', true)
          return
        }
        armLeaderWatchdog()
        return
      }
      case 'down':
        lastLeaderBeatAt = 0
        leaderTabId = null
        stopHeartbeat()
        // The leader disappeared: election. Hidden tabs wait longer so a visible
        // tab (if any) wins.
        scheduleElection('leader stepped down')
        return
      case 'state':
        opts.onRemoteState(msg.state)
        return
      case 'event':
        opts.onRemoteEvent(msg.channel, msg.payload)
        return
      case 'reconnect':
        // Only the leader acts on it.
        if (leader) opts.onRemoteReconnect()
        return
      default:
        return
    }
  }

  return {
    isLeader: () => leader,

    start(): void {
      if (started || closed) return
      started = true

      const factory = opts.channelFactory ?? ((name: string) => new BroadcastChannel(name) as unknown as TabChannelLike)
      try {
        channel = factory(channelName)
      } catch (e) {
        // No BroadcastChannel (old engine, restricted context): behave exactly
        // like the pre-tab-sharing code — this tab owns the connection.
        console.warn('[sseTabChannel] BroadcastChannel unavailable; running solo:', e)
        becomeLeader('no BroadcastChannel')
        return
      }

      onMessage = (event) => {
        const data = event.data as { k?: string } | null
        if (data && typeof data === 'object') handle(data as Msg)
      }
      channel.addEventListener('message', onMessage)

      // Ask whether anyone is already leading; if nobody answers (and no
      // heartbeat arrives) we become the leader ourselves.
      post({ k: 'who', ...myPeer() })
      armLeaderWatchdog()
      // Claim straight away when nobody answers within one heartbeat — this makes
      // the single-tab case as fast as it was before tab sharing existed.
      claimTimer = setTimeout(() => {
        claimTimer = null
        if (closed || leader) return
        if (leaderTabId === null) becomeLeader('no leader after discovery')
      }, heartbeatMs)
      const ct = claimTimer as unknown as { unref?: () => void }
      ct.unref?.()

      // A visible tab preempts a hidden leader: browsers pause/throttle streams in
      // hidden tabs, so following the visible one keeps the feed live.
      onVisibility = () => {
        if (closed) return
        if (isVisible()) {
          const hiddenForMs = hiddenSince === null ? 0 : Date.now() - hiddenSince
          hiddenSince = null
          if (leader) {
            leaderVisible = true
            post({ k: 'beat', ...myPeer() })
          } else if (leaderTabId !== null && !leaderVisible) {
            becomeLeader('visible tab preempting hidden leader')
          } else {
            // Nobody visible is leading (or nobody at all): make sure SOMETHING is.
            armLeaderWatchdog()
          }
          // We may have been frozen/throttled while hidden, missing both
          // deliveries and rendering — ask the app to refresh. A quick alt-tab
          // stays below the threshold and costs nothing.
          if (hiddenForMs >= resyncAfterHiddenMs) {
            maybeResync(`visible after ${Math.round(hiddenForMs / 1000)}s hidden`)
          }
          return
        }
        hiddenSince = Date.now()
        if (leader) {
          // We just went hidden: keep leading (no visible alternative yet) but
          // advertise the change so a visible tab can take over.
          leaderVisible = false
          post({ k: 'beat', ...myPeer() })
        }
      }
      const d = (globalThis as { document?: { addEventListener?: unknown } }).document
      if (d && typeof d.addEventListener === 'function') {
        ;(d as unknown as { addEventListener: (t: string, cb: () => void) => void }).addEventListener(
          'visibilitychange',
          onVisibility,
        )
      }

      // A tab that goes away must hand over promptly, not after a timeout.
      const w = globalThis as unknown as {
        addEventListener?: (t: string, cb: () => void) => void
      }
      if (typeof w.addEventListener === 'function') {
        w.addEventListener('pagehide', () => {
          if (leader) post({ k: 'down', tabId })
        })
      }
    },

    broadcastEvent(channelNameArg: string, payload: unknown): void {
      post({ k: 'event', tabId, channel: channelNameArg, payload })
    },

    broadcastState(state: string): void {
      if (!leader) return
      post({ k: 'state', tabId, state })
    },

    requestReconnect(): void {
      if (leader) {
        opts.onRemoteReconnect()
        return
      }
      post({ k: 'reconnect', tabId })
    },

    close(): void {
      if (closed) return
      // Announce the handover BEFORE flipping the internal `closed` flag:
      // `post()` is a no-op once closed, so posting after the flag would silently
      // drop the `down` message and the remaining tabs would not take over until
      // the heartbeat timeout (caught by `sseTabChannel.spec.ts > closing the
      // leader hands leadership to a remaining tab`).
      if (leader) post({ k: 'down', tabId })
      closed = true
      stopHeartbeat()
      if (leaderWatchdog !== null) {
        clearTimeout(leaderWatchdog)
        leaderWatchdog = null
      }
      if (claimTimer !== null) {
        clearTimeout(claimTimer)
        claimTimer = null
      }
      if (channel && onMessage) channel.removeEventListener('message', onMessage)
      if (onVisibility) {
        const d = (globalThis as { document?: { removeEventListener?: unknown } }).document
        const remove = (d as unknown as { removeEventListener?: (t: string, cb: () => void) => void })
          ?.removeEventListener
        if (typeof remove === 'function') remove.call(d, 'visibilitychange', onVisibility)
      }
      try {
        channel?.close()
      } catch {
        /* already closed */
      }
      channel = null
      onMessage = null
      onVisibility = null
      leader = false
    },
  }
}
