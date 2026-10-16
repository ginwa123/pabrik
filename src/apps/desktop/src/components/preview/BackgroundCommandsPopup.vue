<script setup lang="ts">
import { computed, onMounted, onUnmounted, onUpdated, ref } from 'vue'
import {
  ApiError,
  getBackgroundProcessLog,
  getBackgroundProcesses,
  type BackgroundProcess,
} from '../../api'
import { formatRelativeTime } from '../../helpers/relativeTime'
import UiIcon from '../ui/UiIcon.vue'
import { useSseBus } from '../../helpers/sseBus'

const props = defineProps<{
  sessionId: string
}>()

const LOG_POLL_MS = 2000
const LOG_MAX_BYTES = 20480

const processes = ref<BackgroundProcess[]>([])
const listError = ref<string | null>(null)
// True while `fetchList` is in flight. Without it the "No background commands for this session"
// empty state fires on every open — a false statement, since the popup is opened precisely BECAUSE
// commands are running.
const isLoadingList = ref(false)
const show = ref(false)
const expandedPid = ref<number | null>(null)
const logContent = ref<Record<number, string>>({})
const logLoading = ref<Record<number, boolean>>({})
const logError = ref<Record<number, string | null>>({})
const logTruncated = ref<Record<number, boolean>>({})
const logTotalBytes = ref<Record<number, number>>({})

const runningCount = computed(() => processes.value.filter((p) => p.running).length)

let logTimer: ReturnType<typeof setInterval> | null = null
let offBg: (() => void) | null = null
let offQueue: (() => void) | null = null
let offResync: (() => void) | null = null
let disposed = false

const findProcess = (pid: number): BackgroundProcess | undefined =>
  processes.value.find((p) => p.pid === pid)

const formatStartedAt = (startedAt: number): string => {
  // Backend `started_at` is unix SECONDS (see background_processes_list.zig
  // fixtures: 1700000000). formatRelativeTime accepts unix-MS strings or
  // SQLite datetime strings, so convert seconds -> ms string.
  if (!startedAt) return 'now'
  return formatRelativeTime(String(startedAt * 1000))
}

const fullDateTitle = (startedAt: number): string => {
  if (!startedAt) return ''
  return new Date(startedAt * 1000).toLocaleString()
}

const fetchList = async (): Promise<void> => {
  const sid = props.sessionId
  if (!sid) return
  isLoadingList.value = true
  try {
    const data = await getBackgroundProcesses(sid)
    if (disposed || props.sessionId !== sid) return
    processes.value = data.processes ?? []
    listError.value = null
    // A list refresh can flip the expanded row to completed — stop its
    // 2s tail poll (the log stays visible, just no longer live).
    if (expandedPid.value !== null) {
      const proc = findProcess(expandedPid.value)
      if (proc && !proc.running) stopLogTimer()
    }
  } catch (err) {
    if (disposed || props.sessionId !== sid) return
    console.error('[BackgroundCommands] list fetch failed:', err)
    listError.value = 'Failed to load background commands'
  } finally {
    // Cleared on BOTH paths so a failed fetch cannot park the skeleton.
    isLoadingList.value = false
  }
}

const fetchLog = async (pid: number): Promise<void> => {
  const sid = props.sessionId
  if (!sid) return
  logLoading.value = { ...logLoading.value, [pid]: true }
  try {
    const data = await getBackgroundProcessLog(sid, pid, LOG_MAX_BYTES)
    if (disposed || props.sessionId !== sid) return
    logContent.value = { ...logContent.value, [pid]: data.content ?? '' }
    logTruncated.value = { ...logTruncated.value, [pid]: data.truncated }
    logTotalBytes.value = { ...logTotalBytes.value, [pid]: data.total_bytes }
    logError.value = { ...logError.value, [pid]: null }
  } catch (err) {
    if (disposed || props.sessionId !== sid) return
    console.error('[BackgroundCommands] log fetch failed:', err)
    if (err instanceof ApiError && err.status === 404) {
      logError.value = { ...logError.value, [pid]: 'process not found' }
    } else {
      logError.value = { ...logError.value, [pid]: 'Failed to load log' }
    }
  } finally {
    if (!disposed && props.sessionId === sid) {
      logLoading.value = { ...logLoading.value, [pid]: false }
    }
  }
}

const stopLogTimer = (): void => {
  if (logTimer) {
    clearInterval(logTimer)
    logTimer = null
  }
}

const startLogTimer = (pid: number): void => {
  stopLogTimer()
  logTimer = setInterval(() => {
    const proc = findProcess(pid)
    if (!proc || !proc.running) {
      stopLogTimer()
      return
    }
    void fetchLog(pid)
  }, LOG_POLL_MS)
}

const toggleExpand = (pid: number): void => {
  if (expandedPid.value === pid) {
    expandedPid.value = null
    stopLogTimer()
    return
  }
  expandedPid.value = pid
  void fetchLog(pid)
  const proc = findProcess(pid)
  if (proc?.running) startLogTimer(pid)
  else stopLogTimer()
}

const refreshLog = (pid: number): void => {
  void fetchLog(pid)
}

const handleClose = (): void => {
  show.value = false
}

const refreshList = (): void => {
  void fetchList()
}

const unsubscribeAll = (): void => {
  if (offBg) {
    offBg()
    offBg = null
  }
  if (offQueue) {
    offQueue()
    offQueue = null
  }
  if (offResync) {
    offResync()
    offResync = null
  }
}

const subscribePush = (): void => {
  unsubscribeAll()
  // The global bus is installed once by App.vue; component specs and
  // isolated mounts may not have it — never throw from here.
  try {
    const bus = useSseBus()
    const sid = props.sessionId
    // Primary: dedicated background-process lifecycle events
    // (`background_process_created` on spawn, `background_process_completed`
    // on exit — see background_process_events.zig). No polling.
    offBg = bus.on('backgroundProcess', (event) => {
      if (disposed) return
      if (event.session_id !== sid && event.session_id !== props.sessionId) return
      refreshList()
    })
    // Fallback: completion also queues a message (`queue_queued` via
    // insertQueueMessage), so ANY queue event for this session refreshes
    // too — covers backends that predate the new channel.
    offQueue = bus.on('queue', (event) => {
      if (disposed) return
      if (event.session_id !== sid && event.session_id !== props.sessionId) return
      refreshList()
    })
    // Missed events during leader-takeover / return-from-hidden:
    // re-fetch from REST (same pattern as ChatView loadChatHistory).
    if (bus.onResync) {
      offResync = bus.onResync(() => {
        if (disposed) return
        if (!props.sessionId || props.sessionId !== sid) return
        refreshList()
      })
    }
  } catch (err) {
    console.warn('[BackgroundCommands] SSE bus unavailable (push refresh skipped):', err)
  }
}

const resetForSession = (sid: string): void => {
  processes.value = []
  listError.value = null
  expandedPid.value = null
  logContent.value = {}
  logLoading.value = {}
  logError.value = {}
  logTruncated.value = {}
  logTotalBytes.value = {}
  stopLogTimer()
  if (!sid) {
    unsubscribeAll()
    return
  }
  // Push-driven: immediate fetch on mount/session-switch, then SSE only.
  // Manual refresh (dialog Refresh button) + resync cover missed events.
  void fetchList()
  subscribePush()
}

// Reset on session switch (prev-value guard on update — same reset the
// watcher did; mount is covered by the onMounted reset below).
let prevPopupSessionId = props.sessionId
onUpdated(() => {
  const newSid = props.sessionId
  if (newSid === prevPopupSessionId) return
  prevPopupSessionId = newSid
  resetForSession(newSid)
})

onMounted(() => {
  disposed = false
  resetForSession(props.sessionId)
})

onUnmounted(() => {
  disposed = true
  stopLogTimer()
  unsubscribeAll()
})
</script>

<template>
  <!-- Pill — hidden when nothing is running (cleaner composer footer). -->
  <button
    v-if="runningCount > 0"
    data-testid="bg-commands-pill"
    @click="show = true"
    class="flex items-center gap-1.5 px-3 py-1.5 rounded-lg text-dense transition-all duration-200 hover:scale-105"
    style="
      background-color: var(--semantic-card-bg);
      border: 1px solid var(--color-border);
      cursor: pointer;
    "
    :title="`${runningCount} background command${runningCount !== 1 ? 's' : ''} running — click to view output`"
  >
    <span class="bg-running-dot" aria-hidden="true"></span>
    <UiIcon name="keyboard" />
    <span style="color: var(--semantic-text)">{{ runningCount }}</span>
    <span style="color: var(--semantic-text-dim)">running</span>
  </button>

  <Teleport to="body">
    <Transition name="modal">
      <div
        v-if="show"
        data-testid="bg-commands-dialog"
        class="fixed inset-0 z-50 flex items-center justify-center"
        @click.self="handleClose"
      >
        <!-- Backdrop -->
        <div class="absolute inset-0 bg-black/60 backdrop-blur-sm" @click="handleClose" />

        <!-- Modal Content -->
        <div
          class="relative w-full max-w-lg mx-4 max-h-[80vh] flex flex-col rounded-xl shadow-2xl"
          style="background-color: var(--semantic-card-bg); border: 1px solid var(--color-border)"
        >
          <!-- Header -->
          <div
            class="flex items-center justify-between px-5 py-4 shrink-0"
            style="border-bottom: 1px solid var(--color-border)"
          >
            <div class="flex items-center gap-2">
              <UiIcon name="keyboard" size-class="w-5 h-5" />
              <h3 class="text-lead font-semibold" style="color: var(--semantic-text)">
                Background commands
              </h3>
              <span
                class="px-2 py-0.5 text-dense rounded-full"
                style="background-color: var(--semantic-active-bg); color: var(--semantic-text-dim)"
              >
                {{ processes.length }}
              </span>
            </div>
            <div class="flex items-center gap-1">
              <button
                data-testid="bg-list-refresh"
                class="p-1.5 rounded-lg transition-colors hover:opacity-70 text-dense"
                style="color: var(--semantic-text-dim)"
                aria-label="Refresh background commands"
                title="Refresh (list updates automatically via SSE)"
                @click="refreshList"
              >
                ↻ Refresh
              </button>
              <button
                @click="handleClose"
                class="p-1.5 rounded-lg transition-colors hover:opacity-70"
                style="color: var(--semantic-text-dim)"
                aria-label="Close background commands"
              >
                <svg class="w-5 h-5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
                  <path
                    stroke-linecap="round"
                    stroke-linejoin="round"
                    stroke-width="2"
                    d="M6 18L18 6M6 6l12 12"
                  />
                </svg>
              </button>
            </div>
          </div>

          <!-- Body -->
          <div class="flex-1 overflow-y-auto p-3">
            <div
              v-if="listError"
              data-testid="bg-list-error"
              class="text-center py-4 text-body"
              style="color: var(--color-red)"
            >
              {{ listError }}
            </div>
            <!-- List-loading skeleton — shown while `getBackgroundProcesses`
                 is in flight. Without it the "No background commands for this
                 session" empty state below fires on every open, which is
                 maximally misleading: the popup is opened precisely BECAUSE
                 commands are running. -->
            <div
              v-if="isLoadingList && processes.length === 0"
              class="space-y-2 py-2"
              data-testid="bg-list-skeleton"
              role="status"
              aria-label="Loading background commands"
            >
              <div
                v-for="n in 3"
                :key="n"
                class="h-12 rounded animate-pulse"
                style="background-color: var(--semantic-active-bg)"
              />
            </div>
            <div v-else-if="processes.length === 0" data-testid="bg-empty" class="text-center py-8">
              <UiIcon name="inbox" size-class="w-7 h-7" class="mb-2" />
              <p class="text-body" style="color: var(--semantic-text-dim)">
                No background commands for this session
              </p>
            </div>

            <div v-else class="space-y-2">
              <div
                v-for="proc in processes"
                :key="proc.pid"
                data-testid="bg-process-row"
                :data-pid="proc.pid"
                class="w-full text-left p-3 rounded-lg"
                style="
                  background-color: var(--semantic-active-bg);
                  border: 1px solid var(--color-border);
                "
              >
                <button
                  @click="toggleExpand(proc.pid)"
                  class="w-full flex items-start gap-3 text-left"
                  :aria-expanded="expandedPid === proc.pid"
                >
                  <span
                    v-if="proc.running"
                    class="bg-running-dot mt-1.5 shrink-0"
                    aria-hidden="true"
                  ></span>
                  <span v-else class="mt-1.5 shrink-0 text-dense" aria-hidden="true">⚪</span>
                  <div class="flex-1 min-w-0">
                    <p
                      class="text-body font-mono truncate"
                      style="color: var(--semantic-text)"
                      :title="proc.command"
                    >
                      {{ proc.command }}
                    </p>
                    <p
                      class="text-dense mt-0.5"
                      style="color: var(--semantic-text-dim)"
                      :title="fullDateTitle(proc.started_at)"
                    >
                      pid {{ proc.pid }} · started {{ formatStartedAt(proc.started_at) }}
                    </p>
                  </div>
                  <span
                    data-testid="bg-status-badge"
                    :data-running="proc.running"
                    class="px-2 py-0.5 text-dense rounded-full shrink-0"
                    :style="
                      proc.running
                        ? 'background-color: var(--color-green); color: #fff;'
                        : 'background-color: var(--semantic-active-bg); color: var(--semantic-text-dim); border: 1px solid var(--color-border);'
                    "
                  >
                    {{ proc.running ? 'running' : proc.status || 'completed' }}
                  </span>
                  <svg
                    class="w-4 h-4 mt-1 shrink-0 transition-transform"
                    :class="{ 'rotate-90': expandedPid === proc.pid }"
                    style="color: var(--semantic-text-dim)"
                    fill="none"
                    stroke="currentColor"
                    viewBox="0 0 24 24"
                  >
                    <path
                      stroke-linecap="round"
                      stroke-linejoin="round"
                      stroke-width="2"
                      d="M9 5l7 7-7 7"
                    />
                  </svg>
                </button>

                <!-- Expandable log tail -->
                <div v-if="expandedPid === proc.pid" class="mt-2">
                  <div class="flex items-center justify-between mb-1">
                    <span v-if="proc.running" class="text-meta" style="color: var(--color-green)">
                      ● live — auto-refreshing
                    </span>
                    <span v-else class="text-meta" style="color: var(--semantic-text-dim)">
                      log tail
                      <span v-if="logTruncated[proc.pid]">
                        (truncated, showing last {{ LOG_MAX_BYTES }} bytes)</span
                      >
                      <span v-else-if="logTotalBytes[proc.pid] !== undefined">
                        ({{ logTotalBytes[proc.pid] }} bytes)</span
                      >
                    </span>
                    <button
                      data-testid="bg-log-refresh"
                      :data-pid="proc.pid"
                      @click.stop="refreshLog(proc.pid)"
                      class="px-2 py-0.5 text-meta rounded-md transition-colors hover:opacity-70"
                      style="
                        background-color: var(--semantic-card-bg);
                        border: 1px solid var(--color-border);
                        color: var(--semantic-text-dim);
                      "
                    >
                      Refresh
                    </button>
                  </div>
                  <div
                    v-if="logLoading[proc.pid] && !logContent[proc.pid]"
                    class="text-dense py-2"
                    style="color: var(--semantic-text-dim)"
                  >
                    Loading log…
                  </div>
                  <div
                    v-else-if="logError[proc.pid]"
                    data-testid="bg-log-error"
                    class="text-dense py-2"
                    style="color: var(--color-red)"
                  >
                    {{ logError[proc.pid] }}
                  </div>
                  <pre
                    v-else
                    data-testid="bg-log-content"
                    :data-pid="proc.pid"
                    class="bg-log-pre text-dense font-mono whitespace-pre-wrap break-words overflow-y-auto"
                    style="
                      background-color: var(--semantic-card-bg);
                      border: 1px solid var(--color-border);
                      color: var(--semantic-text);
                    "
                    >{{ logContent[proc.pid] ?? '' }}</pre>
                </div>
              </div>
            </div>
          </div>
        </div>
      </div>
    </Transition>
  </Teleport>
</template>

<style scoped>
.modal-enter-active,
.modal-leave-active {
  transition: opacity 0.2s ease;
}

.modal-enter-from,
.modal-leave-to {
  opacity: 0;
}

.modal-enter-active > div:last-child,
.modal-leave-active > div:last-child {
  transition: transform 0.2s ease;
}

.modal-enter-from > div:last-child,
.modal-leave-to > div:last-child {
  transform: scale(0.95);
}

.bg-running-dot {
  width: 8px;
  height: 8px;
  border-radius: 9999px;
  background-color: var(--color-green);
  animation: bg-pulse 1.4s ease-in-out infinite;
  flex-shrink: 0;
}

@keyframes bg-pulse {
  0%,
  100% {
    opacity: 1;
  }
  50% {
    opacity: 0.35;
  }
}

@media (prefers-reduced-motion: reduce) {
  .bg-running-dot {
    animation: none;
  }
}

.bg-log-pre {
  border-radius: 8px;
  padding: 8px 10px;
  max-height: 220px;
}
</style>
