<script setup lang="ts">
import { onMounted, onUnmounted, onUpdated, ref } from 'vue'
import { Terminal } from '@xterm/xterm'
import { FitAddon } from '@xterm/addon-fit'
import UiIcon from '../../ui/UiIcon.vue'
import '@xterm/xterm/css/xterm.css'
import {
  ApiError,
  createTerminalSession,
  deleteTerminalSession,
  getTerminalOutput,
  resizeTerminal,
  sendTerminalInput,
} from '../../../api'

const props = defineProps<{
  cwd: string
  /**    * Per-chat persistence key. With it, session ids survive tab/chat switches via localStorage and
   * re-attach on return; without it sessions are deleted on unmount. */
  sessionKey?: string
}>()

const MAX_TERMINALS = 20
const WS_BASE_DELAY_MS = 1000
const WS_MAX_DELAY_MS = 30000

interface TermSession {
  id: string
  pid: number
  label: string
}

const container = ref<HTMLElement | null>(null)
const sessions = ref<TermSession[]>([])
const activeId = ref<string | null>(null)
// True while `restoreSessions` validates the stored ids against the server. Without it the panel
// renders its "No terminal yet" empty state during that window — a lie for a user who had three
// terminals open before a reload.
const isRestoring = ref(false)
// Idle until the user explicitly starts a terminal — mounting the tab
// (ChatRightSidebar keeps it mounted via v-show) must not spawn a PTY.
const status = ref('No terminal — click + to start a new one')
const exitedIds = ref<Set<string>>(new Set())

let term: Terminal | null = null
let fit: FitAddon | null = null
let lastCols = 0
let lastRows = 0
let disposed = false
let resizeObserver: ResizeObserver | null = null
let ws: WebSocket | null = null
let wsOpened = false
let wsAttempt = 0
let wsRetryTimer: ReturnType<typeof setTimeout> | null = null
let sessionCounter = 0
const mountedAt = Date.now()
// Mount-time cwd resolution grace: with a git worktree the value resolves as '' -> session dir ->
// worktree dir on every mount.
const hasSessionKey = () => (props.sessionKey ?? '').length > 0
const storageKey = () => `pabrik-terminal-sessions:${props.sessionKey}`

interface StoredSession {
  id: string
  label: string
}

const loadStored = (): StoredSession[] => {
  if (!hasSessionKey()) return []
  try {
    const raw = localStorage.getItem(storageKey())
    if (!raw) return []
    const parsed: unknown = JSON.parse(raw)
    if (!Array.isArray(parsed)) return []
    return parsed
      .filter(
        (s): s is StoredSession =>
          !!s &&
          typeof (s as StoredSession).id === 'string' &&
          (s as StoredSession).id.length > 0 &&
          typeof (s as StoredSession).label === 'string',
      )
      .slice(0, 10)
  } catch {
    return []
  }
}

const saveStored = () => {
  if (!hasSessionKey()) return
  try {
    localStorage.setItem(
      storageKey(),
      JSON.stringify(sessions.value.map((s) => ({ id: s.id, label: s.label })).slice(0, 10)),
    )
  } catch {
    // Storage full/blocked — persistence degrades to this tab's lifetime.
  }
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

const wsBackoffDelay = (attempt: number): number => {
  const exp = Math.min(WS_BASE_DELAY_MS * 2 ** (attempt - 1), WS_MAX_DELAY_MS)
  return exp * (0.5 + 0.5 * Math.random())
}

const closeWs = () => {
  const socket = ws
  ws = null
  wsOpened = false
  if (socket && socket.readyState !== WebSocket.CLOSED) {
    try {
      socket.close()
    } catch {
      // Already gone — nothing to do.
    }
  }
}

const scheduleWsReconnect = (reason: string) => {
  if (disposed) return
  const id = activeId.value
  if (!id || exitedIds.value.has(id)) return
  if (wsRetryTimer !== null) return
  wsAttempt += 1
  const delay = wsBackoffDelay(wsAttempt)
  status.value = `${reason} — reconnecting… (attempt ${wsAttempt})`
  wsRetryTimer = setTimeout(() => {
    wsRetryTimer = null
    connectWs()
  }, delay)
}

const markExited = (id: string, exitCode: number | null | undefined) => {
  exitedIds.value.add(id)
  if (id !== activeId.value) return
  status.value =
    exitCode === null || exitCode === undefined
      ? 'shell exited'
      : `shell exited (code ${exitCode}) — Reconnect for a new one`
  clearWsRetry()
  closeWs()
}

const handleWsMessage = (event: MessageEvent) => {
  const data = event.data
  if (typeof data === 'string') {
    try {
      const msg = JSON.parse(data) as { type?: string; exit_code?: number | null }
      if (msg.type === 'exit' && activeId.value) markExited(activeId.value, msg.exit_code)
    } catch {
      // Non-JSON text — ignore.
    }
    return
  }
  const bytes =
    data instanceof ArrayBuffer
      ? new Uint8Array(data)
      : ArrayBuffer.isView(data)
        ? new Uint8Array(data.buffer as ArrayBuffer, data.byteOffset, data.byteLength)
        : null
  if (bytes) {
    term?.write(new TextDecoder().decode(bytes).replace(/\n/g, '\r\n'))
  } else if (data instanceof Blob) {
    void data.text().then((text) => {
      if (!disposed) term?.write(text.replace(/\n/g, '\r\n'))
    })
  }
}

const connectWs = () => {
  const id = activeId.value
  if (!id || disposed) return
  closeWs()
  // Re-attach replays the full server buffer, so clear a reconnected
  // view to avoid duplicated scrollback. First attach starts empty.
  if (wsAttempt > 0) term?.clear()
  let socket: WebSocket
  try {
    socket = new WebSocket(wsUrl(id))
  } catch {
    scheduleWsReconnect('socket unavailable')
    return
  }
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
    if (!wsOpened) void validateOrReclaim('socket failed')
  }
  socket.onclose = () => {
    if (ws !== socket || disposed) return
    if (!wsOpened) {
      void validateOrReclaim('socket failed')
    } else {
      wsOpened = false
      if (activeId.value && !exitedIds.value.has(activeId.value)) {
        scheduleWsReconnect('socket closed')
      }
    }
  }
}

const validateOrReclaim = async (reason: string) => {
  const id = activeId.value
  if (!id || disposed) return
  try {
    await getTerminalOutput(id, 0)
  } catch (err) {
    if (err instanceof ApiError && err.status === 404) {
      reclaimGoneSession('Terminal was reclaimed (idle) — switched session…')
      return
    }
  }
  scheduleWsReconnect(reason)
}

const reclaimGoneSession = (notice: string) => {
  const goneId = activeId.value
  if (!goneId || disposed) return
  clearWsRetry()
  closeWs()
  sessions.value = sessions.value.filter((s) => s.id !== goneId)
  exitedIds.value.delete(goneId)
  saveStored()
  if (sessions.value.length === 0) {
    // No auto-spawn: the user must explicitly start a new terminal.
    activeId.value = null
    term?.clear()
    status.value = 'No terminal — click + to start a new one'
    return
  }
  status.value = notice
  const next = sessions.value[0]!
  term?.clear()
  activeId.value = next.id
  status.value = 'connecting…'
  wsAttempt = 0
  connectWs()
}

const sendInput = (data: string) => {
  const id = activeId.value
  if (!id || (id && exitedIds.value.has(id))) return
  if (ws && wsOpened && ws.readyState === WebSocket.OPEN) {
    try {
      ws.send(JSON.stringify({ type: 'input', data }))
      return
    } catch {
      // Fall through to REST.
    }
  }
  sendTerminalInput(id, data).catch(() => {
    status.value = 'input failed — retrying…'
  })
}

const fitAndResize = async () => {
  const id = activeId.value
  if (!term || !fit || !id || exitedIds.value.has(id)) return
  try {
    fit.fit()
  } catch {
    return
  }
  const { cols, rows } = term
  if (cols === lastCols && rows === lastRows) return
  lastCols = cols
  lastRows = rows
  if (ws && wsOpened && ws.readyState === WebSocket.OPEN) {
    try {
      ws.send(JSON.stringify({ type: 'resize', cols, rows }))
      return
    } catch {
      // Fall through to REST.
    }
  }
  try {
    await resizeTerminal(id, cols, rows)
  } catch {
    // Resize is best-effort; the session keeps running at its old size.
  }
}

const switchSession = (id: string) => {
  if (id === activeId.value || disposed) return
  clearWsRetry()
  closeWs()
  term?.clear()
  activeId.value = id
  // Always (re-)attach: the server flushes the buffered history first,
  // then sends the exit event for dead shells — so switching back to
  // an exited session still shows its history, not an empty view.
  status.value = 'connecting…'
  wsAttempt = 0
  connectWs()
}

const maxLabelNum = () => {
  let max = 0
  for (const s of sessions.value) {
    const m = /(\d+)\s*$/.exec(s.label)
    if (m) max = Math.max(max, parseInt(m[1]!, 10))
  }
  return max
}

const awaitCwd = async (): Promise<string> => {
  // Wait for a STABLE cwd: with a git worktree the value resolves as
  // '' -> session dir -> worktree dir in quick succession. Returning
  // the first non-empty value would spawn the shell in the wrong dir.
  const start = Date.now()
  let stableSince = 0
  let last = ''
  while (!disposed && Date.now() - start < 2000) {
    const cur = props.cwd
    if (cur && cur === last) {
      if (Date.now() - stableSince >= 300) return cur
    } else {
      last = cur
      stableSince = Date.now()
    }
    await new Promise((resolve) => setTimeout(resolve, 50))
  }
  return props.cwd
}

const newSession = async () => {
  if (disposed) return
  if (sessions.value.length >= MAX_TERMINALS) {
    status.value = `Max ${MAX_TERMINALS} terminals — close one to open a new shell`
    return
  }
  status.value = 'connecting…'
  try {
    fit?.fit()
    // effectiveCwd resolves shortly after mount (session load); wait briefly so a fresh shell
    // spawns in the chat dir instead of the server-cwd fallback. Restored sessions skip this
    // (re-attach by id needs no cwd).
    const cwd = await awaitCwd()
    // The wait above can outlive the tab (unmount during the stability
    // window): never spawn into a dead component — leaked creates
    // shift every later test's ids and sockets.
    if (disposed) return
    const session = await createTerminalSession(cwd, {
      cols: term?.cols ?? 80,
      rows: term?.rows ?? 24,
    })
    if (disposed) {
      await deleteTerminalSession(session.id).catch(() => {})
      return
    }
    sessionCounter += 1
    sessions.value.push({ id: session.id, pid: session.pid, label: `term ${sessionCounter}` })
    saveStored()
    switchSession(session.id)
  } catch (err) {
    if (err instanceof ApiError && err.status === 429) {
      status.value = `Max ${MAX_TERMINALS} terminals — close one to open a new shell`
      return
    }
    status.value =
      err instanceof Error ? `failed to start: ${err.message}` : 'failed to start shell'
  }
}

const restoreSessions = async () => {
  if (disposed) return
  if (!hasSessionKey()) {
    // No persistence key and no explicit user action — stay empty.
    return
  }
  const stored = loadStored()
  if (stored.length === 0) {
    // First visit: wait for the user to click + instead of spawning.
    return
  }
  isRestoring.value = true
  // Validate each stored id (server restarts and LRU eviction drop the
  // in-memory registry). Survivors re-attach below with full scrollback.
  const alive: TermSession[] = []
  for (const s of stored) {
    if (disposed) return
    try {
      await getTerminalOutput(s.id, 0)
      alive.push({ id: s.id, pid: 0, label: s.label })
    } catch {
      // 404/gone (or transient failure) — drop the id.
    }
  }
  if (disposed) return
  sessions.value = alive
  isRestoring.value = false
  // Continue numbering past the highest restored label (stored labels
  // may be non-sequential after closes — alive.length would collide).
  sessionCounter = Math.max(alive.length, maxLabelNum())
  saveStored()
  if (alive.length === 0) {
    // All stored ids are gone (restart/LRU) — stay empty until explicit action.
    activeId.value = null
    status.value = 'No terminal — click + to start a new one'
    return
  }
  activeId.value = alive[0]!.id
  status.value = 'connecting…'
  wsAttempt = 0
  connectWs()
}

const closeSession = async (id: string) => {
  const idx = sessions.value.findIndex((s) => s.id === id)
  if (idx === -1) return
  const wasActive = id === activeId.value
  if (wasActive) {
    clearWsRetry()
    closeWs()
  }
  sessions.value.splice(idx, 1)
  exitedIds.value.delete(id)
  saveStored()
  await deleteTerminalSession(id).catch(() => {})
  if (disposed) return
  if (sessions.value.length === 0) {
    // Empty state is allowed — the user starts the next shell explicitly.
    activeId.value = null
    term?.clear()
    status.value = 'No terminal — click + to start a new one'
    return
  }
  if (wasActive) {
    const next = sessions.value[Math.min(idx, sessions.value.length - 1)]!
    term?.clear()
    activeId.value = next.id
    if (exitedIds.value.has(next.id)) {
      status.value = 'shell exited — Reconnect for a new one'
    } else {
      status.value = 'connecting…'
      wsAttempt = 0
      connectWs()
    }
  }
}

const reconnectActive = async () => {
  const id = activeId.value
  if (!id) {
    await newSession()
    return
  }
  const idx = sessions.value.findIndex((s) => s.id === id)
  clearWsRetry()
  closeWs()
  sessions.value.splice(idx, 1)
  exitedIds.value.delete(id)
  saveStored()
  await deleteTerminalSession(id).catch(() => {})
  if (disposed) return
  term?.clear()
  await newSession()
}

const clear = () => term?.clear()

onMounted(() => {
  term = new Terminal({
    fontSize: 12,
    fontFamily: 'ui-monospace, SFMono-Regular, Menlo, monospace',
    cursorBlink: true,
    scrollback: 5000,
    theme: { background: '#0f0e0c', foreground: '#c5c9c5', cursor: '#c5c9c5' },
  })
  fit = new FitAddon()
  term.loadAddon(fit)
  // Test hook (dev only): functional_ui tests drive a real browser and assert on the terminal
  // buffer, which xterm renders to <canvas> (no DOM text to query). Exposes the live Terminal for
  // buffer reads; never set in production builds.
  if (import.meta.env.DEV) {
    ;(window as unknown as { __pabrikTerm?: Terminal }).__pabrikTerm = term
  }
  if (container.value) {
    term.open(container.value)
    term.onData((data) => sendInput(data))
    resizeObserver = new ResizeObserver(() => {
      void fitAndResize()
    })
    resizeObserver.observe(container.value)
  }
  void restoreSessions()
})

// Cwd scope sync (prev-value guard on update — same guards the watcher
// had; no immediate run, matching the old watcher).
async function syncCwdScope(next: string, prev: string) {
  if (next === prev || disposed) return
  // Initial '' → dir resolution is NOT a scope change: fresh mounts already waited for cwd in
  // newSession, and restored sessions re-attach by id (cwd-independent). Dropping here is what
  // wiped restored sessions on every chat return ("always a new term").
  if (!prev) return
  // Mount-time resolution grace (git worktree '' → session → worktree
  // flips): ignore dir → dir changes inside the grace window, only a
  // settled scope change restarts shells.
  if (Date.now() - mountedAt < 3000) return
  // Cwd scope changed: drop every session. Only restart a shell when
  // the user already had terminals — an empty tab stays empty until
  // explicit action (no auto-spawn on view open / chat switch).
  clearWsRetry()
  closeWs()
  const ids = sessions.value.map((s) => s.id)
  const hadSessions = ids.length > 0
  sessions.value = []
  exitedIds.value = new Set()
  activeId.value = null
  await Promise.all(ids.map((id) => deleteTerminalSession(id).catch(() => {})))
  if (disposed) return
  term?.clear()
  if (!hadSessions) {
    status.value = 'No terminal — click + to start a new one'
    return
  }
  await newSession()
}

let prevCwd = props.cwd
onUpdated(() => {
  const next = props.cwd
  if (next === prevCwd) return
  const prev = prevCwd
  prevCwd = next
  void syncCwdScope(next, prev)
})

onUnmounted(() => {
  disposed = true
  clearWsRetry()
  closeWs()
  resizeObserver?.disconnect()
  resizeObserver = null
  if (hasSessionKey()) {
    // Persistent mode: the server keeps the shells alive; only record
    // the ids so the next mount re-attaches (LRU eviction bounds the
    // registry server-side).
    saveStored()
  } else {
    const ids = sessions.value.map((s) => s.id)
    for (const id of ids) void deleteTerminalSession(id).catch(() => {})
  }
  sessions.value = []
  activeId.value = null
  if (import.meta.env.DEV) {
    ;(window as unknown as { __pabrikTerm?: Terminal }).__pabrikTerm = undefined
  }
  term?.dispose()
  term = null
  fit = null
})
</script>

<template>
  <div class="flex flex-col h-full min-h-0" data-testid="terminal-tab">
    <div
      class="flex items-center gap-1 px-2 h-8 shrink-0 overflow-x-auto"
      style="border-bottom: 1px solid var(--color-border)"
      role="tablist"
      aria-label="Terminal sessions"
    >
      <button
        v-for="s in sessions"
        :key="s.id"
        type="button"
        role="tab"
        :aria-selected="s.id === activeId"
        class="flex items-center gap-1 text-meta rounded px-2 py-0.5 whitespace-nowrap hover:opacity-80"
        :style="
          s.id === activeId
            ? 'background: var(--semantic-active-bg); color: var(--semantic-text)'
            : 'color: var(--semantic-text-dim)'
        "
        :title="`terminal session ${s.label}`"
        data-testid="terminal-session-chip"
        :data-id="s.id"
        @click="switchSession(s.id)"
      >
        {{ s.label }}{{ exitedIds.has(s.id) ? ' ○' : ' ●' }}
        <span
          class="hover:opacity-100 opacity-60 px-0.5"
          title="Close session"
          data-testid="terminal-session-close"
          :data-id="s.id"
          @click.stop="closeSession(s.id)"
        >
          ✕
        </span>
      </button>
      <button
        type="button"
        class="text-meta rounded px-2 py-0.5 hover:opacity-70 whitespace-nowrap disabled:opacity-40 disabled:cursor-not-allowed"
        style="color: var(--semantic-text-dim)"
        :title="
          sessions.length >= MAX_TERMINALS
            ? `Max ${MAX_TERMINALS} terminals`
            : 'New terminal session'
        "
        data-testid="terminal-new"
        :disabled="sessions.length >= MAX_TERMINALS"
        @click="newSession"
      >
        +
      </button>
      <span
        class="text-meta whitespace-nowrap"
        style="color: var(--semantic-text-dim)"
        data-testid="terminal-count"
        :title="`${sessions.length} of ${MAX_TERMINALS} terminals`"
      >
        {{ sessions.length }}/{{ MAX_TERMINALS }}
      </span>
      <span
        class="text-meta truncate flex-1 text-right"
        style="color: var(--semantic-text-dim)"
        data-testid="terminal-cwd"
        :title="cwd"
      >
        <UiIcon name="folder-open" size-class="w-3 h-3" /> {{ cwd || '(no cwd)' }}
      </span>
      <button
        type="button"
        class="text-meta rounded px-2 py-0.5 hover:opacity-70"
        style="color: var(--semantic-text-dim)"
        title="Reconnect active session (new shell)"
        data-testid="terminal-reconnect"
        @click="reconnectActive"
      >
        ⟲
      </button>
      <button
        type="button"
        class="text-meta rounded px-2 py-0.5 hover:opacity-70"
        style="color: var(--semantic-text-dim)"
        title="Clear terminal"
        data-testid="terminal-clear"
        @click="clear"
      >
        <UiIcon name="sparkle" />
      </button>
      <button
        type="button"
        class="text-meta rounded px-2 py-0.5 hover:opacity-70"
        style="color: var(--semantic-text-dim)"
        title="Kill active session"
        data-testid="terminal-kill"
        @click="() => activeId && closeSession(activeId)"
      >
        ✂
      </button>
    </div>
    <div class="relative flex-1 min-h-0 px-1" data-testid="terminal-xterm-wrap">
      <div ref="container" class="h-full min-h-0" data-testid="terminal-xterm" />
      <!-- Restoring placeholder — shown while the stored session ids are
           validated against the server. Without it the "No terminal yet"
           empty state below fires during that window, which is a lie for
           a user who had terminals open before a reload. -->
      <div
        v-if="isRestoring"
        class="absolute inset-0 flex items-center justify-center"
        data-testid="terminal-restoring"
        role="status"
        aria-label="Restoring terminals"
      >
        <div
          class="w-5 h-5 border-2 rounded-full animate-spin"
          style="border-color: var(--color-aqua); border-top-color: transparent"
        ></div>
      </div>
      <div
        v-else-if="sessions.length === 0"
        class="absolute inset-0 flex flex-col items-center justify-center gap-2 text-center px-4"
        data-testid="terminal-empty"
      >
        <div class="text-dense" style="color: var(--semantic-text)">No terminal yet</div>
        <div class="text-meta" style="color: var(--semantic-text-dim)">
          Terminals only start when you ask - nothing spawns on open.
        </div>
        <button
          type="button"
          class="text-dense rounded px-3 py-1.5 hover:opacity-80"
          style="background: var(--semantic-active-bg); color: var(--semantic-text)"
          data-testid="terminal-empty-new"
          @click="newSession"
        >
          + New terminal
        </button>
      </div>
    </div>
    <div
      class="px-3 h-6 shrink-0 flex items-center text-meta truncate"
      style="color: var(--semantic-text-dim); border-top: 1px solid var(--color-border)"
      data-testid="terminal-status"
    >
      {{ status }}
    </div>
  </div>
</template>
