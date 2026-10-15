// src/apps/desktop/src/helpers/sseBus.ts
import type { App, ShallowRef } from 'vue'
import { shallowRef } from 'vue'
import type { SseClient, SseState, SseStateInfo } from './sseClient'
import { createUnifiedSseConnection } from '../api'
import type { TabChannel, TabChannelLike, TabChannelOptions } from './sseTabChannel'
import { createTabChannel } from './sseTabChannel'
import type {
  WorkerEvent,
  SessionEvent,
  KanbanColumnEvent,
  KanbanTaskEvent,
  DesignElementEvent,
  SseEvent,
  QueueMessageEvent,
  BackgroundProcessEvent,
  SkillEvalEvent,
  GitFileStageEvent,
  GitPrStateEvent,
} from '../api'

// NOTE: Plan's Chunk 1 spec imports `KanbanEvent` and `LlmChunkEvent` from `../api`, but those
// names don't exist in `api/index.ts` — the actual exports are `KanbanColumnEvent` /
// `KanbanTaskEvent` and `SseEvent`.
// We use the real names here; the `SseEventMap` shape (worker / session / kanban / design / llm /
// queue) is unchanged.
type SseEventMap = {
  worker: WorkerEvent
  session: SessionEvent
  kanban: KanbanColumnEvent | KanbanTaskEvent
  // Design-mode element mutations. The backend emits three granular event names
  // (`design_element_created` / `_updated` / `_deleted`) that all share the same
  // `DesignElementEvent` payload — see src/ai_workflow/tui/on_event_sent_design.zig.
  // The bus routes all three to this single `design` channel; the consumer can switch on
  // `event.action` to distinguish them if needed. The `designSse.ts` Pinia store treats all three
  // uniformly (re-fetch the page's element list).
  design: DesignElementEvent
  llm: SseEvent
  queue: QueueMessageEvent
  // Background-process lifecycle. The backend emits two granular names
  // (`background_process_created` / `background_process_completed`) that share the
  // `BackgroundProcessEvent` payload — see src/agentic_loop/background_process_events.zig.
  // The bus routes both to this single channel; the consumer filters by `session_id`.
  backgroundProcess: BackgroundProcessEvent
  // Skill-eval lifecycle. The backend emits three granular names (`skill_evals_run_started` /
  // `_run_finished` / `_result_applied`) that share the `SkillEvalEvent` payload — see
  // src/agentic_loop/skill_eval_events.zig.
  // The bus routes all three to this single channel; the consumer filters by `session_id` and
  // re-fetches the eval list for the Evals tab.
  skillEvals: SkillEvalEvent
  // File stage/unstage. The backend emits two granular names (`git_file_staged` /
  // `git_file_unstaged`) that share the `GitFileStageEvent` payload — see
  // src/agentic_loop/git_file_stage_events.zig.
  // The bus routes both to this single channel; the consumer filters by `cwd` and moves ONE row
  // between Staged / Changes / Untracked instead of re-fetching the whole git-status list.
  gitFileStage: GitFileStageEvent
  // Change-request state. The backend emits two granular names (`git_pr_state_merged` /
  // `git_pr_state_closed`) that share the `GitPrStateEvent` payload — see
  // src/agentic_loop/git_pr_state_events.zig.
  // The bus routes both to this single channel; the consumer filters by `cwd` and invalidates the
  // shared PR-status cache entry for `branch`, so the sidebar branch icon and the kanban card badge
  // re-read after a merge.
  gitPrState: GitPrStateEvent
}

type Listener<K extends keyof SseEventMap> = (event: SseEventMap[K]) => void

export interface SseBus {
  /**    * Register a listener for events of `type`. Returns an unsubscribe function. The same `cb`
   * registered twice for the same `type` counts twice (callers must dedupe themselves). No-op if
   * the bus is not yet installed. */
  on<K extends keyof SseEventMap>(type: K, cb: Listener<K>): () => void
  /** Remove a previously-registered listener. No-op if `cb` was not
   * registered for `type`. No-op if the bus is not yet installed. */
  off<K extends keyof SseEventMap>(type: K, cb: Listener<K>): void
  /**    * Reactive read of the current SSE connection state (one of `connecting | open | reconnecting |
   * closed | failed`). Updates synchronously on every state transition emitted by the underlying
   * `SseClient`. */
  readonly state: ShallowRef<SseState>
  /**    * Force a reconnect of the global (non-session-scoped) channels and reset the attempt counter.
   * Use this for a user-driven "Retry" button on the `failed` badge. No-op if the bus is not yet
   * installed. */
  reconnectGlobal(): void
  /**    * Close the bus. Terminal — stops all streams, clears retry timers, leaves the bus uninstalled (a
   * subsequent `installSseBus` rebuilds it). Safe to call multiple times. */
  close(): void
  /** Which role THIS window plays when cross-tab sharing is active: `leader` owns the single
   * EventSource, `follower` receives events over the BroadcastChannel. `off` = sharing disabled
   * (every window opens its own connection, the pre-tab-sharing behaviour). */
  /** Optional so existing test doubles typed as `SseBus` stay valid. */
  readonly tabRole?: ShallowRef<TabSharingRole>
  /** Subscribe to "your view may be stale, refresh from the API" signals. Fires when this window
   * takes over the shared connection (events emitted during the handover gap reached nobody) and
   * when it returns from being hidden long enough to have been frozen/throttled. Coalesced. */
  /** Returns an unsubscribe function. No-op when tab sharing is off, because a window that holds
   * its own connection never misses a delivery. */
  readonly onResync?: (cb: (reason: string) => void) => () => void
  /** Subscribe to SSE connection-state transitions (`connecting | open | reconnecting | closed |
   * failed`). */
  /** Prefer this over reaching for `__getSseBusGlobalClient()`: with cross-tab sharing the
   * underlying `SseClient` is created INSIDE the `onBecomeLeader` callback, so it does not exist
   * yet when a component's `onMounted` runs. */
  /** A subscriber registered on the client at that moment is silently dropped (`?.` short-circuits
   * on null) and never sees the first `open` - which is exactly how `App.vue`'s
   * `fetchInitialWorkers` stopped firing and the sidebar lost its processing spinners. */
  /** Bus-level subscribers are held for the bus's lifetime and replayed onto every client the bus
   * opens, so they survive leader handover and reconnects. Returns an unsubscribe function. */
  readonly onStateChange?: (cb: (s: SseState) => void) => () => void
}

export type TabSharingRole = 'off' | 'leader' | 'follower'

/** Install options — all optional; the defaults are what production uses. `tabSharing` (default
 * `'auto'`): open ONE EventSource for the whole browser profile and fan events out to the other
 * tabs over a `BroadcastChannel`. */
/** Browsers cap HTTP/1.1 connections per origin at ~6, so before this every open tab consumed a
 * slot and the 7th tab could not stream at all. */
/** `'auto'` resolves to OFF under vitest (`import.meta.env.MODE === 'test'`) because the jsdom
 * environment leaks Node's `BroadcastChannel`, which would otherwise push every existing SSE suite
 * onto the asynchronous election path. Tests that exercise sharing pass `'on'` explicitly. */
export interface SseBusInstallOptions {
  tabSharing?: 'auto' | 'on' | 'off'
  /** Test seam: how to open the cross-tab channel. */
  channelFactory?: (name: string) => TabChannelLike
  /** Test seams for the coordinator's timings/visibility. */
  tabChannelOptions?: Pick<
    TabChannelOptions,
    | 'channelName'
    | 'tabId'
    | 'isVisible'
    | 'heartbeatMs'
    | 'leaderTimeoutMs'
    | 'electionJitterMs'
    | 'hiddenTakeoverDelayMs'
  >
}

function resolveTabSharing(mode: 'auto' | 'on' | 'off'): boolean {
  if (mode === 'on') return true
  if (mode === 'off') return false
  const env = (import.meta as unknown as { env?: { MODE?: string } }).env
  if (env?.MODE === 'test') return false
  return (
    typeof (globalThis as unknown as { BroadcastChannel?: unknown }).BroadcastChannel === 'function'
  )
}

let _instance: SseBus | null = null

// Module-level handle to the current `dispatch` function. Populated by `installSseBus` (which owns
// the listener Maps in its closure) and read by `__dispatchSseBus` (the test injection point).
// Setting this to null in `__resetSseBus` / `close()` ensures the test escape hatch becomes a no-op
// once the bus is torn down.
type DispatchFn = <K extends keyof SseEventMap>(type: K, event: SseEventMap[K]) => void
let _dispatch: DispatchFn | null = null

// Module-level handle to the currently-installed global SseClient. Populated by `installSseBus`
// (and by `__setSseBusGlobalClient` when tests swap the client). Read by `__getSseBusGlobalClient`
// so tests can assert which client is wired in.
// Cleared in `close()` and `__resetSseBus` so a fresh test starts with `null`.
let _globalClient: SseClient | null = null

// Module-level unsubscribe for the `onStateChange` listener that mirrors the global SseClient's
// state into the bus's public `state` ShallowRef.
// Stashed here so `__setSseBusGlobalClient` can detach the OLD client's listener before swapping —
// without this handle, replacing the client would leak the old listener (each `onStateChange` call
// adds to the array without bound).
let _stateUnsub: (() => void) | null = null

// Bus-level connection-state subscribers.
// Held for the bus's LIFETIME (not per client) and replayed onto every client `openClient` creates,
// so a component that subscribes in `onMounted` still sees the first `open` even though the client
// does not exist yet when tab sharing defers its creation to the `onBecomeLeader` callback.
const _stateSubs = new Set<(s: SseState) => void>()

// Fan a connection-state transition out to every bus-level subscriber.
// Module-scoped (not inside `installSseBus`) because both the `openClient` closure AND the
// module-level `__setSseBusGlobalClient` wire client listeners — a closure-local helper would be
// invisible to the latter, which is the leader-handover path.
function notifyStateSubs(s: SseState): void {
  for (const cb of _stateSubs) {
    try {
      cb(s)
    } catch (err) {
      console.error('[sseBus] onStateChange subscriber threw:', err)
    }
  }
}

// Module-level handle to the cross-tab coordinator when tab sharing is active
// (null on the legacy solo path and in tests that do not opt in). `close()`
// tears it down so a later `installSseBus` starts a fresh election.
let _tabChannel: TabChannel | null = null

export function installSseBus(_app?: App, options?: SseBusInstallOptions): SseBus {
  if (_instance) return _instance

  // Per-type listener Sets. Each channel's listeners live in their
  // own Set so `on('worker', cb)` doesn't accidentally fire on
  // session events.
  const listeners: { [K in keyof SseEventMap]: Set<Listener<K>> } = {
    worker: new Set<Listener<'worker'>>(),
    session: new Set<Listener<'session'>>(),
    kanban: new Set<Listener<'kanban'>>(),
    design: new Set<Listener<'design'>>(),
    llm: new Set<Listener<'llm'>>(),
    queue: new Set<Listener<'queue'>>(),
    backgroundProcess: new Set<Listener<'backgroundProcess'>>(),
    skillEvals: new Set<Listener<'skillEvals'>>(),
    gitFileStage: new Set<Listener<'gitFileStage'>>(),
    gitPrState: new Set<Listener<'gitPrState'>>(),
  }

  const state = shallowRef<SseState>('closed')
  const sharing = resolveTabSharing(options?.tabSharing ?? 'auto')
  const tabRole = shallowRef<TabSharingRole>(sharing ? 'follower' : 'off')
  // Listeners for "your view may be stale" signals (see `SseBus.onResync`).
  const resyncListeners = new Set<(reason: string) => void>()

  function notifyResync(reason: string): void {
    // oxlint-disable-next-line unicorn/no-useless-spread -- snapshot copy: a listener may unsubscribe itself during notify.
    for (const cb of [...resyncListeners]) {
      try {
        cb(reason)
      } catch (e) {
        // A buggy refresh callback must not break the coordinator.
        console.error('[sseBus] resync listener threw:', e)
      }
    }
  }
  // The client THIS window created (the install-time one). Kept so `close()`
  // can still tear it down after a test swapped `_globalClient`, preserving the
  // defensive fallback the pre-tab-sharing code had.
  let createdClient: SseClient | null = null
  if (sharing) {
    // We are joining a shared connection: its state is unknown until the leader
    // reports in, and 'connecting' is the honest initial value.
    state.value = 'connecting'
  }

  // Build the single global EventSource carrying ALL channels. The bus does NOT open a second
  // EventSource per chat (the v1 refcount design was reverted; see
  // docs/plans/2026-06-30-single-sse-all-sessions-design.md).
  // Listeners for 'llm', 'queue', and 'backgroundProcess' filter by event.session_id on the JS side
  // — defense-in-depth against any backend routing regression. Design listeners filter by
  // `event.workspace_id` in the `designSse.ts` store.
  // With tab sharing on (see `sseTabChannel.ts`) this runs ONLY in the leader tab; followers get
  // the same events forwarded over the BroadcastChannel.
  function openClient(): void {
    if (_globalClient) return
    const client: SseClient = createUnifiedSseConnection({
      channels: {
        workers: (e) => forward('worker', e),
        sessions: (e) => forward('session', e),
        kanban: (e) => forward('kanban', e),
        // Design-mode element events. The `designSse` Pinia store subscribes via `bus.on('design',
        // cb)` to receive all three action variants (created/updated/deleted) on the same callback
        // and re-fetch the page's element list.
        design: (e) => forward('design', e),
        // Bare 'llm' and bare 'queue' — backend broadcasts all sessions'
        // events on central keys. Frontend filter is `event.session_id ===
        // mySessionId.value` inside each listener.
        llm: { onEvent: (e) => forward('llm', e) },
        queue: { onEvent: (e) => forward('queue', e) },
        // Background-process lifecycle — same central-broadcast pattern:
        // backend emits on "background_process", frontend filters by
        // `event.session_id` in BackgroundCommandsPopup.vue.
        backgroundProcess: (e) => forward('backgroundProcess', e),
        // Skill-eval lifecycle — same central-broadcast pattern: backend
        // emits on "skill_evals", frontend filters by `event.session_id`
        // in the Evals tab's store.
        skillEvals: (e) => forward('skillEvals', e),
        // File stage/unstage — same central-broadcast pattern: backend emits on "git_file_stage",
        // frontend filters by `event.cwd` in SidebarDiffPanel.vue and moves ONE row instead of
        // re-fetching the whole git-status list.
        gitFileStage: (e) => forward('gitFileStage', e),
        // Change-request state — same central-broadcast pattern: backend emits on "git_pr_state",
        // frontend filters by `event.cwd` in the bridge that invalidates the shared PR-status cache
        // (helpers/prStatusCache.ts), so a merge in ANOTHER tab still recolours this one's badges.
        gitPrState: (e) => forward('gitPrState', e),
      },
      onError: (err) => {
        console.error('[sseBus] global SSE failed permanently:', err)
      },
      onConnected: () => {
        console.log('[sseBus] global SSE connected')
      },
    })

    // Mirror SseClient state into our ShallowRef so the badge can read it. `getState()` returns the
    // initial value ('connecting', set by createSseClient); subsequent transitions arrive via
    // `onStateChange`.
    // The unsub is stashed in a module-level handle so `__setSseBusGlobalClient` can detach it
    // before swapping the client (otherwise the OLD client's listener would keep firing into the
    // NEW client's ShallowRef).
    state.value = client.getState()
    _stateUnsub = client.onStateChange((s, _info: SseStateInfo) => {
      state.value = s
      // Followers show the leader's state (the shared connection is theirs too).
      _tabChannel?.broadcastState(s)
      notifyStateSubs(s)
    })
    _globalClient = client
    createdClient = client
    tabRole.value = sharing ? 'leader' : 'off'
  }

  function closeClient(reason: string): void {
    if (_stateUnsub) {
      _stateUnsub()
      _stateUnsub = null
    }
    // Bus-level subscribers die with the bus: a later `installSseBus`
    // must not replay transitions into callbacks registered against
    // the previous instance.
    _stateSubs.clear()
    const c = _globalClient
    _globalClient = null
    if (c) {
      try {
        c.close(reason)
      } catch {
        /* already terminal */
      }
    }
    if (sharing) {
      tabRole.value = 'follower'
      // Until the next leader reports in, the shared connection's state is
      // unknown — 'connecting' is the honest value (the badge shows "live").
      state.value = 'connecting'
    }
  }

  /** Deliver a locally-received event: to this window's listeners, and (from the
   * leader) to every other tab so they behave as if they held the connection. */
  function forward<K extends keyof SseEventMap>(type: K, event: SseEventMap[K]): void {
    dispatch(type, event)
    _tabChannel?.broadcastEvent(type, event)
  }

  function dispatch<K extends keyof SseEventMap>(type: K, event: SseEventMap[K]): void {
    const set = listeners[type] as Set<Listener<K>>
    for (const cb of set) {
      try {
        cb(event)
      } catch (e) {
        // A buggy listener must not take down the SseClient's
        // `onEvent` callback (or any sibling listeners). Log to
        // console.error and keep iterating.
        console.error(`[sseBus] ${type} listener threw:`, e)
      }
    }
  }

  // Expose `dispatch` to the module-level `__dispatchSseBus` so tests can inject synthetic events
  // directly (bypassing the SseClient). Stored AFTER the closures are wired so the test escape
  // hatch works from the first `installSseBus` call.
  _dispatch = dispatch

  // Start the connection. With tab sharing on, the coordinator decides whether THIS window owns it
  // (leader) or receives events from the tab that does — so the BrowserProfile keeps exactly one
  // SSE connection per origin no matter how many tabs are open.
  if (sharing) {
    _tabChannel = createTabChannel({
      ...options?.tabChannelOptions,
      channelFactory: options?.channelFactory,
      onBecomeLeader: () => openClient(),
      onLoseLeadership: () => closeClient('lost cross-tab leadership'),
      onRemoteEvent: (channelName, payload) => {
        // Deliver a leader-forwarded event exactly as if this tab had received
        // it from its own EventSource.
        dispatch(channelName as keyof SseEventMap, payload as never)
      },
      onRemoteState: (s) => {
        state.value = s as SseState
      },
      onRemoteReconnect: () => _globalClient?.reconnect('user-clicked-retry-or-bus-reconnect'),
      onResync: (reason) => notifyResync(reason),
      onRoleChange: (role) => {
        tabRole.value = role
      },
    })
    _tabChannel.start()
  } else {
    openClient()
  }

  _instance = {
    on<K extends keyof SseEventMap>(type: K, cb: Listener<K>): () => void {
      ;(listeners[type] as Set<Listener<K>>).add(cb)
      return () => {
        ;(listeners[type] as Set<Listener<K>>).delete(cb)
      }
    },
    onStateChange(cb: (s: SseState) => void): () => void {
      _stateSubs.add(cb)
      return () => {
        _stateSubs.delete(cb)
      }
    },

    off<K extends keyof SseEventMap>(type: K, cb: Listener<K>): void {
      ;(listeners[type] as Set<Listener<K>>).delete(cb)
    },
    state,
    tabRole,
    onResync(cb: (reason: string) => void): () => void {
      // With sharing off this window owns its connection and cannot miss
      // deliveries, so the signal never fires — return a working no-op so
      // callers can subscribe unconditionally.
      resyncListeners.add(cb)
      return () => {
        resyncListeners.delete(cb)
      }
    },
    reconnectGlobal(): void {
      // With cross-tab sharing, only the leader holds a connection — ask it to
      // reconnect (a no-op round trip when we ARE the leader).
      if (_tabChannel) {
        _tabChannel.requestReconnect()
        return
      }
      // Read through the module-level `_globalClient` handle at call time (not the closure-scoped
      // client from install time) so a swap via `__setSseBusGlobalClient` takes effect here.
      // The optional chain is defensive — `_globalClient` could be null after a `close()` followed
      // by `reconnectGlobal()` on a torn-down bus (which `SseBus.close()` already protects against
      // by nulling `_instance`, but tests sometimes poke this).
      // NEW (sse-disconnect-diagnosis): pass a human-readable reason so the next DISCONNECT
      // DIAGNOSIS log attributes the reconnect to "user clicked Retry" instead of an unknown
      // caller.
      _globalClient?.reconnect('user-clicked-retry-or-bus-reconnect')
    },
    close(): void {
      // Leave the cross-tab election FIRST: a leader announces `down` while it
      // tears down, so the remaining tabs take over without waiting for the
      // heartbeat timeout.
      const ch = _tabChannel
      _tabChannel = null
      if (ch) ch.close()
      // Read through the module-level `_globalClient` handle at call time (not the closure-scoped
      // client from install time) so a swap via `__setSseBusGlobalClient` takes effect here.
      // The `_globalClient ?? createdClient` fallback is defensive — in production the two point to
      // the same object, but a test that nulled `_globalClient` via `__resetSseBus` between install
      // and close still gets the original closed.
      const gc = _globalClient ?? createdClient
      // NEW (sse-disconnect-diagnosis): pass a reason so the subsequent state log knows "bus was
      // torn down" — useful when correlating SSE disconnects with App.vue unmount or HMR re-mounts.
      gc?.close('bus-torn-down')
      // Detach the state-mirror listener and clear the test-only
      // handles so a subsequent `installSseBus` starts clean (and
      // `__getSseBusGlobalClient()` returns null after close).
      if (_stateUnsub) {
        _stateUnsub()
        _stateUnsub = null
      }
      _globalClient = null
      createdClient = null
      _dispatch = null
      _instance = null
    },
  }
  return _instance
}

export function useSseBus(): SseBus {
  if (!_instance) throw new Error('useSseBus called before installSseBus')
  return _instance
}

/**  * Test-only: clears the singleton. Closes the global client (via `bus.close()`) so the EventSource
 * stub's retry timer / state listeners are torn down before the next test installs a fresh bus.
 * Safe to call before `installSseBus` (no-op). */
export function __resetSseBus(): void {
  if (_instance) {
    _instance.close()
  }
  // `close()` already nulls `_stateUnsub` + `_globalClient` + `_dispatch` + `_tabChannel`, but be
  // defensive in case `__resetSseBus` is called before `installSseBus` (when `_instance` is null)
  // AND a previous test leaked module-level state via a partial swap.
  _globalClient = null
  if (_tabChannel) {
    try {
      _tabChannel.close()
    } catch {
      /* already closed */
    }
    _tabChannel = null
  }
  if (_stateUnsub) {
    _stateUnsub()
    _stateUnsub = null
  }
  _instance = null
  _dispatch = null
}

/**  * Test-only: dispatches a synthetic event into the bus's listener Maps. Bypasses the SseClient
 * entirely (the test owns the event payload shape — `as any` casts at the call site are intentional
 * to keep this helper loose). No-op if the bus is not installed. */
export function __dispatchSseBus<K extends keyof SseEventMap>(
  type: K,
  event: SseEventMap[K],
): void {
  _dispatch?.(type, event)
}

/** Test-only: replaces the global SseClient and re-wires the state mirror. Closes the previous
 * global client (if any) and detaches the old `onStateChange` listener before subscribing the new
 * client's listener. */
/** Updates the bus's public `state` ShallowRef to the new client's initial state so observers see
 * the swap immediately. No-op if the bus is not installed. */
/** Used by the migration test files (Chunks 5-7) to drive the SSE state badge behavior — the
 * production code paths under test react to `bus.state.value` transitions, not to the underlying
 * `EventSource` lifecycle. */
export function __setSseBusGlobalClient(client: SseClient): void {
  if (!_instance) return
  // Detach the OLD client's state listener first so it doesn't keep
  // firing into the bus's ShallowRef after we swap.
  if (_stateUnsub) {
    _stateUnsub()
    _stateUnsub = null
  }
  // Close the old client (terminal — no further state transitions). Only when it's a different
  // instance — the same object passed in twice would close-then-resubscribe-onto-the-same-thing,
  // which is fine but wasteful.
  if (_globalClient && _globalClient !== client) {
    _globalClient.close()
  }
  _globalClient = client
  _stateUnsub = client.onStateChange((s, _info: SseStateInfo) => {
    // Defensive: `_instance` could theoretically be nulled out
    // by a concurrent `close()` between the check above and this
    // callback firing.
    if (_instance) {
      _instance.state.value = s
    }
    notifyStateSubs(s)
  })
  // Update the public ShallowRef so observers see the new initial
  // state synchronously — they shouldn't have to wait for the new
  // client to emit its first transition.
  _instance.state.value = client.getState()
}

/**  * Test-only: returns the currently-installed global SseClient, or null if the bus is not yet
 * installed (or has been closed). Useful for asserting that `__setSseBusGlobalClient` swapped the
 * right client, and for spying on `.close()` to verify cleanup. */
export function __getSseBusGlobalClient(): SseClient | null {
  return _globalClient
}
