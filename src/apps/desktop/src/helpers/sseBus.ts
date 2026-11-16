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
  DocumentEvent,
} from '../api'

// NOTE: Plan's Chunk 1 spec imports `KanbanEvent` and `LlmChunkEvent` from `../api`, but those names don't exist in `api/index.ts` — the actual exports are …
type SseEventMap = {
  worker: WorkerEvent
  session: SessionEvent
  kanban: KanbanColumnEvent | KanbanTaskEvent
  // Design-mode element mutations.
  design: DesignElementEvent
  llm: SseEvent
  queue: QueueMessageEvent
  // Background-process lifecycle.
  backgroundProcess: BackgroundProcessEvent
  // Skill-eval lifecycle.
  skillEvals: SkillEvalEvent
  // File stage/unstage.
  gitFileStage: GitFileStageEvent
  // Change-request state.
  gitPrState: GitPrStateEvent
  // Document mutations.
  documents: DocumentEvent
}

type Listener<K extends keyof SseEventMap> = (event: SseEventMap[K]) => void

export interface SseBus {
  /** Register a listener for events of `type`. */
  on<K extends keyof SseEventMap>(type: K, cb: Listener<K>): () => void
  /** Remove a previously-registered listener. */
  off<K extends keyof SseEventMap>(type: K, cb: Listener<K>): void
  /** Reactive read of the current SSE connection state (one of `connecting | open | reconnecting | closed | failed`). */
  readonly state: ShallowRef<SseState>
  /** Force a reconnect of the global (non-session-scoped) channels and reset the attempt counter. */
  reconnectGlobal(): void
  /** Close the bus. */
  close(): void
  /** Which role THIS window plays when cross-tab sharing is active: `leader` owns the single EventSource, `follower` receives events over the BroadcastChannel. */
  readonly tabRole?: ShallowRef<TabSharingRole>
  /** Subscribe to "your view may be stale, refresh from the API" signals. */
  readonly onResync?: (cb: (reason: string) => void) => () => void
  /** Subscribe to SSE connection-state transitions (`connecting | open | reconnecting | closed | failed`). */
  readonly onStateChange?: (cb: (s: SseState) => void) => () => void
}

export type TabSharingRole = 'off' | 'leader' | 'follower'

/** Install options — all optional; the defaults are what production uses. */
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

// Module-level handle to the current `dispatch` function.
type DispatchFn = <K extends keyof SseEventMap>(type: K, event: SseEventMap[K]) => void
let _dispatch: DispatchFn | null = null

// Module-level handle to the currently-installed global SseClient.
let _globalClient: SseClient | null = null

// Module-level unsubscribe for the `onStateChange` listener that mirrors the global SseClient's state into the bus's public `state` ShallowRef.
let _stateUnsub: (() => void) | null = null

// Bus-level connection-state subscribers.
const _stateSubs = new Set<(s: SseState) => void>()

// Fan a connection-state transition out to every bus-level subscriber.
function notifyStateSubs(s: SseState): void {
  for (const cb of _stateSubs) {
    try {
      cb(s)
    } catch (err) {
      console.error('[sseBus] onStateChange subscriber threw:', err)
    }
  }
}

// Module-level handle to the cross-tab coordinator when tab sharing is active (null on the legacy solo path and in tests that do not opt in).
let _tabChannel: TabChannel | null = null

export function installSseBus(_app?: App, options?: SseBusInstallOptions): SseBus {
  if (_instance) return _instance

  // Per-type listener Sets.
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
    documents: new Set<Listener<'documents'>>(),
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
  // The client THIS window created (the install-time one).
  let createdClient: SseClient | null = null
  if (sharing) {
    // We are joining a shared connection: its state is unknown until the leader reports in, and 'connecting' is the honest initial value.
    state.value = 'connecting'
  }

  // Build the single global EventSource carrying ALL channels.
  function openClient(): void {
    if (_globalClient) return
    const client: SseClient = createUnifiedSseConnection({
      channels: {
        workers: (e) => forward('worker', e),
        sessions: (e) => forward('session', e),
        kanban: (e) => forward('kanban', e),
        // Design-mode element events.
        design: (e) => forward('design', e),
        // Bare 'llm' and bare 'queue' — backend broadcasts all sessions' events on central keys.
        llm: { onEvent: (e) => forward('llm', e) },
        queue: { onEvent: (e) => forward('queue', e) },
        // Background-process lifecycle — same central-broadcast pattern
        backgroundProcess: (e) => forward('backgroundProcess', e),
        // Skill-eval lifecycle — same central-broadcast pattern: backend emits on "skill_evals", frontend filters by `event.session_id` in the Evals tab's store.
        skillEvals: (e) => forward('skillEvals', e),
        // File stage/unstage — same central-broadcast pattern: backend emits on "git_file_stage", frontend filters by `event.cwd` in SidebarDiffPanel.vue and moves ONE …
        gitFileStage: (e) => forward('gitFileStage', e),
        // Change-request state — same central-broadcast pattern: backend emits on "git_pr_state", frontend filters by `event.cwd` in the bridge that invalidates the …
        gitPrState: (e) => forward('gitPrState', e),
        // Document mutations — the AGENT TOOL only (`document_markdown`).
        documents: (e) => forward('documents', e),
      },
      onError: (err) => {
        console.error('[sseBus] global SSE failed permanently:', err)
      },
      onConnected: () => {
        console.log('[sseBus] global SSE connected')
      },
    })

    // Mirror SseClient state into our ShallowRef so the badge can read it.
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
    // Bus-level subscribers die with the bus: a later `installSseBus` must not replay transitions into callbacks registered against the previous instance.
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
      // Until the next leader reports in, the shared connection's state is unknown — 'connecting' is the honest value (the badge shows "live").
      state.value = 'connecting'
    }
  }

  /** Deliver a locally-received event: to this window's listeners, and (from the leader) to every other tab so they behave as if they held the connection. */
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
        // A buggy listener must not take down the SseClient's `onEvent` callback (or any sibling listeners).
        console.error(`[sseBus] ${type} listener threw:`, e)
      }
    }
  }

  // Expose `dispatch` to the module-level `__dispatchSseBus` so tests can inject synthetic events directly (bypassing the SseClient).
  _dispatch = dispatch

  // Start the connection.
  if (sharing) {
    _tabChannel = createTabChannel({
      ...options?.tabChannelOptions,
      channelFactory: options?.channelFactory,
      onBecomeLeader: () => openClient(),
      onLoseLeadership: () => closeClient('lost cross-tab leadership'),
      onRemoteEvent: (channelName, payload) => {
        // Deliver a leader-forwarded event exactly as if this tab had received it from its own EventSource.
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
      // With sharing off this window owns its connection and cannot miss deliveries, so the signal never fires — return a working no-op so callers can subscribe …
      resyncListeners.add(cb)
      return () => {
        resyncListeners.delete(cb)
      }
    },
    reconnectGlobal(): void {
      // With cross-tab sharing, only the leader holds a connection — ask it to reconnect (a no-op round trip when we ARE the leader).
      if (_tabChannel) {
        _tabChannel.requestReconnect()
        return
      }
      // Read through the module-level `_globalClient` handle at call time (not the closure-scoped client from install time) so a swap via `__setSseBusGlobalClient` …
      _globalClient?.reconnect('user-clicked-retry-or-bus-reconnect')
    },
    close(): void {
      // Leave the cross-tab election FIRST: a leader announces `down` while it tears down, so the remaining tabs take over without waiting for the heartbeat timeout.
      const ch = _tabChannel
      _tabChannel = null
      if (ch) ch.close()
      // Read through the module-level `_globalClient` handle at call time (not the closure-scoped client from install time) so a swap via `__setSseBusGlobalClient` …
      const gc = _globalClient ?? createdClient
      // NEW (sse-disconnect-diagnosis): pass a reason so the subsequent state log knows "bus was torn down" — useful when correlating SSE disconnects with App.vue …
      gc?.close('bus-torn-down')
      // Detach the state-mirror listener and clear the test-only handles so a subsequent `installSseBus` starts clean (and `__getSseBusGlobalClient()` returns null …
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

/** Test-only: clears the singleton. */
export function __resetSseBus(): void {
  if (_instance) {
    _instance.close()
  }
  // `close()` already nulls `_stateUnsub` + `_globalClient` + `_dispatch` + `_tabChannel`, but be defensive in case `__resetSseBus` is called before …
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

/** Test-only: dispatches a synthetic event into the bus's listener Maps. */
export function __dispatchSseBus<K extends keyof SseEventMap>(
  type: K,
  event: SseEventMap[K],
): void {
  _dispatch?.(type, event)
}

/** Test-only: replaces the global SseClient and re-wires the state mirror. */
export function __setSseBusGlobalClient(client: SseClient): void {
  if (!_instance) return
  // Detach the OLD client's state listener first so it doesn't keep firing into the bus's ShallowRef after we swap.
  if (_stateUnsub) {
    _stateUnsub()
    _stateUnsub = null
  }
  // Close the old client (terminal — no further state transitions).
  if (_globalClient && _globalClient !== client) {
    _globalClient.close()
  }
  _globalClient = client
  _stateUnsub = client.onStateChange((s, _info: SseStateInfo) => {
    // Defensive: `_instance` could theoretically be nulled out by a concurrent `close()` between the check above and this callback firing.
    if (_instance) {
      _instance.state.value = s
    }
    notifyStateSubs(s)
  })
  // Update the public ShallowRef so observers see the new initial state synchronously — they shouldn't have to wait for the new client to emit its first transition.
  _instance.state.value = client.getState()
}

/** Test-only: returns the currently-installed global SseClient, or null if the bus is not yet installed (or has been closed). */
export function __getSseBusGlobalClient(): SseClient | null {
  return _globalClient
}
