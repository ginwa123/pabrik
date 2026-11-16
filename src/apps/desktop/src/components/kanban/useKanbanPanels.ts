/** The three full-cover panels the board can show — task detail, create page and the "set project root" picker — plus the single route guard that keeps them in … */
import { computed, nextTick, onMounted, ref } from 'vue'
import { onBeforeRouteUpdate } from 'vue-router'
import { getSystemFolder, listFolder, type FolderEntry } from '../../api'
import { buildProjectSettingsUrl, parseAppPath } from '../../helpers/appUrl'
import type { KanbanColumn, Task } from '../../stores/workspaces'
import { buildAddAppUrl, buildBoardAppUrl, flattenQuery } from './kanbanBoardUrl'
import {
  ADD_COLUMN_PARAM,
  LAYOUT_PARAM,
  PRS_PARAM,
  type KanbanBoardDeps,
  type KanbanLayout,
} from './kanbanViewTypes'
import type { useKanbanPrs } from './useKanbanPrs'

export function useKanbanPanels(deps: KanbanBoardDeps, prs: ReturnType<typeof useKanbanPrs>) {
  const { props, emit, router, route, store, effectiveItemId, layout, sortedColumns } = deps

  const activeTaskDetailId = ref<string | null>(null)
  const showTaskDetail = ref(false)
  // NEW (plan: 2026-08-18-kanban-task-detail-start-agent).
  const startAgentError = ref<string | null>(null)
  // 1-shot re-entrancy guard for the Start agent click.
  const startAgentBusy = ref(false)

  const activeTaskDetail = computed<Task | null>(() => {
    if (!activeTaskDetailId.value) return null
    return (props.item.tasks ?? []).find((t) => t.id === activeTaskDetailId.value) ?? null
  })

  const activeTaskDetailColumn = computed<KanbanColumn | null>(() => {
    const t = activeTaskDetail.value
    if (!t || !t.kanban_column_id) return null
    return (props.item.kanban_columns ?? []).find((c) => c.id === t.kanban_column_id) ?? null
  })

  const handleViewTaskDetail = (taskId: string) => {
    activeTaskDetailId.value = taskId
    showTaskDetail.value = true
    // Deep-link the inline panel so "Open details in new tab" + refresh/share round-trip.
    void router?.push({ query: { ...route?.query, detail: taskId } })
    // Refetch the task list so the panel shows server-truth on open.
    void store.refreshTask(props.workspaceId, props.itemId || props.item.id, taskId)
  }

  // Close the inline detail panel + drop the ?detail= param so the URL reflects the board-only state.
  const closeTaskDetail = () => {
    showTaskDetail.value = false
    activeTaskDetailId.value = null
    const next = flattenQuery(route?.query as Record<string, unknown> | undefined)
    delete next.detail
    void router?.replace(buildBoardAppUrl(props.workspaceId, effectiveItemId.value, next))
  }

  // Open the inline panel for a ?detail=<taskId> value (deep-link from "Open details in new tab", refresh, or shared link).
  const openDetailFromId = (detailId: string) => {
    if (!detailId) return
    if (activeTaskDetailId.value === detailId && showTaskDetail.value) return
    const exists = (props.item.tasks ?? []).some((t) => t.id === detailId)
    if (!exists) return
    activeTaskDetailId.value = detailId
    showTaskDetail.value = true
    void store.refreshTask(props.workspaceId, props.itemId || props.item.id, detailId)
  }

  // Read the ?detail= param defensively (route may be absent in tests).
  const readDetailParam = (): string | null => {
    const raw = (route?.query as Record<string, unknown> | undefined)?.detail
    return typeof raw === 'string' && raw.trim() !== '' ? raw : null
  }

  const openDetailFromRoute = () => {
    const detailId = readDetailParam()
    if (detailId) openDetailFromId(detailId)
  }

  // Close the panel locally WITHOUT touching the router (the URL is already the board URL — used for Back/forward where the history entry the user navigated to …
  const closeDetailLocal = () => {
    showTaskDetail.value = false
    activeTaskDetailId.value = null
  }

  // Panel visibility handler (replaces the old showTaskDetail watcher).
  const onDetailShowUpdate = (open: boolean) => {
    if (open) {
      showTaskDetail.value = true
      return
    }
    closeTaskDetail()
  }

  // ─── Create-task dialog (kanban-add-task-via-detail-dialog — Chunk 1) ────
  const activeCreateColumnId = ref<string | null>(null)
  const showCreateDialog = ref(false)
  const createBusy = ref(false)
  const createError = ref<string | null>(null)

  // Resolve the column object for the dialog's `column` prop.
  const activeCreateColumn = computed<KanbanColumn | null>(() => {
    if (!activeCreateColumnId.value) return null
    return (props.item.kanban_columns ?? []).find((c) => c.id === activeCreateColumnId.value) ?? null
  })

  // Bound to <KanbanColumn>'s `@add-task`.
  const buildAppUrlForAdd = (query: Record<string, string>) =>
    buildAddAppUrl(props.workspaceId, effectiveItemId.value, query)

  const readAddColumnParam = (): string | null => {
    const raw: unknown = route?.query?.[ADD_COLUMN_PARAM]
    return typeof raw === 'string' && raw.trim() !== '' ? raw : null
  }

  const boardQueryWithoutAdd = (): Record<string, string> => {
    const query = flattenQuery(route?.query as Record<string, unknown> | undefined)
    delete query[ADD_COLUMN_PARAM]
    return query
  }

  const handleViewCreateTask = (columnId: string) => {
    activeCreateColumnId.value = columnId
    createError.value = null
    showCreateDialog.value = true
    const query = flattenQuery(route?.query as Record<string, unknown> | undefined)
    query[ADD_COLUMN_PARAM] = columnId
    void router?.push(buildAppUrlForAdd(query))
  }

  // Open the create page.
  const openCreatePage = (columnId: string | null) => {
    if (showCreateDialog.value) return
    const target = columnId ?? sortedColumns.value[0]?.id ?? null
    if (!target) return
    activeCreateColumnId.value = target
    createError.value = null
    showCreateDialog.value = true
  }

  // For a `/add` deep link — a refresh, a shared link, a new tab.
  const openCreateFromRoute = () => {
    if (parseAppPath(route?.path ?? '').kind !== 'projectAdd') return
    openCreatePage(readAddColumnParam())
  }

  const closeCreateLocal = () => {
    showCreateDialog.value = false
    activeCreateColumnId.value = null
  }

  const onCreateShowUpdate = (open: boolean) => {
    if (open) {
      showCreateDialog.value = true
      return
    }
    closeCreateLocal()
    void router?.replace(buildBoardAppUrl(props.workspaceId, effectiveItemId.value, boardQueryWithoutAdd()))
  }

  // ─── "Set project root" banner (backfill UX) ─────────────────────────────
  const showPathPicker = ref(false)
  const pathPickerBusy = ref(false)
  const pathPickerError = ref<string | null>(null)

  const loadItemsForPathPicker = async (path: string): Promise<FolderEntry[]> => {
    const data = path ? await listFolder(path) : await getSystemFolder()
    return (data.entries || []) as FolderEntry[]
  }

  const openMountedPanels = () => {
    openDetailFromRoute()
    openCreateFromRoute()
    prs.openPrsFromRoute()
    prs.fetchPrOpenCount()
  }

  onMounted(openMountedPanels)

  // Back/forward + in-app query navigations while this kanban stays mounted (replaces the old ?detail= / ?layout= watchers): - ?detail= present → open that task's …
  onBeforeRouteUpdate((to) => {
    const toQuery = to.query as Record<string, unknown>
    const rawDetail = toQuery.detail
    if (typeof rawDetail === 'string' && rawDetail.trim() !== '') {
      openDetailFromId(rawDetail)
    } else if (showTaskDetail.value) {
      // Browser Back/forward dropped ?detail= — close the panel locally WITHOUT touching the router (the URL is already the board URL).
      closeDetailLocal()
    }
    // The add page is a path (`/add` on the board path) and the board + add page share ONE route record, so this guard sees every move between them — the browser …
    if (parseAppPath(to.path).kind === 'projectAdd') {
      const rawColumn = toQuery[ADD_COLUMN_PARAM]
      const columnId = typeof rawColumn === 'string' && rawColumn !== '' ? rawColumn : null
      if (columnId && columnId !== activeCreateColumnId.value) activeCreateColumnId.value = columnId
      if (!showCreateDialog.value) openCreatePage(columnId)
    } else if (showCreateDialog.value) {
      closeCreateLocal()
    }
    const rawLayout = toQuery[LAYOUT_PARAM]
    const nextLayout: KanbanLayout = rawLayout === 'rows' ? 'rows' : 'columns'
    if (nextLayout !== layout.value) layout.value = nextLayout
    // ?prs= mirrors the detail pattern: a present value opens the list on that tab, a dropped value closes it locally (the URL is already the board URL — no router …
    const rawPrs = toQuery[PRS_PARAM]
    if (rawPrs === 'open' || rawPrs === 'closed') {
      const tabChanged = prs.prsOpen.value && prs.prsTab.value !== rawPrs
      prs.prsOpen.value = true
      prs.prsTab.value = rawPrs
      if (tabChanged) void nextTick(() => prs.prListRef.value?.reload())
    } else if (prs.prsOpen.value) {
      prs.prsOpen.value = false
    }
  })

const _handleAddColumn = () => {
  emit('addColumn')
}

const handleOpenSettings = () => {
  emit('openSettings')
}

// Agent-Kanbans mirror (Migration 081): navigate to the dedicated settings page with the Tools tab active (iteration 2 — the Agent umbrella tab was split into …
const handleOpenAgentSettings = () => {
  // The URL names the board AND its workspace; with no workspace, the legacy shape is all there is.
  const path = props.workspaceId
    ? buildProjectSettingsUrl(props.workspaceId, props.item.id).path
    : `/app/kanban/${props.item.id}/settings`
  void router.push({
    path,
    query: { tab: 'tools' },
  })
}

// NEW (plan: 2026-08-06-kanban-add-task-button-placement).
const handleOpenCreateDialog = () => {
  const firstColumn = sortedColumns.value[0]
  if (!firstColumn) return // disabled button covers this, defensive
  handleViewCreateTask(firstColumn.id)
}

  return {
    _handleAddColumn,
    handleOpenSettings,
    handleOpenAgentSettings,
    handleOpenCreateDialog,
    activeTaskDetailId,
    showTaskDetail,
    startAgentError,
    startAgentBusy,
    activeTaskDetail,
    activeTaskDetailColumn,
    handleViewTaskDetail,
    closeTaskDetail,
    openDetailFromId,
    readDetailParam,
    openDetailFromRoute,
    closeDetailLocal,
    onDetailShowUpdate,
    activeCreateColumnId,
    showCreateDialog,
    createBusy,
    createError,
    activeCreateColumn,
    buildAppUrlForAdd,
    readAddColumnParam,
    boardQueryWithoutAdd,
    handleViewCreateTask,
    openCreatePage,
    openCreateFromRoute,
    closeCreateLocal,
    onCreateShowUpdate,
    showPathPicker,
    pathPickerBusy,
    pathPickerError,
    loadItemsForPathPicker,
  }
}
