<script setup lang="ts">
import { ref, provide, onMounted, onUnmounted } from 'vue'
import { useRoute } from 'vue-router'
import * as api from './api'
import TopLoadingBar from './components/shell/TopLoadingBar.vue'
import { installSseBus, useSseBus } from './helpers/sseBus'
import { subscribePrStatusEvents } from './helpers/prStatusCache'
import { useTabsStore } from './stores/tabs'
import { useNavigationStore } from './stores/navigation'
import { useDocumentTitle } from './composables/useDocumentTitle'
import type { WorkerActivity } from './components/WorkerElapsedChip.vue'

// LLM processing state - provided to child components
// Object mapping sessionId to processing status (using object instead of Set for better reactivity)
const processingState = ref<Record<string, boolean>>({})
provide('processingState', processingState)

// Worker activity - provided to child components
//
// A SECOND, additive key beside `processingState`, not a widening of it.
// `processingState` is a boolean map read by eight components; making it
// carry timestamps would touch every one of them. This key holds the
// richer shape only `<WorkerElapsedChip>` needs, and is populated from the
// same two sources (SSE worker events + the bootstrap refetch), so the two
// maps can never disagree about which sessions are running.
//
// `startedAt` comes from `worker.created_at`; `lastActivityAt` from
// `worker.last_activity_nano` (unix seconds on the wire). Both are
// normalised to unix MILLISECONDS here so consumers can subtract them
// from `Date.now()` without remembering which is which.
const workerActivity = ref<Record<string, WorkerActivity>>({})
provide('workerActivity', workerActivity)

// One app-wide 1s ticker, provided so every <WorkerElapsedChip> can render
// a counting label without owning an interval of its own. A sidebar mounts
// one chip per row; a timer per row would be a timer per row.
//
// Started and stopped from the two places that change whether anything is
// running — the SSE worker handler and the bootstrap refetch — i.e. from the
// event handlers that cause the change, so no component needs a watcher.
const workerNow = ref(Date.now())
provide('workerNow', workerNow)

let workerTicker: ReturnType<typeof setInterval> | null = null

const startWorkerTicker = () => {
  if (workerTicker !== null) return
  workerNow.value = Date.now()
  workerTicker = setInterval(() => {
    workerNow.value = Date.now()
  }, 1000)
}

const stopWorkerTicker = () => {
  if (workerTicker === null) return
  clearInterval(workerTicker)
  workerTicker = null
}

// The ticker exists only while at least one worker is running.
const syncWorkerTicker = () => {
  if (Object.keys(workerActivity.value).length > 0) {
    startWorkerTicker()
  } else {
    stopWorkerTicker()
  }
}

// Browser tab title follows the active session / task name.
useDocumentTitle()

// Handle worker event from the SSE bus. Migrated from an App.vue-owned
// SseClient (Chunk 5 of the unify-SSE plan): the bus now owns the
// `/api/events?channels=workers,sessions,kanban` connection, and App.vue
// only subscribes to the `worker` channel via `bus.on('worker', cb)`.
//
// The previous per-app `createUnifiedSseConnection` factory was retired
// with the unify-SSE plan — see `docs/sse-reconnect-plan.md` §1.1 for
// the two bugs the SseClient it used to wrap fixes (timer leak on
// unmount, stale timer closing a working connection).
const handleWorkerEvent = (event: api.WorkerEvent) => {
  console.log('[App] Worker event:', event)

  if (event.action === 'deleted') {
    // Remove session from processing state
    const sessionId = event.session_id || event.id
    if (sessionId && processingState.value[sessionId]) {
      const newState = { ...processingState.value }
      delete newState[sessionId]
      processingState.value = newState
    }
    // …and from the activity map, so the elapsed chip disappears with the
    // spinner rather than freezing on its last reading.
    if (sessionId && workerActivity.value[sessionId]) {
      const nextActivity = { ...workerActivity.value }
      delete nextActivity[sessionId]
      workerActivity.value = nextActivity
      syncWorkerTicker()
    }
  } else {
    // created or updated - add to processing state
    const sessionId = event.session_id || event.id
    if (sessionId) {
      processingState.value = {
        ...processingState.value,
        [sessionId]: true,
      }
      // Fold the event's timestamps into the activity map. `created` is the
      // only event that carries a real `created_at`, so an `updated` must
      // preserve whatever start time the row already has — otherwise every
      // heartbeat would reset the elapsed clock to zero.
      const prev = workerActivity.value[sessionId]
      const startedAt = parseWorkerTimestamp(event.created_at) ?? prev?.startedAt ?? Date.now()
      const lastActivityAt = toMillis(event.last_activity) ?? prev?.lastActivityAt ?? Date.now()
      workerActivity.value = {
        ...workerActivity.value,
        [sessionId]: {
          startedAt,
          lastActivityAt,
          description: event.last_activity_description || prev?.description || '',
        },
      }
      syncWorkerTicker()
    }
  }
}

// Unix-ms from a wire value that may be a number (the SSE
// `last_activity` field) or a numeric string (the REST `Worker` shape —
// every `Row.values` entry is a `[]u8`, so the INTEGER column is
// serialised as a string). Seconds and milliseconds are both accepted.
// Returns null when the value is absent or unusable, so callers can fall
// back rather than render "NaNs".
function toMillis(value: number | string | null | undefined): number | null {
  const n = typeof value === 'number' ? value : Number(value)
  if (!Number.isFinite(n) || n <= 0) return null
  // Anything below ~2001-09-09 in seconds is really milliseconds already.
  return n < 1e11 ? n * 1000 : n
}

// Unix-ms from `worker.created_at`, which is a SQLite `CURRENT_TIMESTAMP`
// UTC string ("YYYY-MM-DD HH:MM:SS"). The space separator is not valid ISO,
// so it is swapped for 'T' and marked UTC — the same normalisation
// `formatTaskTimestamp` does. Returns null for empty/unparseable input.
function parseWorkerTimestamp(value: string | null | undefined): number | null {
  if (!value) return null
  const normalized = value.includes('T') ? value : value.replace(' ', 'T')
  const ms = new Date(normalized.endsWith('Z') ? normalized : `${normalized}Z`).getTime()
  return Number.isFinite(ms) ? ms : null
}

// Fetch initial worker state (fallback for when SSE connection starts)
// Throttled: bus.state flips to 'open' on every reconnect, and without a
// guard each reconnect would refetch workers (the columns/workers storm in
// the Network panel). Skips when the last fetch was <10s ago.
let lastWorkersFetchAt = 0
const fetchInitialWorkers = async () => {
  if (Date.now() - lastWorkersFetchAt < 10_000) return
  lastWorkersFetchAt = Date.now()
  try {
    const { workers } = await api.getWorkers(undefined, 50)
    const newState: Record<string, boolean> = {}
    const newActivity: Record<string, WorkerActivity> = {}
    for (const worker of workers) {
      const sessionId = worker.session_id || worker.id
      if (sessionId) {
        newState[sessionId] = true
        // The REST list is the only source that carries `created_at`, so it
        // is where the elapsed clock gets its real start time. A worker row
        // with an unparseable `created_at` falls back to "now" rather than
        // being dropped — the chip still shows a live run, just a young one.
        newActivity[sessionId] = {
          startedAt: parseWorkerTimestamp(worker.created_at) ?? Date.now(),
          lastActivityAt: toMillis(worker.last_activity) ?? Date.now(),
          description: worker.last_activity_description || '',
        }
      }
    }
    processingState.value = newState
    workerActivity.value = newActivity
    syncWorkerTicker()
  } catch (err) {
    console.error('Failed to fetch initial workers:', err)
  }
}

let offWorker: (() => void) | null = null
let offBusOpen: (() => void) | null = null
let offPrState: (() => void) | null = null

onMounted(() => {
  // `installSseBus(_app?: App)` takes an optional `App` parameter for
  // future `provide()` use; the module-singleton implementation
  // doesn't use it, so we pass nothing. Idempotent: a second call
  // (e.g. HMR re-mount, or App.vue's own install from `main.ts`
  // mounting first) returns the same singleton.
  const bus = installSseBus()
  offWorker = bus.on('worker', handleWorkerEvent)

  // PR-status badges (the sidebar's RECENT branch icon, the kanban card badge)
  // read a shared 60s cache — see helpers/prStatusCache.ts. A merge or close
  // performed ANYWHERE invalidates it; subscribed HERE, next to the install,
  // for the same reason the title feed is: children mount before their parent,
  // so a child-side subscription can silently never attach.
  offPrState = subscribePrStatusEvents(bus)

  // Tab titles for chat sessions. Subscribed HERE, next to the install, because
  // children mount before their parent: an AppLayout-side subscription runs
  // before the bus exists and would silently never attach (that is exactly why
  // chat tabs kept the generic "Chat" label after a rename).
  useTabsStore().initTitleFeed()

  // Frontend log client (POST /api/logs) is DISABLED — the block below
  // is now a harmless no-op: `window.__pabrikLogCtx` is never set by
  // `main.ts`, so `logCtx` is undefined and the `if` is skipped. Kept
  // so re-enabling is a one-line change in `main.ts`.
  const route = useRoute()
  const navigationStore = useNavigationStore()
  const logCtx = (
    window as unknown as {
      __pabrikLogCtx:
        | {
            getRoutePath: () => string | null
            getSessionId: () => string | null
          }
        | null
        | undefined
    }
  ).__pabrikLogCtx
  if (logCtx) {
    // route.fullPath already includes path + query + hash — concatenating
    // route.path in front duplicates the path ("/app" + "/app?view=..." =
    // "/app/app?view=..."). Use fullPath alone so logged route_path matches
    // the browser address bar.
    logCtx.getRoutePath = () => route.fullPath
    logCtx.getSessionId = () => navigationStore.sessionId || null
  }

  // Re-sync `processingState` from the DB on every (re)connect. The
  // bus's underlying SseClient may have been `connecting` for a while
  // (server restart, network drop), so the previous in-memory state
  // (built from earlier `worker` events) is stale and may include
  // sessions that no longer exist or omit new ones.
  //
  // Explicit subscription on the underlying SseClient (not a reactive
  // watcher): `onStateChange` fires on every transition including the
  // reconnect path. The immediate check below covers the fast path
  // where the SseClient is already `'open'` by the time this hook runs
  // (the SseClient defers its first `start()` via `setTimeout(0)`, so
  // there's a race between bus install and subscription).
  // Subscribe on the BUS, not on the underlying client. With cross-tab
  // sharing the client is created inside `onBecomeLeader`, so it does
  // not exist yet here — `__getSseBusGlobalClient()?.onStateChange(...)`
  // short-circuited on null and this callback was never registered, so
  // the first `open` was missed and `processingState` stayed empty
  // (the sidebar's Stop-agent row and spinners never appeared).
  // Bus-level subscribers are replayed onto every client the bus opens.
  if (bus.state.value === 'open') void fetchInitialWorkers()
  offBusOpen =
    bus.onStateChange?.((s) => {
      if (s === 'open') void fetchInitialWorkers()
    }) ?? null
})

onUnmounted(() => {
  // Unsubscribe the worker listener first so any in-flight event
  // dispatched during the unmount window doesn't try to mutate
  // unmounted reactive state.
  if (offWorker) {
    offWorker()
    offWorker = null
  }
  if (offBusOpen) {
    offBusOpen()
    offBusOpen = null
  }
  if (offPrState) {
    offPrState()
    offPrState = null
  }
  useTabsStore().disposeTitleFeed()
  // The worker ticker is app-scoped, so it outlives any single chip.
  stopWorkerTicker()
  // Close the bus. Forwards to all underlying SseClients (global +
  // any per-session). Terminal — removes visibility/online listeners,
  // cancels retry timers (no timer leak that would create a dangling
  // EventSource), and nulls the singleton so a subsequent `installSseBus`
  // rebuilds from scratch.
  useSseBus().close()
})
</script>

<template>
  <TopLoadingBar />
  <router-view />
</template>
