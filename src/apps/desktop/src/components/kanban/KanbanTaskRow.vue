<!--
  KanbanTaskRow — one task line inside <KanbanRowView>'s row mode.

  Row mode is the board's *reading* surface: the whole board flattened
  into a scannable list. That makes the row's job different from the
  sidebar's. The sidebar's <WorkspaceItemTaskRow> is a 32 px label for a
  ~200 px-wide panel where the name alone is all that fits. Here the row
  is the primary content and is wide enough to carry a second line, so
  this component owns its own layout:

    ▌  Fix the login redirect on refresh            pin · edit · ⋯ · ✕
       ⑂ worktree/fix-login · #bug · 2h ago

  Why it no longer wraps <WorkspaceItemTaskRow>: restyling a component
  the sidebar also renders would regress the sidebar (which has its own
  density and three spec files) to serve a surface with the opposite
  requirements. Instead this row reuses the SHARED CONTRACT —
  `useTaskActions` for select / pin / rename / delete — and renders its
  own markup, which is exactly the split the card variant makes
  (<WorkspaceItemTaskCard> also owns its own layout off the same
  composable).

  What changed for readability (wireframe
  preview-kanban-row-readable-wireframe.html):
    1. Name at 13 px / `--semantic-text` = 10.17:1 contrast. The sidebar
       row's 12 px / `--semantic-text-dim` is 4.38:1 — AA-large only, and
       this is body copy.
    2. A 3 px status rail on the left edge, so a 110-row group can be
       scanned down the left margin alone.
    3. A metadata line (time · branch · tags · status) — a row showing
       only a name cannot be told apart from its neighbour.
    4. Actions hidden until hover/focus instead of 3 permanent icons on
       every row.
    5. Hairline separators so a run of rows is countable.

  Every field read here already ships on the `Task` payload the board is
  already fetching (updatedAt / createdAt, git_branch, tags,
  needs_human_review, last_finish_reason) — no new endpoint, no new data.

  Public API (unchanged from the first row-mode commit — the kanban
  specs key off these testids and emits):
    props:  task (Task), workspaceId, itemId, cwd?, density?
    emits:  selectTask, openTaskInBackground, deleteTask, renameTask,
            pinTask, viewTaskDetail
-->
<script setup lang="ts">
import { computed, inject, ref, type Ref } from 'vue'
import { useCurrentMainView } from '../../composables/useCurrentMainView'
import { useTaskActions } from '../../composables/useTaskActions'
import { useContextMenu } from '../../composables/useContextMenu'
import { useAgentErrorStore } from '../../stores/agentError'
import { parseAgentErrorHeadline } from '../../helpers/parseAgentErrorHeadline'
import { formatTaskTimestamp, taskTimestampTooltip } from '../../helpers/formatTaskTimestamp'
import OpenInNewTabMenu from '../shell/OpenInNewTabMenu.vue'
import UiIcon from '../ui/UiIcon.vue'
import WorkerElapsedChip from '../WorkerElapsedChip.vue'
import type { Task } from '../../stores/workspaces'

export type KanbanRowDensity = 'comfortable' | 'compact'

const props = withDefaults(
  defineProps<{
    task: Task
    workspaceId: string
    itemId: string
    cwd?: string
    /** `comfortable` (default) is the two-line record: name + metadata.
     * `compact` drops the metadata line back to a single scannable line,
     * for boards like `merged` where 110 two-line rows is a lot of
     * scrolling. Threaded from <KanbanView> via localStorage. */
    density?: KanbanRowDensity
  }>(),
  { cwd: '', density: 'comfortable' },
)

const emit = defineEmits<{
  selectTask: [taskId: string]
  openTaskInBackground: [payload: { workspaceId: string; itemId: string; taskId: string }]
  deleteTask: [workspaceId: string, itemId: string, taskId: string]
  renameTask: [workspaceId: string, itemId: string, taskId: string, currentName: string]
  pinTask: [workspaceId: string, itemId: string, taskId: string, isPinned: boolean]
  viewTaskDetail: [taskId: string]
  // Right-click "Run agent" — starts a worker on this task's existing
  // session. The host (KanbanView) owns the API call; the row only
  // reports intent, same contract as the card's context menu.
  runAgent: [payload: { taskId: string }]
}>()

// Re-injected from App.vue rather than threaded down — same key and same
// reason as <WorkspaceItemTaskRow>: it is keyed by task.id == session_id
// and every per-task surface reads it this way.
const processingState = inject<Ref<Record<string, boolean>>>('processingState', ref({}))

// Shared handler contract (select / pin / rename / delete + the drop
// indicator). `dropIndicator` is unused in row mode — there is no
// pinned-region drag here — but the composable requires the prop shape.
const { handleSelectTask, handleDeleteTask, handleRenameTask, handlePinToggle } = useTaskActions(
  { ...props, dropIndicator: null },
  emit,
)

// ─── Active state ──────────────────────────────────────────────────────────

// URL-driven, like the sidebar row: the highlight must survive refresh,
// deep links and Back/Forward, so it is derived from the route rather
// than from a store flag that can drift.
const currentMainView = useCurrentMainView()
const isActive = computed(
  () =>
    currentMainView.value.kind === 'workspace' &&
    currentMainView.value.chatTaskId === props.task.id,
)

const isBusy = computed(() => !!processingState.value[props.task.id])

// ─── Status rail ───────────────────────────────────────────────────────────
//
// Ordered by what a reader is looking for: an error outranks a review
// request, which outranks work in flight. `reviewed` is a positive
// signal rather than a problem, so it sits last — a wall of green means
// "you can skip all of this", which is worth seeing but not alarming.
const agentErrorStore = useAgentErrorStore()
const agentError = computed(() => agentErrorStore.bySession[props.task.id] ?? null)
const errorRetryLabel = computed(() =>
  agentError.value ? parseAgentErrorHeadline(agentError.value.content).retryLabel : null,
)

const awaitingReview = computed(
  () => !!props.task.needs_human_review && props.task.last_finish_reason === 'stop',
)
const isReviewed = computed(
  () => !awaitingReview.value && !isBusy.value && props.task.last_finish_reason === 'stop',
)

type RowState = 'error' | 'review' | 'busy' | 'reviewed' | 'default'
const rowState = computed<RowState>(() => {
  if (agentError.value) return 'error'
  if (awaitingReview.value) return 'review'
  if (isBusy.value) return 'busy'
  if (isReviewed.value) return 'reviewed'
  return 'default'
})

const RAIL_COLORS: Record<RowState, string> = {
  error: 'var(--color-red)',
  review: 'rgb(251, 146, 60)',
  busy: 'var(--color-yellow)',
  reviewed: 'var(--color-green)',
  default: 'transparent',
}
const railColor = computed(() => RAIL_COLORS[rowState.value])

// A single human-readable sentence for the status slot. Null when
// nothing is worth saying, so the metadata line can skip the separator.
const statusLabel = computed<string | null>(() => {
  if (agentError.value) {
    return errorRetryLabel.value ? `⚠ ${errorRetryLabel.value} retries` : '⚠ workflow halted'
  }
  if (awaitingReview.value) return '● awaiting review'
  if (isBusy.value) return '● agent running'
  if (isReviewed.value) return '✓ reviewed'
  return null
})

const statusTestId = computed<string | null>(() => {
  if (agentError.value) return 'kanban-row-status-error'
  if (awaitingReview.value) return 'kanban-row-status-review'
  if (isBusy.value) return 'kanban-row-status-busy'
  if (isReviewed.value) return 'kanban-row-status-reviewed'
  return null
})

// ─── Metadata line ────────────────────────────────────────────────────────

const lastUpdated = computed<Date | string | null>(() => {
  if (props.task.updatedAt) return props.task.updatedAt
  if (props.task.createdAt) return props.task.createdAt
  return null
})
const updatedLabel = computed(() => formatTaskTimestamp(lastUpdated.value))
const updatedTitle = computed(() => taskTimestampTooltip(lastUpdated.value))

// Branch name or null. Empty string and null both mean "don't render a
// badge" — the backend returns null for a non-repo cwd or detached HEAD.
const gitBranch = computed<string | null>(() => {
  const b = props.task.git_branch
  if (typeof b !== 'string' || b.length === 0) return null
  return b
})

// Cap the tag chips: a row is a line, not a card, and 8 chips would push
// the time off the end. The count of hidden tags rides along as "+N".
const VISIBLE_TAGS_MAX = 3
const visibleTags = computed<string[]>(() => (props.task.tags ?? []).slice(0, VISIBLE_TAGS_MAX))
const extraTagsCount = computed(() =>
  Math.max(0, (props.task.tags ?? []).length - VISIBLE_TAGS_MAX),
)

// Same djb2 → 6-colour palette as <WorkspaceItemTaskCard> and
// <KanbanTagsInput>, so a tag keeps its colour wherever it appears.
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
  const c = TAG_PALETTE[hash % TAG_PALETTE.length] ?? TAG_PALETTE[0]
  return { backgroundColor: c.bg, border: `1px solid ${c.border}`, color: c.text }
}

// ─── Keyboard ──────────────────────────────────────────────────────────────
//
// The row root is a <div role="button"> because it hosts nested
// interactive controls (pin / rename / delete / details) and HTML
// forbids button-inside-button. Enter / Space restore the keyboard
// contract the native element would have given us.
const handleRowKeydown = (event: KeyboardEvent) => {
  if (event.key === 'Enter' || event.key === ' ') {
    event.preventDefault()
    handleSelectTask()
  }
}

// ─── Right-click "open in new tab" ─────────────────────────────────────────
const { menuPos, openAt, close: closeTaskMenu } = useContextMenu()
const onTaskContextMenu = (event: MouseEvent) => openAt(event)

const openTaskMenuInBackground = () => {
  closeTaskMenu()
  emit('openTaskInBackground', {
    workspaceId: props.workspaceId,
    itemId: props.itemId,
    taskId: props.task.id,
  })
}

// Right-click "Run agent". Emits up rather than calling the store —
// the row has no workspace/item context of its own beyond the props it
// already forwards, and the endpoint path is built by KanbanView.
const runAgentFromMenu = () => {
  closeTaskMenu()
  if (isBusy.value) return
  emit('runAgent', { taskId: props.task.id })
}
</script>

<template>
  <div
    class="kanban-task-row group/row flex items-stretch rounded transition-colors duration-150"
    :class="props.density === 'compact' ? 'min-h-[28px]' : 'min-h-[46px]'"
    :style="{
      backgroundColor: isActive ? 'var(--semantic-active-bg)' : 'transparent',
    }"
    :data-kanban-row="props.task.id"
    :data-kanban-row-state="rowState"
    :data-kanban-row-density="props.density"
  >
    <!-- Status rail. Always rendered (rather than v-if) so the row's
         text keeps a constant left inset and the list stays aligned
         when a group mixes states. -->
    <span
      class="w-[3px] shrink-0 rounded-full my-[7px] mr-2"
      :style="{ backgroundColor: railColor }"
      aria-hidden="true"
    />

    <div
      role="button"
      tabindex="0"
      class="flex-1 min-w-0 flex flex-col justify-center cursor-pointer"
      :class="props.density === 'compact' ? 'py-[3px] pr-1' : 'py-1.5 pr-1'"
      :data-task-id="props.task.id"
      data-task-row
      @click="handleSelectTask"
      @keydown="handleRowKeydown"
      @contextmenu.prevent="onTaskContextMenu"
    >
      <div
        class="text-dense leading-[1.35] truncate"
        style="color: var(--semantic-text)"
        :title="props.task.name"
        data-testid="kanban-row-name"
      >
        <span
          v-if="props.task.is_pinned"
          class="mr-1"
          style="color: #e8c87a"
          title="Pinned"
          data-testid="kanban-row-pin-indicator"
          aria-hidden="true"
          ><UiIcon name="pin" /></span
        >{{ props.task.name }}
      </div>

      <!-- Metadata line. Hidden in compact density — that is the whole
           point of the toggle, so the template guard is on the prop
           rather than on a CSS class (no layout is reserved for it). -->
      <div
        v-if="props.density !== 'compact'"
        class="flex items-center gap-2 mt-0.5 text-meta leading-[1.5] whitespace-nowrap overflow-hidden"
        style="color: var(--semantic-text-muted)"
        data-testid="kanban-row-meta"
      >
        <span v-if="statusLabel" :data-testid="statusTestId ?? undefined">{{ statusLabel }}</span>

        <!-- Elapsed + last-activity for a running worker. The rail above
             already says "busy" in yellow; these two numbers say for how
             long and whether it is still heart-beating. -->
        <WorkerElapsedChip
          v-if="isBusy"
          :session-id="props.task.id"
          variant="text"
          test-id="kanban-row-elapsed"
        />

        <span
          v-if="gitBranch"
          class="font-semibold truncate"
          style="color: var(--color-orange)"
          :title="gitBranch"
          data-testid="kanban-row-branch"
          >⑂ {{ gitBranch }}</span
        >

        <template v-for="(tag, idx) in visibleTags" :key="`${tag}-${idx}`">
          <span class="shrink-0" style="color: var(--color-nontext)">·</span>
          <span
            class="shrink-0 text-micro px-1.5 rounded font-medium"
            :style="tagChipStyle(tag)"
            :data-testid="`kanban-row-tag-${tag}`"
            >{{ tag }}</span
          >
        </template>
        <span v-if="extraTagsCount > 0" class="shrink-0" style="color: var(--color-nontext)"
          >+{{ extraTagsCount }}</span
        >

        <span
          v-if="updatedLabel"
          class="shrink-0"
          :title="updatedTitle"
          data-testid="kanban-row-updated"
          >{{ updatedLabel }}</span
        >
      </div>
    </div>

    <!-- Actions. Hidden until the row is hovered or something inside it
         has focus — 3 permanent icons on every row of a 110-row group is
         330 elements of noise the eye reads before the text. The
         `focus-within` arm keeps them reachable by keyboard. -->
    <div
      class="shrink-0 flex items-center gap-0.5 pr-1 opacity-0 transition-opacity duration-150 group-hover/row:opacity-100 focus-within:opacity-100"
    >
      <button
        type="button"
        class="w-6 h-6 flex items-center justify-center rounded hover:bg-[#2e2d2a]"
        :class="props.task.is_pinned ? 'opacity-100' : 'opacity-70'"
        :style="props.task.is_pinned ? 'color: #e8c87a' : 'color: var(--semantic-text-dim)'"
        :title="props.task.is_pinned ? 'Unpin task' : 'Pin task'"
        :aria-label="props.task.is_pinned ? 'Unpin task' : 'Pin task'"
        data-testid="task-pin-toggle"
        @click="handlePinToggle($event)"
      >
        <svg
          v-if="props.task.is_pinned"
          class="w-3.5 h-3.5"
          fill="currentColor"
          viewBox="0 0 24 24"
          aria-hidden="true"
        >
          <path
            d="M16 9V4h1c.55 0 1-.45 1-1s-.45-1-1-1H7c-.55 0-1 .45-1 1s.45 1 1 1h1v5c0 1.66-1.34 3-3 3v2h5.97v7l1 1 1-1v-7H19v-2c-1.66 0-3-1.34-3-3z"
          />
        </svg>
        <svg
          v-else
          class="w-3.5 h-3.5"
          fill="none"
          viewBox="0 0 24 24"
          stroke="currentColor"
          stroke-width="2"
          aria-hidden="true"
        >
          <path
            stroke-linecap="round"
            stroke-linejoin="round"
            d="M16 9V4h1c.55 0 1-.45 1-1s-.45-1-1-1H7c-.55 0-1 .45-1 1s.45 1 1 1h1v5c0 1.66-1.34 3-3 3v2h5.97v7l1 1 1-1v-7H19v-2c-1.66 0-3-1.34-3-3z"
          />
        </svg>
      </button>

      <button
        type="button"
        class="w-6 h-6 flex items-center justify-center rounded opacity-70 hover:opacity-100 hover:bg-[#2e2d2a] hover:text-blue-400"
        style="color: var(--semantic-text-dim)"
        title="Rename task"
        aria-label="Rename task"
        data-testid="task-rename"
        @click="handleRenameTask($event)"
      >
        <svg
          class="w-3.5 h-3.5"
          fill="none"
          viewBox="0 0 24 24"
          stroke="currentColor"
          stroke-width="2"
          aria-hidden="true"
        >
          <path
            stroke-linecap="round"
            stroke-linejoin="round"
            d="M11 5H6a2 2 0 00-2 2v11a2 2 0 002 2h11a2 2 0 002-2v-5m-1.414-9.414a2 2 0 112.828 2.828L11.828 15H9v-2.828l8.586-8.586z"
          />
        </svg>
      </button>

      <button
        type="button"
        class="w-6 h-6 flex items-center justify-center rounded opacity-70 hover:opacity-100 hover:bg-[#2e2d2a]"
        style="color: var(--semantic-text-dim)"
        title="Open task details"
        aria-label="Open task details"
        :data-testid="`kanban-row-${props.task.id}-details`"
        @click.stop="emit('viewTaskDetail', props.task.id)"
      >
        <span class="text-lead leading-none" aria-hidden="true">⋯</span>
      </button>

      <button
        type="button"
        class="w-6 h-6 flex items-center justify-center rounded opacity-70 hover:opacity-100 hover:bg-[#2e2d2a] hover:text-red-400"
        style="color: var(--semantic-text-dim)"
        title="Delete task"
        aria-label="Delete task"
        data-testid="task-delete"
        @click="handleDeleteTask($event)"
      >
        <svg
          class="w-3.5 h-3.5"
          fill="none"
          viewBox="0 0 24 24"
          stroke="currentColor"
          stroke-width="2"
          aria-hidden="true"
        >
          <path stroke-linecap="round" stroke-linejoin="round" d="M6 18L18 6M6 6l12 12" />
        </svg>
      </button>
    </div>

    <OpenInNewTabMenu
      v-if="menuPos"
      :x="menuPos.x"
      :y="menuPos.y"
      show-run-agent
      :is-agent-running="isBusy"
      @open="openTaskMenuInBackground"
      @run-agent="runAgentFromMenu"
    />
  </div>
</template>

<style scoped>
/* Hairline between rows. Applied to every row but the first so a group
   reads as a countable stack instead of one solid block. The colour is
   the app's own --color-border; at 1px it is decorative (below the 3:1
   non-text threshold by design) and exists to guide the eye, not to
   carry information. */
.kanban-task-row + .kanban-task-row {
  border-top: 1px solid rgba(40, 39, 39, 0.55);
}
</style>
