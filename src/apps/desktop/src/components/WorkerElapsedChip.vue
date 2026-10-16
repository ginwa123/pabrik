<!--
  WorkerElapsedChip.vue — "how long has this worker been running" chip.

  Renders nothing unless the session has a live worker. When it does, it
  shows the elapsed time since the run started, and turns amber once the
  worker's last heartbeat is old enough to read as stalled.

  Two numbers, two meanings:
    - elapsed       — now - startedAt. "How long has this run been going?"
    - last activity — now - lastActivityAt. "Is it still doing anything?"

  A run can be 20 minutes old with a 2-second-old heartbeat (one long tool
  call) or 3 minutes old with a 9-minute-old heartbeat (stalled). The
  spinner alone cannot tell those apart, which is the whole point of this
  component.

  Data comes from two provide keys in App.vue:
    - `workerActivity` — a SECOND, additive key beside the boolean
      `processingState` map. Components that only need "is it running"
      keep injecting `processingState` and are untouched; this component
      opts into the richer shape.
    - `workerNow` — a single app-wide 1s ticker. App.vue starts and stops
      it from the SSE handler and the bootstrap refetch, i.e. from the
      event handlers that cause the change, so this component needs no
      watcher of its own and a sidebar of idle rows costs zero timers.

  Everything below is therefore derived state: no interval, no lifecycle
  hook, no reaction to change.
-->
<script setup lang="ts">
import { computed, inject, ref, type Ref } from 'vue'
import { formatElapsedDuration, isWorkerStale } from '../helpers/elapsedDuration'

/** One worker's activity, as tracked by App.vue. */
export interface WorkerActivity {
  /** Unix ms the run started (`worker.created_at`). */
  startedAt: number
  /** Unix ms of the last heartbeat (`worker.last_activity_nano`). */
  lastActivityAt: number
  /** Human-facing "what is it doing" label from the backend. */
  description: string
}

const props = withDefaults(
  defineProps<{
    sessionId: string
    /** `chip` — a pill with the elapsed time (sidebar rows, kanban card).
     * `text` — bare text, for surfaces that already carry a status line
     *          (kanban row metadata, task-detail rows). */
    variant?: 'chip' | 'text'
    /** A distinct `data-testid` lets each surface target its own chip. */
    testId?: string
  }>(),
  { variant: 'chip', testId: 'worker-elapsed-chip' },
)

// Additive sibling of `processingState`. The default keeps the component
// renderable in isolation (a unit test, or a host that never provided it).
const workerActivity = inject<Ref<Record<string, WorkerActivity>>>(
  'workerActivity',
  // eslint-disable-next-line @typescript-eslint/no-explicit-any -- a fresh ref per mount is the documented inject default.
  ref({}) as any,
)

// The shared app-wide ticker. Falls back to a static "now" so an isolated
// mount still renders a label rather than nothing.
const workerNow = inject<Ref<number>>('workerNow', ref(Date.now()))

const activity = computed(() => workerActivity.value[props.sessionId] ?? null)
const isRunning = computed(() => activity.value !== null)

const elapsedLabel = computed(() => {
  const a = activity.value
  if (!a) return ''
  return formatElapsedDuration(workerNow.value - a.startedAt)
})

const stale = computed(() => {
  const a = activity.value
  if (!a) return false
  return isWorkerStale(a.lastActivityAt, workerNow.value)
})

const title = computed(() => {
  const a = activity.value
  if (!a) return ''
  const parts = [`Running for ${elapsedLabel.value}`]
  if (a.description) parts.push(a.description)
  return parts.join(' · ')
})
</script>

<template>
  <span
    v-if="isRunning && elapsedLabel"
    class="worker-elapsed"
    :class="[`worker-elapsed--${variant}`, { 'worker-elapsed--stale': stale }]"
    :data-testid="testId"
    :data-stale="stale ? 'true' : 'false'"
    :title="title"
    >{{ elapsedLabel }}</span
  >
</template>

<style scoped>
.worker-elapsed {
  display: inline-flex;
  align-items: center;
  font-variant-numeric: tabular-nums;
  white-space: nowrap;
  flex-shrink: 0;
  color: var(--color-yellow);
}

.worker-elapsed--chip {
  font-size: var(--text-micro);
  font-weight: 600;
  line-height: 1.5;
  padding: 1px 6px;
  border-radius: 999px;
  background-color: rgba(196, 178, 138, 0.16);
}

.worker-elapsed--text {
  font-size: var(--text-micro);
}

/* Amber = the heartbeat is old enough that the run is about to be reaped
   by the stale-worker cron. Same threshold family the backend enforces,
   just earlier, so the warning is observable before the row vanishes. */
.worker-elapsed--stale {
  color: var(--color-orange);
}

.worker-elapsed--chip.worker-elapsed--stale {
  background-color: rgba(182, 146, 123, 0.16);
}
</style>
