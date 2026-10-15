<!--
  WorkspaceItemTaskCard — the bordered card layout used by the kanban
  board inside <KanbanCard> → <KanbanColumn>.

  Split from <WorkspaceItemTask> on 2026-07-02. The row variant moved
  to <WorkspaceItemTaskRow> (sidebar list). This file owns the modern-
  minimalist kanban-card layout: a visible 1px gray border + card
  background + optional description preview, last-updated meta row,
  and a Jira-style left-edge type accent (blue for memory).
  Hover swaps the gray border for a violet ring.

  Behavior (event payload, drop indicator, active
  styling, pin toggle, hover buttons) is shared with
  the row via the `useTaskActions` composable. See that file for the
  contract.

  Public API:
    props:  task (Task), workspaceId (string), itemId (string),
            dropIndicator? ('above' | 'below' | null)
    emits:  selectTask, deleteTask, renameTask,
            pinTask  (same shapes as before)
    NOTE: editRoutine/runRoutine emits deleted with per-task routines
    (Migration 084).
-->
<script setup lang="ts">
// Extracted from WorkspaceItemTask.vue on 2026-07-02. The shared logic (event handlers + drop
// indicator) now lives in composables/useTaskActions.ts; this file owns ONLY the card layout and
// the card-specific computeds (description preview, meta row, Jira-style type accent).
import { inject, ref, computed, onMounted, onUnmounted, onUpdated, type Ref } from 'vue'
import { useWorkspacesStore } from '../../stores/workspaces'
import { useAgentErrorStore } from '../../stores/agentError'
import { useContextMenu } from '../../composables/useContextMenu'
import { useTaskActions, type TaskComponentProps } from '../../composables/useTaskActions'
import { parseAgentErrorHeadline } from '../../helpers/parseAgentErrorHeadline'
import MarkdownDescription from '../kanban/MarkdownDescription.vue'
import KanbanTaskContextMenu from '../kanban/KanbanTaskContextMenu.vue'
import GitBranchMenu from '../shell/GitBranchMenu.vue'
import { stopSession } from '../../api'
import type { KanbanColumn } from '../../stores/workspaces'
import {
  fetchPrInfoCached,
  fetchPrStatusCached,
  fetchPrConflictCached,
  branchUrlFromPrUrl,
  onPrStatusInvalidated,
} from '../../helpers/prStatusCache'
import { formatTaskTimestamp as formatRelativeTime } from '../../helpers/formatTaskTimestamp'
import UiIcon from '../ui/UiIcon.vue'
import WorkerElapsedChip from '../WorkerElapsedChip.vue'

// Kanban task tags palette (Migration 067 — plan
// docs/superpowers/plans/2026-07-28-kanban-task-tags.md).
// Same 6 colors as KanbanTagsInput.vue so the card chips and dialog chips share colors. djb2 hash
// of the lowercase tag selects the index deterministically.
const TAG_PALETTE = [
  { bg: 'rgba(139, 92, 246, 0.18)', border: 'rgba(139, 92, 246, 0.45)', text: '#a78bfa' },
  { bg: 'rgba(59, 130, 246, 0.18)', border: 'rgba(59, 130, 246, 0.45)', text: '#60a5fa' },
  { bg: 'rgba(34, 197, 94, 0.18)', border: 'rgba(34, 197, 94, 0.45)', text: '#4ade80' },
  { bg: 'rgba(245, 158, 11, 0.18)', border: 'rgba(245, 158, 11, 0.45)', text: '#fbbf24' },
  { bg: 'rgba(249, 115, 22, 0.18)', border: 'rgba(249, 115, 22, 0.45)', text: '#fb923c' },
  { bg: 'rgba(239, 68, 68, 0.18)', border: 'rgba(239, 68, 68, 0.45)', text: '#f87171' },
] as const

function tagChipStyle(tag: string): Record<string, string> {
  let hash = 5381
  for (const c of tag.toLowerCase()) {
    hash = ((hash << 5) + hash + c.charCodeAt(0)) >>> 0
  }
  const idx = hash % TAG_PALETTE.length
  const c = TAG_PALETTE[idx] ?? TAG_PALETTE[0]
  return {
    backgroundColor: c.bg,
    border: `1px solid ${c.border}`,
    color: c.text,
  }
}

// Re-inject processingState from App.vue (same key WorkspaceItem and
// ChatsList consume). Keyed by task.id == session_id.
const processingState = inject<Ref<Record<string, boolean>>>(
  'processingState',
  ref<Record<string, boolean>>({}),
)

const workspacesStore = useWorkspacesStore()

// 2026-08-29 (task_1787985074550_0): agent-error indicator surfaces the latest diagnostic for this
// task on the kanban card.
// The store outlives ChatView remounts (Plan §1 — same Pinia store the ChatView writes to via SSE
// `is_error` full events), so the indicator stays in sync with the chat card across session
// switches. task.id === session_id (migration 052 invariant) is the lookup key.
const agentErrorStore = useAgentErrorStore()
const agentError = computed(() => agentErrorStore.bySession[props.task.id] ?? null)
const errorHeadline = computed(() =>
  agentError.value ? parseAgentErrorHeadline(agentError.value.content).headline : null,
)
const errorRetryLabel = computed(() =>
  agentError.value ? parseAgentErrorHeadline(agentError.value.content).retryLabel : null,
)

// `columns` / `currentColumnId` back the context menu's "Move to column" submenu. They are NOT part
// of the shared TaskComponentProps because the sidebar-row variant (<WorkspaceItemTaskRow>) has no
// board to move between and passes neither.
const props = withDefaults(
  defineProps<
    TaskComponentProps & {
      /** The board's columns, already ordered. Drives the submenu. */
      columns?: KanbanColumn[]
      /** Marked as "current" in the submenu. */
      currentColumnId?: string | null
    }
  >(),
  {
    cwd: '',
    columns: () => [],
    currentColumnId: null,
  },
)

const emit = defineEmits<{
  selectTask: [taskId: string]
  deleteTask: [workspaceId: string, itemId: string, taskId: string]
  renameTask: [workspaceId: string, itemId: string, taskId: string, currentName: string]
  pinTask: [workspaceId: string, itemId: string, taskId: string, isPinned: boolean]
  // Open the full task-detail dialog (kanban-task-detail-dialog
  // feature). The host (KanbanView) opens the dialog locally with
  // the matching task — we only emit the id.
  viewTaskDetail: [taskId: string]
  openTaskInBackground: [payload: { workspaceId: string; itemId: string; taskId: string }]
  openTaskDetailInBackground: [payload: { workspaceId: string; itemId: string; taskId: string }]
  // Context-menu "Move to column". We emit only the DESTINATION — the append position depends on
  // how many tasks the target column holds, which this component can't see. <KanbanColumn> resolves
  // it and re-emits the existing `moveTask` shape its host already handles.
  moveTaskToColumn: [payload: { taskId: string; columnId: string }]
  // Context-menu "Run agent". Starts a worker on this task's existing session without queueing a
  // new user message — the same `startAgentOnTask` call the detail dialog's caret menu makes, just
  // reachable without opening the dialog.
  // The host (KanbanView) owns the API call and the error surface; the card only reports intent.
  runAgent: [payload: { taskId: string }]
}>()

// Shared logic — event handlers, drop indicator.
// Only the two pieces the card still uses inline. The event-taking
// handlers (delete / rename / pin) existed for the hover buttons and
// are gone with them — the context menu emits the same payloads
// directly (see `*FromMenu` below), because those handlers' only job
// was `stopPropagation()` away from the card root's @click and the
// teleported menu never traverses the card. They stay in the composable
// for <WorkspaceItemTaskRow>, which still renders its own buttons.
const { dropIndicatorBoxShadow, handleSelectTask } = useTaskActions(props, emit)

// Right-click action menu for this task. The menu position lives in useContextMenu; the task ids
// come from props and the handlers below.
// `openAtPoint` is what the ContextMenu-key path uses: it takes the card's own coordinates and
// applies the same edge clamp as a real right-click, so a card near the bottom-right corner doesn't
// push the menu off-screen.
const { menuPos, openAt, openAtPoint, close: closeTaskMenu } = useContextMenu()

const onTaskContextMenu = (event: MouseEvent) => {
  openAt(event)
}

// Enter / Space activate the card. The root is a <div role="button"> rather than a real <button>
// because the card contains nested interactive controls (the description's @path chips / tag links)
// and HTML forbids button-inside-button.
// This restores the keyboard contract the native element would have given us. ContextMenu / F10
// open the action menu.
// Removing the hover button strip (plan §2, G1) took away the only discoverable route to rename /
// delete / move, so the keyboard path to the menu is a hard requirement, not a nice-to-have —
// otherwise the change is an accessibility regression.
const handleCardKeydown = (event: KeyboardEvent) => {
  if (event.key === 'Enter' || event.key === ' ') {
    event.preventDefault()
    handleSelectTask()
    return
  }
  if (event.key === 'ContextMenu' || (event.key === 'F10' && event.shiftKey)) {
    event.preventDefault()
    // Anchor at the card's centre — there is no cursor to follow on a keyboard gesture. Reuses the
    // same viewport clamp as a real right-click so a card near the bottom-right corner doesn't push
    // the menu off-screen.
    const rect = (event.currentTarget as HTMLElement | null)?.getBoundingClientRect()
    openAtPoint(
      rect ? rect.left + rect.width / 2 : 0,
      rect ? rect.top + rect.height / 2 : 0,
      event.currentTarget as HTMLElement | null,
    )
  }
}

// Context-menu "Move to column". We forward the destination only; the
// <KanbanColumn> ancestor resolves the append position and re-emits the
// existing `moveTask` shape, so nothing above the card changes.
const moveTaskFromMenu = (columnId: string) => {
  closeTaskMenu()
  emit('moveTaskToColumn', { taskId: props.task.id, columnId })
}

// Pin / rename / view-detail, driven from the context menu.
//
// These deliberately do NOT call the `useTaskActions` handlers. Those take
// a DOM event solely to `stopPropagation()` it away from the card root's
// @click — a defence that the old inline buttons needed (a <button> nested
// inside the card's role="button" div). The menu is Teleported to `body`,
// so its clicks never traverse the card at all and there is nothing to
// stop; synthesising a MouseEvent to satisfy the signature would be noise.
// The emitted payloads are identical to the buttons'.
const pinFromMenu = () => {
  closeTaskMenu()
  emit('pinTask', props.workspaceId, props.itemId, props.task.id, !props.task.is_pinned)
}
const renameFromMenu = () => {
  closeTaskMenu()
  emit('renameTask', props.workspaceId, props.itemId, props.task.id, props.task.name)
}
const viewDetailFromMenu = () => {
  closeTaskMenu()
  emit('viewTaskDetail', props.task.id)
}

// Context-menu "Delete task". Emits straight up like every other task action; the confirmation is
// owned by whoever performs the delete (Sidebar's ConfirmDialog, via AppLayout's delete-task
// pass-through).
// The card used to open its own ConfirmDialog here, but that dialog only forwarded — it never
// deleted anything — so the click still reached the Sidebar and opened a second, stacked confirm on
// top of the first. Two owners for one irreversible action; the card keeps none of them.
const requestDeleteFromMenu = () => {
  closeTaskMenu()
  emit('deleteTask', props.workspaceId, props.itemId, props.task.id)
}

const openTaskMenuInBackground = () => {
  closeTaskMenu()
  emit('openTaskInBackground', {
    workspaceId: props.workspaceId,
    itemId: props.itemId,
    taskId: props.task.id,
  })
}

const openTaskDetailMenuInBackground = () => {
  closeTaskMenu()
  emit('openTaskDetailInBackground', {
    workspaceId: props.workspaceId,
    itemId: props.itemId,
    taskId: props.task.id,
  })
}

// Right-click menu on the git-branch badge: open GitHub branch / PR URLs in a new tab. Separate
// position state from the card menu so a badge right-click never opens the chat menu. URLs resolve
// via the shared PR-info cache; the branch URL derives from the PR repo base.
const { menuPos: gitMenuPos, openAt: openGitMenuAt, close: closeGitMenu } = useContextMenu()
const gitMenuBranchUrl = ref('')
const gitMenuPrUrl = ref('')

const onGitBadgeContextMenu = async (event: MouseEvent) => {
  event.preventDefault()
  event.stopPropagation()
  const branch = gitBranchBadge.value ?? ''
  const cwd = effectiveCwd.value
  gitMenuBranchUrl.value = ''
  gitMenuPrUrl.value = ''
  openGitMenuAt(event)
  if (!branch || !cwd) return
  try {
    const info = await fetchPrInfoCached(cwd, branch)
    if (gitMenuPos.value == null) return
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

// Right-click "Stop agent" — visible only while a worker runs on this task
// (processingState[task.id] === true, same key the elapsed chip + detail Start-agent button use).
// Calls the same POST /api/llm/session/:id/stop the chat's Stop button uses (task.id == session_id
// per Migration 052). Idempotent server-side; the SSE `worker deleted` event clears processingState
// so the menu item + chip disappear without further action.
const isAgentRunning = computed(() => processingState.value[props.task.id] === true)
const isStoppingAgent = ref(false)

const stopAgentFromMenu = async () => {
  closeTaskMenu()
  if (!isAgentRunning.value || isStoppingAgent.value) return
  isStoppingAgent.value = true
  try {
    await stopSession(props.task.id)
  } catch (err) {
    console.error('Failed to stop agent from card menu:', err)
  } finally {
    isStoppingAgent.value = false
  }
}

// Context-menu "Run agent" — the inverse of the row above. Emits up rather than calling the store
// itself: the card is also mounted by hosts that have no workspace/item context to build the
// endpoint path with, and the API call belongs wherever that context lives (KanbanView).
// The menu row is hidden while a worker runs, so the backend's 409 is a race guard rather than the
// primary UX.
const runAgentFromMenu = () => {
  closeTaskMenu()
  if (isAgentRunning.value) return
  emit('runAgent', { taskId: props.task.id })
}

// (card-ux-v3 — Jira-style priority-bar pattern). A thin 3px colored stripe down the left edge of
// the card that reflects the task's type. Standard tasks get NO stripe (cleanest default); memory
// tasks get a blue stripe.
// (The old violet routine stripe was deleted with per-task routines, Migration 084.) Implemented as
// an inset box-shadow so it doesn't affect the card's layout (no width change) and stacks naturally
// with the dropIndicator box-shadow and the v6 3D base shadow.
// Returns a string suitable for use as the `boxShadow` CSS value, or `''` for the no-stripe case
// (the caller's `||` chain keeps the dropIndicator in place when the type stripe is absent).
function typeAccentShadow(): string {
  const t = props.task.task_type
  if (t === 'memory') return 'inset 3px 0 0 0 rgb(96, 165, 250)' // blue-400
  return ''
}

// (card-ux-v6) Replaces the v5 visible 1px border with a layered
// 3D box-shadow. Three layers compose the "card floating on the
// board" feel without a hard outline:
//
//   1. Outer drop shadow at idle   — soft 1+2px offset, dark rgba,
//      lifts the card off the column visually. Hover swaps to a
//      bigger 4+2px shadow with brighter bevel for a "picking
//      up the card" feel.
//   2. Inset 1px bevel highlight   — low-opacity white stroke that
//      simulates a beveled edge in dark mode. Visible without a
//      harsh line; without it the card looks flat against the
//      dark column.
//   3. (Composed in cardBoxShadow below) Type accent + dropIndicator
//      inset shadows sit on TOP of the 3D base to keep the Jira-style
//      left stripe and the pinned-region drag line working
//      unchanged.
// CSS box-shadow stacking: FIRST value drawn on top. Outer shadows
// come first (they're the dominant visual), inset accents last.
const baseCardShadow =
  '0 1px 3px 0 rgba(0, 0, 0, 0.5), ' +
  '0 1px 2px -1px rgba(0, 0, 0, 0.4), ' +
  'inset 0 0 0 1px rgba(255, 255, 255, 0.06)'

const hoverCardShadow =
  '0 4px 6px -1px rgba(0, 0, 0, 0.55), ' +
  '0 2px 4px -2px rgba(0, 0, 0, 0.4), ' +
  'inset 0 0 0 1px rgba(255, 255, 255, 0.1)'

// Local hover state — drives the shadow transition. Pure UX, no
// business logic.
const isHovered = ref(false)

// Combined box-shadow for the card. Layered values, in CSS stacking order (first on top): 3D base +
// Jira-style type accent (left stripe) + yellow drop indicator (pinned-region drag).
// On hover the 3D base swaps to its hover variant; transition-shadow in the template class animates
// the swap smoothly.
const cardBoxShadow = computed<string>(() => {
  const accent = typeAccentShadow()
  const drop = dropIndicatorBoxShadow.value
  const base = isHovered.value ? hoverCardShadow : baseCardShadow
  const layers: string[] = [base]
  if (accent) layers.push(accent)
  if (drop && drop !== 'none') layers.push(drop)
  return layers.join(', ')
})

// The "time since" formatter for the meta row now lives in helpers/formatTaskTimestamp.ts, shared
// with the row-mode row (KanbanTaskRow.vue) so a card and its row-mode twin can never disagree on
// what "2h ago" means. The most-recent update timestamp available.
// Falls back to `createdAt` when `updatedAt` is missing. Returns null when neither is present
// (older task fixtures), which the meta row uses to skip the time pill.
const lastUpdated = computed<Date | string | null>(() => {
  if (props.task.updatedAt) return props.task.updatedAt
  if (props.task.createdAt) return props.task.createdAt
  return null
})

// The rendered "X ago" string. Computed once per lastUpdated change
// so the card doesn't re-format on every re-render. Empty string
// when no timestamp is present.
const lastUpdatedLabel = computed<string>(() => formatRelativeTime(lastUpdated.value))

// Visible tags for the chip row (Migration 067). Caps at 3 to keep the card compact; the "+N more"
// affordance covers the rest. `task.tags` is `[]` for tasks without tags — the v-if on the tags row
// in the template handles the "no tags" case.
const VISIBLE_TAGS_MAX = 3
const visibleTags = computed<string[]>(() => {
  const tags = props.task.tags ?? []
  return tags.slice(0, VISIBLE_TAGS_MAX)
})
const extraTagsCount = computed<number>(() => {
  const tags = props.task.tags ?? []
  return Math.max(0, tags.length - VISIBLE_TAGS_MAX)
})

// Image thumbnail (Migration 069 read-path fix, plan:
// docs/superpowers/plans/2026-08-24-kanban-task-image-urls-read-path.md Task 4). The card renders
// the FIRST image as a 48px-tall thumbnail + a `+N` badge when more images exist.
// Clicking the thumb opens the detail dialog (viewTaskDetail) — same affordance as the `+N more`
// tags link. `task.imageUrls` is `string[]` (the store's normalizeTaskImageUrlsInPlace splits the
// ||-joined wire string at every fetch site); undefined for legacy task literals.
const firstImage = computed<string | null>(() => {
  const urls = props.task.imageUrls
  if (!urls || urls.length === 0) return null
  return urls[0] ?? null
})
const extraImagesCount = computed<number>(() => {
  const urls = props.task.imageUrls
  if (!urls) return 0
  return Math.max(0, urls.length - 1)
})

// Media-flags change — list/get carry only flags; the card avoids a per-card
// media fetch and shows a lightweight badge when the task has media
// that hasn't been lazy-loaded yet (the detail dialog fetches on open).
const hasUnloadedMedia = computed<boolean>(() => {
  const t = props.task
  if ((t.imageUrls?.length ?? 0) > 0) return false
  return t.is_have_image === true || t.is_have_video === true
})

// The user-facing task-type label shown in the meta row. Returns
// 'memory' for memory tasks, or null for plain standard tasks
// (no badge — the type is implied by the absence of a badge).
const typeBadge = computed<string | null>(() => {
  const t = props.task.task_type
  if (t === 'memory') return 'memory'
  return null
})

// Git-branch badge (plan:
// Null results in NO badge rendered (graceful no-op for non-git
// workspaces / tasks without worktree + non-git cwd).
const gitBranchBadge = computed<string | null>(() => {
  const b = props.task.git_branch
  if (typeof b !== 'string') return null
  if (b.length === 0) return null
  return b
})

// Git-branch PR state coloring: green = open, violet = merged, red = closed, orange = plain branch
// (no PR / fetch failed). Same palette as SidebarDiffPanel's prStatusStyle so the kanban card and
// the PR tab agree.
// Bold by design: semibold text + thicker icon stroke so the badge pops against the dim meta row.
const prStatus = ref('')
// Conflict-only hint: true when the PR reports CONFLICTING/DIRTY.
// Quiet-when-clean — false for mergeable, unknown, or failed fetches.
const prHasConflict = ref(false)

const effectiveCwd = computed<string>(() => props.cwd || props.task.cwd || '')

const gitBranchStyle = computed<Record<string, string>>(() => {
  if (prStatus.value === 'merged') return { color: 'var(--color-violet)', fontWeight: '600' }
  if (prStatus.value === 'closed') return { color: 'var(--semantic-error)', fontWeight: '600' }
  if (prStatus.value === 'open') return { color: 'var(--color-green)', fontWeight: '600' }
  return { color: 'var(--color-orange)', fontWeight: '600' } as Record<string, string>
})

const gitBranchTitle = computed<string>(() => {
  const branch = gitBranchBadge.value ?? ''
  const conflictSuffix = prHasConflict.value ? ' — merge conflicts' : ''
  if (prStatus.value === 'merged') return `PR merged — ${branch}`
  if (prStatus.value === 'closed') return `PR closed — ${branch}`
  if (prStatus.value === 'open') return `PR open${conflictSuffix} — ${branch}`
  return prHasConflict.value ? `${branch} — merge conflicts` : branch
})

// Label shown in the badge: branch name plus a conflict suffix only
// when conflicting (quiet-when-clean — clean PRs look as before).
const gitBranchLabel = computed<string>(() => {
  const branch = gitBranchBadge.value ?? ''
  return prHasConflict.value ? `${branch} · ⚠ conflicts` : branch
})

let prSeq = 0
const loadPrStatus = async () => {
  const branch = gitBranchBadge.value
  const cwd = effectiveCwd.value
  if (!branch || !cwd) {
    prStatus.value = ''
    prHasConflict.value = false
    return
  }
  const seq = ++prSeq
  // Shared cache: dedupes the board-load burst across cards, retries
  // transient failures, resolves '' (fail-silent) when unknown.
  const [status, hasConflict] = await Promise.all([
    fetchPrStatusCached(cwd, branch),
    fetchPrConflictCached(cwd, branch),
  ])
  if (seq !== prSeq) return
  prStatus.value = status
  prHasConflict.value = hasConflict
}

// Reload PR status when the badge or cwd changes: mount covers the
// initial load, prev-combo guard on update covers branch/cwd swaps.
const prevPrKey = ref('')
const prKey = () => `${gitBranchBadge.value ?? ''}|${effectiveCwd.value}`

// A merge or close ANYWHERE — this tab's MergeBox, or the `git_pr_state` SSE event from another
// client — drops the shared cache entry for that branch and calls this back with the pair.
// Without it the badge keeps the `open` green it fetched before the merge until the card happens to
// remount. A subscription, not a `watch`: `local/no-watch` bans reacting to change inside a
// component, and this signal comes from outside it.
// The filter is what keeps a merge on one branch from re-reading all ~140 cards on the board.
let unsubscribePrStatus: (() => void) | null = null
onMounted(() => {
  prevPrKey.value = prKey()
  void loadPrStatus()
  unsubscribePrStatus = onPrStatusInvalidated((change) => {
    if (change.cwd !== effectiveCwd.value || change.branch !== gitBranchBadge.value) return
    void loadPrStatus()
  })
})
onUnmounted(() => {
  unsubscribePrStatus?.()
  unsubscribePrStatus = null
})
onUpdated(() => {
  const key = prKey()
  if (key !== prevPrKey.value) {
    prevPrKey.value = key
    void loadPrStatus()
  }
})
</script>

<template>
  <div
    role="button"
    tabindex="0"
    class="flex flex-col gap-2 p-3 w-full rounded-lg text-dense group/task cursor-pointer transition-shadow duration-200"
    :data-task-id="task.id"
    :data-drop-indicator="dropIndicator ?? undefined"
    :data-has-agent-error="agentError ? 'true' : undefined"
    data-task-card
    :style="{
      color:
        workspacesStore.activeTaskId === task.id ? 'var(--color-aqua)' : 'var(--semantic-text)',
      backgroundColor:
        workspacesStore.activeTaskId === task.id
          ? 'var(--semantic-active-bg)'
          : 'var(--semantic-card-bg)',
      boxShadow: cardBoxShadow,
    }"
    @click="handleSelectTask"
    @keydown="handleCardKeydown"
    @contextmenu.prevent="onTaskContextMenu"
    @mouseenter="isHovered = true"
    @mouseleave="isHovered = false"
  >
    <!-- Top row. A more modern, minimalist layout — title is the
         hero, icons are subtle. The bullet/dot is hidden in card
         variant (visual noise); only the routine clock, status dot,
         and pin indicator stay because they communicate information.
         The action icons (pin toggle, edit, run, delete) are all
         hover-revealed with a small subtle background pill on hover. -->
    <div class="flex items-center gap-2 min-w-0">
      <!-- single branch — per-task routines deleted (Migration 084). -->
      <!-- (standard content unwrapped) -->
      <!-- Kanban notification icon (Chunk 6 of
             docs/plans/2026-07-26-kanban-task-notification-icon.md).
             8px orange-400 dot with a 4-pulse glow when the AI has
             finished a turn (finish_reason=stop) and the user
             hasn't engaged with the task since. Rendered BEFORE the pin
             indicator (so the reading order is "awaiting
             review → pinned state → name"). The elapsed time pill below
             is the activity marker while the worker runs — the circle
             spinner was removed as redundant. Tooltip explains the
             state for screen-reader / hover users.

             The pulse keyframe lives in the scoped <style> block
             below — see `needs-review-pulse`. animation-iteration-
             count: 4 means the dot pulses 4 times then settles to
             a steady glow; iteration-fill-mode: forwards keeps the
             final 0% state (steady, no glow) so the user has a
             consistent "always visible" affordance. -->
      <span
        v-if="task.needs_human_review && task.last_finish_reason === 'stop'"
        class="w-2 h-2 rounded-full shrink-0"
        style="
          background-color: rgb(251, 146, 60);
          box-shadow: 0 0 0 0 rgba(251, 146, 60, 0.6);
          animation: needs-review-pulse 2.4s ease-out 4 forwards;
        "
        title="AI finished — awaiting your review"
        data-testid="task-needs-review"
      />
      <!-- Kanban notification icon (Chunk 6) — green "reviewed"
             checkmark. Shown when last_finish_reason='stop' AND
             needs_human_review=false (i.e. user has touched the
             task since the AI finished). Defensive: we also gate
             on last_finish_reason==='stop' so a stale
             needs_human_review=false + finish_reason='tool_calls'
             state doesn't paint a phantom "reviewed" checkmark
             during a session-status flip. -->
      <span
        v-else-if="task.last_finish_reason === 'stop'"
        class="shrink-0 text-green-500"
        title="Reviewed"
        data-testid="task-reviewed"
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
      <!-- 2026-08-29 agent-error-indicator (task_1787985074550_0):
             additive to pulse / checkmark because retry chains
             fire WHILE the worker is still active. Tooltip shows the
             same headline + retry chip the ChatView's AgentErrorCard
             parses, so users see the same information regardless of
             which surface they're on. Respects prefers-reduced-motion
             (no animation when requested — see the `agent-error-pulse`
             keyframes in the scoped <style> block). -->
      <span
        v-if="agentError"
        class="relative shrink-0 error-icon-wrap"
        data-testid="task-agent-error"
      >
        <span
          class="error-pulse w-3.5 h-3.5 rounded-full flex items-center justify-center"
          style="background: rgba(196, 116, 110, 0.18); border: 1px solid var(--color-red)"
          aria-label="Agent error — click card to view detail"
        >
          <span
            style="color: var(--color-red); font-size: var(--text-micro); line-height: 1"
            aria-hidden="true"
            >⚠</span
          >
        </span>
        <!-- Hover tooltip — same parsing as AgentErrorCard but trimmed
               (no server-detail block; the kanban-tooltip is too small
               for the raw body — the full detail lives in ChatView). -->
        <div
          class="error-tooltip absolute left-0 top-full mt-1.5 w-[280px] z-50 rounded-lg p-2 pointer-events-none opacity-0 invisible transition-opacity duration-150"
          style="
            background: #0e0e0c;
            border: 1px solid rgba(196, 116, 110, 0.45);
            box-shadow: 0 4px 16px rgba(0, 0, 0, 0.4);
          "
          role="tooltip"
          data-testid="task-agent-error-tooltip"
        >
          <div class="flex items-center gap-2 mb-1.5">
            <span style="color: var(--color-red); font-size: var(--text-meta)" aria-hidden="true"
              >⚠</span
            >
            <span class="text-meta font-medium" style="color: var(--color-red)">Agent error</span>
            <span
              v-if="errorRetryLabel"
              class="text-micro px-1.5 py-0.5 rounded-full"
              style="background: rgba(196, 116, 110, 0.18); color: #e8928c"
              data-testid="task-agent-error-retry"
              >retry {{ errorRetryLabel }}</span
            >
          </div>
          <div
            class="text-meta leading-snug"
            style="color: var(--semantic-text-muted)"
            data-testid="task-agent-error-headline"
          >
            {{ errorHeadline }}
          </div>
        </div>
      </span>
      <!-- Card variant: bullet is HIDDEN (the card itself signals
             a task — the dot is visual noise in the modern-
             minimalist design). -->
      <!-- (intentionally no bullet span here in card variant) -->
      <!-- Pin indicator (always visible when pinned). -->
      <span
        v-if="task.is_pinned"
        class="w-3 h-3 flex items-center justify-center shrink-0 text-yellow-400"
        title="Pinned"
        data-testid="task-pin-indicator"
      >
        <svg class="w-3 h-3" fill="currentColor" viewBox="0 0 24 24">
          <path
            d="M16 9V4h1c.55 0 1-.45 1-1s-.45-1-1-1H7c-.55 0-1 .45-1 1s.45 1 1 1h1v5c0 1.66-1.34 3-3 3v2h5.97v7l1 1 1-1v-7H19v-2c-1.66 0-3-1.34-3-3z"
          />
        </svg>
      </span>
      <!-- How long this task has been running. Time pill is the activity
           marker while the worker runs — the circle spinner was removed
           as redundant. -->
      <WorkerElapsedChip :session-id="task.id" test-id="task-card-elapsed-chip" />
      <span class="flex-1 min-w-0 text-body font-medium leading-snug truncate">{{
        task.name
      }}</span>
      <!-- The four hover action buttons that used to live here
           (pin / rename / details / delete) are gone: they ate ~100px
           of a 280px column and truncated the task name to ~150px.
           Every one of them now lives in <KanbanTaskContextMenu>,
           opened by right-click or the ContextMenu key. The pin
           INDICATOR above stays — that is state, not an action. -->
    </div>
    <!-- Description preview. Renders the markdown via <MarkdownDescription>
         (which handles bold/italic/headings/images/@path chips). The
         container caps the height at ~3rem + line-clamp-2 so long
         descriptions don't bloat the card. The `w-full text-left` pair
         is preserved from the previous plain-text version to keep the
         description left-aligned within the flex-col parent (line-clamp
         display quirk). -->
    <div
      v-if="task.description"
      class="text-meta leading-relaxed pr-1 w-full text-left line-clamp-2"
      style="color: var(--semantic-text-muted); max-height: 3rem; overflow: hidden"
      data-testid="task-description"
    >
      <MarkdownDescription
        :source="task.description"
        :cwd="cwd"
        max-height="3rem"
        :test-id="`task-description-rendered`"
      />
    </div>
    <!-- Image thumbnail (Migration 069 read-path fix). First image
         as a 48px-tall cover-cropped thumb + a `+N` badge when more
         images exist. Click opens the detail dialog (same affordance
         as the `+N more` tags link). Plan:
         docs/superpowers/plans/2026-08-24-kanban-task-image-urls-read-path.md -->
    <div
      v-if="firstImage"
      class="relative w-full rounded overflow-hidden shrink-0"
      data-testid="task-image-thumb-wrap"
    >
      <img
        :src="firstImage"
        alt=""
        class="w-full h-12 object-cover rounded cursor-pointer"
        data-testid="task-image-thumb"
        @click.stop="emit('viewTaskDetail', task.id)"
      />
      <span
        v-if="extraImagesCount > 0"
        class="absolute bottom-1 right-1 text-micro px-1.5 py-0.5 rounded font-medium"
        style="background: rgba(0, 0, 0, 0.6); color: #fff"
        data-testid="task-image-more"
        >+{{ extraImagesCount }}</span
      >
    </div>
    <!-- Media-flags change — flag-only list payload: show a lightweight badge
         when the task has media that hasn't been lazy-loaded yet.
         The store prefetches card thumbnails in the background after
         the list lands (queueCardMediaLoad), so this badge is the
         card-first placeholder until the thumb arrives. -->
    <div
      v-else-if="hasUnloadedMedia"
      class="flex items-center gap-1 text-meta self-start"
      style="color: var(--semantic-text-muted)"
      data-testid="task-media-badge"
    >
      <UiIcon name="image" size-class="w-3 h-3" />
      <span>has media</span>
    </div>
    <!-- Tags row (Migration 067 — kanban task tags feature).
         Up to 3 chips visible; "+N more" link if more (opens the
         detail dialog). Same djb2-hash 6-color palette as the
         KanbanTagsInput component so the card chips and dialog
         chips share colors. -->
    <div
      v-if="task.tags && task.tags.length > 0"
      class="flex items-center gap-1 flex-wrap self-start w-full mt-1"
      data-testid="task-tags-row"
    >
      <span
        v-for="(tag, idx) in visibleTags"
        :key="`${tag}-${idx}`"
        class="inline-flex items-center text-micro px-1.5 py-0.5 rounded font-medium"
        :style="tagChipStyle(tag)"
        :data-testid="`task-tag-chip-${tag}`"
      >
        {{ tag }}
      </span>
      <button
        v-if="extraTagsCount > 0"
        type="button"
        class="text-micro underline"
        style="color: var(--semantic-text-dim)"
        @click.stop="emit('viewTaskDetail', task.id)"
        :data-testid="`task-tags-more`"
      >
        +{{ extraTagsCount }} more
      </button>
    </div>
    <!-- Meta row. Just the last-updated time + a single subtle type
         label when relevant. The row gets a hairline top border with
         extra top padding for clear visual separation. `self-start`
         keeps the row pinned to the left edge if a future flex parent
         defaults to centered alignment. -->
    <div
      v-if="lastUpdatedLabel || typeBadge || gitBranchBadge || agentError"
      class="flex items-center gap-1.5 pt-1 text-micro flex-wrap self-start w-full"
      style="color: var(--semantic-text-dim)"
      data-testid="task-meta"
    >
      <!-- Last-updated time pill. Single SVG clock icon + text.
           Renders only when lastUpdatedLabel is non-empty. -->
      <span
        v-if="lastUpdatedLabel"
        class="inline-flex items-center gap-1"
        data-testid="task-meta-updated"
        :title="
          typeof lastUpdated === 'string'
            ? lastUpdated
            : lastUpdated instanceof Date
              ? lastUpdated.toISOString()
              : ''
        "
      >
        <svg class="w-3 h-3 shrink-0" fill="none" viewBox="0 0 24 24" stroke="currentColor">
          <path
            stroke-linecap="round"
            stroke-linejoin="round"
            stroke-width="2"
            d="M12 8v4l3 3m6-3a9 9 0 11-18 0 9 9 0 0118 0z"
          />
        </svg>
        <span>{{ lastUpdatedLabel }}</span>
      </span>
      <!-- Task-type subtle label. Rendered as plain dim text (no
           colored pill background) for a more minimalist feel. -->
      <span
        v-if="typeBadge"
        class="inline-flex items-center gap-1"
        :data-testid="`task-meta-type-${typeBadge}`"
        title="Memory note"
      >
        <span aria-hidden="true">·</span>
        <span>{{ typeBadge }}</span>
      </span>
      <!-- Git-branch badge (plan:
           docs/superpowers/plans/2026-08-06-kanban-task-git-branch.md).
           Shows the task's current git branch (worktree branch when
           bound, else the workspace's current branch). Backend
           computes via `git -C <cwd> symbolic-ref --short HEAD` per
           request; null when cwd is not a git repo or HEAD is
           detached. GitHub-style fork/branch SVG icon (12px) +
           branch name, truncated for long names. Tooltip shows the
           full branch name on hover. -->
      <span
        v-if="gitBranchBadge"
        class="inline-flex items-center gap-1 max-w-[8rem] truncate font-semibold cursor-context-menu"
        :style="gitBranchStyle"
        :title="`${gitBranchTitle} — right-click to open the change request`"
        :data-pr-status="prStatus || undefined"
        :data-pr-conflict="prHasConflict || undefined"
        data-testid="task-git-branch"
        @contextmenu.prevent.stop="onGitBadgeContextMenu"
      >
        <svg
          class="w-4 h-4 shrink-0"
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
        <span class="truncate" :title="gitBranchTitle">{{ gitBranchLabel }}</span>
      </span>
      <!-- 2026-08-29 agent-error-meta-pill (task_1787985074550_0) —
           same data as the icon, in the meta row where users
           naturally scan for status. Shows `3/10 retries` while
           retrying, swaps to `workflow halted` on the TooManyRetries
           bail (when the content has no [Retry N/M] prefix). -->
      <span
        v-if="agentError"
        class="inline-flex items-center gap-1 px-1.5 py-0.5 rounded"
        style="background: rgba(196, 116, 110, 0.12); color: var(--color-red)"
        data-testid="task-meta-agent-error"
      >
        <span aria-hidden="true">⚠</span>
        <span>{{ errorRetryLabel ? `${errorRetryLabel} retries` : 'workflow halted' }}</span>
      </span>
    </div>
    <KanbanTaskContextMenu
      v-if="menuPos"
      :x="menuPos.x"
      :y="menuPos.y"
      :is-pinned="!!task.is_pinned"
      :is-agent-running="isAgentRunning"
      :task-name="task.name"
      :columns="columns"
      :current-column-id="currentColumnId"
      @pin="pinFromMenu"
      @rename="renameFromMenu"
      @view-detail="viewDetailFromMenu"
      @delete-task="requestDeleteFromMenu"
      @open-chat="openTaskMenuInBackground"
      @open-details="openTaskDetailMenuInBackground"
      @stop="stopAgentFromMenu"
      @run-agent="runAgentFromMenu"
      @move-to-column="moveTaskFromMenu"
    />
    <GitBranchMenu
      v-if="gitMenuPos"
      :x="gitMenuPos.x"
      :y="gitMenuPos.y"
      :branch="gitBranchBadge ?? ''"
      :branch-url="gitMenuBranchUrl"
      :pr-url="gitMenuPrUrl"
      @open-branch="openGitBranchInBackground"
      @open-pr="openGitPrInBackground"
    />
  </div>
</template>

<style scoped>
/* Chunk 6 of kanban-task-notification-icon: orange "awaiting review"
   dot pulse. 4 short pulses (~10s total) when the icon first
   appears, then settles to a steady orange dot. Each cycle:
     - 0%:   box-shadow radius 0px,   opacity 0.6 (steady, ready)
     - 70%:  box-shadow radius 12px,  opacity 0 (ripple dissipates)
   The animation: shorthand on the element pairs:
     animation-iteration-count: 4     (4 pulses then stop)
     animation-fill-mode: forwards    (keep the final 0% state
                                       so the user has a consistent
                                       "always visible" affordance
                                       afterwards — no glow, just
                                       the steady dot)
     animation-timing-function: ease-out  (ripple starts fast,
                                          dissipates slowly —
                                          organic, not mechanical)
*/
@keyframes needs-review-pulse {
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

/* 2026-08-29 agent-error-indicator (task_1787985074550_0) — red ⚠
   pulse on first appearance (3 cycles then settles to a steady
   ring). The keyframes live inside
   @media (prefers-reduced-motion: no-preference) so the
   `.error-pulse` class becomes a no-op when the user has reduced-
   motion enabled (the icon stays as a steady ring without
   animation — same pattern as `needs-review-pulse` above). */
@media (prefers-reduced-motion: no-preference) {
  @keyframes agent-error-pulse {
    0% {
      box-shadow: 0 0 0 0 rgba(196, 116, 110, 0.7);
    }
    70% {
      box-shadow: 0 0 0 8px rgba(196, 116, 110, 0);
    }
    100% {
      box-shadow: 0 0 0 0 rgba(196, 116, 110, 0);
    }
  }
  .error-pulse {
    animation: agent-error-pulse 1.8s ease-out 3 forwards;
    border-radius: 50%;
  }
}

/* Hover-tooltip visibility: default hidden, visible on the parent
   icon wrap hover. Sibling classes share the same visibility
   pattern used by the tooltips in <WorkspaceItemTaskRow> (Task 6). */
.error-icon-wrap:hover .error-tooltip {
  opacity: 1;
  visibility: visible;
}

/* Red-tinted card border + box-shadow ring when the task has an
   active agent error. The data-attribute is bound on the card ROOT by
   the script section above; the selector targets the attribute value so
   it never leaks outside this card.

   The `button` tag qualifier this used to carry was dead: the root
   element is a <div role="button">, not a <button>, so the rule never
   matched and the error ring had not been rendering at all. Scoped to
   the data attribute instead. */
[data-has-agent-error='true'] {
  border-color: rgba(196, 116, 110, 0.55);
  box-shadow: 0 0 0 1px rgba(196, 116, 110, 0.25);
}
</style>
