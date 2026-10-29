<!--
  WorkspaceItemTaskRow — the single-line compact per-task row used by
  the sidebar list inside <WorkspaceItem>.

  Split from <WorkspaceItemTask> on 2026-07-02. The card variant moved
  to <WorkspaceItemTaskCard> (kanban-only). This file owns ONLY the
  row layout — the legacy single-line flexbox that the sidebar has used
  since 2026-06-10.

  Behavior (event payload, drop indicator, active styling) is shared
  with the card via the `useTaskActions` composable. See that file for
  the contract.

  The three hover action buttons (pin / rename / delete) were migrated
  into the row's right-click menu (<OpenInNewTabMenu>), the same change
  <WorkspaceItemTaskCard> made to its own strip. The emitted payloads
  are unchanged; only the trigger surface moved. The pin INDICATOR
  stays — that is state, not an action.

  Public API:
    props:  task (Task), workspaceId (string), itemId (string),
            dropIndicator? ('above' | 'below' | null)
    emits:  selectTask, deleteTask, renameTask,
            pinTask  (same shapes as before)
    NOTE: editRoutine/runRoutine emits deleted with per-task routines
    (Migration 084).

  Why a <div role="button"> instead of a <button> for the row?
  The row used to contain nested interactive controls (pin / rename /
  delete), and HTML forbids button-inside-button — Vue's compiler warns
  about it, keyboard activation of a button with focusable descendants
  is spec-undefined, and a screen reader folds the inner buttons'
  labels into the outer button's accessible name. The root is therefore
  a div with role="button" + tabindex=0 + an Enter/Space handler, and
  the same shape is kept now that the actions live in the menu: the
  ContextMenu / Shift+F10 keys open it, so the row is still one
  keyboard-operable unit. Same pattern as DesignPageRow.vue.
-->
<script setup lang="ts">
// Extracted from WorkspaceItem.vue on 2026-06-10. This component owns ONLY the per-task row inside
// the expanded workspace-item panel — the item row (chevron / name / hover buttons) and the
// expansion state stay in WorkspaceItem.
import { inject, ref, computed, type Ref } from 'vue'
import { useCurrentMainView } from '../../composables/useCurrentMainView'
import { useContextMenu } from '../../composables/useContextMenu'
import { useTaskActions, type TaskComponentProps } from '../../composables/useTaskActions'
import WorkerElapsedChip from '../WorkerElapsedChip.vue'
import OpenInNewTabMenu from '../shell/OpenInNewTabMenu.vue'
// 2026-08-29 agent-error-row (task_1787985074550_0) — sidebar variant of the kanban-card indicator.
// Same store + helper as the kanban card (Task 5); single source of truth so the indicator stays in
// sync with the chat card across session switches.
import { useAgentErrorStore } from '../../stores/agentError'
import { parseAgentErrorHeadline } from '../../helpers/parseAgentErrorHeadline'
import { useWorkspacesStore } from '../../stores/workspaces'
import { useNotificationStore } from '../../stores/notifications'

// Re-inject processingState from App.vue (same key WorkspaceItem and ChatsList consume). Keyed by
// task.id == session_id.
const processingState = inject<Ref<Record<string, boolean>>>(
  'processingState',
  ref<Record<string, boolean>>({}),
)

const props = defineProps<TaskComponentProps>()

// A worker is running on this task. Same key the card's elapsed chip and
// the detail dialog's Start-agent button read; gates the "Run agent"
// menu row (the backend answers 409 while a worker is in flight).
const isBusy = computed(() => processingState.value[props.task.id] === true)

// URL-driven "what is the main content area showing?". SIMPLIFY-URL-BROWSER (2026-08-15): the
// legacy `kind: 'task'` variant has been dropped from useCurrentMainView.
const currentMainView = useCurrentMainView()
const isActive = computed(
  () =>
    currentMainView.value.kind === 'workspace' &&
    currentMainView.value.chatTaskId === props.task.id,
)

const emit = defineEmits<{
  selectTask: [taskId: string]
  openTaskInBackground: [payload: { workspaceId: string; itemId: string; taskId: string }]
  deleteTask: [workspaceId: string, itemId: string, taskId: string]
  renameTask: [workspaceId: string, itemId: string, taskId: string, currentName: string]
  // (pinned-tasks feature): emitted by the menu's Pin/Unpin row. Payload
  // carries the new is_pinned state so the store doesn't have to
  // re-read the task prop.
  pinTask: [workspaceId: string, itemId: string, taskId: string, isPinned: boolean]
}>()

// Shared logic — event handlers, drop indicator. See composables/useTaskActions.ts for the
// contract. Only the two pieces the row still uses inline.
const { dropIndicatorBoxShadow, handleSelectTask } = useTaskActions(props, emit)

// Right-click "Open in new tab" for this task. The menu position lives in useContextMenu; the task
// ids come from props. The event bubbles up (sidebar list or kanban board) where the host builds
// the task chat URL and opens a real browser tab.
const { menuPos, openAt, openAtPoint, close: closeTaskMenu } = useContextMenu()

const onTaskContextMenu = (event: MouseEvent) => {
  openAt(event)
}

// Enter / Space activate the row; ContextMenu / Shift+F10 open the action menu. The root is a <div
// role="button"> rather than a real <button> — see the header comment for why.
const handleRowKeydown = (event: KeyboardEvent) => {
  if (event.key === 'Enter' || event.key === ' ') {
    event.preventDefault()
    handleSelectTask()
    return
  }
  // ContextMenu / Shift+F10 open the action menu. Removing the hover buttons took away the only
  // discoverable route to rename / delete, so the keyboard path is a hard requirement, not a
  // nice-to-have — otherwise the change is an accessibility regression.
  if (event.key === 'ContextMenu' || (event.key === 'F10' && event.shiftKey)) {
    event.preventDefault()
    // Anchor at the row's centre — there is no cursor to follow on a keyboard gesture. Reuses the
    // same viewport clamp as a real right-click so a row near the bottom-right corner doesn't push
    // the menu off-screen.
    const rect = (event.currentTarget as HTMLElement | null)?.getBoundingClientRect()
    openAtPoint(
      rect ? rect.left + rect.width / 2 : 0,
      rect ? rect.top + rect.height / 2 : 0,
      event.currentTarget as HTMLElement | null,
    )
  }
}

const openTaskMenuInBackground = () => {
  closeTaskMenu()
  emit('openTaskInBackground', {
    workspaceId: props.workspaceId,
    itemId: props.itemId,
    taskId: props.task.id,
  })
}

// Migration 104 — right-click Pin/Unpin on kanban task rows (session list in kanban). Emits pinTask
// directly (handlePinToggle needs a click event for stopPropagation; the menu has none). The
// backend syncs sessions so the PINNED section updates.
const pinTaskFromMenu = () => {
  closeTaskMenu()
  emit('pinTask', props.workspaceId, props.itemId, props.task.id, !props.task.is_pinned)
}

// Rename / delete from the menu. Same contract as `pinTaskFromMenu` above: emit straight up with
// the identical payload the old hover buttons produced.
const renameTaskFromMenu = () => {
  closeTaskMenu()
  emit('renameTask', props.workspaceId, props.itemId, props.task.id, props.task.name)
}

const deleteTaskFromMenu = () => {
  closeTaskMenu()
  emit('deleteTask', props.workspaceId, props.itemId, props.task.id)
}

// Right-click "Run agent" — starts a worker on this task's existing session without queueing a new
// user message (the same `startAgentOnTask` the kanban card and the detail dialog use).
const workspacesStore = useWorkspacesStore()
const isRunningAgent = ref(false)

const runAgentFromMenu = async () => {
  closeTaskMenu()
  if (isBusy.value || isRunningAgent.value) return
  isRunningAgent.value = true
  try {
    const result = await workspacesStore.startAgentOnTask(
      props.workspaceId,
      props.itemId,
      props.task.id,
    )
    if (result && result.success && result.status === 'triggered') return
    if (result && result.success === false) {
      useNotificationStore().notifyError(
        "Agent didn't start — server reported failure.",
        'Run agent',
      )
    } else if (result === undefined) {
      useNotificationStore().notifyError("Agent didn't start — network error.", 'Run agent')
    } else {
      useNotificationStore().notifyError("Agent didn't start — unexpected response.", 'Run agent')
    }
  } catch (err) {
    console.error('Failed to run agent from sidebar row:', err)
    useNotificationStore().notifyError(
      err instanceof Error ? err.message : String(err),
      'Run agent',
    )
  } finally {
    isRunningAgent.value = false
  }
}

// 2026-08-29 agent-error-row — reactive read of the latest agent error keyed by task.id ==
// session_id (migration 052 invariant). Same store + helper as the kanban card and ChatView's
// AgentErrorCard — see stores/agentError.ts and helpers/parseAgentErrorHeadline.ts.
const agentErrorStore = useAgentErrorStore()
const agentError = computed(() => agentErrorStore.bySession[props.task.id] ?? null)
const errorHeadline = computed(() =>
  agentError.value ? parseAgentErrorHeadline(agentError.value.content).headline : null,
)
const errorRetryLabel = computed(() =>
  agentError.value ? parseAgentErrorHeadline(agentError.value.content).retryLabel : null,
)
</script>

<template>
  <div
    role="button"
    tabindex="0"
    class="relative flex items-center px-[var(--sb-gutter)] h-[var(--sb-row)] rounded-lg text-dense group/task cursor-pointer transition-colors duration-150 w-full text-left"
    :data-task-id="task.id"
    :data-drop-indicator="dropIndicator ?? undefined"
    data-task-row
    :style="{
      color: isActive ? 'var(--semantic-active-text)' : 'var(--semantic-text-dim)',
      backgroundColor: isActive ? 'var(--semantic-active-bg)' : 'transparent',
      boxShadow: dropIndicatorBoxShadow,
    }"
    @click="handleSelectTask"
    @keydown="handleRowKeydown"
    @contextmenu.prevent="onTaskContextMenu"
  >
    <!-- single branch — per-task routines deleted (Migration 084,
     plan 2026-09-10-workspace-items-routines). All tasks render
     the standard row. -->
    <!-- (standard content unwrapped) -->
    <!-- Row variant: bullet renders as before for the sidebar's
           compact list. Hidden while the worker is running so
           the row shows a SINGLE visual marker (either the bullet
           when idle, or the elapsed time pill when processing). -->
    <span class="w-[var(--sb-mark)] shrink-0 flex items-center">
      <span
        v-if="!processingState[task.id]"
        class="w-1 h-1 rounded-full shrink-0"
        :style="{
          backgroundColor:
            isActive || task.is_pinned ? 'var(--color-yellow)' : 'var(--semantic-text-dim)',
          opacity: isActive || task.is_pinned ? 1 : 0.6,
        }"
      />
      <!-- 2026-08-29 agent-error-row (task_1787985074550_0) — sidebar
           variant of the kanban-card indicator. No border ring (no
           row-level border exists); no meta pill (the row has no
           meta row). Just the icon with the same hover-tooltip so
           users see "this chat has an error" in the chat list
           regardless of which surface they're on. Smaller than the
           kanban variant because the row's vertical real estate is
           ~28px vs the card's ~80px. Additive v-if (sibling to the
           bullet above, NOT a v-else-if) because retry attempts
           fire WHILE the worker is still active and the indicator
           must coexist with the time pill. -->
      <span
        v-if="agentError"
        class="relative shrink-0 error-icon-wrap"
        data-testid="task-agent-error-row"
      >
        <span
          class="w-3 h-3 rounded-full flex items-center justify-center"
          style="background: rgba(196, 116, 110, 0.18); border: 1px solid var(--color-red)"
          aria-label="Agent error"
        >
          <span
            style="color: var(--color-red); font-size: var(--text-micro); line-height: 1"
            aria-hidden="true"
            >⚠</span
          >
        </span>
        <!-- sb-scope: overlay — a floating card, not a row in the panel.
           It keeps its own 240px width on purpose (narrower than the
           kanban card's 280px because sidebar rows are denser) and its
           own type scale, so Sidebar.spacing.spec.ts skips this block. -->
        <!-- Same tooltip markup as the kanban card, but 240px wide
             (the card uses 280px); sidebar rows are denser so the
             narrower tooltip feels less obtrusive. -->
        <div
          class="error-tooltip absolute left-0 top-full mt-1.5 w-[240px] z-50 rounded-lg p-2 pointer-events-none opacity-0 invisible transition-opacity duration-150"
          style="
            background: var(--semantic-card-bg);
            border: 1px solid rgba(196, 116, 110, 0.45);
            box-shadow: 0 4px 16px rgba(0, 0, 0, 0.4);
          "
          role="tooltip"
          data-testid="task-agent-error-row-tooltip"
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
              data-testid="task-agent-error-row-retry"
              >retry {{ errorRetryLabel }}</span
            >
          </div>
          <div
            class="text-meta leading-snug"
            style="color: var(--semantic-text-muted)"
            data-testid="task-agent-error-row-headline"
          >
            {{ errorHeadline }}
          </div>
        </div>
        <!-- /sb-scope: overlay -->
      </span>
      <!-- Pin indicator (always visible when pinned). -->
      <span
        v-if="task.is_pinned"
        class="w-3 h-3 flex items-center justify-center shrink-0"
        style="color: var(--color-yellow)"
        title="Pinned"
        data-testid="task-pin-indicator"
      >
        <svg class="w-3 h-3" fill="currentColor" viewBox="0 0 24 24">
          <path
            d="M16 9V4h1c.55 0 1-.45 1-1s-.45-1-1-1H7c-.55 0-1 .45-1 1s.45 1 1 1h1v5c0 1.66-1.34 3-3 3v2h5.97v7l1 1 1-1v-7H19v-2c-1.66 0-3-1.34-3-3z"
          />
        </svg>
      </span>
    </span>
    <span class="flex-1 min-w-0 truncate">{{ task.name }}</span>
    <!-- The three hover action buttons that used to live here
         (pin / rename / delete) are gone: they ate ~72px of a ~200px
         panel and truncated the task name. Every one of them now lives
         in <OpenInNewTabMenu>, opened by right-click or the
         ContextMenu key. The pin INDICATOR above stays — that is
         state, not an action. -->

    <!-- How long this task has been running. Time pill is the only
         activity marker — the circle spinner was removed as redundant. -->
    <span class="ml-2 shrink-0 flex items-center">
      <WorkerElapsedChip :session-id="task.id" test-id="task-elapsed-chip" variant="text" />
    </span>
    <OpenInNewTabMenu
      v-if="menuPos"
      :x="menuPos.x"
      :y="menuPos.y"
      show-pin
      :is-pinned="task.is_pinned"
      show-rename
      show-delete
      show-run-agent
      :is-agent-running="isBusy"
      @open="openTaskMenuInBackground"
      @pin="pinTaskFromMenu"
      @rename="renameTaskFromMenu"
      @delete-task="deleteTaskFromMenu"
      @run-agent="runAgentFromMenu"
    />
  </div>
</template>

<!-- 2026-08-29 agent-error-row (task_1787985074550_0) — scoped
     style for the hover-tooltip visibility. WorkspaceItemTaskCard
     has its own scoped rule with the same selector; Vue's scoped
     CSS does NOT cross component boundaries, so this row needs its
     own mirror here. Same shape as the kanban card variant
     (WorkspaceItemTaskCard.vue line ~834) — hover the wrap to
     reveal the tooltip. The opacity/visibility transition lives
     inline on the tooltip div itself (`opacity-0 invisible ...
     transition-opacity duration-150`); this rule just flips the
     final state on hover. -->
<style scoped>
.error-icon-wrap:hover .error-tooltip {
  opacity: 1;
  visibility: visible;
}
</style>
