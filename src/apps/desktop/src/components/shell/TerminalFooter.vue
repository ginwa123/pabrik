<script setup lang="ts">
/** The window-level terminal footer: a strip along the bottom of the app whose
 * Terminal entry opens a dialog listing the live shells grouped per workspace.
 * Picking one turns the dialog into that terminal. */
import { computed, nextTick, onMounted, onUnmounted, ref } from 'vue'
import { Effect, Either } from 'effect'
import { Terminal } from '@xterm/xterm'
import { FitAddon } from '@xterm/addon-fit'
import UiIcon from '../ui/UiIcon.vue'
import '@xterm/xterm/css/xterm.css'
import {
  createTerminalSession,
  listTerminalSessions,
  resizeTerminal,
  sendTerminalInput,
} from '../../api'
import type { TerminalSessionSummary } from '../../api'

interface WorkspaceRef {
  id: string
  name: string
  items?: { path?: string | null }[]
}

const props = defineProps<{
  /** The workspaces the app knows about — the group headings. */
  workspaces: WorkspaceRef[]
  /** The workspace a new shell belongs to when the button names none. */
  activeWorkspaceId?: string
  /** Where a new shell starts. */
  cwd?: string
}>()

/** How often the footer re-reads the live list. */
const REFRESH_MS = 15000
const WS_BASE_DELAY_MS = 1000
const WS_MAX_DELAY_MS = 30000

const open = ref(false)
const view = ref<'list' | 'terminal'>('list')
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

interface SessionGroup {
  workspaceId: string
  name: string
  /** False when the workspace is gone: the shell still runs, the workspace
   * that owned it does not, and the person has to be able to close it. */
  known: boolean
  rows: TerminalSessionSummary[]
}

/** A control frame the server sends as JSON text. */
interface ControlFrame {
  type?: string
  exit_code?: number | null
}

const groups = computed<SessionGroup[]>(() => {
  const byWorkspace = new Map<string, TerminalSessionSummary[]>()
  for (const s of sessions.value) {
    const rows = byWorkspace.get(s.workspace_id)
    if (rows) rows.push(s)
    else byWorkspace.set(s.workspace_id, [s])
  }
  const out: SessionGroup[] = []
  for (const [workspaceId, rows] of byWorkspace) {
    const known = props.workspaces.find((w) => w.id === workspaceId)
    out.push({
      workspaceId,
      name: known?.name ?? (workspaceId ? workspaceId : 'No workspace'),
      known: !!known,
      rows,
    })
  }
  return out
})

const liveCount = computed(() => sessions.value.filter((s) => !s.exited).length)
const workspaceCount = computed(() => groups.value.length)
const activeSession = computed(() => sessions.value.find((s) => s.id === activeId.value) ?? null)

/** Read a control frame without a `try`/`catch`: a frame that is not JSON is
 * not a control frame, and the failure stays a value. */
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

const openDialog = async () => {
  open.value = true
  view.value = 'list'
  await refresh()
}

const closeDialog = () => {
  open.value = false
  stopTerminal()
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
  // A re-attach replays the whole server buffer, so a reconnected view is
  // cleared first — otherwise the scrollback arrives twice.
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
    status.value = 'connected'
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

/** Send a control frame over the socket. A socket that reports OPEN can
 * still have closed in between, so the send is a value, not a throw. */
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
  if (sendControl({ type: 'input', data })) return
  void sendTerminalInput(id, data).catch((cause: unknown) => {
    error.value = cause instanceof Error ? cause.message : 'input failed'
  })
}

const fitAndResize = async () => {
  const id = activeId.value
  if (!term || !fit || !id) return
  // `proposeDimensions` is null while the terminal has no box, which is the
  // case right after the dialog swaps the list for the terminal.
  if (!fit.proposeDimensions()) return
  fit.fit()
  const { cols, rows } = term
  if (sendControl({ type: 'resize', cols, rows })) return
  await resizeTerminal(id, cols, rows).catch((cause: unknown) => {
    console.error('[terminal-footer] resize failed:', cause)
  })
}

const startTerminal = async (id: string) => {
  activeId.value = id
  view.value = 'terminal'
  status.value = 'connecting…'
  await nextTick()
  const container = termContainer.value
  if (!container) return
  term = new Terminal({
    fontSize: 12,
    fontFamily: 'ui-monospace, SFMono-Regular, Menlo, monospace',
    cursorBlink: true,
    scrollback: 5000,
    theme: { background: '#0f0e0c', foreground: '#c5c9c5', cursor: '#c5c9c5' },
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
  term = null
  fit = null
  activeId.value = null
  status.value = ''
}

const pick = async (row: TerminalSessionSummary) => {
  await startTerminal(row.id)
}

const backToList = () => {
  view.value = 'list'
  stopTerminal()
  void refresh()
}

/** Where a new shell in `workspaceId` starts: the app's current cwd when it
 * is the workspace in front of the user, else that workspace's own path. */
const cwdFor = (workspaceId: string): string => {
  if (workspaceId && workspaceId === props.activeWorkspaceId) return props.cwd ?? ''
  const workspace = props.workspaces.find((w) => w.id === workspaceId)
  const item = workspace?.items?.find((i) => i.path)
  return item?.path ?? ''
}

const newTerminal = async (workspaceId: string) => {
  if (busy.value) return
  busy.value = true
  error.value = null
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

const onKeydown = (event: KeyboardEvent) => {
  if (event.key === 'Escape' && open.value) closeDialog()
}

onMounted(() => {
  window.addEventListener('keydown', onKeydown)
  void refresh()
  refreshTimer = setInterval(() => {
    if (document.visibilityState === 'visible') void refresh()
  }, REFRESH_MS)
})

onUnmounted(() => {
  disposed = true
  window.removeEventListener('keydown', onKeydown)
  if (refreshTimer !== null) {
    clearInterval(refreshTimer)
    refreshTimer = null
  }
  stopTerminal()
})
</script>

<template>
  <div
    class="shrink-0 flex items-center gap-3 px-3 h-8"
    style="border-top: 1px solid var(--color-border); background-color: var(--semantic-content-bg)"
    data-testid="terminal-footer"
  >
    <span class="text-meta truncate" style="color: var(--semantic-text-dim)">
      {{ liveCount }} shell{{ liveCount === 1 ? '' : 's' }} live
    </span>
    <div class="flex-1"></div>
    <button
      type="button"
      class="flex items-center gap-1.5 px-2 py-0.5 rounded text-meta hover:opacity-80"
      style="color: var(--semantic-text)"
      title="Terminals"
      data-testid="terminal-footer-open"
      @click="openDialog"
    >
      <UiIcon name="keyboard" size-class="w-3 h-3" />
      <span>Terminal</span>
      <span
        v-if="liveCount > 0"
        class="px-1 rounded"
        style="background: var(--semantic-active-bg); color: var(--semantic-text)"
        data-testid="terminal-footer-count"
      >
        {{ liveCount }}
      </span>
    </button>
  </div>

  <Teleport to="body">
    <div
      v-if="open"
      class="fixed inset-0 z-50 flex items-center justify-center p-4"
      data-testid="terminal-footer-dialog"
      @click.self="closeDialog"
    >
      <div class="absolute inset-0 bg-black/60 backdrop-blur-sm" @click="closeDialog"></div>
      <div
        class="relative w-full max-w-lg rounded-xl flex flex-col overflow-hidden"
        style="
          background-color: var(--semantic-content-bg);
          border: 1px solid var(--color-border);
          box-shadow: rgba(0, 0, 0, 0.25) 0 25px 50px -12px;
        "
        role="dialog"
        aria-modal="true"
        aria-label="Terminals"
      >
        <div class="flex items-center gap-3 px-6 pt-6 pb-4">
          <button
            v-if="view === 'terminal'"
            type="button"
            class="text-meta rounded px-1.5 py-0.5 hover:opacity-80"
            style="color: var(--semantic-text-dim)"
            title="Back to the list"
            data-testid="terminal-footer-back"
            @click="backToList"
          >
            &#8592;
          </button>
          <h3 class="text-lead font-semibold" style="color: var(--semantic-text)">
            {{ view === 'terminal' ? (activeSession?.id ?? 'Terminal') : 'Terminals' }}
          </h3>
          <div class="flex-1"></div>
          <span
            v-if="view === 'list'"
            class="text-meta whitespace-nowrap"
            style="color: var(--semantic-text-dim)"
            data-testid="terminal-footer-summary"
          >
            {{ liveCount }} live across {{ workspaceCount }} workspace{{
              workspaceCount === 1 ? '' : 's'
            }}
          </span>
          <button
            type="button"
            class="text-meta rounded px-1.5 py-0.5 hover:opacity-80"
            style="color: var(--semantic-text-dim)"
            title="Close"
            data-testid="terminal-footer-close"
            @click="closeDialog"
          >
            &#215;
          </button>
        </div>

        <div
          v-if="view === 'list'"
          class="px-6 pb-4 overflow-y-auto"
          style="max-height: 420px"
          data-testid="terminal-footer-list"
        >
          <div
            v-if="sessions.length === 0"
            class="text-meta py-8 text-center"
            style="color: var(--semantic-text-dim)"
            data-testid="terminal-footer-empty"
          >
            No terminal yet. Terminals only start when you ask - nothing spawns on open.
          </div>
          <div
            v-for="group in groups"
            :key="group.workspaceId"
            class="mb-4"
            data-testid="terminal-footer-group"
            :data-workspace-id="group.workspaceId"
          >
            <div class="flex items-center gap-2 mb-1">
              <span
                class="text-meta truncate"
                :style="
                  group.known ? 'color: var(--semantic-text)' : 'color: var(--semantic-text-dim)'
                "
                data-testid="terminal-footer-group-name"
              >
                {{ group.name }}
              </span>
              <span v-if="group.known" class="text-meta" style="color: var(--semantic-text-dim)">
                &middot; {{ group.workspaceId }}
              </span>
              <span
                v-else
                class="text-meta whitespace-nowrap"
                style="color: var(--semantic-text-dim)"
                data-testid="terminal-footer-group-gone"
              >
                &middot; workspace deleted
              </span>
              <div class="flex-1"></div>
              <button
                type="button"
                class="text-meta rounded px-1.5 py-0.5 hover:opacity-80 disabled:opacity-40"
                style="color: var(--semantic-text-dim)"
                title="New terminal in this workspace"
                data-testid="terminal-footer-group-new"
                :disabled="busy"
                @click="newTerminal(group.workspaceId)"
              >
                +
              </button>
            </div>
            <button
              v-for="row in group.rows"
              :key="row.id"
              type="button"
              class="w-full flex items-center gap-2 px-2 py-1.5 rounded text-left hover:opacity-80"
              :style="
                group.known
                  ? 'color: var(--semantic-text)'
                  : 'color: var(--semantic-text-dim); opacity: .55'
              "
              data-testid="terminal-footer-row"
              :data-session="row.id"
              :data-workspace="row.workspace_id"
              @click="pick(row)"
            >
              <span
                class="w-1.5 h-1.5 rounded-full shrink-0"
                :style="
                  row.exited
                    ? 'background: var(--semantic-text-dim)'
                    : 'background: var(--color-aqua)'
                "
              ></span>
              <span class="text-dense">{{ row.id }}</span>
              <code class="text-meta truncate" style="color: var(--semantic-text-dim)">
                {{ row.cwd || '(no cwd)' }}
              </code>
              <div class="flex-1"></div>
              <span class="text-meta whitespace-nowrap" style="color: var(--semantic-text-dim)">
                {{ row.exited ? 'exited' : row.backend }}
              </span>
            </button>
          </div>
        </div>

        <div v-else class="px-6 pb-4 flex flex-col" data-testid="terminal-footer-terminal">
          <div
            ref="termContainer"
            class="h-64 rounded"
            style="background: #0f0e0c"
            data-testid="terminal-footer-xterm"
          ></div>
          <div
            class="text-meta mt-2 truncate"
            style="color: var(--semantic-text-dim)"
            data-testid="terminal-footer-status"
          >
            {{ status }}
          </div>
        </div>

        <div
          v-if="error"
          class="px-6 pb-3 text-meta"
          style="color: var(--semantic-danger, #d16a5a)"
          data-testid="terminal-footer-error"
        >
          {{ error }}
        </div>

        <div
          class="flex items-center gap-2 px-6 py-4"
          style="border-top: 1px solid var(--color-border)"
        >
          <span class="text-meta flex-1" style="color: var(--semantic-text-dim)">
            Nothing spawns on open. A session appears here once it exists.
          </span>
          <button
            v-if="view === 'list'"
            type="button"
            class="text-dense rounded px-3 py-1.5 hover:opacity-80 disabled:opacity-40"
            style="background: var(--semantic-active-bg); color: var(--semantic-text)"
            data-testid="terminal-footer-new"
            :disabled="busy"
            @click="newTerminal(props.activeWorkspaceId ?? '')"
          >
            New terminal
          </button>
        </div>
      </div>
    </div>
  </Teleport>
</template>
