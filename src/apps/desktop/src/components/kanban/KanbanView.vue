<!--
  KanbanView — the board layout for a kanban workspace item.

  Layout (top → bottom):
    1. Header — kanban name (item.name) + "+ Column" button.
                "+ Column" emits `add-column` (the parent opens
                KanbanColumnEditor in 'add' mode).
    2. Columns row — horizontally-scrollable container of
                <KanbanColumn>, one per item.kanban_columns (sorted
                by position). Each column receives the full tasks
                array and filters internally by kanban_column_id.

  The view is purely presentational — all the heavy lifting (CRUD
  on columns and tasks) lives in the host (WorkspaceItem.vue →
  Sidebar.vue → workspacesStore). The board just emits events
  upward; the host decides what to do (open the editor, call a
  store action, navigate, etc.).

  Public API:
    props:
      item          WorkspaceItem
      workspaceId   string  (default '' — host should pass the real id)
      itemId        string  (default item.id — kept separate so the
                              host can override if needed)
    emits:
      add-column    []
      move-task     [{ taskId, columnId, position }]
      rename-column [{ columnId, name }]
      delete-column [columnId]
      reorder-column [{ columnId, targetColumnId }]
      // Pass-through from KanbanColumn:
      select-task, delete-task, rename-task,
      pin-task
      request-rename-column, request-delete-column (host opens
      KanbanColumnEditor on these)
      view-task-detail (consumed internally — see comment below)
      rename-item (kanban header pencil; forwarded to AppLayout)

  Live updates:
    The component reacts to backend SSE events on `/api/kanban/events`
    through the workspacesStore. Two event families drive auto-refresh:
      - kanban_column.* (created / updated / deleted / reordered)
        → workspacesStore.fetchKanbanColumns refreshes
          item.kanban_columns. The columns row re-renders.
      - kanban_task.* (assigned / moved / unassigned)
        → workspacesStore.fetchKanbanTasks refreshes item.tasks.
          The cards re-filter by kanban_column_id and re-sort by
          kanban_position, so the affected card visibly moves
          between columns without a manual reload.

    Both refresh paths are owned by useKanbanSseStore (one global
    connection, AppLayout-managed). KanbanView.vue does NOT open
    its own SSE connection — the store-level subscription covers
    the lifetime of the AppLayout (one connection, even if the
    user navigates between kanbans).
-->
<script setup lang="ts">
import { computed, onMounted, provide, ref } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import KanbanBoardBody from './KanbanBoardBody.vue'
import KanbanBoardHeader from './KanbanBoardHeader.vue'
import KanbanBoardOverlays from './KanbanBoardOverlays.vue'
import { KANBAN_BOARD_KEY, type KanbanBoardContext } from './kanbanBoardContext'
import { buildBoardAppUrl } from './kanbanBoardUrl'
import { loadBoardData } from './kanbanBoardLoad'
import type { KanbanViewEmits, KanbanViewProps } from './kanbanViewTypes'
import type { Task } from '../../stores/workspaces'
import {
  COLLAPSED_STORAGE_PREFIX,
  DENSITY_STORAGE_KEY,
  LAYOUT_PARAM,
  LAYOUT_STORAGE_KEY,
  type KanbanBoardDeps,
  type KanbanLayout,
} from './kanbanViewTypes'
import { useKanbanBoardView } from './useKanbanBoardView'
import { useKanbanPanels } from './useKanbanPanels'
import { useKanbanPrs } from './useKanbanPrs'
import { useKanbanScrollRestore } from '../../composables/useKanbanScrollRestore'
import { useWorkspacesStore } from '../../stores/workspaces'
import { useNotificationStore } from '../../stores/notifications'
import { updateSession as apiUpdateSession } from '../../api'
import { updateTaskSimple } from '../../api'
import { columnBulkSummary, startAgentFailure } from './kanbanAgentOutcome'
import { fileToBase64, submitKanbanTask, type CreateTaskPayload } from './kanbanCreateTask'
import type { KanbanRowDensity } from './KanbanTaskRow.vue'

const props = withDefaults(defineProps<KanbanViewProps>(), {
  workspaceId: '',
  itemId: '',
})

const workspacesStore = useWorkspacesStore()
const router = useRouter()
const route = useRoute()

// Lazy-load the kanban's columns on mount + whenever the item id changes (e.g. user navigates from
// one kanban to another without unmounting the component).
const effectiveItemId = computed(() => props.itemId || props.item.id)

const emit = defineEmits<KanbanViewEmits>()

const kanbanColumnsContainer = ref<HTMLElement | null>(null)
const kanbanScrollStorageKey = computed(() => `kanban-scroll-${effectiveItemId.value}`)
useKanbanScrollRestore(kanbanColumnsContainer, kanbanScrollStorageKey)

// ─── Layout (columns | rows) ────────────────────────────────────────────── Row mode renders the
// same board as a vertical list grouped by column.
const readStoredLayout = (): KanbanLayout | null => {
  try {
    const v = localStorage.getItem(LAYOUT_STORAGE_KEY)
    return v === 'rows' || v === 'columns' ? v : null
  } catch {
    // localStorage may throw in disabled / private-mode.
    return null
  }
}

const writeStoredLayout = (next: KanbanLayout): void => {
  try {
    localStorage.setItem(LAYOUT_STORAGE_KEY, next)
  } catch {
    // Persistence is best-effort; the in-memory state still works.
  }
}

const readLayoutParam = (): KanbanLayout | null => {
  // No try/catch: an absent router leaves `route` undefined, and optional chaining is total on
  // null/undefined, so there is nothing to catch (same reasoning as `readPrsParam`).
  const v = route?.query?.[LAYOUT_PARAM]
  return v === 'rows' || v === 'columns' ? v : null
}

const layout = ref<KanbanLayout>(readLayoutParam() ?? readStoredLayout() ?? 'columns')

// Row-mode scroll position. The columns row scrolls horizontally; the
// row list scrolls vertically, so it needs its own container + key.
const kanbanRowsContainer = ref<HTMLElement | null>(null)
const kanbanRowScrollStorageKey = computed(() => `kanban-row-scroll-${effectiveItemId.value}`)
useKanbanScrollRestore(kanbanRowsContainer, kanbanRowScrollStorageKey, 'y')

// ─── Row-mode density (comfortable | compact) ───────────────────────────── The two-line row (name
// + metadata) is right for most columns but a lot of scrolling for a 100+ row group like `merged`.
// Compact drops the metadata line back to a single scannable line.
const readStoredDensity = (): KanbanRowDensity | null => {
  try {
    const v = localStorage.getItem(DENSITY_STORAGE_KEY)
    return v === 'compact' || v === 'comfortable' ? v : null
  } catch {
    return null
  }
}

const rowDensity = ref<KanbanRowDensity>(readStoredDensity() ?? 'comfortable')

const setRowDensity = (next: KanbanRowDensity) => {
  if (rowDensity.value === next) return
  rowDensity.value = next
  try {
    localStorage.setItem(DENSITY_STORAGE_KEY, next)
  } catch {
    // Persistence is best-effort; the in-memory state still works.
  }
}

// ─── Row-mode group collapse ────────────────────────────────────────────── Per board, persisted
// in localStorage as a JSON array of collapsed column ids. Collapse is a density preference, not a
// view switch, so it deliberately does NOT go in the URL.
const readCollapsedIds = (): string[] => {
  try {
    const raw = localStorage.getItem(`${COLLAPSED_STORAGE_PREFIX}${effectiveItemId.value}`)
    if (!raw) return []
    const parsed: unknown = JSON.parse(raw)
    if (!Array.isArray(parsed)) return []
    return parsed.filter((v): v is string => typeof v === 'string')
  } catch {
    // Malformed JSON or unavailable storage — start expanded.
    return []
  }
}

const collapsedColumnIds = ref<string[]>(readCollapsedIds())

const toggleColumnCollapsed = (columnId: string) => {
  const next = collapsedColumnIds.value.includes(columnId)
    ? collapsedColumnIds.value.filter((id) => id !== columnId)
    : [...collapsedColumnIds.value, columnId]
  collapsedColumnIds.value = next
  try {
    localStorage.setItem(
      `${COLLAPSED_STORAGE_PREFIX}${effectiveItemId.value}`,
      JSON.stringify(next),
    )
  } catch {
    // Persistence is best-effort.
  }
}

const tasks = computed<Task[]>(() => props.item.tasks ?? [])

// ─── Derived data ────────────────────────────────────────────────────────── Columns sorted by
// position ascending (defensive — the backend already returns them in order, but we sort again
// locally so a reorder never produces an out-of-order board even before the API response lands).
const sortedColumns = computed(() => {
  return (props.item.kanban_columns ?? []).slice().sort((a, b) => a.position - b.position)
})

const board: KanbanBoardDeps = {
  props,
  emit,
  store: workspacesStore,
  router,
  route,
  effectiveItemId,
  layout,
  tasks,
  sortedColumns,
}

const view = useKanbanBoardView(board, writeStoredLayout)
const { columnSorts, columnRefs, writeSortsToUrl, setLayout } = view
const prs = useKanbanPrs(board)
const panels = useKanbanPanels(board, prs)
const {
  activeTaskDetailId,
  startAgentError,
  startAgentBusy,
  closeTaskDetail,
  activeCreateColumnId,
  createBusy,
  createError,
  boardQueryWithoutAdd,
  closeCreateLocal,
  pathPickerBusy,
  pathPickerError,
  showPathPicker,
  showTaskDetail,
} = panels

const setColumnsContainerEl = (el: unknown) => {
  kanbanColumnsContainer.value = el as HTMLElement | null
}
const setRowsContainerEl = (el: unknown) => {
  kanbanRowsContainer.value = el as HTMLElement | null
}

// NOTE: KanbanView no longer owns a chat pane. Regression note (2026-08-06): the previous version
// of this function ONLY fetched URL-mentioned columns when the URL had sort entries.
const loadColumnsAndTasks = async () => {
  if (!props.workspaceId || !effectiveItemId.value) return
  const wsId = props.workspaceId
  const itemId = effectiveItemId.value

  // Step 1: parse the URL's sorts (defensive — route/router may
  // be null in tests that don't mock vue-router).
  const routeObj = route ?? null

  await loadBoardData({
    store: workspacesStore,
    wsId,
    itemId,
    route: routeObj ?? undefined,
    urlLayout: readLayoutParam(),
    layout,
    columnSorts,
    columnRefs,
    writeSortsToUrl,
  })
}

// Single onMounted hook (kanban-onmount-single-fetch, task_1785730557641, 2026-08-06). The previous
// code had TWO onMounted hooks: (a) loadColumnsAndTasks — fetches columns + per-column tasks, (b)
// URL restore — parsed sorts, updated columnSorts, called setSortMode.
onMounted(loadColumnsAndTasks)

// NEW (plan: 2026-09-09-run-all-agents-by-column, Tasks 3+4, Option C). Column "Run all agents"
// host handler. Wired to KanbanColumn's `@request-run-all-agents` emit.
const runAllBusyByColumn = ref<Record<string, boolean>>({})
const runAllSummary = ref<string | null>(null)
// In-flight state for the per-column bulk "Stop all agents" action.
// The summary reuses `runAllSummary` (one banner slot; a stop that lands
// after a run overwrites it, which matches the single-action UX).
const stopAllBusyByColumn = ref<Record<string, boolean>>({})
// Dialog save handler — delegates to the store action which runs the optimistic update + API call +
// rollback-on-error. We close the dialog only on success; on error we keep it open so the user can
// retry without re-typing.
const handleTaskDetailSave = async (payload: {
  name: string
  description: string
  tags?: string[]
  depends_on?: string[]
}) => {
  if (!activeTaskDetailId.value) return
  try {
    await workspacesStore.updateTaskDetails(
      props.workspaceId,
      props.itemId || props.item.id,
      activeTaskDetailId.value,
      payload,
    )
    closeTaskDetail()
  } catch (err) {
    console.error('Failed to save task details:', err)
    // Keep the dialog open so the user can retry / fix
  }
}

// NEW (plan: 2026-08-18-kanban-task-detail-start-agent). Edit-mode Start agent click handler. Wired
// to the dialog's @start-agent emit.
const handleStartAgent = async (payload: { taskId: string }) => {
  // Defensive: ignore if the dialog is already closed or the click
  // somehow fires for a different task than the one we have open.
  if (!activeTaskDetailId.value || activeTaskDetailId.value !== payload.taskId) return
  if (startAgentBusy.value) return
  startAgentBusy.value = true
  startAgentError.value = null
  try {
    const result = await workspacesStore.startAgentOnTask(
      props.workspaceId,
      props.itemId || props.item.id,
      payload.taskId,
    )
    startAgentError.value = startAgentFailure(result)
    // Background worker started successfully: close the panel and stay on the kanban — the user can
    // click the task card to open the chat view if they want to watch the agent work.
    if (startAgentError.value === null) closeTaskDetail()
  } catch (err) {
    console.error('Failed to start agent:', err)
    startAgentError.value = err instanceof Error ? err.message : String(err)
  } finally {
    startAgentBusy.value = false
  }
}

const handleRunAllAgents = async (columnId: string) => {
  if (!columnId || runAllBusyByColumn.value[columnId]) return
  const column = (props.item.kanban_columns ?? []).find((c) => c.id === columnId)
  const columnName = column?.name ?? columnId
  if (!confirm(`Run all agents in '${columnName}'?`)) return
  runAllBusyByColumn.value[columnId] = true
  runAllSummary.value = null
  try {
    const result = await workspacesStore.runAllAgentsInColumn(
      props.workspaceId,
      props.itemId || props.item.id,
      columnId,
    )
    runAllSummary.value = columnBulkSummary(result, 'run')
  } catch (err) {
    console.error('Failed to run all agents in column:', err)
    runAllSummary.value = err instanceof Error ? err.message : String(err)
  } finally {
    runAllBusyByColumn.value[columnId] = false
  }
}

// Column "Stop all agents" host handler — the mirror of `handleRunAllAgents` above. Wired to
// KanbanColumn's (and KanbanRowView's) `@request-stop-all-agents` emit.
const handleStopAllAgents = async (columnId: string) => {
  if (!columnId || stopAllBusyByColumn.value[columnId]) return
  const column = (props.item.kanban_columns ?? []).find((c) => c.id === columnId)
  const columnName = column?.name ?? columnId
  if (!confirm(`Stop all agents in '${columnName}'?`)) return
  stopAllBusyByColumn.value[columnId] = true
  runAllSummary.value = null
  try {
    const result = await workspacesStore.stopAllAgentsInColumn(
      props.workspaceId,
      props.itemId || props.item.id,
      columnId,
    )
    runAllSummary.value = columnBulkSummary(result, 'stop')
  } catch (err) {
    console.error('Failed to stop all agents in column:', err)
    runAllSummary.value = err instanceof Error ? err.message : String(err)
  } finally {
    stopAllBusyByColumn.value[columnId] = false
  }
}

// Card / row context-menu "Run agent". Wired to KanbanColumn's (and KanbanRowView's) `@run-agent`
// emit, which the card's right-click menu fires.
const runAgentBusyByTask = ref<Record<string, boolean>>({})

const handleRunAgentFromMenu = async (payload: { taskId: string }) => {
  const taskId = payload?.taskId
  if (!taskId || runAgentBusyByTask.value[taskId]) return
  runAgentBusyByTask.value[taskId] = true
  try {
    const result = await workspacesStore.startAgentOnTask(
      props.workspaceId,
      props.itemId || props.item.id,
      taskId,
    )
    const failure = startAgentFailure(result)
    // Nothing else to do on success — the SSE worker events drive the card's spinner and the elapsed
    // chip from here.
    if (failure !== null) useNotificationStore().notifyError(failure, 'Run agent')
  } catch (err) {
    console.error('Failed to run agent from menu:', err)
    useNotificationStore().notifyError(
      err instanceof Error ? err.message : String(err),
      'Run agent',
    )
  } finally {
    runAgentBusyByTask.value[taskId] = false
  }
}

// Unattended-mode toggle handler (edit mode only). Persists immediately via PUT
// /api/llm/session/<id> — the flag lives on the sessions table (task.id == session.id for routine
// tasks per the project convention), NOT on workspace_item_tasks.
const handleUnattendedToggle = async (payload: { value: '0' | '1'; previous: '0' | '1' }) => {
  const taskId = activeTaskDetailId.value
  if (!taskId) return
  try {
    await apiUpdateSession(taskId, { isAutoRetryUntilStop: payload.value })
  } catch (err) {
    console.error('Failed to toggle unattended mode:', err)
    // On failure, the SSE re-fetch (or the dialog re-open via activeTaskDetailId) will paint the
    // correct server-truth value into the toggle.
  }
}

// NEW (plan: 2026-08-14-kanban-task-detail-edit-cwd). Edit-mode cwd picker handler. Persists
// immediately via PUT /api/workspaces/tasks/<id> with `cwd` — the field already round-trips through
// the backend's `task_update.zig` validated_cwd block (Migration 070).
const handleUpdateCwd = async (payload: { cwd: string }) => {
  const taskId = activeTaskDetailId.value
  if (!taskId) return
  try {
    await updateTaskSimple(taskId, { cwd: payload.cwd })
  } catch (err) {
    console.error('Failed to update task cwd:', err)
  }
}

// Create-task submit handler.
const handleCreateTaskSave = async (payload: CreateTaskPayload) => {
  if (!activeCreateColumnId.value) return
  // NEW (plan: 2026-08-24-kanban-create-run-disable-double-click). Re-entry guard: createBusy is
  // flipped synchronously below, but two clicks in the SAME tick (double-click faster than Vue's
  // re-render) would both pass the dialog's disabled-button check before the prop propagates.
  if (createBusy.value) return
  createBusy.value = true
  createError.value = null
  const wsId = props.workspaceId
  const itId = props.itemId || props.item.id
  const desiredColumnId = activeCreateColumnId.value
  try {
    const pendingFiles = payload.pendingFiles ?? []
    let uploadedImageUrls: string[] = []
    if (pendingFiles.length > 0) {
      try {
        uploadedImageUrls = await Promise.all(pendingFiles.map((entry) => fileToBase64(entry.file)))
      } catch (err) {
        console.error('[handleCreateTaskSave] file-to-base64 conversion failed:', err)
        createError.value = `Image conversion failed: ${
          err instanceof Error ? err.message : String(err)
        }`
        return
      }
    }
    const created = await submitKanbanTask({
      store: workspacesStore,
      wsId,
      itId,
      desiredColumnId,
      payload,
      uploadedImageUrls,
    })
    if (!created) {
      createError.value = 'Failed to create task — please retry.'
      return
    }
    closeCreateLocal()
    void router?.replace(
      buildBoardAppUrl(props.workspaceId, effectiveItemId.value, boardQueryWithoutAdd()),
    )
  } catch (err) {
    console.error('Failed to create kanban task:', err)
    createError.value = err instanceof Error ? err.message : String(err)
  } finally {
    createBusy.value = false
  }
}

const handleProjectRootSelected = async (path: string) => {
  showPathPicker.value = false
  if (!path) return
  pathPickerBusy.value = true
  pathPickerError.value = null
  try {
    await workspacesStore.updateKanbanItemPath(props.workspaceId, props.item.id, path)
  } catch (err) {
    pathPickerError.value = err instanceof Error ? err.message : String(err)
  } finally {
    pathPickerBusy.value = false
  }
}

const boardContext: KanbanBoardContext = {
  ...board,
  ...view,
  ...prs,
  ...panels,
  item: props.item,
  itemId: props.itemId || props.item.id,
  workspaceId: props.workspaceId,
  setLayout,
  showTaskDetail,
  rowDensity,
  setRowDensity,
  collapsedColumnIds,
  toggleColumnCollapsed,
  runAllBusyByColumn,
  stopAllBusyByColumn,
  runAllSummary,
  setColumnsContainerEl,
  setRowsContainerEl,
  handleRunAllAgents,
  handleStopAllAgents,
  handleRunAgentFromMenu,
  handleProjectRootSelected,
  handleTaskDetailSave,
  handleCreateTaskSave,
  handleUnattendedToggle,
  handleUpdateCwd,
  handleStartAgent,
}
provide(KANBAN_BOARD_KEY, boardContext)

</script>

<template>
  <div
    class="kanban-view-wrap relative flex flex-row h-full min-h-0"
    :data-kanban-item-id="item.id"
    data-kanban-host-wrap
  >
    <section
      class="kanban-view flex flex-col flex-1 min-w-0 h-full min-h-0"
      :data-kanban-item-id="item.id"
      :data-kanban-view="item.id"
      data-kanban-host
    >
      <KanbanBoardHeader />
      <KanbanBoardBody />
    </section>
    <KanbanBoardOverlays />
  </div>
</template>

<style scoped>
/* Custom scrollbar styling for the horizontal column row.
   WebKit / Blink browsers (and the pabrik Electron shell). */
.kanban-view :deep(div.overflow-x-auto)::-webkit-scrollbar {
  height: 8px;
}

.kanban-view :deep(div.overflow-x-auto)::-webkit-scrollbar-track {
  background: transparent;
}

.kanban-view :deep(div.overflow-x-auto)::-webkit-scrollbar-thumb {
  background: var(--color-border);
  border-radius: 4px;
}

.kanban-view :deep(div.overflow-x-auto)::-webkit-scrollbar-thumb:hover {
  background: var(--semantic-text-dim);
}
</style>
