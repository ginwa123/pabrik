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
import { computed, nextTick, onMounted, onUnmounted, ref } from 'vue'
import KanbanColumn from './KanbanColumn.vue'
import KanbanRowView from './KanbanRowView.vue'
import type { KanbanRowDensity } from './KanbanTaskRow.vue'
import KanbanSearchInput from './KanbanSearchInput.vue'
import KanbanTaskDetail from './KanbanTaskDetail.vue'
import { buildTaskCreateMessage } from './buildTaskCreateMessage'
import InlineEditableText from '../preview/InlineEditableText.vue'
import { useWorkspacesStore } from '../../stores/workspaces'
import { useNotificationStore } from '../../stores/notifications'
import { useKanbanScrollRestore } from '../../composables/useKanbanScrollRestore'
import { onBeforeRouteUpdate, useRoute, useRouter } from 'vue-router'
import { buildAppUrl } from '../../helpers/appUrl'
import type { PreviewFile } from '../file/FilePreview.vue'
import type { WorkspaceItem, Task, KanbanColumn as KanbanColumnType } from '../../stores/workspaces'

const props = withDefaults(
  defineProps<{
    item: WorkspaceItem
    workspaceId?: string
    itemId?: string
  }>(),
  {
    workspaceId: '',
    itemId: '',
  },
)

const workspacesStore = useWorkspacesStore()
const router = useRouter()
const route = useRoute()

// Lazy-load the kanban's columns on mount + whenever the item id changes (e.g. user navigates from
// one kanban to another without unmounting the component).
const effectiveItemId = computed(() => props.itemId || props.item.id)

// NOTE: KanbanView no longer owns a chat pane. Regression note (2026-08-06): the previous version
// of this function ONLY fetched URL-mentioned columns when the URL had sort entries.
const loadColumnsAndTasks = async () => {
  if (!props.workspaceId || !effectiveItemId.value) return
  const wsId = props.workspaceId
  const itemId = effectiveItemId.value

  // Step 1: parse the URL's sorts (defensive — route/router may
  // be null in tests that don't mock vue-router).
  const routeObj = (() => {
    try {
      return route
    } catch {
      return null
    }
  })()
  const sortsRaw = routeObj ? (routeObj.query?.sorts as string | undefined) : undefined
  const urlEntries = sortsRaw ? parseSortsParam(sortsRaw) : []
  const nonDefaultUrlEntries = urlEntries.filter(
    (e) => !(e.sortBy === 'position' && e.direction === 'asc'),
  )

  // Step 1b: mirror the URL's `?layout=` into the local ref so a deep link wins over the stored
  // preference. The ref is initialised from the URL at setup time, but this re-runs on item
  // navigation, where the query carries over to a different board.
  const urlLayout = readLayoutParam()
  if (urlLayout && urlLayout !== layout.value) layout.value = urlLayout

  // Step 2: mirror URL sorts into columnSorts (drives the watcher's URL write — no-op since the URL
  // already matches, no fetch). Also fires the column's local setSortMode on the next tick so the
  // UI's "active sort" highlight matches.
  if (urlEntries.length > 0) {
    const next: Record<string, SortEntry> = {}
    for (const entry of urlEntries) {
      next[entry.columnId] = entry
    }
    columnSorts.value = next
    // The old columnSorts watcher mirrored this assignment back to the
    // URL; call it explicitly (no-op — the URL already matches).
    writeSortsToUrl()
    void nextTick(() => {
      for (const entry of urlEntries) {
        const col = columnRefs.value[entry.columnId] as
          { setSortMode?: (s: string, d: string) => void } | null | undefined
        if (col && typeof col.setSortMode === 'function') {
          col.setSortMode(entry.sortBy, entry.direction)
        }
      }
    })
  }

  // Step 3: load columns (always — even if the URL has only
  // default entries, we still need the column list to render
  // the board).
  await workspacesStore.fetchKanbanColumns(wsId, itemId)

  // Step 4: figure out the fetch plan.
  const item = workspacesStore.workspaces
    .find((ws) => ws.id === wsId)
    ?.items.find((it) => it.id === itemId)
  if (!item) return
  const cp = item.columnPagination ?? {}
  const needFetch = (item.kanban_columns ?? []).filter((col) => !cp[col.id])

  let fetchPlan: Array<{
    columnId: string
    sortBy?: 'created_at' | 'updated_at' | 'name'
    direction?: 'asc' | 'desc'
  }>

  // Build a set of columns mentioned in the URL (default or non-default). Used by the "fetch other
  // columns with default sort" path to skip columns that already have an explicit URL entry (their
  // fetch carries the URL sort instead).
  const urlEntryColumnIds = new Set(urlEntries.map((e) => e.columnId))

  if (nonDefaultUrlEntries.length > 0) {
    // URL has non-default sort entries (e.g. ?sorts=col_a:name:asc). 1. Fetch the URL-mentioned
    // columns with their URL sort. 2.
    const urlSortFetches = nonDefaultUrlEntries.map((e) => {
      const apiSortBy =
        e.sortBy === 'position' ? undefined : (e.sortBy as 'created_at' | 'updated_at' | 'name')
      return { columnId: e.columnId, sortBy: apiSortBy, direction: e.direction }
    })
    const defaultFetches = needFetch
      .filter((col) => !urlEntryColumnIds.has(col.id))
      .map((col) => ({ columnId: col.id }))
    fetchPlan = [...urlSortFetches, ...defaultFetches]
  } else if (needFetch.length === 0) {
    // No non-default URL entries AND no unpaginated columns → nothing to do. Single endpoint
    // (fetchKanbanColumns) is already fired above; no per-column fetch needed.
    return
  } else {
    // No non-default URL entries AND unpaginated columns exist → fetch all unpaginated columns with
    // default sort. This is the "first-time visit" path (no URL sort history) AND the "URL has only
    // default entries" path (those columns re-fetch with default sort on mount).
    fetchPlan = needFetch.map((col) => ({ columnId: col.id }))
  }

  // Step 5: fire per-column fetches in parallel.
  await Promise.all(
    fetchPlan.map((p) =>
      workspacesStore.fetchKanbanTasks(
        wsId,
        itemId,
        p.columnId,
        10,
        undefined, // cursor — page 1
        undefined, // q — no search filter
        p.sortBy,
        p.direction,
      ),
    ),
  )
}

// Single onMounted hook (kanban-onmount-single-fetch, task_1785730557641, 2026-08-06). The previous
// code had TWO onMounted hooks: (a) loadColumnsAndTasks — fetches columns + per-column tasks, (b)
// URL restore — parsed sorts, updated columnSorts, called setSortMode.
onMounted(loadColumnsAndTasks)

// Navigating to a different kanban remounts this component (AppLayout's KanbanView branch carries
// `:key` on the item id), so `onMounted` above is the only load trigger.
const kanbanColumnsContainer = ref<HTMLElement | null>(null)
const kanbanScrollStorageKey = computed(() => `kanban-scroll-${effectiveItemId.value}`)
useKanbanScrollRestore(kanbanColumnsContainer, kanbanScrollStorageKey)

// ─── Layout (columns | rows) ────────────────────────────────────────────── Row mode renders the
// same board as a vertical list grouped by column.
type KanbanLayout = 'columns' | 'rows'
const LAYOUT_PARAM = 'layout'
const LAYOUT_STORAGE_KEY = 'pabrik-kanban-layout'

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
  try {
    const v = route.query?.[LAYOUT_PARAM]
    return v === 'rows' || v === 'columns' ? v : null
  } catch {
    // route may be absent in tests that don't mock vue-router.
    return null
  }
}

const layout = ref<KanbanLayout>(readLayoutParam() ?? readStoredLayout() ?? 'columns')

const setLayout = (next: KanbanLayout) => {
  if (layout.value === next) return
  layout.value = next
  writeStoredLayout(next)
  try {
    const query = flatQuery()
    // `sorts` is written from the reactive ref, not read back off the (possibly stale)
    // `route.query` snapshot — the sorts watcher can fire in the same tick as this switch, and a
    // stale read would clobber it. Mirrors the protection the sorts watcher applies to `layout`.
    const encoded = encodeSortsParam(Object.values(columnSorts.value))
    if (encoded) query.sorts = encoded
    else delete query.sorts
    if (next === 'columns') delete query[LAYOUT_PARAM]
    else query[LAYOUT_PARAM] = next
    void router.replace(buildAppUrlForBoard(query))
  } catch {
    // Router absent in unit tests — local state already updated.
  }
}

// Row-mode scroll position. The columns row scrolls horizontally; the
// row list scrolls vertically, so it needs its own container + key.
const kanbanRowsContainer = ref<HTMLElement | null>(null)
const kanbanRowScrollStorageKey = computed(() => `kanban-row-scroll-${effectiveItemId.value}`)
useKanbanScrollRestore(kanbanRowsContainer, kanbanRowScrollStorageKey, 'y')

// ─── Row-mode density (comfortable | compact) ───────────────────────────── The two-line row (name
// + metadata) is right for most columns but a lot of scrolling for a 100+ row group like `merged`.
// Compact drops the metadata line back to a single scannable line.
const DENSITY_STORAGE_KEY = 'pabrik-kanban-row-density'

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
const COLLAPSED_STORAGE_PREFIX = 'pabrik-kanban-row-collapsed:'

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

const emit = defineEmits<{
  addColumn: []
  moveTask: [{ taskId: string; columnId: string; position: number }]
  renameColumn: [{ columnId: string; name: string }]
  deleteColumn: [columnId: string]
  // Column drag-and-drop reorder (Trello/Jira UX). Bubbled up
  // from <KanbanColumn> headers to AppLayout, which calls the
  // workspacesStore.reorderKanbanColumn action.
  reorderColumn: [{ columnId: string; targetColumnId: string }]
  // Open the per-board KanbanSettingsDialog (host owns it). No
  // payload — the host derives the active item from its own state.
  openSettings: []
  // (openAgentSettings was REMOVED in the kanban-agent-as-tab plan — the Agent button now navigates
  // directly to /app/kanban/:itemId/settings?tab=agent instead of emitting for the host to mount a
  // dialog.
  selectTask: [taskId: string]
  openTaskInBackground: [payload: { workspaceId: string; itemId: string; taskId: string }]
  openTaskDetailInBackground: [payload: { workspaceId: string; itemId: string; taskId: string }]
  deleteTask: [workspaceId: string, itemId: string, taskId: string]
  renameTask: [workspaceId: string, itemId: string, taskId: string, currentName: string]
  pinTask: [workspaceId: string, itemId: string, taskId: string, isPinned: boolean]
  // Open the per-task detail dialog (kanban-task-detail-dialog feature). Consumed INTERNALLY here —
  // the dialog is mounted in this file's template (we own the kanban's columns & tasks, so
  // resolving the matching column is trivial). AppLayout doesn't need to know about this dialog.
  viewTaskDetail: [taskId: string]
  // The column's "⋮" menu sends these; the host opens
  // KanbanColumnEditor in the right mode.
  requestRenameColumn: [columnId: string]
  requestDeleteColumn: [columnId: string]
  /**    * Fired when the user renames the kanban via the inline pencil on the header title. Mirrors
   * KanbanSettingsDialog's rename-item emit so AppLayout handles both with one handler. Plan:
   * docs/superpowers/plans/2026-06-30-edit-workspace-item-name.md */
  renameItem: [name: string]
  // Chat pane (kanban-embed-chatview plan, Task 2+4). Fired when ChatView's header close button is
  // clicked. AppLayout's handler clears activeTask + navigates to view=workspace (URL is the source
  // of truth).
  closeChat: []
}>()

// ─── Derived data ────────────────────────────────────────────────────────── Columns sorted by
// position ascending (defensive — the backend already returns them in order, but we sort again
// locally so a reorder never produces an out-of-order board even before the API response lands).
const sortedColumns = computed(() => {
  return (props.item.kanban_columns ?? []).slice().sort((a, b) => a.position - b.position)
})

// Tasks for this kanban (defensive — undefined is treated as []).
const tasks = computed<Task[]>(() => props.item.tasks ?? [])

// ─── Search (kanban task search — Chunk 6) ──────────────────────────────── The search input is a
// v-model'd ref. A 300ms trailing-edge debounce (hand-rolled — @vueuse/core is not installed in
// this project) drives a refetch via workspacesStore.fetchKanbanTasks(q).
const searchQuery = ref('')
let searchDebounceTimer: ReturnType<typeof setTimeout> | null = null

const clearSearchDebounce = () => {
  if (searchDebounceTimer !== null) {
    clearTimeout(searchDebounceTimer)
    searchDebounceTimer = null
  }
}

// Search input handler (replaces the old searchQuery watcher): every
// keystroke restarts the 300 ms debounce, then fires one request per
// column. Wired via `@update:model-value` on the search input below.
const onSearchInput = (newQ: string) => {
  searchQuery.value = newQ
  clearSearchDebounce()
  searchDebounceTimer = setTimeout(() => {
    searchDebounceTimer = null
    const trimmed = newQ.trim()
    // Per-column initial fetch (Option B): the search affects every
    // column, so we fire one request per column. fetchKanbanTasks
    // populates columnPagination per column with the new cursor.
    void workspacesStore.fetchKanbanTasksForAllColumns(
      props.workspaceId,
      effectiveItemId.value,
      10, // limit (matches loadMoreTasks + the store's default)
      trimmed || undefined,
    )
  }, 300)
}

onUnmounted(clearSearchDebounce)

// ─── Per-column sort (kanban-sort-by, redo 2026-08-06) ──────────────── Each KanbanColumn has its
// own sortBy + direction (columns/index.vue emits 'sortChange' on every change). KanbanView is the
// source of truth for: 1. URL persistence — `?sorts=col_<id>:<sortBy>:<direction>,...`.
interface SortEntry {
  columnId: string
  sortBy: 'position' | 'created_at' | 'updated_at' | 'name'
  direction: 'asc' | 'desc'
}

// Parse the URL's `sorts` query param. Returns an empty array if
// missing / malformed.
const parseSortsParam = (raw: string | string[] | undefined): SortEntry[] => {
  if (!raw) return []
  const s = Array.isArray(raw) ? raw.join(',') : raw
  const entries: SortEntry[] = []
  for (const part of s.split(',')) {
    const trimmed = part.trim()
    if (!trimmed) continue
    const [columnId, sortBy, direction] = trimmed.split(':')
    if (!columnId || !sortBy || !direction) continue
    if (
      sortBy !== 'position' &&
      sortBy !== 'created_at' &&
      sortBy !== 'updated_at' &&
      sortBy !== 'name'
    )
      continue
    if (direction !== 'asc' && direction !== 'desc') continue
    entries.push({ columnId, sortBy, direction })
  }
  return entries
}

// Encode the per-column sorts into a URL-safe `sorts` string. Default sorts (position + asc) are
// OMITTED so the URL stays clean. Returns null when no non-default sorts exist (caller writes no
// `sorts` param).
const encodeSortsParam = (entries: SortEntry[]): string | null => {
  const filtered = entries.filter((e) => !(e.sortBy === 'position' && e.direction === 'asc'))
  if (filtered.length === 0) return null
  return filtered.map((e) => `${e.columnId}:${e.sortBy}:${e.direction}`).join(',')
}

// Map of column.id → latest sort. Reflects every column's picks
// (not just the latest one). Used by the URL mirror and by the
// fetch watcher.
const columnSorts = ref<Record<string, SortEntry>>({})

// Template refs to each KanbanColumn instance — needed so we can call the columns' setSortMode()
// (defineExpose seam) on URL restore. Map keyed by column.id, populated by the `ref="..."` callback
// in the template.
const columnRefs = ref<Record<string, unknown>>({})
const setColumnRef = (columnId: string) => (el: unknown) => {
  if (el) columnRefs.value[columnId] = el
}

// On mount: the URL restore (sorts parsing, columnSorts mirror, setSortMode) is handled INSIDE
// loadColumnsAndTasks above — see Step 1 + Step 2. No separate onMounted needed.
const writeSortsToUrl = () => {
  const encoded = encodeSortsParam(Object.values(columnSorts.value))
  // Preserve sibling params (`?detail=`, `?layout=`, …) — rebuilding the query from scratch here
  // used to silently drop them, so picking a column sort closed the detail panel and reset the
  // layout.
  const query = flatQuery()
  if (props.workspaceId) query.workspaceId = props.workspaceId
  if (effectiveItemId.value) query.itemId = effectiveItemId.value
  if (encoded) query.sorts = encoded
  else delete query.sorts
  if (layout.value === 'rows') query[LAYOUT_PARAM] = 'rows'
  else delete query[LAYOUT_PARAM]
  // Emit the CANONICAL path shape, not the legacy `/app?view=workspace` one.
  void router.replace(buildAppUrlForBoard(query))
}

// Handler for the column's sort-change emit. Updates the map (which mirrors the URL via
// writeSortsToUrl below) AND fires the fetch for ONLY the changed column — other columns' data is
// untouched (they keep their previously-fetched state, which still matches their own last sort).
const handleColumnSortChange = (
  columnId: string,
  payload: { sortBy: SortEntry['sortBy']; direction: SortEntry['direction'] },
) => {
  // 1. Update the columnSorts map + mirror the URL
  //    (`?sorts=col_X:...`) via writeSortsToUrl.
  columnSorts.value = {
    ...columnSorts.value,
    [columnId]: { columnId, sortBy: payload.sortBy, direction: payload.direction },
  }
  // Mirror to the URL (replaces the old columnSorts watcher arm).
  writeSortsToUrl()

  // 2. Fire the fetch for ONLY this column with its own sort. Other columns are untouched — their
  // local tasks still match their own last sort (the per-column fetch maintains each column's data
  // in its own sort order).
  if (payload.sortBy === 'position' && payload.direction === 'asc') {
    void workspacesStore.fetchKanbanTasks(props.workspaceId, effectiveItemId.value, columnId, 10)
  } else {
    // The store's sortBy param excludes 'position' (no server
    // equivalent); narrow at the call site so the type checker
    // accepts the union.
    const apiSortBy =
      payload.sortBy === 'position'
        ? undefined
        : (payload.sortBy as 'created_at' | 'updated_at' | 'name')
    void workspacesStore.fetchKanbanTasks(
      props.workspaceId,
      effectiveItemId.value,
      columnId,
      10,
      undefined, // cursor — reset to page 1 of the new sort
      undefined, // q — no search filter
      apiSortBy,
      payload.direction,
    )
  }
}

// ─── Handlers ──────────────────────────────────────────────────────────────
// eslint-disable-next-line @typescript-eslint/no-unused-vars -- kept for diff readability.
const _handleAddColumn = () => {
  emit('addColumn')
}

const handleOpenSettings = () => {
  emit('openSettings')
}

// Agent-Kanbans mirror (Migration 081): navigate to the dedicated settings page with the Tools tab
// active (iteration 2 — the Agent umbrella tab was split into Tools + Knowledge; we land on Tools
// since that's the more security-critical config — the access allowlist).
const handleOpenAgentSettings = () => {
  void router.push({
    path: `/app/kanban/${props.item.id}/settings`,
    query: { tab: 'tools' },
  })
}

// NEW (plan: 2026-08-06-kanban-add-task-button-placement). Open the create dialog with the first
// column pre-selected. The header button does NOT preserve a previously-picked column — every fresh
// open starts at the leftmost column.
const handleOpenCreateDialog = () => {
  const firstColumn = sortedColumns.value[0]
  if (!firstColumn) return // disabled button covers this, defensive
  handleViewCreateTask(firstColumn.id)
}

// ─── "Set project root" banner (backfill UX) ───────────────────────────── When a kanban has `path
// = null` (the user created it before the path field existed on the create endpoint), every chat
// session in this kanban's tasks is cwd-less — git/file tools fail with "no such directory".
import { getSystemFolder, listFolder, updateTaskSimple, type FolderEntry } from '../../api'
import { updateSession as apiUpdateSession } from '../../api'
import { listPrs } from '../../api'
import { invalidatePrStatus } from '../../helpers/prStatusCache'
import { forgeWording } from '../../helpers/forgeWording'
import KanbanPrList, { type PrListTab } from './KanbanPrList.vue'
import FilePickerDialog from '../FilePickerDialog.vue'
import UiIcon from '../ui/UiIcon.vue'

const showPathPicker = ref(false)
const pathPickerBusy = ref(false)
const pathPickerError = ref<string | null>(null)

const loadItemsForPathPicker = async (path: string): Promise<FolderEntry[]> => {
  const data = path ? await listFolder(path) : await getSystemFolder()
  return (data.entries || []) as FolderEntry[]
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

// ─── Task-detail dialog (kanban-task-detail-dialog.
const activeTaskDetailId = ref<string | null>(null)
const showTaskDetail = ref(false)
// NEW (plan: 2026-08-18-kanban-task-detail-start-agent). Error banner state for the edit-mode Start
// agent flow. Bound to the dialog's errorMessage prop; cleared at the start of each click.
const startAgentError = ref<string | null>(null)
// 1-shot re-entrancy guard for the Start agent click. Independent of the dialog's
// `:disabled="isWorkerRunning"` (which only catches the cross-session SSE race) — protects against
// double-clicks during the in-flight POST.
const startAgentBusy = ref(false)

const activeTaskDetail = computed<Task | null>(() => {
  if (!activeTaskDetailId.value) return null
  return (props.item.tasks ?? []).find((t) => t.id === activeTaskDetailId.value) ?? null
})

const activeTaskDetailColumn = computed<KanbanColumnType | null>(() => {
  const t = activeTaskDetail.value
  if (!t || !t.kanban_column_id) return null
  return (props.item.kanban_columns ?? []).find((c) => c.id === t.kanban_column_id) ?? null
})

const handleViewTaskDetail = (taskId: string) => {
  activeTaskDetailId.value = taskId
  showTaskDetail.value = true
  // Deep-link the inline panel so "Open details in new tab" + refresh/share round-trip. PUSH (not
  // replace) preserves the board URL in history so browser Back drops the param and the route guard
  // closes the panel back to the plain board. Preserves existing query (sorts etc).
  try {
    void router.push({ query: { ...route.query, detail: taskId } })
  } catch {
    // Router may be absent in unit tests — panel still opens locally.
  }
  // Refetch the task list so the panel shows server-truth on open.
  void workspacesStore.refreshTask(props.workspaceId, props.itemId || props.item.id, taskId)
}

// Copy the current URL query as a flat string map (dropping
// non-string values) so it satisfies vue-router's LocationQueryRaw.
const flatQuery = (): Record<string, string> => {
  const out: Record<string, string> = {}
  let src: Record<string, unknown> = {}
  try {
    src = (route.query as Record<string, unknown> | undefined) ?? {}
  } catch {
    src = {}
  }
  for (const [k, v] of Object.entries(src)) {
    if (typeof v === 'string') out[k] = v
    else if (Array.isArray(v)) {
      const first = v.find((x): x is string => typeof x === 'string')
      if (first !== undefined) out[k] = first
    }
  }
  return out
}

// Build the canonical board URL for a query map.
const buildAppUrlForBoard = (query: Record<string, string>) => {
  const wsId = props.workspaceId
  const itemId = effectiveItemId.value
  if (!wsId || !itemId) return { path: '/app', query }
  return buildAppUrl({ workspaceId: wsId, projectId: itemId, query })
}

// ─── Board-level PR/MR list (kanban-pull-request-button) ────────────────── Header button →
// full-cover <KanbanPrList>, URL-backed as `?prs=` so a deep link / refresh restores it: - opening
// pushes `?prs=open` (navigation — Back returns to board).
const PRS_PARAM = 'prs'

const prsOpen = ref(false)
const prsTab = ref<PrListTab>('open')
// Handle to the mounted list for explicit reloads (tab switches).
// The list exposes `reload()` instead of watching its props.
const prListRef = ref<{ reload: () => void } | null>(null)
// Open-count badge: null until the forge answers — never a fake 0.
const prOpenCount = ref<number | null>(null)
const prOpenTruncated = ref(false)
// Forge guess for the button label + close calls. Updated by the
// mount fetch; the list view learns the authoritative provider from
// its own response.
const prProviderGuess = ref('')
const prPluralLabel = computed(() =>
  forgeWording(prProviderGuess.value || undefined).short === 'MR'
    ? 'Merge requests'
    : 'Pull requests',
)

const readPrsParam = (): PrListTab | null => {
  // No try/catch here: `local/no-silent-fallback-catch` counts this file's fallbacks against a
  // baseline, and a `catch → null` would be an 8th. Optional chaining is total on null/undefined,
  // so there is nothing to catch.
  const raw: unknown = route?.query?.[PRS_PARAM]
  return raw === 'open' || raw === 'closed' ? raw : null
}

const openPrsFromRoute = () => {
  const tab = readPrsParam()
  if (tab) {
    prsTab.value = tab
    prsOpen.value = true
  }
}

const openPrList = () => {
  if (!props.item.path || prsOpen.value) return
  prsOpen.value = true
  prsTab.value = 'open'
  try {
    const query = flatQuery()
    query[PRS_PARAM] = 'open'
    void router.push(buildAppUrlForBoard(query))
  } catch {
    // Router absent in unit tests — local state already updated.
  }
}

const onPrTabChange = (tab: PrListTab) => {
  prsTab.value = tab
  // The list does not watch the tab prop (`local/no-watch` bans new
  // watchers) — reload explicitly, after the prop has propagated.
  void nextTick(() => prListRef.value?.reload())
  try {
    const query = flatQuery()
    query[PRS_PARAM] = tab
    void router.replace(buildAppUrlForBoard(query))
  } catch {
    // Router absent in unit tests — local state already updated.
  }
}

const closePrList = () => {
  prsOpen.value = false
  try {
    const query = flatQuery()
    delete query[PRS_PARAM]
    void router.replace(buildAppUrlForBoard(query))
  } catch {
    // Router absent in unit tests — local state already cleared.
  }
}

const onPrListOpenCount = (n: number) => {
  prOpenCount.value = n
}

// One open-count fetch on mount. A failure leaves the badge absent
// rather than showing 0 — the `.then(ok, err)` shape (no
// try/catch) matches the list view's own fail-visible contract.
const fetchPrOpenCount = () => {
  const cwd = props.item.path || ''
  if (!cwd) return
  listPrs(cwd, { state: 'open', limit: 30 }).then(
    (resp) => {
      prOpenCount.value = (resp.changes ?? []).length
      prOpenTruncated.value = !!resp.truncated
      prProviderGuess.value = resp.provider || ''
    },
    () => {
      // Leave the badge absent — a fake 0 is worse than no badge.
    },
  )
}

// After a successful close the board button's count drops by one and the affected card's badge must
// flip from open to closed.
const prBadgeTick = ref(0)
const prClosedBranches = ref<string[]>([])

const prColumnKey = (columnId: string): string => {
  if (prBadgeTick.value === 0) return columnId
  const holds = (tasks.value ?? []).some(
    (t) => t.kanban_column_id === columnId && prClosedBranches.value.includes(t.git_branch ?? ''),
  )
  return holds ? `${columnId}:pr${prBadgeTick.value}` : columnId
}

const onPrListClosed = (payload: { number: number; headRef: string }) => {
  const cwd = props.item.path || ''
  if (cwd && payload.headRef) {
    invalidatePrStatus(cwd, payload.headRef)
    if (!prClosedBranches.value.includes(payload.headRef))
      prClosedBranches.value = [...prClosedBranches.value, payload.headRef]
    prBadgeTick.value += 1
  }
  if (prOpenCount.value !== null) prOpenCount.value = Math.max(0, prOpenCount.value - 1)
}

// Close the inline detail panel + drop the ?detail= param so the
// URL reflects the board-only state. Used by save-success,
// start-agent-success, and the panel's close/cancel affordance.
const closeTaskDetail = () => {
  showTaskDetail.value = false
  activeTaskDetailId.value = null
  try {
    const next = flatQuery()
    delete next.detail
    void router.replace(buildAppUrlForBoard(next))
  } catch {
    // Router may be absent in unit tests — local state already cleared.
  }
}

// Open the inline panel for a ?detail=<taskId> value (deep-link from "Open details in new tab",
// refresh, or shared link). Unknown ids are ignored so a stale link renders the plain board instead
// of an empty panel.
const openDetailFromId = (detailId: string) => {
  if (!detailId) return
  if (activeTaskDetailId.value === detailId && showTaskDetail.value) return
  const exists = (props.item.tasks ?? []).some((t) => t.id === detailId)
  if (!exists) return
  activeTaskDetailId.value = detailId
  showTaskDetail.value = true
  void workspacesStore.refreshTask(props.workspaceId, props.itemId || props.item.id, detailId)
}

// Read the ?detail= param defensively (route may be absent in tests).
const readDetailParam = (): string | null => {
  try {
    const raw = (route.query as Record<string, unknown> | undefined)?.detail
    return typeof raw === 'string' && raw.trim() !== '' ? raw : null
  } catch {
    return null
  }
}

const openDetailFromRoute = () => {
  const detailId = readDetailParam()
  if (detailId) openDetailFromId(detailId)
}

// Close the panel locally WITHOUT touching the router (the URL is
// already the board URL — used for Back/forward where the history
// entry the user navigated to must win).
const closeDetailLocal = () => {
  showTaskDetail.value = false
  activeTaskDetailId.value = null
}

onMounted(() => {
  openDetailFromRoute()
  openPrsFromRoute()
  fetchPrOpenCount()
})

// Back/forward + in-app query navigations while this kanban stays mounted (replaces the old
// ?detail= / ?layout= watchers): - ?detail= present → open that task's panel. - ?detail= dropped
// while the panel is open → close locally (no router call — the URL is already the board URL).
onBeforeRouteUpdate((to) => {
  const toQuery = to.query as Record<string, unknown>
  const rawDetail = toQuery.detail
  if (typeof rawDetail === 'string' && rawDetail.trim() !== '') {
    openDetailFromId(rawDetail)
  } else if (showTaskDetail.value) {
    // Browser Back/forward dropped ?detail= — close the panel
    // locally WITHOUT touching the router (the URL is already
    // the board URL). This is what makes Back return to kanban.
    closeDetailLocal()
  }
  const rawLayout = toQuery[LAYOUT_PARAM]
  const nextLayout: KanbanLayout = rawLayout === 'rows' ? 'rows' : 'columns'
  if (nextLayout !== layout.value) layout.value = nextLayout
  // ?prs= mirrors the detail pattern: a present value opens the list on that tab, a dropped value
  // closes it locally (the URL is already the board URL — no router call).
  const rawPrs = toQuery[PRS_PARAM]
  if (rawPrs === 'open' || rawPrs === 'closed') {
    const tabChanged = prsOpen.value && prsTab.value !== rawPrs
    prsOpen.value = true
    prsTab.value = rawPrs
    if (tabChanged) void nextTick(() => prListRef.value?.reload())
  } else if (prsOpen.value) {
    prsOpen.value = false
  }
})

// (The old ?detail= watcher lived here — now handled by the `onBeforeRouteUpdate` guard above.)
// (The old ?layout= watcher lived here — now handled by the `onBeforeRouteUpdate` guard above.)
// Panel visibility handler (replaces the old showTaskDetail watcher).
const onDetailShowUpdate = (open: boolean) => {
  if (open) {
    showTaskDetail.value = true
    return
  }
  closeTaskDetail()
}

// Dialog save handler — delegates to the store action which runs the optimistic update + API call +
// rollback-on-error. We close the dialog only on success; on error we keep it open so the user can
// retry without re-typing.
const handleTaskDetailSave = async (payload: {
  name: string
  description: string
  tags?: string[]
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
// to the dialog's @start-agent emit. Plan:
// docs/superpowers/specs/2026-08-18-kanban-task-detail-start-agent.md
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
    if (result && result.success && result.status === 'triggered') {
      // Background worker started successfully. Close the panel
      // and stay on the kanban — the user can click the task card
      // to open the chat view if they want to watch the agent work.
      closeTaskDetail()
    } else if (result && result.success === false) {
      startAgentError.value = "Agent didn't start — server reported failure."
    } else if (result === undefined) {
      startAgentError.value = "Agent didn't start — network error."
    } else {
      // Defensive: response present but without the expected
      // success/status fields. Map to a generic error.
      startAgentError.value = `Agent didn't start — unexpected response.`
    }
  } catch (err) {
    console.error('Failed to start agent:', err)
    startAgentError.value = err instanceof Error ? err.message : String(err)
  } finally {
    startAgentBusy.value = false
  }
}

// NEW (plan: 2026-09-09-run-all-agents-by-column, Tasks 3+4, Option C). Column "Run all agents"
// host handler. Wired to KanbanColumn's `@request-run-all-agents` emit.
const runAllBusyByColumn = ref<Record<string, boolean>>({})
const runAllSummary = ref<string | null>(null)
// In-flight state for the per-column bulk "Stop all agents" action.
// The summary reuses `runAllSummary` (one banner slot; a stop that lands
// after a run overwrites it, which matches the single-action UX).
const stopAllBusyByColumn = ref<Record<string, boolean>>({})

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
    if (result?.success === false) {
      runAllSummary.value = 'Failed to run all agents in column.'
    } else {
      const started = result?.started ?? []
      const skipped = result?.skipped ?? []
      const failed = result?.failed ?? []
      runAllSummary.value = `Started ${started.length}, skipped ${skipped.length} (already running), failed ${failed.length}.`
    }
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
    if (result?.success === false) {
      runAllSummary.value = 'Failed to stop all agents in column.'
    } else {
      const stopped = result?.stopped ?? []
      const skipped = result?.skipped ?? []
      const failed = result?.failed ?? []
      runAllSummary.value = `Stopped ${stopped.length}, skipped ${skipped.length} (not running), failed ${failed.length}.`
    }
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
    if (result && result.success && result.status === 'triggered') {
      // Nothing else to do — the SSE worker events drive the card's
      // spinner and the elapsed chip from here.
      return
    }
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

// ─── Create-task dialog (kanban-add-task-via-detail-dialog — Chunk 1) ──── When the user clicks "+
// Add" on a kanban column, we open the SAME KanbanTaskDetailDialog in `mode="create"` (rather than
// the small AddTaskDialog the picker used to open).
const activeCreateColumnId = ref<string | null>(null)
const showCreateDialog = ref(false)
const createBusy = ref(false)
const createError = ref<string | null>(null)

// Resolve the column object for the dialog's `column` prop. Returns
// null until/unless `activeCreateColumnId` is set; the column is
// looked up in the kanban's columns list which is already in scope.
const activeCreateColumn = computed<KanbanColumnType | null>(() => {
  if (!activeCreateColumnId.value) return null
  return (props.item.kanban_columns ?? []).find((c) => c.id === activeCreateColumnId.value) ?? null
})

// Bound to <KanbanColumn>'s `@add-task`. Sets the target column +
// opens the create dialog. Resets any previous error so a fresh
// open doesn't carry over a stale banner.
const handleViewCreateTask = (columnId: string) => {
  activeCreateColumnId.value = columnId
  createError.value = null
  showCreateDialog.value = true
}

// Create-task submit handler.
const handleCreateTaskSave = async (payload: {
  mode: 'create' | 'create_session' | 'create_and_run'
  name: string
  description: string
  is_auto_retry_until_stop?: '0' | '1'
  // Create-mode worktree toggle from the dialog (undefined = off).
  // Only consumed on the create_and_run path.
  useGitWorktree?: boolean
  // Create-mode worktree path from the dialog (undefined/empty =
  // agent picks the path itself). Only consumed on create_and_run.
  worktreePath?: string
  // Create-mode base ref the worktree branches FROM, e.g. `origin/main`
  // (undefined/empty = no `Base:` line, so the agent branches from the
  // repo HEAD). Only consumed on create_and_run.
  worktreeBaseBranch?: string
  tags?: string[]
  // NEW (plan: 2026-08-06-kanban-task-profile-selector). Empty string = backend default / "Default
  // (top-level config)". Threaded through to runAgentOnNewTask only (Path A — plain create doesn't
  // persist the choice; user can set from chatview later).
  selectedProfile?: string
  // NEW (plan: 2026-08-06-kanban-image-base64-in-chatview, replaces
  // 2026-08-06-kanban-no-base64-in-desc). Files the dialog staged in create mode
  // (KanbanDescriptionEditor.pendingFiles).
  pendingFiles?: PreviewFile[]
  // NEW (Migration 070 — kanban-cwd-session-optional plan). Per-task cwd override.
  cwdSession?: string
}) => {
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
    // NEW (plan: 2026-08-14-kanban-task-create-endpoints). The 2-step addTask + (in create_and_run)
    // runAgentOnNewTask dance is now a single call to addKanbanTask(mode, payload).
    const pendingFiles = payload.pendingFiles ?? []
    const fileToBase64 = (file: File): Promise<string> =>
      new Promise((resolve, reject) => {
        const reader = new FileReader()
        reader.onload = () => resolve(reader.result as string)
        reader.onerror = reject
        reader.readAsDataURL(file)
      })
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

    const queueMessage =
      payload.mode === 'create_and_run'
        ? buildTaskCreateMessage(
            payload.name,
            payload.description,
            payload.useGitWorktree ?? false,
            payload.worktreePath ?? '',
            payload.worktreeBaseBranch ?? '',
          )
        : undefined

    const response = await workspacesStore.addKanbanTask(wsId, itId, payload.mode, {
      name: payload.name,
      description: payload.description,
      tags: payload.tags,
      cwd: payload.cwdSession,
      isAutoRetryUntilStop: payload.is_auto_retry_until_stop,
      selected_profile_model: payload.selectedProfile,
      queue_message: queueMessage,
      imageUrls: uploadedImageUrls,
    })

    if (!response.task) {
      // Partial success (create_and_run only) — the store action
      // already surfaced a toast. Keep the dialog open so the user
      // can retry without re-typing.
      createError.value = 'Failed to create task — please retry.'
      return
    }

    const taskId = response.task.id

    // Move the task to the column the user clicked. The backend's
    // auto-assign put it in the first column; moveTaskToColumn
    // overwrites that. Position 0 = top of the column.
    await workspacesStore.moveTaskToColumn(wsId, itId, taskId, desiredColumnId, 0)

    // In plain create mode the backend's INSERT path already persisted image_urls (via the
    // createStandardTask useCase). In create_and_run mode the same path applies. We don't need a
    // follow-up updateTaskDetails call — the columns are populated server-side now.
    showCreateDialog.value = false
    activeCreateColumnId.value = null
  } catch (err) {
    console.error('Failed to create kanban task:', err)
    createError.value = err instanceof Error ? err.message : String(err)
  } finally {
    createBusy.value = false
  }
}
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
      <!--
      Layout: KanbanView renders ONLY the full-width board. The chat
      task is an AppLayout branch that replaces this view when a task
      belonging to this kanban is active. Clicking a task therefore
      unmounts KanbanView; the horizontal scroll position survives via
      the localStorage persistence in the composable above.
    -->
      <!-- ─── Header ────────────────────────────────────────────────────── -->
      <header
        class="flex items-center gap-3 px-3 py-2 shrink-0"
        style="border-bottom: 1px solid var(--color-border)"
      >
        <h3
          class="text-body font-semibold truncate flex-1"
          style="color: var(--semantic-text)"
          :data-testid="`kanban-view-${item.id}-title`"
        >
          <InlineEditableText
            :value="item.name"
            :placeholder="'unnamed kanban'"
            :ariaLabel="'kanban name'"
            :testId="`kanban-view-${item.id}-rename`"
            display-class="text-body font-semibold"
            @save="(newName) => emit('renameItem', newName)"
          />
        </h3>

        <!--
        "Set project root" banner — surfaces only when the kanban
        has `path = null` (i.e. it was created before the path field
        existed on the create endpoint). Without a path, every chat
        session in this kanban's tasks is cwd-less and git/file
        tools fail with "no such directory". The button opens the
        same FilePickerDialog used by AddKanbanDialog / AddItemDialog.

        Hidden once a path is set. The CSS uses `path ? null`-
        equivalent check via the explicit v-if (the API returns
        `path: null` for unset kanbans; we treat null AND undefined
        AND empty-string as "needs backfill" defensively).
      -->
        <button
          v-if="!item.path"
          type="button"
          @click="showPathPicker = true"
          :disabled="pathPickerBusy"
          class="shrink-0 px-2 py-1 rounded text-dense font-medium transition-all duration-200 disabled:opacity-50 disabled:cursor-not-allowed"
          style="
            background-color: rgba(234, 179, 8, 0.18);
            color: rgb(202, 138, 4);
            border: 1px solid rgba(234, 179, 8, 0.4);
          "
          :data-testid="`kanban-view-${item.id}-set-project-root`"
          title="Set a project root so chat sessions have a working directory"
        >
          <span aria-hidden="true">⚠️</span>
          <span class="ml-1">{{ pathPickerBusy ? 'Setting…' : 'Set project root' }}</span>
        </button>
        <KanbanSearchInput :model-value="searchQuery" @update:model-value="onSearchInput" />

        <!-- Layout toggle — Columns (the board) vs Rows (a grouped
             linear list). URL-backed via `?layout=rows`; `columns` is
             the default and is stripped from the URL. -->
        <div
          class="inline-flex rounded overflow-hidden shrink-0"
          style="border: 1px solid var(--color-border)"
          role="tablist"
          aria-label="Kanban layout"
        >
          <button
            type="button"
            role="tab"
            :aria-selected="layout === 'columns'"
            class="px-2 py-1 text-dense border-none cursor-pointer transition-colors"
            :style="
              layout === 'columns'
                ? 'background: var(--color-violet); color: var(--color-bg);'
                : 'background: transparent; color: var(--semantic-text-muted);'
            "
            :data-testid="`kanban-view-${item.id}-layout-columns`"
            title="Show the board as columns"
            @click="setLayout('columns')"
          >
            <span aria-hidden="true">▦</span><span class="ml-1">Columns</span>
          </button>
          <button
            type="button"
            role="tab"
            :aria-selected="layout === 'rows'"
            class="px-2 py-1 text-dense border-none cursor-pointer transition-colors"
            :style="
              layout === 'rows'
                ? 'background: var(--color-violet); color: var(--color-bg);'
                : 'background: transparent; color: var(--semantic-text-muted);'
            "
            :data-testid="`kanban-view-${item.id}-layout-rows`"
            title="Show the board as a grouped list"
            @click="setLayout('rows')"
          >
            <span aria-hidden="true">☰</span><span class="ml-1">Rows</span>
          </button>
        </div>

        <!-- Density toggle — Comfortable (two-line record: name +
             metadata) vs Compact (single line). The two-line row is
             right for most columns but a lot of scrolling for a 100+
             row group like `merged`, so this is the escape hatch.
             localStorage-backed, not URL-backed: it is a density
             preference, like group collapse, not a distinct view.
             Only meaningful in row mode, so it is hidden in columns. -->
        <button
          v-if="layout === 'rows'"
          type="button"
          class="px-2 py-1 text-dense rounded shrink-0 cursor-pointer transition-colors"
          style="border: 1px solid var(--color-border); color: var(--semantic-text-muted)"
          :data-testid="`kanban-view-${item.id}-density-toggle`"
          :title="
            rowDensity === 'comfortable'
              ? 'Comfortable rows — name plus metadata. Switch to compact for single-line rows.'
              : 'Compact rows — single line, no metadata. Switch to comfortable for name plus metadata.'
          "
          :aria-label="
            rowDensity === 'comfortable' ? 'Row density: comfortable' : 'Row density: compact'
          "
          :aria-pressed="rowDensity === 'compact'"
          @click="setRowDensity(rowDensity === 'comfortable' ? 'compact' : 'comfortable')"
        >
          <span aria-hidden="true">{{ rowDensity === 'comfortable' ? '☰' : '≡' }}</span>
          <span class="ml-1">{{ rowDensity === 'comfortable' ? 'Comfortable' : 'Compact' }}</span>
        </button>

        <!-- NEW (plan: 2026-08-06-kanban-add-task-button-placement). One
           global + Add task button (replaces per-column footer add
           buttons — see KanbanColumn.vue cleanup). Opens the create
           dialog with the first column pre-selected; the dialog's
           column dropdown lets the user pick a different column.
           Disabled when the kanban has zero columns; the `title`
           attribute explains the disabled state. -->
        <button
          type="button"
          class="px-2 py-1 rounded text-dense font-medium hover:opacity-80 transition-opacity disabled:opacity-50 disabled:cursor-not-allowed"
          style="
            background-color: var(--semantic-sidebar-bg);
            border: 1px solid var(--color-border);
            color: var(--semantic-text-muted);
          "
          data-testid="kanban-add-task-button"
          :disabled="sortedColumns.length === 0"
          :title="
            sortedColumns.length ? 'Add a task to this kanban' : 'Add columns first in Settings'
          "
          @click="handleOpenCreateDialog"
        >
          <UiIcon name="plus" />
          <span class="ml-1">Add task</span>
        </button>

        <!-- Board-level change-request list (kanban-pull-request-button).
             Opens the full-cover KanbanPrList (?prs=open). The badge
             shows the open count once the forge answers — it is
             omitted (not 0) until then. Disabled without a project
             root, with the reason visible AND in `title`. -->
        <button
          type="button"
          class="px-2 py-1 rounded text-dense font-medium hover:opacity-80 transition-opacity disabled:opacity-50 disabled:cursor-not-allowed"
          style="
            background-color: var(--semantic-sidebar-bg);
            border: 1px solid var(--color-border);
            color: var(--semantic-text-muted);
          "
          :data-testid="`kanban-view-${item.id}-pr-button`"
          :disabled="!item.path"
          :title="
            item.path ? `Open the ${prPluralLabel.toLowerCase()} list` : 'Set a project root first'
          "
          @click="openPrList"
        >
          <UiIcon name="pr" />
          <span class="ml-1">{{ prPluralLabel }}</span>
          <span
            v-if="prOpenCount !== null"
            class="ml-1 px-1.5 rounded-full text-micro"
            style="background-color: var(--color-violet); color: var(--color-bg)"
            :data-testid="`kanban-view-${item.id}-pr-count`"
            :title="prOpenTruncated ? `At least ${prOpenCount} open` : `${prOpenCount} open`"
            >{{ prOpenCount }}{{ prOpenTruncated ? '+' : '' }}</span
          >
          <span
            v-else-if="!item.path"
            class="ml-1 text-micro"
            style="color: var(--semantic-text-dim)"
          >
            needs project root
          </span>
        </button>

        <button
          type="button"
          class="px-2 py-1 rounded text-dense font-medium hover:opacity-80 transition-opacity"
          style="
            background-color: var(--semantic-sidebar-bg);
            border: 1px solid var(--color-border);
            color: var(--semantic-text-muted);
          "
          :data-testid="`kanban-view-${item.id}-open-settings`"
          @click="handleOpenSettings"
          title="Open board settings (add columns, edit descriptions)"
        >
          <UiIcon name="settings" />
          <span class="ml-1">Settings</span>
        </button>

        <!-- Agent config (Migration 081, agent-kanbans mirror).
           Navigates to /app/kanban/:itemId/settings?tab=tools — the
           Tools allowlist is mounted there as a tab body
           (KanbanToolsPanel inside KanbanSettingsView). User can
           also visit ?tab=knowledge for the Knowledge + System
           Prompt persona-content panel (KanbanKnowledgePanel). -->
        <button
          type="button"
          class="px-2 py-1 rounded text-dense font-medium hover:opacity-80 transition-opacity"
          style="
            background-color: var(--semantic-sidebar-bg);
            border: 1px solid var(--color-border);
            color: var(--semantic-text-muted);
          "
          :data-testid="`kanban-view-${item.id}-open-agent-settings`"
          @click="handleOpenAgentSettings"
          title="Open agent config in board settings"
        >
          <UiIcon name="robot" />
          <span class="ml-1">Agent</span>
        </button>
      </header>

      <!--
      Search "no matches" banner (kanban task search, Chunk 6). Renders
      only when the backend returned an empty task list AND the user
      has a non-empty search query. Empty-string query is excluded so
      the banner doesn't appear on a freshly-opened empty board.
      Dismissed automatically when the search is cleared or any task
      matches.
    -->
      <div
        v-if="tasks.length === 0 && searchQuery.trim() !== ''"
        class="px-3 py-2 text-dense shrink-0"
        style="color: var(--semantic-text-dim)"
        :data-testid="`kanban-view-${item.id}-no-search-matches`"
      >
        No tasks match "{{ searchQuery }}"
      </div>

      <!--
      NEW (plan: 2026-09-09-run-all-agents-by-column, Task 4, Option C).
      Bulk "Run all agents" summary banner. Rendered after
      `handleRunAllAgents` resolves with the server's
      `{started, skipped, failed}` counts. Run-state visuals stay
      with the existing processingState/SessionSlider SSE flow.
    -->
      <div
        v-if="runAllSummary"
        class="px-3 py-2 text-dense shrink-0"
        style="color: var(--semantic-text)"
        :data-testid="`kanban-view-${item.id}-run-all-summary`"
        role="status"
        aria-live="polite"
      >
        {{ runAllSummary }}
      </div>

      <!-- ─── Columns row (horizontal scroll) ──────────────────────────── -->
      <!--
      Horizontal scroll position is persisted to localStorage so the
      kanban stays where the user scrolled it across the standalone
      <-> 3-column layout transition in AppLayout. See
      useKanbanScrollRestore composable + the comment block in the
      <script setup>. Do NOT remove `ref="kanbanColumnsContainer"`
      without also removing the composable call — the two are paired.
    -->
      <div
        v-if="layout === 'columns'"
        ref="kanbanColumnsContainer"
        class="flex-1 min-h-0 overflow-x-auto overflow-y-hidden"
        style="scrollbar-width: thin"
        :data-testid="`kanban-view-${item.id}-columns`"
      >
        <div class="flex gap-3 p-3 h-full items-stretch">
          <KanbanColumn
            v-for="column in sortedColumns"
            :key="prColumnKey(column.id)"
            :ref="setColumnRef(column.id)"
            :column="column"
            :tasks="tasks"
            :workspace-id="workspaceId"
            :item-id="itemId || item.id"
            :cwd="item.path || ''"
            :columns="sortedColumns"
            @move-task="(payload) => emit('moveTask', payload)"
            @rename-column="(payload) => emit('renameColumn', payload)"
            @delete-column="(columnId) => emit('deleteColumn', columnId)"
            @reorder-column="(payload) => emit('reorderColumn', payload)"
            @request-rename-column="(columnId) => emit('requestRenameColumn', columnId)"
            @request-delete-column="(columnId) => emit('requestDeleteColumn', columnId)"
            @request-run-all-agents="handleRunAllAgents"
            @run-agent="(payload) => handleRunAgentFromMenu(payload)"
            :run-all-busy="!!runAllBusyByColumn[column.id]"
            :stop-all-busy="!!stopAllBusyByColumn[column.id]"
            @request-stop-all-agents="handleStopAllAgents"
            @select-task="(id) => emit('selectTask', id)"
            @open-task-in-background="(payload) => emit('openTaskInBackground', payload)"
            @open-task-detail-in-background="
              (payload) => emit('openTaskDetailInBackground', payload)
            "
            @delete-task="(ws, item, id) => emit('deleteTask', ws, item, id)"
            @rename-task="(ws, item, id, name) => emit('renameTask', ws, item, id, name)"
            @pin-task="(ws, item, id, pinned) => emit('pinTask', ws, item, id, pinned)"
            @view-task-detail="handleViewTaskDetail"
            @sort-change="(payload) => handleColumnSortChange(column.id, payload)"
          />
        </div>
      </div>

      <!-- Row mode — the same board as a grouped linear list. Shares the
           header, banners, detail panel and search with column mode; only
           this body differs. The wrapper div owns the vertical scroll
           container ref (a ref on a component yields the instance, not
           the element). -->
      <div v-else ref="kanbanRowsContainer" class="flex-1 min-h-0 flex flex-col">
        <KanbanRowView
          :columns="sortedColumns"
          :tasks="tasks"
          :workspace-id="workspaceId"
          :item-id="itemId || item.id"
          :cwd="item.path || ''"
          :collapsed-ids="collapsedColumnIds"
          :density="rowDensity"
          :run-all-busy-by-column="runAllBusyByColumn"
          :stop-all-busy-by-column="stopAllBusyByColumn"
          @toggle-collapse="toggleColumnCollapsed"
          @rename-column="(payload) => emit('renameColumn', payload)"
          @delete-column="(columnId) => emit('deleteColumn', columnId)"
          @request-rename-column="(columnId) => emit('requestRenameColumn', columnId)"
          @request-delete-column="(columnId) => emit('requestDeleteColumn', columnId)"
          @request-run-all-agents="handleRunAllAgents"
          @request-stop-all-agents="handleStopAllAgents"
          @select-task="(id) => emit('selectTask', id)"
          @open-task-in-background="(payload) => emit('openTaskInBackground', payload)"
          @open-task-detail-in-background="(payload) => emit('openTaskDetailInBackground', payload)"
          @delete-task="(ws, item, id) => emit('deleteTask', ws, item, id)"
          @rename-task="(ws, item, id, name) => emit('renameTask', ws, item, id, name)"
          @pin-task="(ws, item, id, pinned) => emit('pinTask', ws, item, id, pinned)"
          @view-task-detail="handleViewTaskDetail"
          @run-agent="(payload) => handleRunAgentFromMenu(payload)"
          @sort-change="(payload) => handleColumnSortChange(payload.columnId, payload)"
        />
      </div>
    </section>
    <!--
    Full-cover task view (replaces the former centered card AND the
    old KanbanTaskDetailDialog modal). Covers the whole kanban view
    area like the task chat does — the board stays mounted
    underneath but is fully hidden. Opening appends
    ?detail=<taskId> via router.push, so browser Back drops the
    param and the route guard returns to the plain board. Close
    via the panel's X / Cancel / Esc, Save, or Back. Edit + create
    are mutually exclusive.
  -->
    <div
      v-if="showTaskDetail || showCreateDialog"
      class="absolute inset-0 z-30 overflow-y-auto"
      style="background-color: var(--semantic-content-bg)"
      data-testid="kanban-detail-panel"
    >
      <div class="w-full max-w-6xl mx-auto p-4 sm:p-6">
        <KanbanTaskDetail
          v-if="showTaskDetail"
          :show="showTaskDetail"
          @update:show="onDetailShowUpdate"
          :task="activeTaskDetail"
          :column="activeTaskDetailColumn"
          :cwd="item.path || ''"
          :workspace-id="workspaceId"
          :error-message="startAgentError"
          @save="handleTaskDetailSave"
          @update-unattended="handleUnattendedToggle"
          @update-cwd="handleUpdateCwd"
          @start-agent="handleStartAgent"
        />
        <KanbanTaskDetail
          v-if="showCreateDialog"
          v-model:show="showCreateDialog"
          mode="create"
          :task="null"
          :column="activeCreateColumn"
          :available-columns="sortedColumns"
          :cwd="item.path || ''"
          :workspace-id="workspaceId"
          :error-message="createError"
          :creating="createBusy"
          @create="(payload) => handleCreateTaskSave({ ...payload, mode: 'create_session' })"
          @create-and-run="
            (payload) => handleCreateTaskSave({ ...payload, mode: 'create_and_run' })
          "
          @column-change="(columnId) => (activeCreateColumnId = columnId)"
        />
      </div>
    </div>
    <!--
    Full-cover change-request list (kanban-pull-request-button).
    Mounted like the task detail panel above: a `v-if` full-cover
    block that hides the board underneath. `?prs=` in the URL is the
    source of truth (Back drops the param, the route guard closes
    this locally). No `data-testid` on this wrapper — the component
    root already carries `kanban-pr-list-panel`.
  -->
    <div
      v-if="prsOpen"
      class="absolute inset-0 z-30 overflow-y-auto"
      style="background-color: var(--semantic-card-bg)"
    >
      <KanbanPrList
        ref="prListRef"
        :item-path="item.path || ''"
        :item-id="itemId || item.id"
        :workspace-id="workspaceId"
        :tasks="tasks"
        :open="prsOpen"
        :tab="prsTab"
        @back="closePrList"
        @tab-change="onPrTabChange"
        @open-count="onPrListOpenCount"
        @closed="onPrListClosed"
      />
    </div>
  </div>
  <!--
    FilePickerDialog for the "Set project root" banner. Mounted at the
    bottom of the template so it sits in the same Teleport target as
    the rest of the kanban's modals. Same data source wiring as
    AddKanbanDialog's picker — kept duplicated (not extracted) to
    avoid coupling the two pickers.
  -->
  <FilePickerDialog
    v-model="showPathPicker"
    mode="folder"
    :load-items="loadItemsForPathPicker"
    :key-for="(e: any) => e.path as string"
    :path-for="(e: any) => e.path as string"
    :is-expandable="(e: any) => e.is_directory as boolean"
    :label-for="(e: any) => e.name as string"
    :close-on-select="false"
    :enable-recent-history="true"
    title="Select Project Root for this Kanban"
    @select="handleProjectRootSelected"
  />
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
