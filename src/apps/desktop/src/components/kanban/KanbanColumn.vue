<!--
  KanbanColumn — a single column in a kanban board.

  Layout (top → bottom):
    1. Header  — column name + count badge + "⋮" menu.
                Single-clicking the name starts an inline rename
                (small input, Enter saves, Escape/blur cancels). The
                "⋮" menu offers Rename (re-opens via KanbanColumnEditor)
                and Delete (opens KanbanColumnEditor in delete mode).
                The header is DRAGGABLE — dragging it onto another
                column's header reorders the columns (Trello/Jira
                UX). Uses a dedicated MIME type
                `application/x-kanban-column-id` so it doesn't
                collide with the per-card MIME
                (`application/x-kanban-task-id`).
    2. Cards   — scrollable list of <KanbanCard>, filtered by the
                column id from the `tasks` prop. The backend
                applies the per-column sort (sortBy + direction,
                both stateful in this component) — wire data
                arrives already in the column's own order.
    3. Drop    — the cards area is a drop zone. dragover.preventDefault
                (required by the HTML5 DnD spec to mark this as a
                valid drop target), drop reads the task id from
                `application/x-kanban-task-id` and emits `move-task`
                with the column id and the drop position.

  Public API:
    props:
      column       KanbanColumn
      tasks        Task[] (the full task list for the parent kanban)
      workspaceId  string (passed through to KanbanCard)
      itemId       string (passed through to KanbanCard)
    emits:
      move-task          [{ taskId: string, columnId: string, position: number }]
      rename-column      [{ columnId: string, name: string }]
      delete-column      [columnId: string]
      reorder-column     [{ columnId: string, targetColumnId: string }]
      select-task        [taskId: string]
      delete-task        [workspaceId, itemId, taskId]
      rename-task        [workspaceId, itemId, taskId, currentName]
      pin-task           [workspaceId, itemId, taskId, isPinned]
-->
<script setup lang="ts">
import { computed, ref, nextTick, onMounted, onUnmounted, onUpdated } from 'vue'
import KanbanCard from './KanbanCard.vue'
import KanbanSortMenu from './KanbanSortMenu.vue'
import { VirtualScroller } from '@/helpers'
import { useKanbanColumnScrollRestore } from '../../composables/useKanbanColumnScrollRestore'
import { useWorkspacesStore } from '../../stores/workspaces'
import type { KanbanColumn, Task } from '../../stores/workspaces'

/**  * Minimal view of <VirtualScroller>'s `defineExpose` surface. Local on purpose: the component does
 * not export its exposed type, and this component needs exactly one member of it. `containerRef`
 * arrives as the HTMLElement itself, not a ref — `defineExpose` auto-unwraps. */
interface ColumnScrollerExposed {
  containerRef: HTMLElement | null
}

const props = withDefaults(
  defineProps<{
    column: KanbanColumn
    tasks: Task[]
    workspaceId: string
    itemId: string
    // Absolute path used as the root for `@`-trigger file pickers /
    // file-path resolution in descendant cards. Threaded from
    // <KanbanView> via `props.item.path`.
    cwd?: string
    // NEW (plan: 2026-09-09-run-all-agents-by-column, Task 3, Option C). In-flight state for the
    // column's bulk "Run all agents" action. The host (KanbanView) sets this while its per-column
    // `handleRunAllAgents` POST is in flight; the menu item is disabled while true.
    runAllBusy?: boolean
    // In-flight state for the column's bulk "Stop all agents" action.
    // Mirror of `runAllBusy` — the host sets this while its per-column
    // `handleStopAllAgents` POST is in flight.
    stopAllBusy?: boolean
    // Every column on the board, already ordered. Threaded to each
    // card so its context menu can render the "Move to column"
    // submenu. Empty (default) hides the submenu entirely.
    columns?: KanbanColumn[]
  }>(),
  {
    cwd: '',
    runAllBusy: false,
    stopAllBusy: false,
    columns: () => [],
  },
)

const emit = defineEmits<{
  moveTask: [{ taskId: string; columnId: string; position: number }]
  renameColumn: [{ columnId: string; name: string }]
  deleteColumn: [columnId: string]
  // The "⋮" menu's rename option should open KanbanColumnEditor in 'rename' mode (the modal UX).
  // The host listens for this and wires it up. Different from the inline rename UX (single-click
  // the name → edit-in-place) — the menu is the modal-based path.
  requestRenameColumn: [columnId: string]
  // The "⋮" menu's delete option opens KanbanColumnEditor in
  // 'delete' mode (confirmation modal). The host listens for this.
  requestDeleteColumn: [columnId: string]
  // NEW (plan: 2026-09-09-run-all-agents-by-column, Task 3, Option C).
  // The "⋮" menu's "Run all agents" option. The host (KanbanView)
  // listens for this and runs the bulk endpoint for the column.
  requestRunAllAgents: [columnId: string]
  // The "⋮" menu's "Stop all agents" option — the mirror of
  // `requestRunAllAgents`. The host listens for this and runs the bulk
  // stop endpoint for the column.
  requestStopAllAgents: [columnId: string]
  // Fired when the user picks a sort mode in the column's "Sort tasks…" modal. The host
  // (KanbanView) listens for this and: 1. fires `fetchKanbanTasks` for ONLY the changed column with
  // that column's sortBy/direction (per-column backend sort.
  sortChange: [
    { sortBy: 'position' | 'created_at' | 'updated_at' | 'name'; direction: 'asc' | 'desc' },
  ]
  // Column drag-and-drop reorder. Emitted when a column's header is dragged onto another column's
  // header (the dropped-on column becomes the new "slot" for the dragged column; the host's store
  // action resolves the target position and calls the API).
  reorderColumn: [{ columnId: string; targetColumnId: string }]
  // Pass-through from KanbanCard (which re-emits from WorkspaceItemTask).
  selectTask: [taskId: string]
  openTaskInBackground: [payload: { workspaceId: string; itemId: string; taskId: string }]
  openTaskDetailInBackground: [payload: { workspaceId: string; itemId: string; taskId: string }]
  deleteTask: [workspaceId: string, itemId: string, taskId: string]
  renameTask: [workspaceId: string, itemId: string, taskId: string, currentName: string]
  pinTask: [workspaceId: string, itemId: string, taskId: string, isPinned: boolean]
  // Open the per-task detail dialog (kanban-task-detail-dialog
  // feature). Re-emitted verbatim from <KanbanCard>.
  viewTaskDetail: [taskId: string]
  // Context-menu "Move to column" requested by one of this column's cards. This component resolves
  // the append position and re-emits it as the EXISTING `moveTask` shape, so <KanbanView> and
  // AppLayout — which already handle drag-and-drop moves — need no change at all.
  moveTaskToColumn: [payload: { taskId: string; columnId: string }]
  // Context-menu "Run agent" requested by one of this column's cards.
  // Pure pass-through: unlike a move there is no position to resolve,
  // so the column adds nothing and <KanbanView> makes the API call.
  runAgent: [payload: { taskId: string }]
}>()

// ─── Per-column sort state (kanban-sort-by, plan Task 3) ──────────────── Each KanbanColumn owns
// its own sortBy + direction refs (LOCAL — not in the store, not in the URL, not lifted to
// KanbanView). Two columns can have different sorts simultaneously.
type SortField = 'position' | 'created_at' | 'updated_at' | 'name'
type SortDirection = 'asc' | 'desc'
const sortBy = ref<SortField>('position')
const direction = ref<SortDirection>('asc')

// setSortMode is the test + URL-restore seam. Mutates the refs WITHOUT emitting — the caller is
// responsible for emitting (or for the URL restore path, the onMount loop below also fires the
// fetchKanbanTasks after calling setSortMode, so we don't need a duplicate emit here).
const setSortMode = (newSortBy: SortField, newDirection: SortDirection) => {
  sortBy.value = newSortBy
  direction.value = newDirection
}

defineExpose({ setSortMode })

// ─── Derived data ────────────────────────────────────────────────────────── Cards in this column.
// Plan: docs/superpowers/plans/2026-08-06-kanban-sort-independence.md
const cardsInColumn = computed<Task[]>(() => {
  return props.tasks.filter((t) => t.kanban_column_id === props.column.id).slice()
})

// ─── Virtual scrolling + lazy load (kanban-virtual-scroll, 2026-08-06) ─── The cards list is
// rendered through <VirtualScroller>, which mounts only the rows currently in the viewport (plus a
// buffer above and below). Plan: docs/superpowers/plans/2026-08-06-kanban-virtual-scroll.md
const workspacesStore = useWorkspacesStore()

// Resolve the parent WorkspaceItem once. Used to read `hasMore` / `isLoading` for both the
// auto-trigger (from VirtualScroller) and the manual button. Returns null when the store doesn't
// have this item yet (defensive during SSE races / item navigation).
const parentItem = computed(() => {
  if (!props.workspaceId || !props.itemId) return null
  return (
    workspacesStore.workspaces
      .find((ws) => ws.id === props.workspaceId)
      ?.items.find((i) => i.id === props.itemId) ?? null
  )
})

// Per-column pagination state.
const moreTasksAvailable = computed(
  () => parentItem.value?.columnPagination?.[props.column.id]?.hasMore ?? false,
)
const loadingMoreTasks = computed(
  () => parentItem.value?.columnPagination?.[props.column.id]?.isLoading ?? false,
)

// True while this column's FIRST page is in flight. Without it the column renders its "No tasks
// yet" empty state during the fetch — a false statement about the user's data, since the column may
// well have tasks. The skeleton below gates on this instead.
const isFirstPageLoading = computed(() =>
  workspacesStore.isFirstPageLoading(props.itemId, props.column.id),
)

// Drives the manual "Load more" button visibility. When the scroller IS scrollable, the
// auto-trigger handles loading and the button would be redundant.
const scrollerIsScrollable = ref(false)
const handleScrollabilityChange = (scrollable: boolean) => {
  scrollerIsScrollable.value = scrollable
  maybeAutoFetchNextPage()
}

// @load-more from VirtualScroller. Fire `loadMoreTasksForColumn`. The store's `isLoading` guard
// (workspaces.ts) makes this a no-op when a fetch is already in flight, so the scroller's internal
// debounce + this guard are stacked safely.
const handleScrollerLoadMore = () => {
  if (!moreTasksAvailable.value) return
  if (loadingMoreTasks.value) return
  void workspacesStore.loadMoreTasksForColumn(props.workspaceId, props.itemId, props.column.id)
}

// Manual fallback (button click). Same code path as the scroller's
// `@load-more` — both routes go through `loadMoreTasksForColumn`,
// which is idempotent under the store's `isLoading` guard.
const handleManualLoadMore = () => {
  void workspacesStore.loadMoreTasksForColumn(props.workspaceId, props.itemId, props.column.id)
}

// ─── Auto-fetch when the viewport fits the page (kanban-virtual-scroll) ─── VirtualScroller's
// `@load-more` ONLY fires when the user is near the bottom of a scrollable container.
const PAGE_SIZE = 10
const hasAutoFetched = ref(false)
const maybeAutoFetchNextPage = () => {
  // Nothing to fetch → release the guard so the next "has more" state
  // can re-trigger.
  if (!moreTasksAvailable.value) {
    hasAutoFetched.value = false
    return
  }
  // Already a fetch in flight → wait for it.
  if (loadingMoreTasks.value) return
  // Not the "viewport fits the page" case → let VirtualScroller
  // handle it (the scroll-driven @load-more).
  if (cardsInColumn.value.length >= PAGE_SIZE) return
  // Container is scrollable → VirtualScroller will handle it.
  if (scrollerIsScrollable.value) return
  // Already auto-fetched for this DOM state → wait for the new
  // page's mount to re-arm. The update guard re-fires when the next
  // page's cards arrive (cardsInColumn.length changes).
  if (hasAutoFetched.value) return
  hasAutoFetched.value = true
  void workspacesStore.loadMoreTasksForColumn(props.workspaceId, props.itemId, props.column.id)
}
// One explicit path instead of four watchers: mount covers the initial state, and a prev-combo
// guard on update covers all four inputs (new page arrivals change the card count; pagination flags
// and the scrollability flag arrive via the handler above).
const prevAutoFetchKey = ref('')
const autoFetchKey = () =>
  `${cardsInColumn.value.length}|${moreTasksAvailable.value ? '1' : '0'}|${loadingMoreTasks.value ? '1' : '0'}|${scrollerIsScrollable.value ? '1' : '0'}`
onMounted(() => {
  prevAutoFetchKey.value = autoFetchKey()
  maybeAutoFetchNextPage()
})
onUpdated(() => {
  const key = autoFetchKey()
  if (key !== prevAutoFetchKey.value) {
    prevAutoFetchKey.value = key
    maybeAutoFetchNextPage()
  }
})

// ─── Inline rename state ───────────────────────────────────────────────────
const isRenaming = ref(false)
const renameValue = ref('')
const renameInput = ref<HTMLInputElement | null>(null)

const startInlineRename = async () => {
  renameValue.value = props.column.name
  isRenaming.value = true
  await nextTick()
  renameInput.value?.focus()
  renameInput.value?.select()
}

const cancelInlineRename = () => {
  isRenaming.value = false
  renameValue.value = ''
}

const commitInlineRename = () => {
  const trimmed = renameValue.value.trim()
  isRenaming.value = false
  if (!trimmed || trimmed === props.column.name) {
    // No-op: empty or unchanged.
    renameValue.value = ''
    return
  }
  emit('renameColumn', { columnId: props.column.id, name: trimmed })
  renameValue.value = ''
}

// ─── Per-column vertical scroll persistence ──────────────────────────────── The card list lives
// in a <VirtualScroller> with its own overflow-y-auto container.
const virtualScrollerRef = ref<ColumnScrollerExposed | null>(null)
const scrollerContainerRef = computed<HTMLElement | null>(
  () => virtualScrollerRef.value?.containerRef ?? null,
)
const columnScrollStorageKey = computed(
  () => `kanban-col-scroll-${props.itemId}:${props.column.id}`,
)
useKanbanColumnScrollRestore(scrollerContainerRef, columnScrollStorageKey)

// ─── "⋮" menu state ────────────────────────────────────────────────────────
const menuOpen = ref(false)
const menuRef = ref<HTMLElement | null>(null)

const toggleMenu = () => {
  menuOpen.value = !menuOpen.value
}

const closeMenu = () => {
  menuOpen.value = false
}

// The header "⋮" menu offers Rename + Delete. Both delegate to the host (KanbanView /
// WorkspaceItem), which opens KanbanColumnEditor in the right mode. Sort tasks… opens the
// per-column sort modal mounted in this component.
const handleMenuRename = () => {
  menuOpen.value = false
  emit('requestRenameColumn', props.column.id)
}

// NEW (kanban-sort-by, per-column). Clicking "Sort tasks…" in the
// column's ⋮ menu opens a centered modal that hosts the
// <KanbanSortMenu> component in showTrigger=false mode.
const handleMenuSort = () => {
  menuOpen.value = false
  openSortModal()
}

const handleMenuDelete = () => {
  menuOpen.value = false
  emit('requestDeleteColumn', props.column.id)
}

// NEW (plan: 2026-09-09-run-all-agents-by-column, Task 3, Option C). The column "⋮" menu's "Run all
// agents" option. Closes the menu and emits the column id; the host (KanbanView) owns the confirm
// gate + bulk POST. No-op while `runAllBusy` (the button is also disabled).
const handleMenuRunAll = () => {
  if (props.runAllBusy) return
  menuOpen.value = false
  emit('requestRunAllAgents', props.column.id)
}

// The column "⋮" menu's "Stop all agents" option — the mirror of
// `handleMenuRunAll`. Closes the menu and emits the column id; the host
// owns the confirm gate + bulk stop POST. No-op while `stopAllBusy`.
const handleMenuStopAll = () => {
  if (props.stopAllBusy) return
  menuOpen.value = false
  emit('requestStopAllAgents', props.column.id)
}

// ─── Per-column sort modal (kanban-sort-by, plan Task 4) ───────────── Mounted inside the column's
// <section> (not Teleport'd). The modal uses position: fixed + inset-0, so it visually centres
// regardless of where it sits in the DOM.
const sortModalOpen = ref(false)
const sortModalKey = ref(0)

const openSortModal = () => {
  sortModalKey.value++
  sortModalOpen.value = true
}

// Close the modal AND emit the sort change unconditionally — even if the user picked the SAME sort
// (Manual again, etc.), the parent's per-column fetch should still fire so the wire data is
// refreshed. Plan: docs/superpowers/plans/2026-08-06-kanban-sort-independence.md
const handleSortModalSelect = () => {
  sortModalOpen.value = false
  emit('sortChange', { sortBy: sortBy.value, direction: direction.value })
}

const handleSortModalBackdrop = () => {
  sortModalOpen.value = false
}

const handleSortModalKeyDown = (event: KeyboardEvent) => {
  if (event.key === 'Escape' && sortModalOpen.value) {
    event.preventDefault()
    sortModalOpen.value = false
  }
}

// Close the menu when clicking outside. Mirror the pattern in
// ProjectsList.vue's `handleClickOutside`.
const handleDocumentClick = (event: MouseEvent) => {
  if (!menuOpen.value) return
  const target = event.target as Node | null
  if (menuRef.value && target && !menuRef.value.contains(target)) {
    closeMenu()
  }
}

onMounted(() => {
  document.addEventListener('click', handleDocumentClick)
  document.addEventListener('keydown', handleSortModalKeyDown)
})
onUnmounted(() => {
  document.removeEventListener('click', handleDocumentClick)
  document.removeEventListener('keydown', handleSortModalKeyDown)
})

// ─── Drag-and-drop state (drop zone) ─────────────────────────────────────── Same pattern as
// WorkspaceItemTask's pinned-region drop handler: track which card the cursor is over (so we can
// compute the drop position) and update visual feedback in real-time.
const isDragOver = ref(false)
const isDragging = ref(false)

const handleDragOver = (event: DragEvent) => {
  // preventDefault is REQUIRED for HTML5 DnD — without it the browser cancels the drop with a "not
  // allowed" cursor.
  if (!event.dataTransfer) return
  if (!event.dataTransfer.types.includes('application/x-kanban-task-id')) {
    return
  }
  event.preventDefault()
  if (event.dataTransfer) event.dataTransfer.dropEffect = 'move'
  isDragOver.value = true
}

const handleDragLeave = (event: DragEvent) => {
  // Only clear when the cursor LEAVES the drop zone entirely (not
  // when crossing between cards inside the zone). `currentTarget` is
  // the zone; if `relatedTarget` is still inside, do nothing.
  const zone = event.currentTarget as HTMLElement | null
  const next = event.relatedTarget as Node | null
  if (zone && next && zone.contains(next)) return
  isDragOver.value = false
}

const handleDrop = (event: DragEvent) => {
  event.preventDefault()
  isDragOver.value = false
  const dataTransfer = event.dataTransfer
  if (!dataTransfer) return
  const taskId = dataTransfer.getData('application/x-kanban-task-id')
  if (!taskId) return
  // v1: append to the end of the receiving column. The position is
  // the current card count — the backend re-numbers siblings after
  // the insert, so "append" maps to "position = current length".
  const position = cardsInColumn.value.length
  emit('moveTask', {
    taskId,
    columnId: props.column.id,
    position,
  })
}

// ─── Context-menu "Move to column" ──────────────────────────────────── The card's context menu
// emits the DESTINATION column only — it cannot see the rest of the board, so it cannot know the
// append position.
const handleMoveToColumn = (payload: { taskId: string; columnId: string }) => {
  // No-op when the target is the card's current column — the POST would
  // renumber siblings for no visible change.
  if (payload.columnId === props.column.id) return
  const task = props.tasks.find((t) => t.id === payload.taskId)
  if (task && task.kanban_column_id === payload.columnId) return
  const position = props.tasks.filter((t) => t.kanban_column_id === payload.columnId).length
  emit('moveTask', {
    taskId: payload.taskId,
    columnId: payload.columnId,
    position,
  })
}

// Mirror KanbanCard's dragstart so the source card can dim while
// dragging (visual cue). We listen on the cards container with
// event delegation, the same pattern as ProjectsList's item DnD.
const handleDragStartCapture = () => {
  isDragging.value = true
}
const handleDragEndCapture = () => {
  isDragging.value = false
  isDragOver.value = false
}

// ─── Drag-and-drop state (column reorder) ────────────────────────────────── Column header
// drag-and-drop (separate from the per-card DnD above).
const isColumnDragOver = ref(false)

const handleColumnDragStart = (event: DragEvent) => {
  // Set the column-specific MIME. Effect is set to 'move' so the
  // cursor shows the move arrow (matches the per-card DnD).
  if (!event.dataTransfer) return
  event.dataTransfer.effectAllowed = 'move'
  event.dataTransfer.setData('application/x-kanban-column-id', props.column.id)
}

const handleColumnDragOver = (event: DragEvent) => {
  // Only accept column drags; ignore card drags (those target the
  // cards container, not the header).
  if (!event.dataTransfer) return
  if (!event.dataTransfer.types.includes('application/x-kanban-column-id')) {
    return
  }
  event.preventDefault()
  if (event.dataTransfer) event.dataTransfer.dropEffect = 'move'
  isColumnDragOver.value = true
}

const handleColumnDragLeave = (event: DragEvent) => {
  // Only clear when the cursor leaves the header entirely (not when
  // crossing between the header's children). Same pattern as
  // handleDragLeave for the cards drop zone.
  const header = event.currentTarget as HTMLElement | null
  const next = event.relatedTarget as Node | null
  if (header && next && header.contains(next)) return
  isColumnDragOver.value = false
}

const handleColumnDrop = (event: DragEvent) => {
  event.preventDefault()
  isColumnDragOver.value = false
  const dataTransfer = event.dataTransfer
  if (!dataTransfer) return
  const draggedColumnId = dataTransfer.getData('application/x-kanban-column-id')
  if (!draggedColumnId) return
  // No-op if the user dropped a column onto itself — emitting
  // reorder would be a wasted API call (and the backend would
  // still renumber, but to the same positions).
  if (draggedColumnId === props.column.id) return
  emit('reorderColumn', {
    columnId: draggedColumnId,
    targetColumnId: props.column.id,
  })
}

// ─── Footer add ──────────────────────────────────────────────────────────── REMOVED (plan:
// 2026-08-06-kanban-add-task-button-placement). The single global + Add task button in the kanban
// header (KanbanView.vue) replaces per-column footer add buttons.
</script>

<template>
  <section
    class="kanban-column flex flex-col rounded-lg shrink-0"
    :data-column-id="column.id"
    :data-kanban-column="column.id"
    style="
      width: 280px;
      background-color: var(--semantic-sidebar-bg);
      border: 1px solid var(--color-border);
    "
  >
    <!-- ─── Header ───────────────────────────────────────────────────── -->
    <!-- The header is DRAGGABLE: drag it onto another column's
         header to reorder columns. dragover.preventDefault is
         required for HTML5 DnD to mark this as a valid drop
         target; drop reads `application/x-kanban-column-id` and
         emits `reorderColumn`. The visual feedback is a violet
         outline when another column is being dragged over. -->
    <header
      class="px-3 py-2 flex items-center gap-2 shrink-0"
      :style="
        isColumnDragOver
          ? 'border-bottom: 1px solid var(--color-border); outline: 2px solid var(--color-violet); outline-offset: -2px;'
          : 'border-bottom: 1px solid var(--color-border);'
      "
      :data-testid="`kanban-column-${column.id}-header`"
      draggable="true"
      @dragstart="handleColumnDragStart"
      @dragover="handleColumnDragOver"
      @dragleave="handleColumnDragLeave"
      @drop="handleColumnDrop"
    >
      <!-- Inline-rename input (visible while isRenaming) OR plain name (otherwise) -->
      <input
        v-if="isRenaming"
        ref="renameInput"
        v-model="renameValue"
        type="text"
        :data-testid="`kanban-column-${column.id}-rename-input`"
        class="flex-1 px-2 py-0.5 rounded text-body outline-none"
        style="
          background-color: var(--semantic-card-bg);
          border: 1px solid var(--color-border);
          color: var(--semantic-text);
        "
        @keyup.enter="commitInlineRename"
        @keyup.escape="cancelInlineRename"
        @blur="commitInlineRename"
      />
      <button
        v-else
        type="button"
        class="flex-1 text-left text-body font-medium truncate hover:opacity-80"
        style="color: var(--semantic-text)"
        :data-testid="`kanban-column-${column.id}-name`"
        @click="startInlineRename"
      >
        {{ column.name }}
      </button>
      <!-- Count badge -->
      <span
        class="text-dense px-1.5 py-0.5 rounded-full shrink-0"
        style="background-color: var(--color-bg-p1); color: var(--semantic-text-dim)"
        :data-testid="`kanban-column-${column.id}-count`"
      >
        {{ cardsInColumn.length }}
      </span>
      <!-- "⋮" menu trigger + dropdown -->
      <div ref="menuRef" class="relative shrink-0">
        <button
          type="button"
          class="w-6 h-6 flex items-center justify-center rounded hover:opacity-80"
          style="color: var(--semantic-text-dim)"
          :data-testid="`kanban-column-${column.id}-menu-trigger`"
          @click.stop="toggleMenu"
        >
          <span class="text-lead leading-none">⋮</span>
        </button>
        <ul
          v-if="menuOpen"
          class="absolute right-0 top-full mt-1 py-1 rounded-md shadow-lg z-10 min-w-[120px]"
          style="background-color: var(--semantic-card-bg); border: 1px solid var(--color-border)"
          :data-testid="`kanban-column-${column.id}-menu`"
        >
          <li>
            <button
              type="button"
              class="w-full px-3 py-2 text-left text-body hover:opacity-80"
              style="color: var(--semantic-text)"
              :data-testid="`kanban-column-${column.id}-menu-rename`"
              @click="handleMenuRename"
            >
              Rename
            </button>
          </li>
          <li>
            <!--
              NEW (kanban-sort-by, per-column). Opens the per-column
              sort modal (mounted below the menu). Sorted state lives
              in this column — each column can have an independent
              sort (column A → Name (A→Z), column B → Manual).
            -->
            <button
              type="button"
              class="w-full px-3 py-2 text-left text-body hover:opacity-80"
              style="color: var(--semantic-text)"
              :data-testid="`kanban-column-${column.id}-menu-sort`"
              @click="handleMenuSort"
            >
              Sort tasks…
            </button>
          </li>
          <li>
            <button
              type="button"
              class="w-full px-3 py-2 text-left text-body hover:opacity-80"
              style="color: #ef4444"
              :data-testid="`kanban-column-${column.id}-menu-delete`"
              @click="handleMenuDelete"
            >
              Delete
            </button>
          </li>
          <li>
            <!--
              NEW (plan: 2026-09-09-run-all-agents-by-column, Task 3,
              Option C). Bulk "Run all agents" — starts agents on every
              idle task in this column via the server-side bulk
              endpoint (pagination-irrelevant). Disabled while the
              host's per-column bulk run is in flight.
            -->
            <button
              type="button"
              class="w-full px-3 py-2 text-left text-body hover:opacity-80 disabled:opacity-50 disabled:cursor-not-allowed"
              style="color: var(--semantic-text)"
              :data-testid="`kanban-column-${column.id}-menu-run-all`"
              :disabled="runAllBusy"
              @click="handleMenuRunAll"
            >
              {{ runAllBusy ? 'Running all agents…' : 'Run all agents' }}
            </button>
          </li>
          <li>
            <!--
              Bulk "Stop all agents" — the mirror of "Run all agents" above.
              Cancels every running agent in this column via the server-side
              bulk stop endpoint (pagination-irrelevant). Disabled while the
              host's per-column bulk stop is in flight.
            -->
            <button
              type="button"
              class="w-full px-3 py-2 text-left text-body hover:opacity-80 disabled:opacity-50 disabled:cursor-not-allowed"
              style="color: var(--semantic-text)"
              :data-testid="`kanban-column-${column.id}-menu-stop-all`"
              :disabled="stopAllBusy"
              @click="handleMenuStopAll"
            >
              {{ stopAllBusy ? 'Stopping all agents…' : 'Stop all agents' }}
            </button>
          </li>
        </ul>
      </div>
    </header>

    <!-- Description subtitle (Chunk 2 of kanban-column-description-settings).
         Sits between the header row (name + count + menu) and the
         cards drop zone so it reads as a sub-header line. Hidden
         when description is empty/null/undefined — all three falsy
         in v-if, which matches the backend's "empty string = no
         description" sentinel plus legacy KanbanColumn literals. -->
    <p
      v-if="column.description"
      class="text-meta px-3 pt-0.5 pb-1.5 truncate"
      style="color: var(--semantic-text-dim)"
      :title="column.description"
      :data-testid="`kanban-column-${column.id}-description`"
    >
      {{ column.description }}
    </p>

    <!-- ─── Cards (drop zone + virtual scroller) ────────────────────── -->
    <!-- The wrapper <div> is the drop zone (receives dragover/drop for
         card moves between columns) AND the flex parent for the
         VirtualScroller below. VirtualScroller owns its own
         scrollable container internally — we don't put
         `overflow-y-auto` here. The DnD handlers stay on this
         wrapper so the browser fires dragenter/dragleave correctly
         even when the cursor crosses between virtualized rows.

         `p-2` restores the inner padding that used to live on the
         cards container before the VirtualScroller migration — it
         gives the first/last card breathing room from the column
         edges. The card-to-card gap is applied inside the scroller
         slot via `pb-1` on each row's wrapper (see below). -->
    <div
      class="flex-1 min-h-0 flex flex-col p-2"
      :style="
        isDragOver
          ? 'background-color: var(--semantic-active-bg); outline: 2px dashed var(--color-violet); outline-offset: -4px;'
          : ''
      "
      :data-kanban-drop-zone="column.id"
      :data-testid="`kanban-column-${column.id}-cards`"
      @dragover="handleDragOver"
      @dragleave="handleDragLeave"
      @drop="handleDrop"
      @dragstart.capture="handleDragStartCapture"
      @dragend.capture="handleDragEndCapture"
    >
      <!--
        VirtualScroller mounts only the cards currently in the viewport
        (plus buffer above/below — default 5 each side). For a column
        with 100+ tasks, the DOM stays at ~10-14 cards regardless of
        total. The slot uses `:key="item.id"` (NOT the index — the
        index changes as the user scrolls, which would unmount and
        re-mount each card and lose focus/scroll state).

        Each card is wrapped in a `<div class="pb-1">` so the gap
        between cards is uniform (matches the pre-migration
        `space-y-1` behaviour). The `pb-1` adds 4 px to each row's
        measured height — the `defaultItemHeight` below includes this
        buffer (100 px = ~96 card + 4 gap) so the scroller's
        initial render lines up with reality before the first
        measurement cycle (~150 ms).
      -->
      <VirtualScroller
        v-if="cardsInColumn.length > 0"
        ref="virtualScrollerRef"
        :items="cardsInColumn"
        :default-item-height="100"
        :buffer="5"
        :load-more-threshold="200"
        :load-more-threshold-ratio="0.5"
        @load-more="handleScrollerLoadMore"
        @scrollability-change="handleScrollabilityChange"
      >
        <template #default="{ item: task }">
          <div :key="task.id" class="pb-1">
            <KanbanCard
              :task="task"
              :workspace-id="workspaceId"
              :item-id="itemId"
              :cwd="cwd"
              :columns="columns"
              :current-column-id="column.id"
              :style="isDragging ? 'opacity: 0.4;' : ''"
              @select-task="(id) => emit('selectTask', id)"
              @open-task-in-background="(payload) => emit('openTaskInBackground', payload)"
              @open-task-detail-in-background="
                (payload) => emit('openTaskDetailInBackground', payload)
              "
              @delete-task="(ws, item, id) => emit('deleteTask', ws, item, id)"
              @rename-task="(ws, item, id, name) => emit('renameTask', ws, item, id, name)"
              @pin-task="(ws, item, id, pinned) => emit('pinTask', ws, item, id, pinned)"
              @view-task-detail="(id) => emit('viewTaskDetail', id)"
              @move-task-to-column="handleMoveToColumn"
              @run-agent="(payload) => emit('runAgent', payload)"
            />
          </div>
        </template>
      </VirtualScroller>
      <!--
        First-page skeleton — shown while this column's page-1 fetch is
        in flight. Mirrors the card's shape (full-width bar at the
        scroller's `defaultItemHeight` of 100px, same `pb-1` gap) so the
        column holds its height instead of collapsing to the "No tasks
        yet" line and snapping open when the page lands.

        Gated on the store's `isFirstPageLoading` rather than the
        absence of `columnPagination[colId]` — that absence is the
        sentinel KanbanView's mount path uses to decide which columns
        still need fetching, so it cannot double as a loading flag.
      -->
      <div
        v-if="isFirstPageLoading"
        class="space-y-1"
        :data-testid="`kanban-column-${column.id}-skeleton`"
        role="status"
        aria-label="Loading tasks"
      >
        <div v-for="n in 3" :key="n" class="pb-1">
          <div
            class="h-[100px] rounded-lg animate-pulse"
            style="background-color: var(--semantic-active-bg)"
          />
        </div>
      </div>
      <!-- Empty placeholder — shown only when there are no cards. Gives
           the drop zone a clear "drop here" affordance. Suppressed while
           the first page is in flight so the skeleton is not immediately
           replaced by a false "No tasks yet". -->
      <div
        v-else-if="cardsInColumn.length === 0"
        class="text-dense text-center py-6"
        style="color: var(--semantic-text-dim)"
        :data-testid="`kanban-column-${column.id}-empty`"
      >
        No tasks yet
      </div>
      <!-- Manual "Load more" fallback — visible when the backend says
           more tasks exist AND this column has at least one task loaded
           AND the VirtualScroller is NOT scrollable (the auto-trigger
           can never fire for non-scrollable content). Catches keyboard-
           only users and short columns. The button is hidden when the
           scroller IS scrollable because the scroll-driven auto-trigger
           handles loading there. -->
      <button
        v-if="moreTasksAvailable && cardsInColumn.length > 0 && !scrollerIsScrollable"
        type="button"
        :disabled="loadingMoreTasks"
        @click="handleManualLoadMore"
        class="w-full flex items-center justify-center gap-1.5 px-3 py-1.5 rounded text-dense transition-all duration-200 disabled:opacity-50 disabled:cursor-not-allowed hover:opacity-80"
        style="color: var(--semantic-text-dim)"
        :data-testid="`kanban-column-${column.id}-load-more`"
      >
        <span v-if="loadingMoreTasks" class="w-3 h-3">
          <div
            class="w-3 h-3 border-2 rounded-full animate-spin"
            style="border-color: var(--color-aqua); border-top-color: transparent"
          ></div>
        </span>
        <span>{{ loadingMoreTasks ? 'Loading…' : 'Load more' }}</span>
      </button>
    </div>

    <!--
      Per-column sort modal (kanban-sort-by, plan Task 4). Opens
      when the user clicks "Sort tasks…" in the column's ⋮ menu.
      Centered on the viewport (position: fixed + inset-0). The
      backdrop click + Esc close it. Inside, <KanbanSortMenu
      :show-trigger="false"> renders just the menu items — the
      showTrigger=false mode (Task 2) skips the trigger button +
      click-outside / Esc handlers, leaving the modal wrapper as
      the sole owner of those behaviours.
    -->
    <div
      v-if="sortModalOpen"
      class="fixed inset-0 z-50 flex items-center justify-center"
      style="background-color: rgba(0, 0, 0, 0.5)"
      :data-testid="`kanban-column-${column.id}-sort-modal`"
      :key="`sort-modal-${column.id}-${sortModalKey}`"
      @click.self="handleSortModalBackdrop"
    >
      <div
        class="rounded-lg shadow-2xl p-2 min-w-[240px] max-w-[90vw]"
        style="background-color: var(--semantic-card-bg); border: 1px solid var(--color-border)"
      >
        <KanbanSortMenu
          v-model:sort-by="sortBy"
          v-model:direction="direction"
          :show-trigger="false"
          @click="handleSortModalSelect"
        />
      </div>
    </div>
  </section>
</template>

<style scoped>
/* Column hover affordance — make the ⋮ menu visible without hover
   on the column itself (the menu trigger is always visible, but
   the column gets a subtle border highlight when hovered to hint
   "interactive".) */
.kanban-column {
  transition: border-color 0.15s ease;
}

.kanban-column:hover {
  border-color: var(--color-violet) !important;
}
</style>
