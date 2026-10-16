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

// Worker activity - provided to child components A SECOND, additive key beside `processingState`,
// not a widening of it. `processingState` is a boolean map read by eight components; making it
// carry timestamps would touch every one of them.
const workerActivity = ref<Record<string, WorkerActivity>>({})
provide('workerActivity', workerActivity)

// One app-wide 1s ticker, provided so every <WorkerElapsedChip> can render a counting label without
// owning an interval of its own. A sidebar mounts one chip per row; a timer per row would be a
// timer per row.
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

// Handle worker event from the SSE bus. Migrated from an App.vue-owned SseClient (Chunk 5 of the
// unify-SSE plan): the bus now owns the `/api/events?channels=workers,sessions,kanban` connection,
// and App.vue only subscribes to the `worker` channel via `bus.on('worker', cb)`.
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
      // Fold the event's timestamps into the activity map. `created` is the only event that carries
      // a real `created_at`, so an `updated` must preserve whatever start time the row already has
      // — otherwise every heartbeat would reset the elapsed clock to zero.
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

// Unix-ms from a wire value that may be a number (the SSE `last_activity` field) or a numeric
// string (the REST `Worker` shape — every `Row.values` entry is a `[]u8`, so the INTEGER column is
// serialised as a string). Seconds and milliseconds are both accepted.
function toMillis(value: number | string | null | undefined): number | null {
  const n = typeof value === 'number' ? value : Number(value)
  if (!Number.isFinite(n) || n <= 0) return null
  // Anything below ~2001-09-09 in seconds is really milliseconds already.
  return n < 1e11 ? n * 1000 : n
}

// Unix-ms from `worker.created_at`, which is a SQLite `CURRENT_TIMESTAMP` UTC string ("YYYY-MM-DD
// HH:MM:SS"). The space separator is not valid ISO, so it is swapped for 'T' and marked UTC — the
// same normalisation `formatTaskTimestamp` does. Returns null for empty/unparseable input.
function parseWorkerTimestamp(value: string | null | undefined): number | null {
  if (!value) return null
  const normalized = value.includes('T') ? value : value.replace(' ', 'T')
  const ms = new Date(normalized.endsWith('Z') ? normalized : `${normalized}Z`).getTime()
  return Number.isFinite(ms) ? ms : null
}

// Fetch initial worker state (fallback for when SSE connection starts) Throttled: bus.state flips
// to 'open' on every reconnect, and without a guard each reconnect would refetch workers (the
// columns/workers storm in the Network panel). Skips when the last fetch was <10s ago.
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
        // The REST list is the only source that carries `created_at`, so it is where the elapsed
        // clock gets its real start time. A worker row with an unparseable `created_at` falls back
        // to "now" rather than being dropped — the chip still shows a live run, just a young one.
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
  // `installSseBus(_app?: App)` takes an optional `App` parameter for future `provide()` use; the
  // module-singleton implementation doesn't use it, so we pass nothing.
  const bus = installSseBus()
  offWorker = bus.on('worker', handleWorkerEvent)

  // PR-status badges (the sidebar's RECENT branch icon, the kanban card badge) read a shared 60s
  // cache — see helpers/prStatusCache.ts.
  offPrState = subscribePrStatusEvents(bus)

  // Tab titles for chat sessions.
  useTabsStore().initTitleFeed()

  // Frontend log client (POST /api/logs) is DISABLED — the block below is now a harmless no-op:
  // `window.__pabrikLogCtx` is never set by `main.ts`, so `logCtx` is undefined and the `if` is
  // skipped. Kept so re-enabling is a one-line change in `main.ts`.
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
    // route.fullPath already includes path + query + hash — concatenating route.path in front
    // duplicates the path ("/app" + "/app?view=..." = "/app/app?view=..."). Use fullPath alone so
    // logged route_path matches the browser address bar.
    logCtx.getRoutePath = () => route.fullPath
    logCtx.getSessionId = () => navigationStore.sessionId || null
  }

  // Re-sync `processingState` from the DB on every (re)connect.
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
  // Close the bus. Forwards to all underlying SseClients (global + any per-session).
  useSseBus().close()
})
</script>

<template>
  <TopLoadingBar />
  <router-view />
</template>
