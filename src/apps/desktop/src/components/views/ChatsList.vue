<script setup lang="ts">
import { ref, inject, onMounted, onUnmounted, onUpdated, nextTick, computed, type Ref } from 'vue'
import { useRouter } from 'vue-router'
import { useNavigationStore } from '../../stores/navigation'
import { useWorkspacesStore } from '../../stores/workspaces'
import { useSidebarStore } from '../../stores/sidebar'
import { useCurrentMainView } from '../../composables/useCurrentMainView'
import { buildAppUrl } from '../../helpers/appUrl'
import { useContextMenu } from '../../composables/useContextMenu'
import { isBackgroundOpenEvent } from '../../helpers/tabTarget'
import { openInNewTab } from '../../helpers/openInNewTab'
import { VirtualScroller, formatRelativeTime } from '../../helpers'
import {
  fetchPrInfoCached,
  fetchPrStatusCached,
  fetchPrConflictCached,
  branchUrlFromPrUrl,
  onPrStatusInvalidated,
} from '../../helpers/prStatusCache'
import { useAgentErrorStore } from '../../stores/agentError'
import { parseAgentErrorHeadline } from '../../helpers/parseAgentErrorHeadline'
import { sessionEngineDb, toSessionRow } from '../../sync/SessionEngineDb'
import { runSyncEffect, runSyncEffectOr, runSyncVoid } from '../../sync/runtime'
import * as api from '../../api'
import WorkerElapsedChip from '../WorkerElapsedChip.vue'
import SidebarSkeleton from '../shell/SidebarSkeleton.vue'
import ChatRowContextMenu from '../shell/ChatRowContextMenu.vue'
import RenameTaskModal from '../dialogs/RenameTaskModal.vue'
import GitBranchMenu from '../shell/GitBranchMenu.vue'
import UiIcon from '../ui/UiIcon.vue'

const router = useRouter()

// Props
// eslint-disable-next-line @typescript-eslint/no-unused-vars -- kept for diff readability.
const props = defineProps<{
  collapsed?: boolean
}>()

const emit = defineEmits<{
  navigate: [id: string, chatName?: string]
}>()

// Stores
const navigationStore = useNavigationStore()
const sidebarStore = useSidebarStore()
const workspacesStore = useWorkspacesStore()

// Same Pinia store the kanban card and ChatView read. It outlives
// ChatView remounts, so the badge stays in sync across session
// switches without a second fetch.
const agentErrorStore = useAgentErrorStore()

type StatusBadgeRow = {
  id: string
  last_finish_reason?: string
  needs_human_review?: boolean
}

const isAwaitingReview = (row: StatusBadgeRow): boolean =>
  row.needs_human_review === true && row.last_finish_reason === 'stop'

// The `last_finish_reason === 'stop'` gate is load-bearing: without it a
// stale `needs_human_review: false` + `finish_reason: 'tool_calls'`
// state paints a phantom "reviewed" checkmark mid-turn.
const isReviewed = (row: StatusBadgeRow): boolean =>
  !isAwaitingReview(row) && row.last_finish_reason === 'stop'

const rowAgentError = (id: string) => agentErrorStore.bySession[id] ?? null
const rowErrorRetryLabel = (id: string): string | null => {
  const entry = rowAgentError(id)
  return entry ? parseAgentErrorHeadline(entry.content).retryLabel : null
}

// URL-driven "what is the main content area showing?". See useCurrentMainView for the full
// contract. See useCurrentMainView for the full contract.
const currentMainView = useCurrentMainView()

// Workspace scope for the CHATS list (plan: 2026-09-22-revamp-ui-chats). The list shows ONLY this
// workspace's sessions — the backend filters via `?workspace_id=`. Source: the URL path workspace
// when present, else the store's active workspace (landing / transition windows).
const scopedWorkspaceId = computed(() => {
  const v = currentMainView.value
  if (v.kind === 'chat' && v.workspaceId) return v.workspaceId
  if (v.kind === 'workspace' && v.workspaceId) return v.workspaceId
  return workspacesStore.activeWorkspace?.id
})

// Reactive active check for a chat row. Called from the template on every render so the row's
// highlight stays in sync with URL changes (pre-fix, `active` was set as a one-shot flag inside
// `loadChats()` — leaving it stale after a chat → workspace navigation).
const isCurrentChat = (sessionId: string): boolean =>
  currentMainView.value.kind === 'chat' && currentMainView.value.sessionId === sessionId

// Migration 082 - "AI is ahead of you" stale-dot check.
// Both come from the backend as unix-ms strings (Migration 075
// convention) - we compare as numbers.
const isStale = (human: string | undefined, updated: string | undefined): boolean => {
  if (!human) return false
  if (!updated) return false
  // Both fields are SQLite datetime UTC strings ('YYYY-MM-DD HH:MM:SS') - identical format - so
  // lexicographic string comparison is the most accurate (and fastest) way to detect 'updated_at >
  // human_time'.
  return updated > human
}

// Single-badge rule: the orange awaiting-review dot already covers
// the "AI is ahead" state, so the amber stale dot stays hidden then.
// Without this both dots paint together (same SQL predicate).
type StaleDotRow = StatusBadgeRow & {
  last_human_touched_at?: string
  updated_at?: string
}

const shouldShowStaleDot = (item: StaleDotRow): boolean => {
  if (isAwaitingReview(item)) return false
  return isStale(item.last_human_touched_at, item.updated_at)
}

// Inject processingState from App.vue
const processingState = inject<Ref<Record<string, boolean>>>('processingState', ref({}))

// PR branch badges use the same palette as WorkspaceItemTaskCard:
// green = open, violet = merged, red = closed. Rows without a pull
// request omit the badge entirely.
const prStatuses = ref<Record<string, string>>({})
// Conflict-only hint per chat: true when the PR reports CONFLICTING/DIRTY.
// Quiet-when-clean — absent/false for mergeable, unknown, or failed fetches.
const prConflicts = ref<Record<string, boolean>>({})
const prSeqByChat = new Map<string, number>()

type ChatRow = {
  id: string
  cwd?: string
  git_worktree_cwd?: string
  git_branch?: string
}

const effectiveChatCwd = (item: ChatRow): string => item.git_worktree_cwd || item.cwd || ''

const chatBranchStyle = (id: string): Record<string, string> => {
  const s = prStatuses.value[id] || ''
  if (s === 'merged') return { color: 'var(--color-violet)', fontWeight: '600' }
  if (s === 'closed') return { color: 'var(--semantic-error)', fontWeight: '600' }
  if (s === 'open') return { color: 'var(--color-green)', fontWeight: '600' }
  return { color: 'var(--color-orange)', fontWeight: '600' }
}

const chatBranchTitle = (item: ChatRow): string => {
  const branch = item.git_branch || ''
  const s = prStatuses.value[item.id] || ''
  const conflictSuffix = prConflicts.value[item.id] ? ' — merge conflicts' : ''
  const base =
    s === 'merged'
      ? `PR merged — ${branch}`
      : s === 'closed'
        ? `PR closed — ${branch}`
        : s === 'open'
          ? `PR open${conflictSuffix} — ${branch}`
          : prConflicts.value[item.id]
            ? `${branch} — merge conflicts`
            : branch
  // Surface the worktree path alongside the branch so the full
  // checkout location stays discoverable on hover.
  if (item.git_worktree_cwd) return `${base} — ${item.git_worktree_cwd}`
  return base
}

const refreshChatPrStatus = async (item: ChatRow) => {
  const branch = item.git_branch || ''
  const cwd = effectiveChatCwd(item)
  if (!branch || !cwd) {
    if (prStatuses.value[item.id]) delete prStatuses.value[item.id]
    if (prConflicts.value[item.id]) delete prConflicts.value[item.id]
    return
  }
  const seq = (prSeqByChat.get(item.id) || 0) + 1
  prSeqByChat.set(item.id, seq)
  // Shared cache: dedupes the list-load burst across rows, retries
  // transient failures, resolves '' (fail-silent) when unknown.
  const [status, hasConflict] = await Promise.all([
    fetchPrStatusCached(cwd, branch),
    fetchPrConflictCached(cwd, branch),
  ])
  if (prSeqByChat.get(item.id) !== seq) return
  if (status) prStatuses.value[item.id] = status
  else if (prStatuses.value[item.id]) delete prStatuses.value[item.id]
  if (hasConflict) prConflicts.value[item.id] = true
  else if (prConflicts.value[item.id]) delete prConflicts.value[item.id]
}

// Helper to check if a session is processing. Reads the injected
// processingState live so rows reflect spinner state without mirroring
// it onto each row object.
const isProcessing = (id: string): boolean => !!processingState.value[id]

// State
const chatsLoading = ref(false)
const navItems = ref<
  {
    id: string
    name: string
    active?: boolean
    relativeTime?: string
    selected_profile_model?: string
    sub_agent_name?: string
    parent_session_id?: string
    cwd?: string
    git_worktree_cwd?: string
    git_branch?: string
    is_auto_retry_until_stop?: string
    last_human_touched_at?: string
    updated_at?: string
    // Raw `updated_at` sort value (matches the backend
    // `sort_by=updated_at` order). Used for display sorting and for
    // cache-first scroll-back (`loadOlderFromCache`).
    sortKey?: string
    // Migration 104 — pinned sessions (PINNED section above RECENT).
    is_pinned?: boolean
    pinned_position?: number
    last_finish_reason?: string
    needs_human_review?: boolean
  }[]
>([])
const chatsHasMore = ref(false)
const chatsNextCursor = ref<string | null>(null)
const chatsSortDirection = ref<'asc' | 'desc'>(navigationStore.chatsSortDirection)
const chatsTotal = ref(0)

// Resolve PR colors whenever the row list (re)populates — same burst
// pattern as the kanban board mount. Runs at the end of loadChats().
const burstChatPrStatus = () => {
  for (const item of navItems.value || []) {
    if (item.git_branch) void refreshChatPrStatus(item)
  }
}

// A merge or close ANYWHERE — this tab's MergeBox, or the `git_pr_state` SSE event from another
// client — drops the shared cache entry and calls this back.
let unsubscribePrStatus: (() => void) | null = null
onMounted(() => {
  unsubscribePrStatus = onPrStatusInvalidated(() => {
    burstChatPrStatus()
  })
})
onUnmounted(() => {
  unsubscribePrStatus?.()
  unsubscribePrStatus = null
})

// Right-click action menu for a chat row. Position state + dismiss
// wiring live in useContextMenu; the row payload lives here so the menu
// can label itself and so each emit knows WHICH row was picked.
const { menuPos, openAt, close: closeContextMenu } = useContextMenu()
const contextMenuChatId = ref<string | null>(null)

// Mirrors `navItems`'s element shape. Kept as a separate ref rather
// than re-reading navItems on every emit so the menu keeps rendering
// the row it was opened on even if the list reloads underneath it.
const contextMenuChat = ref<{
  id: string
  name: string
  selected_profile_model?: string
  is_auto_retry_until_stop?: string
  is_pinned?: boolean
} | null>(null)

// Re-entry lock for "Stop agent": the row stays actionable while the
// POST is in flight otherwise, and a double-click fires it twice.
const isStoppingChat = ref(false)

const onChatRowContextMenu = (
  event: MouseEvent,
  item: { id: string; name: string; is_pinned?: boolean },
) => {
  contextMenuChatId.value = item.id
  contextMenuChat.value = item
  openAt(event)
}

// Read the picked row straight off navItems so handlers always see the
// freshest `selected_profile_model` / `is_auto_retry_until_stop`, falling
// back to the snapshot taken at open time.
const pickedChat = () => {
  const id = contextMenuChatId.value
  if (!id) return null
  return navItems.value.find((item) => item.id === id) ?? contextMenuChat.value
}

const openContextMenuInBackground = () => {
  const id = contextMenuChatId.value
  contextMenuChatId.value = null
  contextMenuChat.value = null
  closeContextMenu()
  if (!id) return
  openChatInNewTab({ id })
}

// ─── Rename ──────────────────────────────────────────────────────────────── Goes through
// `api.updateTaskSimple`, NOT `api.updateSession`, and the difference is load-bearing:
// updateTaskSimple → PUT /api/workspaces/tasks/:task_id → task_update.updateTaskName → cascade to.
const renameModalOpen = ref(false)
const renameModalName = ref('')

const startRenameFromMenu = () => {
  const chat = pickedChat()
  if (!chat) return
  closeContextMenu()
  renameModalName.value = chat.name
  renameModalOpen.value = true
}

const confirmRename = async (name: string) => {
  const id = contextMenuChatId.value ?? contextMenuChat.value?.id ?? null
  // The menu is already closed; the row is identified by the last pick.
  const targetId = id ?? navItems.value.find((item) => item.name === renameModalName.value)?.id
  if (!targetId) return

  // Optimistic paint so the row doesn't flicker back to the old name
  // while the PUT is in flight. The SSE reload replaces this a moment
  // later regardless of the outcome.
  const row = navItems.value.find((item) => item.id === targetId)
  if (row) row.name = name

  try {
    await api.updateTaskSimple(targetId, { name })
  } catch (err) {
    // Revert: the server is the source of truth and the SSE reload will
    // restore it, but do not leave a name on screen that was never saved.
    if (row) row.name = renameModalName.value
    console.error('Failed to rename chat:', err)
  }
}

// ─── Unattended mode ───────────────────────────────────────────────────────
// `is_auto_retry_until_stop` lives on `sessions`, so this one genuinely has to go through
// updateSession — which means selectedAgent must be sent back explicitly.
const isUnattended = (chat: { is_auto_retry_until_stop?: string }): boolean =>
  chat.is_auto_retry_until_stop === '1'

const toggleUnattendedFromMenu = async () => {
  const chat = pickedChat()
  closeContextMenu()
  if (!chat) return

  const next = isUnattended(chat) ? '0' : '1'
  const row = navItems.value.find((item) => item.id === chat.id)
  const previous = row?.is_auto_retry_until_stop
  // Optimistic flip; reverted on failure. KanbanView.handleUnattendedToggle
  // lets SSE repaint instead, but a context-menu pick reads as a toggle
  // and an un-flipped switch under the cursor looks broken.
  if (row) row.is_auto_retry_until_stop = next

  try {
    await api.updateSession(chat.id, {
      isAutoRetryUntilStop: next,
      selectedAgent: chat.selected_profile_model ?? '',
    })
  } catch (err) {
    if (row) row.is_auto_retry_until_stop = previous
    console.error('Failed to toggle unattended mode:', err)
  }
}

// ─── Stop agent ────────────────────────────────────────────────────────────
const stopAgentFromMenu = async () => {
  const chat = pickedChat()
  closeContextMenu()
  if (!chat || isStoppingChat.value) return
  isStoppingChat.value = true
  try {
    await api.stopSession(chat.id)
  } catch (err) {
    // stopSession already swallows transport failures into
    // {success:false}; this only fires on a programming error.
    console.error('Failed to stop agent:', err)
  } finally {
    isStoppingChat.value = false
  }
}

// Right-click menu on the git icon: open GitHub branch / PR URLs in a new tab. Separate position
// state from the row menu so a git-icon right-click never opens the chat menu.
const { menuPos: gitMenuPos, openAt: openGitMenuAt, close: closeGitMenu } = useContextMenu()
const gitMenuBranch = ref('')
const gitMenuBranchUrl = ref('')
const gitMenuPrUrl = ref('')

const onGitIconContextMenu = async (event: MouseEvent, item: ChatRow) => {
  event.preventDefault()
  event.stopPropagation()
  const branch = item.git_branch || ''
  const cwd = effectiveChatCwd(item)
  gitMenuBranch.value = branch
  gitMenuBranchUrl.value = ''
  gitMenuPrUrl.value = ''
  openGitMenuAt(event)
  if (!branch || !cwd) return
  try {
    const info = await fetchPrInfoCached(cwd, branch)
    // Stale guard: user may have right-clicked another icon while
    // this fetch was in flight.
    if (gitMenuBranch.value !== branch) return
    gitMenuPrUrl.value = info.prUrl || ''
    gitMenuBranchUrl.value = branchUrlFromPrUrl(info.prUrl || '', branch)
  } catch {
    // Fail-silent: menu stays open with disabled items.
  }
}

const openGitBranchInBackground = () => {
  const url = gitMenuBranchUrl.value
  closeGitMenu()
  if (!url) return
  window.open(url, '_blank', 'noopener')
}

const openGitPrInBackground = () => {
  const url = gitMenuPrUrl.value
  closeGitMenu()
  if (!url) return
  window.open(url, '_blank', 'noopener')
}

// Sort toggle extracted to a method so the template stays a single expression.
const onSortToggle = () => {
  chatsSortDirection.value = chatsSortDirection.value === 'desc' ? 'asc' : 'desc'
  navigationStore.setChatsSortDirection(chatsSortDirection.value)
  loadChats()
}

// Chats resize handling
const isChatsResizing = ref(false)
const chatsResizeStartY = ref(0)
const chatsResizeStartPx = ref(0)

// ChatsList maintains its OWN navItems mirror of workspacesStore state, populated by loadChats().
const virtualScrollerRef = ref<any>(null) // eslint-disable-line @typescript-eslint/no-explicit-any -- intentional escape hatch; the surrounding type is intentionally opaque.

// Get computed chats height in pixels from percentage
const getChatsHeightPx = (): number => {
  const aside = document.querySelector('aside')
  if (!aside) return 200
  const navHeight = aside.clientHeight - 56 - 48 // header + footer
  return (navHeight * sidebarStore.chatsHeight) / 100
}

const startChatsResize = (e: MouseEvent) => {
  e.preventDefault()
  e.stopPropagation()
  console.log('[ChatsList] startChatsResize', e.clientY)
  isChatsResizing.value = true
  chatsResizeStartY.value = e.clientY
  chatsResizeStartPx.value = getChatsHeightPx()
  document.addEventListener('mousemove', handleChatsResize, { passive: false })
  document.addEventListener('mouseup', stopChatsResize)
  document.body.style.userSelect = 'none'
  document.body.style.cursor = 'row-resize'
}

const handleChatsResize = (e: MouseEvent) => {
  e.preventDefault()
  if (!isChatsResizing.value) return
  console.log(
    '[ChatsList] handleChatsResize',
    e.clientY,
    'delta:',
    e.clientY - chatsResizeStartY.value,
  )
  const deltaY = e.clientY - chatsResizeStartY.value
  const newHeightPx = Math.max(80, chatsResizeStartPx.value + deltaY)
  // Convert back to percentage
  const aside = document.querySelector('aside')
  if (!aside) return
  const navHeight = aside.clientHeight - 56 - 48
  const newPercent = (newHeightPx / navHeight) * 100
  console.log('[ChatsList] newPercent:', newPercent)
  sidebarStore.setChatsHeight(newPercent)
}

const stopChatsResize = () => {
  isChatsResizing.value = false
  document.removeEventListener('mousemove', handleChatsResize)
  document.removeEventListener('mouseup', stopChatsResize)
  document.body.style.userSelect = ''
  document.body.style.cursor = ''
}

// Public methods for parent to call Amber stale-dot clear (yellow-dot-fix): optimistic patch +
// best-effort backend touch. isStale() predicate is unchanged — clearing the dot is done by
// aligning last_human_touched_at to updated_at.
const optimisticClearStaleDot = (id: string) => {
  const item = navItems.value.find((i) => i.id === id)
  if (item && item.updated_at) {
    item.last_human_touched_at = item.updated_at
    item.relativeTime = formatRelativeTime(item.last_human_touched_at)
  }
}

// Loop-guard (touched-echo fix): fireSessionTouched fires at most ONCE per sessionId per component
// lifetime.
const touchedFiredFor = new Set<string>()
const touchedAtMs = new Map<string, number>()
// Echo window: a session.updated arriving within this long after our
// own touched POST is assumed to be the backend echo of that POST,
// not an independent rename — skip the refetch for it.
const TOUCH_ECHO_SUPPRESS_MS = 5000

const fireSessionTouched = (id: string) => {
  if (!id || touchedFiredFor.has(id)) return
  touchedFiredFor.add(id)
  touchedAtMs.set(id, Date.now())
  api.markSessionTouched(id).catch((e) => {
    // Allow retry on failure: a failed stamp never reached the DB,
    // so no SSE echo is coming — drop the guards.
    touchedFiredFor.delete(id)
    touchedAtMs.delete(id)
    console.error('Failed to mark session touched:', e)
  })
}

// Sidebar local-first: the cache partition key. Matches the
// `scopedWorkspaceId` refetch boundary — each workspace paints its own
// cached rows, `'all'` when unscoped (back-compat).
const sessionCacheKey = (): string => scopedWorkspaceId.value ?? 'all'

// Single mapper for server session → row view model, shared by the cache paint and the network paint
// so both shapes stay identical (same "no shape drift" rule as ChatView's toChatMessages).
// eslint-disable-next-line @typescript-eslint/no-explicit-any -- intentional escape hatch; the surrounding type is intentionally opaque.
const toNavItem = (session: any) => ({
  id: session.session_id,
  name: session.session_name || 'New Chat',
  // active state now derives from the URL via isCurrentChat() in the template
  // (sidebar-single-active fix 2026-08-06). Storing it here would freeze the highlight at
  // loadChats() time and leave stale `active: true` after navigation away from chat.
  active: false,
  // Migration 082 — prefer human-touched timestamp when present.
  relativeTime: formatRelativeTime(session.last_human_touched_at || session.updated_at),
  selected_profile_model: session.selected_profile_model || '',
  sub_agent_name: session.sub_agent_name || '',
  parent_session_id: session.parent_session_id || '',
  cwd: session.cwd || '',
  git_worktree_cwd: session.git_worktree_cwd || '',
  git_branch: session.git_branch || '',
  // Migration 063 — defaulted to "0" in getChats mapping so the
  // `=== '1'` badge check below is well-defined.
  is_auto_retry_until_stop: session.is_auto_retry_until_stop || '0',
  // Migration 082 — captured separately for the stale-dot check
  // (compares updated_at vs last_human_touched_at to render the
  // amber "AI is ahead of you" indicator).
  last_human_touched_at: session.last_human_touched_at || '',
  updated_at: session.updated_at || '',
  sortKey: session.updated_at || '',
  // Migration 104 — pinned sessions. Boolean on the wire; default
  // false so legacy caches read as unpinned.
  is_pinned: session.is_pinned ?? false,
  pinned_position: session.pinned_position ?? 0,
  last_finish_reason: session.last_finish_reason || '',
  // NOT `?? false`: a legacy cache row with no field must read as
  // "no badge", not "reviewed".
  needs_human_review: session.needs_human_review ?? undefined,
})

// Display order for cached paints. The engine stores newest-first;
// the backend serves `direction` order — re-apply it here so a warm
// mount in asc mode matches the network order exactly.
const sortNavItemsForDisplay = () => {
  const asc = chatsSortDirection.value === 'asc'
  navItems.value.sort((a, b) => {
    const ak = a.sortKey ?? ''
    const bk = b.sortKey ?? ''
    if (ak === bk) return 0
    return (ak < bk ? -1 : 1) * (asc ? 1 : -1)
  })
}

// Migration 104 — PINNED section above RECENT. Pinned rows sort by
// `pinned_position` DESC (first pinned = highest position = top);
// recents exclude pinned rows entirely so a session never renders twice.
const pinnedItems = computed(() =>
  navItems.value
    .filter((i) => i.is_pinned)
    .slice()
    .sort((a, b) => (b.pinned_position ?? 0) - (a.pinned_position ?? 0)),
)
const recentItems = computed(() => navItems.value.filter((i) => !i.is_pinned))
const recentTotal = computed(() => Math.max(0, chatsTotal.value - pinnedItems.value.length))

// Right-click pin/unpin (Migration 104). Optimistic flip + cache
// write-through; reverted on failure. The SSE reload revalidates
// totals/cursors a moment later regardless of outcome.
const togglePinFromMenu = async () => {
  const chat = pickedChat()
  closeContextMenu()
  if (!chat) return
  const next = !chat.is_pinned
  const row = navItems.value.find((item) => item.id === chat.id)
  const prevPinned = row?.is_pinned
  const prevPos = row?.pinned_position
  if (row) {
    row.is_pinned = next
    if (!next) row.pinned_position = 0
  }
  try {
    const res = await api.pinSession(chat.id, next)
    if (row && next && res && typeof res.pinned_position === 'number') {
      row.pinned_position = res.pinned_position
    }
    await runSyncVoid(
      sessionEngineDb.putLocal(
        sessionCacheKey(),
        navItems.value.map((r) => toSessionRow(mapNavItemToChat(r))),
      ),
      'sessions.putLocal',
    )
  } catch (err) {
    if (row) {
      row.is_pinned = prevPinned
      row.pinned_position = prevPos
    }
    console.error('Failed to toggle session pin:', err)
  }
}

// Minimal Chat shape for the cache write-through above.
// eslint-disable-next-line @typescript-eslint/no-explicit-any
const mapNavItemToChat = (r: any): any => ({
  session_id: r.id,
  session_name: r.name,
  cwd: r.cwd ?? '',
  git_worktree_cwd: r.git_worktree_cwd ?? '',
  git_branch: r.git_branch ?? '',
  updated_at: r.updated_at ?? '',
  selected_profile_model: r.selected_profile_model ?? '',
  is_auto_retry_until_stop: r.is_auto_retry_until_stop ?? '0',
  last_human_touched_at: r.last_human_touched_at ?? '',
  is_pinned: r.is_pinned ?? false,
  pinned_position: r.pinned_position ?? 0,
  last_finish_reason: r.last_finish_reason ?? '',
  needs_human_review: r.needs_human_review ?? undefined,
})

// PINNED drag-drop reorder (Migration 104). HTML5 DnD on the pinned rows only (small list, no
// virtualization): dragstart captures the id, dragover tracks the target + before/after half, drop
// splices + POSTs the full top-to-bottom order.
const dragPinnedId = ref<string | null>(null)
const dragPinnedOverId = ref<string | null>(null)
const dragPinnedBefore = ref(false)

const onPinnedDragStart = (event: DragEvent, id: string) => {
  dragPinnedId.value = id
  dragPinnedOverId.value = null
  event.dataTransfer?.setData('application/x-pinned-session-id', id)
  if (event.dataTransfer) event.dataTransfer.effectAllowed = 'move'
}

const onPinnedDragOver = (event: DragEvent, id: string) => {
  if (!dragPinnedId.value || dragPinnedId.value === id) return
  event.preventDefault()
  const el = event.currentTarget as HTMLElement | null
  const rect = el?.getBoundingClientRect()
  const before = rect ? event.clientY < rect.top + rect.height / 2 : true
  dragPinnedOverId.value = id
  dragPinnedBefore.value = before
  if (event.dataTransfer) event.dataTransfer.dropEffect = 'move'
}

const onPinnedDragLeave = () => {
  dragPinnedOverId.value = null
}

const onPinnedDrop = async (event: DragEvent, targetId: string) => {
  event.preventDefault()
  const draggedId = dragPinnedId.value
  dragPinnedId.value = null
  dragPinnedOverId.value = null
  if (!draggedId || draggedId === targetId) return
  const order = pinnedItems.value.map((i) => i.id).filter((id) => id !== draggedId)
  const at = order.indexOf(targetId)
  if (at < 0) {
    order.push(draggedId)
  } else {
    order.splice(dragPinnedBefore.value ? at : at + 1, 0, draggedId)
  }
  // Optimistic: renumber positions locally so the drop paints instantly.
  const count = order.length
  order.forEach((id, i) => {
    const row = navItems.value.find((r) => r.id === id)
    if (row) row.pinned_position = count - 1 - i
  })
  try {
    await api.reorderPinnedSessions(order)
  } catch (err) {
    console.error('Failed to reorder pinned sessions:', err)
    loadChats()
  }
}

const onPinnedDragEnd = () => {
  dragPinnedId.value = null
  dragPinnedOverId.value = null
}

// Empty-refresh resilience. A rejected fetch, a timed-out request or a non-2xx lands in
// `api.getChats`'s catch as `{ sessions: [], total: 0, failed: true }`; `loadDelta` turns that flag
// into a failed Effect, and this backoff is what keeps the RECENT list from settling on zero.
const LOAD_RETRY_DELAYS_MS = [1_000, 3_000, 8_000, 20_000]
let loadRetryTimer: ReturnType<typeof setTimeout> | undefined
let loadRetryAttempt = 0

const clearLoadRetry = () => {
  if (loadRetryTimer !== undefined) {
    clearTimeout(loadRetryTimer)
    loadRetryTimer = undefined
  }
  loadRetryAttempt = 0
}

const scheduleLoadRetry = (ctx: string) => {
  if (loadRetryTimer !== undefined) return // one in flight
  if (loadRetryAttempt >= LOAD_RETRY_DELAYS_MS.length) return // budget spent
  const delay = LOAD_RETRY_DELAYS_MS[loadRetryAttempt] as number
  loadRetryAttempt += 1
  loadRetryTimer = setTimeout(() => {
    loadRetryTimer = undefined
    // Scope moved on while we waited — the scope guard owns the load now.
    if (sessionCacheKey() !== ctx) return
    void loadChats()
  }, delay)
}

const loadChats = async () => {
  chatsLoading.value = true
  chatsNextCursor.value = null
  // Local-first mount (mirrors ChatView): paint the workspace cache
  // instantly, then revalidate page 1 in the background. The ctx guard
  // drops late paints after a fast workspace switch.
  const ctx = sessionCacheKey()
  const isCurrentCtx = () => sessionCacheKey() === ctx
  try {
    console.log('[ChatsList] loadChats called, cache-first...')
    const cached = await runSyncEffectOr(
      sessionEngineDb.primeFromCache(ctx, 30),
      [],
      'sessions.primeFromCache',
    )
    if (cached.length > 0 && isCurrentCtx()) {
      navItems.value = cached.map((r) => toNavItem(r.raw))
      sortNavItemsForDisplay()
      chatsLoading.value = false
      restoreActiveFromUrl()
    }
    const delta = await runSyncEffect(sessionEngineDb.loadDelta(ctx, 30), 'sessions.loadDelta')
    if (delta && isCurrentCtx()) {
      const rows = delta.items.map((r) => toNavItem(r.raw))
      if (rows.length === 0 && navItems.value.length > 0) {
        // Failed refresh wearing a successful response's clothes. Keep
        // what the user can see and try again shortly.
        console.error(
          `[ChatsList] refresh for ${ctx} returned no sessions; keeping ${navItems.value.length} painted row(s) and retrying`,
        )
        scheduleLoadRetry(ctx)
        return
      }
      navItems.value = rows
      sortNavItemsForDisplay()
      chatsHasMore.value = delta.hasMore
      chatsNextCursor.value = delta.nextCursor
      chatsTotal.value = delta.total
      clearLoadRetry()
      restoreActiveFromUrl()
    } else if (isCurrentCtx()) {
      // A delta that never arrived is a failed revalidate, not an empty
      // scope: keep whatever is painted and come back for it.
      scheduleLoadRetry(ctx)
    }
  } catch (err) {
    // A thrown load must not blank painted rows either — same reasoning as
    // the empty-page guard above. The console entry is the diagnosis.
    console.error('Failed to load chats:', err)
  } finally {
    console.log(
      '[ChatsList] loadChats finished, chatsLoading:',
      chatsLoading.value,
      'navItems:',
      navItems.value.length,
    )
    chatsLoading.value = false
  }
  burstChatPrStatus()
}

// Deep-link / refresh cover, extracted so both the cache paint and the delta paint can run it: if
// the URL already shows a chat, optimistic-clear its dot + fire the touch so the dot clears without
// waiting for the next SSE refresh. fireSessionTouched is once-per-lifetime guarded, so the double.
const restoreActiveFromUrl = () => {
  // If we found and activated a saved chat, restore it in AppLayout
  const activeItem = navItems.value.find((item) => item.active)
  if (activeItem) {
    navigationStore.setActiveChatName(activeItem.name)
    emit('navigate', `chat-${activeItem.id}`, activeItem.name)
  }

  const current = currentMainView.value
  if (current.kind === 'chat' && current.sessionId) {
    // Fresh-tab title: a deep link never left-clicks, so activeChatName is empty/stale and the
    // browser tab would read plain "Pabrik". The name is usually already in this list — fall back
    // to a single-session fetch past page 1.
    const match = navItems.value.find((i) => i.id === current.sessionId)
    if (match && match.name && match.name !== 'New Chat') {
      navigationStore.setActiveChatName(match.name)
    } else {
      const sessionId = current.sessionId
      void api.getSession(sessionId).then((sess) => {
        const now = currentMainView.value
        if (now.kind === 'chat' && now.sessionId === sessionId && sess?.sessionName) {
          navigationStore.setActiveChatName(sess.sessionName)
        }
      })
    }
    optimisticClearStaleDot(current.sessionId)
    fireSessionTouched(current.sessionId)
  }
}

const loadMoreChats = async () => {
  if (!chatsHasMore.value || chatsLoading.value || !chatsNextCursor.value) return
  const ctx = sessionCacheKey()
  // Cache-first scroll-back in desc mode (mirrors ChatView.fetchOlderPage): the write-through below
  // accumulates every fetched page, so older rows are usually already local. Cursor unchanged,
  // id-dedupe covers overlap.
  if (chatsSortDirection.value === 'desc' && navItems.value.length > 0) {
    const oldest = navItems.value[navItems.value.length - 1]?.sortKey ?? ''
    const cached = await runSyncEffectOr(
      sessionEngineDb.loadOlderFromCache(ctx, oldest, 20),
      [],
      'sessions.loadOlderFromCache',
    )
    if (cached.length > 0) {
      const seen = new Set(navItems.value.map((i) => i.id))
      const fresh = cached.filter((r) => !seen.has(r.id))
      if (fresh.length > 0) {
        navItems.value.push(...fresh.map((r) => toNavItem(r.raw)))
        return
      }
    }
  }
  chatsLoading.value = true
  try {
    const data = await api.getChats(
      'updated_at',
      chatsSortDirection.value,
      20,
      chatsNextCursor.value,
      scopedWorkspaceId.value,
    )
    const newItems = (data.sessions || []).map(toNavItem)
    navItems.value.push(...newItems)
    // Write-through so later mounts and scroll-backs hit the cache.
    await runSyncVoid(
      sessionEngineDb.putLocal(ctx, (data.sessions || []).map(toSessionRow)),
      'sessions.putLocal',
    )
    chatsHasMore.value = data.has_more
    chatsNextCursor.value = data.next_cursor
  } catch (err) {
    console.error('Failed to load more chats:', err)
  } finally {
    chatsLoading.value = false
  }
}

const toggleNavSection = () => {
  const wasExpanded = sidebarStore.navExpanded
  sidebarStore.toggleNavExpanded()
  // If just became expanded and no chats loaded, reload
  if (!wasExpanded && navItems.value.length === 0) {
    loadChats()
  }
}

// Workspace switch refetch (plan: 2026-09-22-revamp-ui-chats). The list is scoped per workspace, so
// a scope change clears the old workspace's rows FIRST (no stale frame) and refetches.
const switchWorkspaceScope = () => {
  navItems.value = []
  chatsNextCursor.value = null
  chatsHasMore.value = false
  // The old workspace's total is a lie for the new scope: it drives the
  // scroller's `loadMore` gate (`items.length < totalCount`), so a stale
  // value from a bigger workspace makes the list page past its end.
  chatsTotal.value = 0
  // A pending retry belongs to the scope that scheduled it.
  clearLoadRetry()
  loadChats()
}
const prevScopeId = ref(scopedWorkspaceId.value)
onMounted(() => {
  prevScopeId.value = scopedWorkspaceId.value
})
onUpdated(() => {
  if (scopedWorkspaceId.value !== prevScopeId.value) {
    prevScopeId.value = scopedWorkspaceId.value
    switchWorkspaceScope()
  }
})

/**  * Ctrl/Cmd+click, middle click and the context menu open a chat in a real browser tab (window.open)
 * instead of navigating — the browser gesture. A plain click keeps the previous behaviour.
 * Path-based (plan: 2026-09-22-revamp-ui-chats): /app/{ws}/chat/{sid}. */
const openChatInNewTab = (item: { id: string }) => {
  const wsId = scopedWorkspaceId.value
  if (wsId) {
    openInNewTab(router, buildAppUrl({ workspaceId: wsId, chatSessionId: item.id }))
  } else {
    openInNewTab(router, { path: '/app', query: { view: 'chat', session: item.id } })
  }
}

const onChatRowClick = (event: MouseEvent, item: { id: string; name: string }) => {
  if (isBackgroundOpenEvent(event)) {
    openChatInNewTab(item)
    return
  }
  void setActive(item.id)
}

const onChatRowAuxClick = (event: MouseEvent, item: { id: string; name: string }) => {
  if (event.button !== 1) return
  event.preventDefault()
  openChatInNewTab(item)
}

const setActive = async (id: string) => {
  // 1) Existing navigation first, synchronously, so the UI never blocks.
  const chat = navItems.value.find((item) => item.id === id)
  const chatName = chat?.name || ''
  navigationStore.setActiveChatName(chatName)
  // Mutually exclusive active state: chat wins, clear workspace item.
  workspacesStore.setActiveWorkspaceItem(null)
  // ...and clear any active task (inverse direction: task → chat).
  workspacesStore.setActiveTask(null)
  navItems.value = navItems.value.map((item) => ({ ...item, active: item.id === id }))
  navigationStore.setActiveChat(id, chatName)
  // Update URL with session ID (path-based: /app/{ws}/chat/{sid}).
  const wsId = scopedWorkspaceId.value
  if (wsId) {
    router.replace(buildAppUrl({ workspaceId: wsId, chatSessionId: id }))
  } else {
    router.replace({ path: '/app', query: { view: 'chat', session: id } })
  }
  // 2) Optimistic clear: align human time to updated_at so isStale()
  // flips false immediately (no wait for the next list refresh).
  optimisticClearStaleDot(id)
  // 3) Best-effort backend stamp (don't await navigation).
  fireSessionTouched(id)
}

const removeChat = async (chatId: string) => {
  const index = navItems.value.findIndex((item) => item.id === chatId)
  if (index !== -1) {
    const wasActive = navItems.value[index]?.active ?? false
    navItems.value.splice(index, 1)
    // Keep the cache consistent with the optimistic splice.
    await runSyncVoid(
      sessionEngineDb.removeSession(sessionCacheKey(), chatId),
      'sessions.removeSession',
    )
    // Clear from navigation store if this was the active chat
    if (wasActive) {
      navigationStore.clearActiveChat()
      // Mutually exclusive active state: deleting the active chat drops us
      // back to "no chat selected" — also clear the workspace item.
      workspacesStore.setActiveWorkspaceItem(null)
      // ...and clear any active task (inverse direction: task → chat).
      workspacesStore.setActiveTask(null)
    }
    try {
      await api.deleteChat(chatId)
    } catch (err) {
      console.error('Failed to delete chat:', err)
    }
    if (wasActive && navItems.value.length > 0 && navItems.value[0]) {
      navItems.value[0].active = true
      const nextChat = navItems.value[0]
      navigationStore.setActiveChat(nextChat.id, nextChat.name)
      const nextWsId = scopedWorkspaceId.value
      if (nextWsId) {
        router.replace(buildAppUrl({ workspaceId: nextWsId, chatSessionId: nextChat.id }))
      } else {
        router.replace({ path: '/app', query: { view: 'chat', session: nextChat.id } })
      }
    }
  }
}

// Migration 063 — the unattended-mode toggle USED to live as a clickable badge in this list. See
// Chunk 6 of the unify-frontend-sse plan.
let sseReloadTimer: ReturnType<typeof setTimeout> | undefined
const scheduleSseReload = () => {
  if (sseReloadTimer !== undefined) return // burst already coalesced
  sseReloadTimer = setTimeout(() => {
    sseReloadTimer = undefined
    loadChats()
  }, 400)
}
const unsubSession = workspacesStore.onSessionEvent((event) => {
  if (event.action === 'deleted') {
    // Instant evict: drop the row from the cache and the list now,
    // then let the debounced reload revalidate totals/cursors.
    void runSyncVoid(
      sessionEngineDb.removeSession(sessionCacheKey(), event.id),
      'sessions.removeSession',
    )
    navItems.value = navItems.value.filter((i) => i.id !== event.id)
    scheduleSseReload()
    return
  }
  if (event.action === 'updated') {
    const firedAt = touchedAtMs.get(event.id)
    if (firedAt !== undefined && Date.now() - firedAt < TOUCH_ECHO_SUPPRESS_MS) {
      return
    }
  }
  scheduleSseReload()
})
onUnmounted(() => {
  unsubSession()
  if (sseReloadTimer !== undefined) {
    clearTimeout(sseReloadTimer)
    sseReloadTimer = undefined
  }
  // A retry firing after unmount would reload a list nobody is looking at.
  clearLoadRetry()
})

onMounted(async () => {
  console.log('[ChatsList] onMounted called')
  // Wait for DOM to be ready
  await nextTick()
  // Load chats immediately when mounted
  loadChats()
})

onUnmounted(() => {
  // No SSE teardown needed — ChatsList no longer owns a session-
  // event stream. The canonical subscription lives in the
  // workspaces store and persists for the app's lifetime.
})

// Cleanup on unmount
const cleanup = () => {
  stopChatsResize()
}

defineExpose({
  loadChats,
  removeChat,
  resetActiveChat: () => {
    navItems.value = navItems.value.map((navItem) => ({ ...navItem, active: false }))
  },
  cleanup,
  updateChatId: (oldId: string, newId: string) => {
    const chatItem = navItems.value.find((item) => item.id === oldId)
    if (chatItem) {
      chatItem.id = newId
    }
  },
  virtualScrollerRef,
})
</script>

<template>
  <!-- Chats Section with Resizable Height.
       data-workspace-scope keeps this component's own render effect
       subscribed to the scope (row slots render inside VirtualScroller
       and don't subscribe us): a scope change re-renders here, which
       is what fires the onUpdated scope guard below. Do not remove. -->
  <div
    v-if="!collapsed"
    class="shrink-0 flex flex-col"
    :data-workspace-scope="scopedWorkspaceId ?? ''"
    :style="
      sidebarStore.navExpanded
        ? { height: sidebarStore.chatsHeight + '%', minHeight: '80px' }
        : { height: 'auto', minHeight: '0' }
    "
  >
    <!-- Migration 104 — PINNED section above RECENT. Draggable rows
         (HTML5 DnD, custom MIME type mirrors WorkspaceItem). Hidden when
         empty so recents-only workspaces see no layout shift.
         Independent from RECENT: collapsing RECENT (navExpanded) keeps
         PINNED visible; PINNED has its own pinnedExpanded flag. -->
    <div
      v-if="pinnedItems.length > 0"
      class="shrink-0 flex flex-col border-b border-(--color-border)/40"
      data-testid="pinned-section"
    >
      <div
        class="px-[var(--sb-gutter)] h-7 flex items-center shrink-0 border-b border-(--color-border)/40"
        data-testid="pinned-section-header"
        @click="sidebarStore.togglePinnedExpanded()"
      >
        <button
          class="flex items-center h-full min-w-0 flex-1 text-left transition-opacity hover:opacity-80"
          :aria-expanded="sidebarStore.pinnedExpanded"
          aria-label="Pinned"
          @click.stop="sidebarStore.togglePinnedExpanded()"
        >
          <span
            class="w-[var(--sb-mark)] shrink-0 flex items-center text-meta transition-transform duration-200"
            :style="{
              transform: sidebarStore.pinnedExpanded ? 'rotate(90deg)' : 'rotate(0deg)',
            }"
            style="color: var(--semantic-text-dim)"
            >▶</span
          >
          <span
            class="text-micro font-semibold uppercase tracking-[0.08em]"
            style="color: var(--semantic-text-dim)"
            data-testid="pinned-section-title"
            >Pinned</span
          >
          <span
            class="text-micro ml-1.5"
            style="
              color: var(--semantic-text-dim);
              opacity: 0.7;
              font-variant-numeric: tabular-nums;
            "
            data-testid="pinned-section-count"
            >{{ pinnedItems.length }}</span
          >
        </button>
      </div>
      <div v-if="sidebarStore.pinnedExpanded" class="flex flex-col pb-1">
        <button
          v-for="item in pinnedItems"
          :key="item.id"
          draggable="true"
          @click="onChatRowClick($event, item)"
          @auxclick="onChatRowAuxClick($event, item)"
          @contextmenu.prevent="onChatRowContextMenu($event, item)"
          @dragstart="onPinnedDragStart($event, item.id)"
          @dragover="onPinnedDragOver($event, item.id)"
          @dragleave="onPinnedDragLeave"
          @drop="onPinnedDrop($event, item.id)"
          @dragend="onPinnedDragEnd"
          :data-testid="`chat-row-${item.id}`"
          data-pinned="true"
          :data-drop-before="dragPinnedOverId === item.id && dragPinnedBefore ? 'true' : undefined"
          :data-drop-after="dragPinnedOverId === item.id && !dragPinnedBefore ? 'true' : undefined"
          class="relative w-full flex items-center px-[var(--sb-gutter)] h-[var(--sb-row)] rounded-lg text-dense transition-all duration-150 border-t border-transparent overflow-hidden text-left"
          :class="isCurrentChat(item.id) ? 'border-(--color-border)/60' : ''"
          :style="
            isCurrentChat(item.id)
              ? 'background: var(--semantic-active-bg); color: var(--semantic-active-text); box-shadow: inset 2px 0 0 0 var(--color-violet);'
              : 'color: var(--semantic-text-muted);'
          "
        >
          <span class="w-[var(--sb-mark)] shrink-0 flex items-center">
            <span
              v-if="item.git_branch && prStatuses[item.id]"
              class="inline-flex items-center cursor-context-menu"
              :style="chatBranchStyle(item.id)"
              :title="chatBranchTitle(item) + ' — right-click to open the change request'"
              :data-pr-status="prStatuses[item.id] || undefined"
              :data-pr-conflict="prConflicts[item.id] || undefined"
              data-testid="chat-git-branch"
              @contextmenu.prevent.stop="onGitIconContextMenu($event, item)"
            >
              <svg
                class="w-3 h-3 shrink-0"
                fill="none"
                viewBox="0 0 24 24"
                stroke="currentColor"
                stroke-width="2.5"
                aria-hidden="true"
              >
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  d="M6 3v12M18 9a3 3 0 100-6 3 3 0 000 6zM6 21a3 3 0 100-6 3 3 0 000 6zM18 9a9 9 0 01-9 9"
                />
              </svg>
            </span>
          </span>
          <span class="flex-1 min-w-0 truncate text-left" :title="item.name">{{ item.name }}</span>
          <span class="ml-2 flex items-center gap-1.5 shrink-0">
            <span
              v-if="item.sub_agent_name"
              class="text-micro"
              style="color: var(--color-violet)"
              :title="
                item.parent_session_id ? 'Sub-agent of ' + item.parent_session_id : 'Sub-agent'
              "
              ><UiIcon name="tools" size-class="w-3 h-3" /> {{ item.sub_agent_name }}</span
            >
            <span
              v-if="isAwaitingReview(item)"
              class="inline-flex items-center shrink-0"
              title="AI finished — awaiting your review"
              data-testid="chat-status-awaiting-review"
            >
              <span
                class="w-2 h-2 rounded-full"
                style="
                  background-color: rgb(251, 146, 60);
                  box-shadow: 0 0 0 0 rgba(251, 146, 60, 0.6);
                  animation: chat-needs-review-pulse 2.4s ease-out 4 forwards;
                "
              />
            </span>
            <span
              v-else-if="isReviewed(item)"
              class="inline-flex items-center shrink-0 text-green-500"
              title="Reviewed"
              data-testid="chat-status-reviewed"
            >
              <svg
                class="w-3 h-3"
                fill="none"
                viewBox="0 0 24 24"
                stroke="currentColor"
                stroke-width="2.5"
              >
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  d="M9 12l2 2 4-4m6 2a9 9 0 11-18 0 9 9 0 0118 0z"
                />
              </svg>
            </span>
            <span
              v-if="rowAgentError(item.id)"
              class="inline-flex items-center shrink-0"
              style="color: var(--color-red)"
              :title="
                rowErrorRetryLabel(item.id)
                  ? `Agent error — retry ${rowErrorRetryLabel(item.id)}`
                  : 'Agent error'
              "
              data-testid="chat-status-agent-error"
            >
              ⚠
            </span>
            <span
              v-if="prConflicts[item.id]"
              class="inline-flex items-center shrink-0 cursor-context-menu"
              style="color: var(--color-red)"
              :title="'Merge conflicts — ' + (item.git_branch || '')"
              data-testid="chat-status-pr-conflict"
              @contextmenu.prevent.stop="onGitIconContextMenu($event, item)"
            >
              <UiIcon name="alert" size-class="w-3 h-3" />
            </span>
            <span
              v-if="!isProcessing(item.id)"
              class="text-micro opacity-70 flex items-center gap-1"
            >
              <span
                v-if="shouldShowStaleDot(item)"
                class="w-1 h-1 rounded-full bg-amber-400"
                title="AI is still working — your last touch was earlier"
                data-testid="chat-stale-dot"
              />
              <span
                :title="
                  item.last_human_touched_at
                    ? 'Last human activity'
                    : 'Last activity (never touched by you yet)'
                "
                data-testid="chat-time-pill"
                >{{ item.relativeTime || 'now' }}</span
              >
            </span>
            <WorkerElapsedChip
              v-else
              :session-id="item.id"
              test-id="chat-elapsed-chip"
              variant="text"
            />
          </span>
        </button>
      </div>
    </div>

    <!-- Header with expand/collapse toggle. Every measurement here
         resolves against the --sb-* tokens in style.css, and
         Sidebar.spacing.spec.ts asserts the rendered values, so this
         block is free to change shape without a grep guard. Inside:
         a single chevron + the section title; the trailing sort
         control uses bare text (no SVG, no decoration) for a minimal
         typographic feel. There is deliberately NO "+ new chat"
         button (removed 2026-09-22 revamp) — new chats are created
         from workspace items (projects), so every chat belongs to a
         workspace and the list below can stay scoped. -->
    <div
      class="px-[var(--sb-gutter)] h-7 flex items-center shrink-0 border-b border-(--color-border)/40"
      data-testid="recent-section-header"
      @click="toggleNavSection"
    >
      <button
        class="flex items-center h-full min-w-0 flex-1 text-left transition-opacity hover:opacity-80"
        :aria-expanded="sidebarStore.navExpanded"
        aria-label="Recent"
        @click.stop="toggleNavSection"
      >
        <span
          class="w-[var(--sb-mark)] shrink-0 flex items-center text-meta transition-transform duration-200"
          :style="{
            transform: sidebarStore.navExpanded ? 'rotate(90deg)' : 'rotate(0deg)',
          }"
          style="color: var(--semantic-text-dim)"
          >▶</span
        >
        <span
          class="text-micro font-semibold uppercase tracking-[0.08em]"
          style="color: var(--semantic-text-dim)"
          data-testid="recent-section-title"
          >Recent</span
        >
        <span
          class="text-micro ml-1.5"
          style="color: var(--semantic-text-dim); opacity: 0.7; font-variant-numeric: tabular-nums"
          data-testid="recent-section-count"
          >{{ recentTotal }}</span
        >
      </button>
      <button
        v-if="sidebarStore.navExpanded"
        @click.stop="onSortToggle"
        :title="
          chatsSortDirection === 'desc'
            ? 'Newest first (click to flip)'
            : 'Oldest first (click to flip)'
        "
        :aria-label="chatsSortDirection === 'desc' ? 'Sort: newest first' : 'Sort: oldest first'"
        data-testid="chats-sort-toggle"
        class="ml-auto w-[var(--sb-hit)] h-[var(--sb-hit)] text-meta font-medium transition-opacity duration-150 hover:opacity-100 flex items-center justify-center shrink-0"
        style="color: var(--semantic-text-dim); opacity: 0.7"
      >
        {{ chatsSortDirection === 'desc' ? '↓' : '↑' }}
      </button>
    </div>

    <!-- Chat List -->
    <div v-if="sidebarStore.navExpanded" class="flex-1 min-h-0 flex flex-col overflow-hidden">
      <VirtualScroller
        ref="virtualScrollerRef"
        :totalCount="recentTotal"
        :items="recentItems"
        :default-item-height="32"
        :buffer="5"
        :load-more-threshold="200"
        @load-more="loadMoreChats"
        class="flex-1 min-h-0"
      >
        <template #default="{ item }">
          <button
            @click="onChatRowClick($event, item)"
            @auxclick="onChatRowAuxClick($event, item)"
            @contextmenu.prevent="onChatRowContextMenu($event, item)"
            :data-testid="`chat-row-${item.id}`"
            class="relative w-full flex items-center px-[var(--sb-gutter)] h-[var(--sb-row)] rounded-lg text-dense transition-all duration-150 border-t border-transparent overflow-hidden text-left"
            :class="isCurrentChat(item.id) ? 'border-(--color-border)/60' : ''"
            :style="
              isCurrentChat(item.id)
                ? 'background: var(--semantic-active-bg); color: var(--semantic-active-text); box-shadow: inset 2px 0 0 0 var(--color-violet);'
                : 'color: var(--semantic-text-muted);'
            "
          >
            <span class="w-[var(--sb-mark)] shrink-0 flex items-center">
              <span
                v-if="item.git_branch && prStatuses[item.id]"
                class="inline-flex items-center cursor-context-menu"
                :style="chatBranchStyle(item.id)"
                :title="chatBranchTitle(item) + ' — right-click to open the change request'"
                :data-pr-status="prStatuses[item.id] || undefined"
                :data-pr-conflict="prConflicts[item.id] || undefined"
                data-testid="chat-git-branch"
                @contextmenu.prevent.stop="onGitIconContextMenu($event, item)"
              >
                <svg
                  class="w-3 h-3 shrink-0"
                  fill="none"
                  viewBox="0 0 24 24"
                  stroke="currentColor"
                  stroke-width="2.5"
                  aria-hidden="true"
                >
                  <path
                    stroke-linecap="round"
                    stroke-linejoin="round"
                    d="M6 3v12M18 9a3 3 0 100-6 3 3 0 000 6zM6 21a3 3 0 100-6 3 3 0 000 6zM18 9a9 9 0 01-9 9"
                  />
                </svg>
              </span>
            </span>
            <span class="flex-1 min-w-0 truncate text-left" :title="item.name">{{
              item.name
            }}</span>
            <span class="ml-2 flex items-center gap-1.5 shrink-0">
              <span
                v-if="item.sub_agent_name"
                class="text-micro"
                style="color: var(--color-violet)"
                :title="
                  item.parent_session_id ? 'Sub-agent of ' + item.parent_session_id : 'Sub-agent'
                "
                ><UiIcon name="tools" size-class="w-3 h-3" /> {{ item.sub_agent_name }}</span
              >
              <span
                v-if="isAwaitingReview(item)"
                class="inline-flex items-center shrink-0"
                title="AI finished — awaiting your review"
                data-testid="chat-status-awaiting-review"
              >
                <span
                  class="w-2 h-2 rounded-full"
                  style="
                    background-color: rgb(251, 146, 60);
                    box-shadow: 0 0 0 0 rgba(251, 146, 60, 0.6);
                    animation: chat-needs-review-pulse 2.4s ease-out 4 forwards;
                  "
                />
              </span>
              <span
                v-else-if="isReviewed(item)"
                class="inline-flex items-center shrink-0 text-green-500"
                title="Reviewed"
                data-testid="chat-status-reviewed"
              >
                <svg
                  class="w-3 h-3"
                  fill="none"
                  viewBox="0 0 24 24"
                  stroke="currentColor"
                  stroke-width="2.5"
                >
                  <path
                    stroke-linecap="round"
                    stroke-linejoin="round"
                    d="M9 12l2 2 4-4m6 2a9 9 0 11-18 0 9 9 0 0118 0z"
                  />
                </svg>
              </span>
              <span
                v-if="rowAgentError(item.id)"
                class="inline-flex items-center shrink-0"
                style="color: var(--color-red)"
                :title="
                  rowErrorRetryLabel(item.id)
                    ? `Agent error — retry ${rowErrorRetryLabel(item.id)}`
                    : 'Agent error'
                "
                data-testid="chat-status-agent-error"
              >
                ⚠
              </span>
              <span
                v-if="prConflicts[item.id]"
                class="inline-flex items-center shrink-0 cursor-context-menu"
                style="color: var(--color-red)"
                :title="'Merge conflicts — ' + (item.git_branch || '')"
                data-testid="chat-status-pr-conflict"
                @contextmenu.prevent.stop="onGitIconContextMenu($event, item)"
              >
                <UiIcon name="alert" size-class="w-3 h-3" />
              </span>
              <span
                v-if="!isProcessing(item.id)"
                class="text-micro opacity-70 flex items-center gap-1"
              >
                <span
                  v-if="shouldShowStaleDot(item)"
                  class="w-1 h-1 rounded-full bg-amber-400"
                  title="AI is still working — your last touch was earlier"
                  data-testid="chat-stale-dot"
                />
                <span
                  :title="
                    item.last_human_touched_at
                      ? 'Last human activity'
                      : 'Last activity (never touched by you yet)'
                  "
                  data-testid="chat-time-pill"
                  >{{ item.relativeTime || 'now' }}</span
                >
              </span>
              <WorkerElapsedChip
                v-else
                :session-id="item.id"
                test-id="chat-elapsed-chip"
                variant="text"
              />
            </span>
          </button>
        </template>
      </VirtualScroller>

      <!-- Initial load skeleton — shown while the first page is in
           flight and nothing is painted yet. Replaces the old plain
           "Loading..." text so the list keeps its layout instead of
           flashing empty. Pagination (rows already on screen) keeps
           the text indicator below. -->
      <SidebarSkeleton
        v-if="chatsLoading && navItems.length === 0"
        :rows="6"
        test-id="chats-loading-skeleton"
      />

      <!-- Loading indicator (pagination only) -->
      <div v-if="chatsLoading && navItems.length > 0" class="py-2 text-center shrink-0">
        <span class="px-[var(--sb-gutter)] py-2 text-micro" style="color: var(--semantic-text-dim)"
          >Loading...</span
        >
      </div>

      <!-- Drag Resize Handle -->
      <div
        class="h-3 cursor-row-resize flex items-center justify-center group/resize shrink-0 mt-1"
        :class="'bg-(--color-border)/20 hover:bg-(--color-border)/40 transition-colors'"
        title="Drag to resize"
        @mousedown="startChatsResize"
      >
        <div
          class="w-2/3 h-0.5 transition-all duration-200 group-hover/resize:h-1 rounded"
          style="background: var(--color-border)"
        />
      </div>
    </div>
  </div>

  <!-- Collapsed state: no chats affordance. The "+" new-chat button
       was removed (2026-09-22 revamp) — new chats come from workspace
       items, so the collapsed sidebar shows nothing here. The wrapper
       div stays so the layout spacing is unchanged. -->
  <div v-else class="mb-2 shrink-0" data-testid="collapsed-chats-placeholder" />

  <ChatRowContextMenu
    v-if="menuPos"
    :x="menuPos.x"
    :y="menuPos.y"
    :chat-name="contextMenuChat?.name ?? ''"
    :is-processing="contextMenuChatId ? isProcessing(contextMenuChatId) : false"
    :unattended="isUnattended(contextMenuChat ?? {})"
    :is-stopping="isStoppingChat"
    :is-pinned="pickedChat()?.is_pinned ?? contextMenuChat?.is_pinned ?? false"
    @rename="startRenameFromMenu"
    @toggle-unattended="toggleUnattendedFromMenu"
    @toggle-pin="togglePinFromMenu"
    @stop="stopAgentFromMenu"
    @open-in-new-tab="openContextMenuInBackground"
  />
  <RenameTaskModal
    :show="renameModalOpen"
    :current-name="renameModalName"
    heading="Rename chat"
    label="Chat name"
    placeholder="Chat name"
    @close="renameModalOpen = false"
    @rename="confirmRename"
  />
  <GitBranchMenu
    v-if="gitMenuPos"
    :x="gitMenuPos.x"
    :y="gitMenuPos.y"
    :branch="gitMenuBranch"
    :branch-url="gitMenuBranchUrl"
    :pr-url="gitMenuPrUrl"
    @open-branch="openGitBranchInBackground"
    @open-pr="openGitPrInBackground"
  />
</template>

<style scoped>
/* Prefixed `chat-` so it cannot collide with the kanban card's
   same-shaped `needs-review-pulse` in its own scoped block. */
@keyframes chat-needs-review-pulse {
  0% {
    box-shadow: 0 0 0 0 rgba(251, 146, 60, 0.6);
  }
  70% {
    box-shadow: 0 0 0 12px rgba(251, 146, 60, 0);
  }
  100% {
    box-shadow: 0 0 0 0 rgba(251, 146, 60, 0);
  }
}

@media (prefers-reduced-motion: reduce) {
  [data-testid='chat-status-awaiting-review'] span {
    animation: none;
  }
}
</style>
