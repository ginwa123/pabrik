<script setup lang="ts">
import { computed, nextTick, onMounted, onUnmounted, ref } from 'vue'
import { Effect, Either } from 'effect'
import { Terminal } from '@xterm/xterm'
import { FitAddon } from '@xterm/addon-fit'
import UiIcon from '../ui/UiIcon.vue'
import '@xterm/xterm/css/xterm.css'
import {
  createTerminalSession,
  deleteTerminalSession,
  listTerminalSessions,
  resizeTerminal,
  sendTerminalInput,
} from '../../api'
import type { TerminalSessionSummary } from '../../api'
import { inputForBackend } from '../../helpers/terminalInput'

interface WorkspaceRef {
  id: string
  name: string
  items?: { path?: string | null }[]
}

const props = defineProps<{
  workspaces: WorkspaceRef[]
  activeWorkspaceId?: string
  cwd?: string
}>()

const REFRESH_MS = 15000
const WS_BASE_DELAY_MS = 1000
const WS_MAX_DELAY_MS = 30000
const HEIGHT_KEY = 'pabrik-terminal-panel-height'
const DEFAULT_HEIGHT = 280
const MIN_HEIGHT = 120
const MAX_HEIGHT_RATIO = 0.8
const MAXIMIZED_HEIGHT = '70vh'

const open = ref(false)
const maximized = ref(false)
const height = ref(DEFAULT_HEIGHT)
const resizing = ref(false)
const workspaceMenuOpen = ref(false)
const sessions = ref<TerminalSessionSummary[]>([])
const activeId = ref<string | null>(null)
const status = ref('')
const busy = ref(false)
const error = ref<string | null>(null)
const termContainer = ref<HTMLElement | null>(null)

let term: Terminal | null = null
let fit: FitAddon | null = null
let ws: WebSocket | null = null
let wsOpened = false
let wsAttempt = 0
let wsRetryTimer: ReturnType<typeof setTimeout> | null = null
let resizeObserver: ResizeObserver | null = null
let refreshTimer: ReturnType<typeof setInterval> | null = null
let disposed = false
let resizeStartY = 0
let resizeStartHeight = DEFAULT_HEIGHT

interface ControlFrame {
  type?: string
  exit_code?: number | null
}

const clampHeight = (value: number): number => {
  const ceiling = Math.max(MIN_HEIGHT, Math.round(window.innerHeight * MAX_HEIGHT_RATIO))
  return Math.min(ceiling, Math.max(MIN_HEIGHT, Math.round(value)))
}

const readStoredHeight = (): number => {
  const raw = window.localStorage.getItem(HEIGHT_KEY)
  const parsed = raw === null ? Number.NaN : Number(raw)
  return Number.isFinite(parsed) ? clampHeight(parsed) : DEFAULT_HEIGHT
}

const storeHeight = (value: number) => {
  window.localStorage.setItem(HEIGHT_KEY, String(value))
}

const pointerY = (event: MouseEvent | TouchEvent): number => {
  if ('touches' in event) return event.touches[0]?.clientY ?? resizeStartY
  return event.clientY
}

const workspaceOf = (workspaceId: string) => props.workspaces.find((w) => w.id === workspaceId)

const workspaceName = (workspaceId: string): string => {
  const workspace = workspaceOf(workspaceId)
  if (workspace) return workspace.name
  return workspaceId === '' ? 'No workspace' : workspaceId
}

const orderedSessions = computed<TerminalSessionSummary[]>(() => {
  const buckets = new Map<string, TerminalSessionSummary[]>()
  const order: string[] = []
  for (const session of sessions.value) {
    const rows = buckets.get(session.workspace_id)
    if (rows) rows.push(session)
    else {
      buckets.set(session.workspace_id, [session])
      order.push(session.workspace_id)
    }
  }
  return order.flatMap((workspaceId) =>
    (buckets.get(workspaceId) ?? []).slice().sort((a, b) => a.id.localeCompare(b.id)),
  )
})

const liveCount = computed(() => sessions.value.filter((s) => !s.exited).length)
const activeSession = computed(() => sessions.value.find((s) => s.id === activeId.value) ?? null)
const activeOrphan = computed(
  () => activeSession.value !== null && !workspaceOf(activeSession.value.workspace_id),
)

const panelStyle = computed(() => ({
  height: maximized.value ? MAXIMIZED_HEIGHT : `${height.value}px`,
}))

const tabTitle = (session: TerminalSessionSummary): string => {
  const parts = [workspaceName(session.workspace_id), session.cwd || 'no cwd', session.backend]
  if (!workspaceOf(session.workspace_id)) parts.unshift('workspace deleted')
  if (session.exited) parts.push('exited')
  return parts.join(' · ')
}

const readControlFrame = (raw: string): ControlFrame | null => {
  const outcome = Effect.runSync(
    Effect.either(
      Effect.try({
        try: () => JSON.parse(raw) as ControlFrame,
        catch: () => new Error('not a control frame'),
      }),
    ),
  )
  return Either.isLeft(outcome) ? null : outcome.right
}

const refresh = async () => {
  if (disposed) return
  await listTerminalSessions()
    .then((rows) => {
      sessions.value = rows
      error.value = null
    })
    .catch((cause: unknown) => {
      error.value = cause instanceof Error ? cause.message : 'could not read the terminals'
    })
}

const wsUrl = (id: string) => {
  const proto = window.location.protocol === 'https:' ? 'wss' : 'ws'
  return `${proto}://${window.location.host}/api/terminal/ws?id=${encodeURIComponent(id)}`
}

const clearWsRetry = () => {
  if (wsRetryTimer !== null) {
    clearTimeout(wsRetryTimer)
    wsRetryTimer = null
  }
}

const closeWs = () => {
  const socket = ws
  ws = null
  wsOpened = false
  if (socket && socket.readyState !== WebSocket.CLOSED) socket.close()
}

const scheduleWsReconnect = (reason: string) => {
  if (disposed || !activeId.value) return
  if (wsRetryTimer !== null) return
  wsAttempt += 1
  const exp = Math.min(WS_BASE_DELAY_MS * 2 ** (wsAttempt - 1), WS_MAX_DELAY_MS)
  const delay = exp * (0.5 + 0.5 * Math.random())
  status.value = `${reason} — reconnecting… (attempt ${wsAttempt})`
  wsRetryTimer = setTimeout(() => {
    wsRetryTimer = null
    connectWs()
  }, delay)
}

const handleWsMessage = (event: MessageEvent) => {
  const data = event.data
  if (typeof data === 'string') {
    const frame = readControlFrame(data)
    if (frame?.type !== 'exit') return
    status.value =
      frame.exit_code === null || frame.exit_code === undefined
        ? 'shell exited'
        : `shell exited (code ${frame.exit_code})`
    clearWsRetry()
    closeWs()
    void refresh()
    return
  }
  const bytes =
    data instanceof ArrayBuffer
      ? new Uint8Array(data)
      : ArrayBuffer.isView(data)
        ? new Uint8Array(data.buffer as ArrayBuffer, data.byteOffset, data.byteLength)
        : null
  if (bytes) term?.write(new TextDecoder().decode(bytes).replace(/\n/g, '\r\n'))
}

const connectWs = () => {
  const id = activeId.value
  if (!id || disposed) return
  closeWs()
  if (wsAttempt > 0) term?.clear()
  const outcome = Effect.runSync(
    Effect.either(
      Effect.try({
        try: () => new WebSocket(wsUrl(id)),
        catch: () => new Error('socket unavailable'),
      }),
    ),
  )
  if (Either.isLeft(outcome)) {
    scheduleWsReconnect('socket unavailable')
    return
  }
  const socket = outcome.right
  socket.binaryType = 'arraybuffer'
  ws = socket
  socket.onopen = () => {
    if (disposed || ws !== socket) return
    wsOpened = true
    wsAttempt = 0
    clearWsRetry()
    status.value =
      activeSession.value?.backend === 'pipe'
        ? 'connected · pipe backend (no TUI: this host has no pseudoconsole)'
        : 'connected'
  }
  socket.onmessage = (event) => {
    if (ws !== socket) return
    handleWsMessage(event)
  }
  socket.onerror = () => {
    if (ws !== socket || disposed) return
    if (!wsOpened) scheduleWsReconnect('socket failed')
  }
  socket.onclose = () => {
    if (ws !== socket || disposed) return
    if (!wsOpened) {
      scheduleWsReconnect('socket failed')
      return
    }
    wsOpened = false
    scheduleWsReconnect('socket closed')
  }
}

const sendControl = (payload: unknown): boolean => {
  const socket = ws
  if (!socket || !wsOpened || socket.readyState !== WebSocket.OPEN) return false
  const outcome = Effect.runSync(
    Effect.either(
      Effect.try({
        try: () => socket.send(JSON.stringify(payload)),
        catch: () => new Error('socket closed'),
      }),
    ),
  )
  return !Either.isLeft(outcome)
}

const sendInput = (data: string) => {
  const id = activeId.value
  if (!id) return
  const payload = inputForBackend(activeSession.value?.backend ?? '', data)
  if (payload.length === 0) return
  if (sendControl({ type: 'input', data: payload })) return
  void sendTerminalInput(id, payload).catch((cause: unknown) => {
    error.value = cause instanceof Error ? cause.message : 'input failed'
  })
}

const fitAndResize = async () => {
  const id = activeId.value
  if (!term || !fit || !id) return
  if (!fit.proposeDimensions()) return
  fit.fit()
  const { cols, rows } = term
  if (sendControl({ type: 'resize', cols, rows })) return
  await resizeTerminal(id, cols, rows).catch((cause: unknown) => {
    error.value = cause instanceof Error ? cause.message : 'resize failed'
  })
}

const startTerminal = async (id: string) => {
  activeId.value = id
  status.value = 'connecting…'
  await nextTick()
  const container = termContainer.value
  if (!container) return
  term = new Terminal({
    fontSize: 12,
    fontFamily: 'ui-monospace, SFMono-Regular, Menlo, monospace',
    cursorBlink: true,
    scrollback: 5000,
    theme: { background: '#12120f', foreground: '#c5c9c5', cursor: '#c5c9c5' },
  })
  fit = new FitAddon()
  term.loadAddon(fit)
  term.open(container)
  term.onData((data) => sendInput(data))
  resizeObserver = new ResizeObserver(() => {
    void fitAndResize()
  })
  resizeObserver.observe(container)
  connectWs()
}

const stopTerminal = () => {
  clearWsRetry()
  closeWs()
  resizeObserver?.disconnect()
  resizeObserver = null
  term?.dispose()
  termContainer.value?.replaceChildren()
  term = null
  fit = null
  activeId.value = null
  status.value = ''
}

const attachAnySession = async () => {
  const candidate = orderedSessions.value.find((s) => !s.exited) ?? orderedSessions.value[0]
  if (!candidate) return
  await startTerminal(candidate.id)
}

const openPanel = async () => {
  open.value = true
  await refresh()
  await nextTick()
  await attachAnySession()
}

const closePanel = () => {
  open.value = false
  maximized.value = false
  workspaceMenuOpen.value = false
  stopTerminal()
}

const togglePanel = async () => {
  if (open.value) closePanel()
  else await openPanel()
}

const selectSession = async (id: string) => {
  if (id === activeId.value) return
  stopTerminal()
  await startTerminal(id)
}

const clearOutput = () => {
  term?.clear()
}

const killActive = async () => {
  const id = activeId.value
  if (!id) return
  stopTerminal()
  await deleteTerminalSession(id).catch((cause: unknown) => {
    error.value = cause instanceof Error ? cause.message : 'could not kill the shell'
  })
  await refresh()
  await nextTick()
  await attachAnySession()
}

const cwdFor = (workspaceId: string): string => {
  if (workspaceId && workspaceId === props.activeWorkspaceId) return props.cwd ?? ''
  const workspace = workspaceOf(workspaceId)
  const item = workspace?.items?.find((i) => i.path)
  return item?.path ?? ''
}

const newTerminal = async (workspaceId: string) => {
  if (busy.value) return
  busy.value = true
  error.value = null
  workspaceMenuOpen.value = false
  await createTerminalSession(workspaceId, cwdFor(workspaceId), {})
    .then(async (session) => {
      await refresh()
      const row = sessions.value.find((s) => s.id === session.id)
      await startTerminal(row?.id ?? session.id)
    })
    .catch((cause: unknown) => {
      error.value = cause instanceof Error ? cause.message : 'failed to start a shell'
    })
    .finally(() => {
      busy.value = false
    })
}

const startResize = (event: MouseEvent | TouchEvent) => {
  maximized.value = false
  resizing.value = true
  resizeStartY = pointerY(event)
  resizeStartHeight = height.value
  document.addEventListener('mousemove', handleResize)
  document.addEventListener('mouseup', stopResize)
  document.addEventListener('touchmove', handleResize)
  document.addEventListener('touchend', stopResize)
  document.body.style.userSelect = 'none'
  document.body.style.cursor = 'row-resize'
}

const handleResize = (event: MouseEvent | TouchEvent) => {
  if (!resizing.value) return
  height.value = clampHeight(resizeStartHeight + resizeStartY - pointerY(event))
}

const stopResize = () => {
  if (!resizing.value) return
  resizing.value = false
  document.removeEventListener('mousemove', handleResize)
  document.removeEventListener('mouseup', stopResize)
  document.removeEventListener('touchmove', handleResize)
  document.removeEventListener('touchend', stopResize)
  document.body.style.userSelect = ''
  document.body.style.cursor = ''
  storeHeight(height.value)
}

const resetHeight = () => {
  height.value = DEFAULT_HEIGHT
  storeHeight(height.value)
}

const toggleMaximized = () => {
  maximized.value = !maximized.value
}

const closeWorkspaceMenu = () => {
  workspaceMenuOpen.value = false
}

const toggleWorkspaceMenu = () => {
  workspaceMenuOpen.value = !workspaceMenuOpen.value
}

const onWindowResize = () => {
  height.value = clampHeight(height.value)
}

const onKeydown = (event: KeyboardEvent) => {
  if (event.key === 'Escape' && workspaceMenuOpen.value) {
    closeWorkspaceMenu()
    return
  }
  if (event.ctrlKey && event.key === '`') {
    event.preventDefault()
    void togglePanel()
  }
}

onMounted(() => {
  height.value = readStoredHeight()
  window.addEventListener('keydown', onKeydown)
  window.addEventListener('resize', onWindowResize)
  document.addEventListener('mousedown', closeWorkspaceMenu)
  void refresh()
  refreshTimer = setInterval(() => {
    if (document.visibilityState === 'visible') void refresh()
  }, REFRESH_MS)
})

onUnmounted(() => {
  disposed = true
  window.removeEventListener('keydown', onKeydown)
  window.removeEventListener('resize', onWindowResize)
  document.removeEventListener('mousedown', closeWorkspaceMenu)
  if (refreshTimer !== null) {
    clearInterval(refreshTimer)
    refreshTimer = null
  }
  stopTerminal()
})
</script>

<template>
  <section class="shrink-0 flex flex-col" data-testid="terminal-dock">
    <div
      v-if="open"
      class="flex flex-col min-h-0"
      :style="panelStyle"
      role="region"
      aria-label="Terminal"
      data-testid="terminal-panel"
    >
      <div
        class="h-1 shrink-0 cursor-row-resize hover:bg-[var(--semantic-active-bg)]"
        title="Drag to resize, double-click to reset"
        data-testid="terminal-panel-resize"
        @mousedown="startResize"
        @touchstart="startResize"
        @dblclick="resetHeight"
      ></div>

      <div
        class="h-8 shrink-0 flex items-stretch"
        style="background-color: var(--color-bg-m1)"
        data-testid="terminal-header"
      >
        <div class="flex items-stretch min-w-0 flex-1 overflow-x-auto">
          <button
            v-for="session in orderedSessions"
            :key="session.id"
            type="button"
            class="flex items-center gap-1.5 px-2.5 text-meta whitespace-nowrap"
            :style="{
              color:
                session.id === activeId && !session.exited
                  ? 'var(--semantic-text)'
                  : 'var(--semantic-text-muted)',
              backgroundColor: session.id === activeId ? 'var(--color-bg-dim)' : 'transparent',
            }"
            :title="tabTitle(session)"
            :data-session="session.id"
            :data-workspace="session.workspace_id"
            :data-active="session.id === activeId ? 'true' : 'false'"
            :data-exited="session.exited ? 'true' : 'false'"
            :data-orphan="workspaceOf(session.workspace_id) ? 'false' : 'true'"
            data-testid="terminal-tab"
            @click="selectSession(session.id)"
          >
            <span
              class="w-1.5 h-1.5 rounded-full shrink-0"
              :style="{
                backgroundColor: session.exited ? 'var(--semantic-text-dim)' : 'var(--color-aqua)',
              }"
            ></span>
            <span>{{ session.id }}</span>
          </button>
          <div class="relative flex items-stretch" @mousedown.stop>
            <button
              type="button"
              class="flex items-center justify-center w-7 text-meta hover:opacity-80 disabled:opacity-40"
              style="color: var(--semantic-text-muted)"
              title="New terminal"
              data-testid="terminal-new"
              :disabled="busy"
              @click="newTerminal(props.activeWorkspaceId ?? '')"
            >
              <UiIcon name="plus" size-class="w-3 h-3" />
            </button>
            <button
              type="button"
              class="flex items-center justify-center w-5 hover:opacity-80"
              style="color: var(--semantic-text-muted)"
              title="New terminal in another workspace"
              data-testid="terminal-new-menu"
              @click="toggleWorkspaceMenu"
            >
              <UiIcon name="chevron-down" size-class="w-3 h-3" />
            </button>
            <div
              v-if="workspaceMenuOpen"
              class="absolute left-0 top-full z-30 min-w-44 py-1 rounded"
              style="
                background-color: var(--semantic-card-bg);
                border: 1px solid var(--color-border);
                box-shadow: rgba(0, 0, 0, 0.25) 0 25px 50px -12px;
              "
              data-testid="terminal-new-workspaces"
            >
              <button
                v-for="workspace in props.workspaces"
                :key="workspace.id"
                type="button"
                class="w-full text-left px-3 py-1.5 text-dense truncate hover:bg-[var(--semantic-active-bg)] disabled:opacity-40"
                style="color: var(--semantic-text)"
                :data-workspace-id="workspace.id"
                data-testid="terminal-new-in-workspace"
                :disabled="busy"
                @click="newTerminal(workspace.id)"
              >
                {{ workspace.name }}
              </button>
              <div
                v-if="props.workspaces.length === 0"
                class="px-3 py-1.5 text-meta"
                style="color: var(--semantic-text-dim)"
              >
                No workspace
              </div>
            </div>
          </div>
        </div>

        <div class="flex items-center gap-0.5 px-1 shrink-0">
          <button
            type="button"
            class="flex items-center justify-center px-1.5 h-6 rounded text-meta hover:bg-[var(--semantic-active-bg)] disabled:opacity-40"
            style="color: var(--semantic-text-muted)"
            title="Clear the visible output"
            data-testid="terminal-clear"
            :disabled="!activeId"
            @click="clearOutput"
          >
            clear
          </button>
          <button
            type="button"
            class="flex items-center justify-center w-6 h-6 rounded hover:bg-[var(--semantic-active-bg)] disabled:opacity-40"
            style="color: var(--semantic-text-muted)"
            title="Kill this shell"
            data-testid="terminal-kill"
            :disabled="!activeId"
            @click="killActive"
          >
            <UiIcon name="trash" size-class="w-3.5 h-3.5" />
          </button>
          <button
            type="button"
            class="flex items-center justify-center w-6 h-6 rounded hover:bg-[var(--semantic-active-bg)]"
            style="color: var(--semantic-text-muted)"
            :title="maximized ? 'Restore the panel' : 'Maximize the panel'"
            data-testid="terminal-maximize"
            @click="toggleMaximized"
          >
            <UiIcon :name="maximized ? 'chevron-down' : 'chevron-up'" size-class="w-3.5 h-3.5" />
          </button>
          <button
            type="button"
            class="flex items-center justify-center w-6 h-6 rounded hover:bg-[var(--semantic-active-bg)]"
            style="color: var(--semantic-text-muted)"
            title="Close the panel"
            data-testid="terminal-close"
            @click="closePanel"
          >
            <UiIcon name="close" size-class="w-3.5 h-3.5" />
          </button>
        </div>
      </div>

      <div class="flex-1 min-h-0 relative" style="background-color: var(--color-bg-dim)">
        <div
          v-if="orderedSessions.length === 0"
          class="absolute inset-0 flex flex-col items-center justify-center gap-3 px-4"
          data-testid="terminal-empty"
        >
          <p class="text-meta" style="color: var(--semantic-text-dim)">
            No shell is running. Nothing spawns until you start one.
          </p>
          <div class="flex flex-wrap items-center justify-center gap-2">
            <button
              v-for="workspace in props.workspaces"
              :key="workspace.id"
              type="button"
              class="px-3 py-1 rounded text-dense hover:opacity-80 disabled:opacity-40"
              style="background-color: var(--semantic-active-bg); color: var(--semantic-text)"
              :data-workspace-id="workspace.id"
              data-testid="terminal-empty-new"
              :disabled="busy"
              @click="newTerminal(workspace.id)"
            >
              {{ workspace.name }}
            </button>
          </div>
        </div>
        <div
          v-else
          ref="termContainer"
          class="absolute inset-0 pl-2 pt-1"
          data-testid="terminal-xterm"
        ></div>
      </div>

      <div
        class="h-6 shrink-0 flex items-center gap-2 px-3 text-meta overflow-hidden"
        style="background-color: var(--color-bg-m1); color: var(--semantic-text-muted)"
        data-testid="terminal-statusbar"
      >
        <span data-testid="terminal-status">{{ status || 'not attached' }}</span>
        <span v-if="activeSession" class="truncate" data-testid="terminal-cwd">
          {{ activeSession.cwd || '(no cwd)' }}
        </span>
        <span class="flex-1"></span>
        <span v-if="activeOrphan" data-testid="terminal-orphan">workspace deleted</span>
        <span v-if="error" data-testid="terminal-error" style="color: var(--color-red)">
          {{ error }}
        </span>
      </div>
    </div>

    <div
      class="shrink-0 flex items-center gap-3 px-3 h-8"
      style="border-top: 1px solid var(--color-border); background-color: var(--semantic-content-bg)"
      data-testid="terminal-footer"
    >
      <button
        type="button"
        class="flex items-center gap-1.5 px-1.5 py-0.5 rounded text-meta hover:bg-[var(--semantic-active-bg)]"
        :style="{ color: open ? 'var(--semantic-text)' : 'var(--semantic-text-muted)' }"
        title="Terminal (Ctrl+`)"
        data-testid="terminal-footer-open"
        :data-open="open ? 'true' : 'false'"
        @click="togglePanel"
      >
        <UiIcon name="keyboard" size-class="w-3 h-3" />
        <span>Terminal</span>
        <UiIcon :name="open ? 'chevron-down' : 'chevron-up'" size-class="w-3 h-3" />
      </button>
      <span class="flex-1"></span>
      <span class="text-meta whitespace-nowrap" style="color: var(--semantic-text-dim)">
        <span data-testid="terminal-footer-count">{{ liveCount }}</span>
        shell{{ liveCount === 1 ? '' : 's' }} live
      </span>
      <span
        v-if="error && !open"
        class="text-meta truncate"
        style="color: var(--color-red)"
        data-testid="terminal-footer-error"
      >
        {{ error }}
      </span>
    </div>
  </section>
</template>
