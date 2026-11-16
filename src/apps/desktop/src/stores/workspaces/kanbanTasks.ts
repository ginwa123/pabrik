import type { Ref } from 'vue'
import * as api from '../../api'
import { runSyncVoid } from '../../sync/runtime'
import { normalizeTaskTags } from './normalize'
import type { createTaskCache } from './taskCache'
import type { Workspace, WorkspaceItem } from './types'

interface KanbanTasksParams {
  workspaces: Ref<Workspace[]>
  findItem: (workspaceId: string, itemId: string) => WorkspaceItem | undefined
  taskCache: ReturnType<typeof createTaskCache>
  firstPageLoadingColumns: Ref<Set<string>>
  firstPageLoadingKey: (itemId: string, columnId: string) => string
  activeSearchQueries: Map<string, string>
  activeSortBy: Map<string, 'created_at' | 'updated_at' | 'name'>
  activeSortDirection: Map<string, 'asc' | 'desc'>
  queueCardMediaLoad: (workspaceId: string, itemId: string) => void
  fetchKanbanColumns: (workspaceId: string, itemId: string) => Promise<void>
}

export function createKanbanTasks(p: KanbanTasksParams) {
  const {
    workspaces,
    findItem,
    taskCache,
    firstPageLoadingColumns,
    firstPageLoadingKey,
    activeSearchQueries,
    activeSortBy,
    activeSortDirection,
    queueCardMediaLoad,
    fetchKanbanColumns,
  } = p
  const { taskEngineDb, taskRequest, primeTaskCache } = taskCache
  const { revalidateTaskCache, replaceItemTasksForColumn } = taskCache

  // Refresh an item's tasks from the backend and merge the response into the local `item.tasks` array.
  async function fetchKanbanTasks(
    workspaceId: string,
    itemId: string,
    columnId: string, // NEW (Option B) — required for per-column fetch
    limit = 10,
    cursor?: string,
    q?: string,
    sortBy?: 'created_at' | 'updated_at' | 'name',
    direction?: 'asc' | 'desc',
  ): Promise<void> {
    const item = findItem(workspaceId, itemId)
    if (!item) return
    // Mark this column's first page as in-flight so KanbanColumn / KanbanRowView can show a skeleton instead of the "No tasks yet" empty state.
    const isFirstPage = !cursor
    if (isFirstPage) {
      firstPageLoadingColumns.value.add(firstPageLoadingKey(itemId, columnId))
    }
    try {
      const cached = cursor
        ? []
        : await primeTaskCache(workspaceId, itemId, columnId, limit, q, sortBy, direction)
      if (cached.length > 0) replaceItemTasksForColumn(item, columnId, cached)
      const fresh = await revalidateTaskCache(
        workspaceId,
        itemId,
        columnId,
        limit,
        q,
        sortBy,
        direction,
      )
      if (fresh) {
        // A complete page (has_more=false) lists every row in this context — cached rows it omits were deleted or moved out, so they are dropped instead of merged back …
        const merged = new Map((fresh.has_more ? cached : []).map((task) => [task.id, task]))
        for (const task of fresh.tasks) merged.set(task.id, task)
        replaceItemTasksForColumn(item, columnId, [...merged.values()])
        if (!item.columnPagination) item.columnPagination = {}
        item.columnPagination[columnId] = {
          cursor: fresh.next_cursor,
          hasMore: fresh.has_more,
          isLoading: false,
        }
      } else if (cached.length > 0) {
        if (!item.columnPagination) item.columnPagination = {}
        item.columnPagination[columnId] = {
          cursor: null,
          hasMore: false,
          isLoading: false,
        }
      }

      // Track the active q so SSE handlers + loadMoreTasks can forward it on subsequent refetches.
      if (q && q.length > 0) {
        activeSearchQueries.set(itemId, q)
      } else {
        activeSearchQueries.delete(itemId)
      }

      // Track the active sort so loadMoreTasksForColumn + kanbanSse can forward it on subsequent refetches.
      if (sortBy && direction) {
        activeSortBy.set(itemId, sortBy)
        activeSortDirection.set(itemId, direction)
      } else {
        activeSortBy.delete(itemId)
        activeSortDirection.delete(itemId)
      }

      // Card-first async media: cards already rendered from the flag-only payload above; queue thumbnail loads behind it.
      queueCardMediaLoad(workspaceId, itemId)
    } catch (err) {
      console.error(
        `[workspacesStore.fetchKanbanTasks] API call failed for column ${columnId}:`,
        err,
      )
      // Leave the existing tasks array untouched so the UI doesn't flash to empty on a transient network blip.
    } finally {
      // Clear the first-page flag on BOTH paths — a failed fetch must not park the skeleton forever (the column falls back to its empty state, which is the honest …
      if (isFirstPage) {
        firstPageLoadingColumns.value.delete(firstPageLoadingKey(itemId, columnId))
      }
    }
  }

  // Fire `fetchKanbanTasks` for every column of a kanban item.
  async function fetchKanbanTasksForAllColumns(
    workspaceId: string,
    itemId: string,
    limit = 10,
    q?: string,
    sortBy?: 'created_at' | 'updated_at' | 'name',
    direction?: 'asc' | 'desc',
  ): Promise<void> {
    const item = findItem(workspaceId, itemId)
    if (!item) return
    let columns = item.kanban_columns ?? []
    if (columns.length === 0) {
      // No columns loaded yet — fetch them first so we have ids. fetchKanbanColumns is idempotent (just an HTTP GET), safe to call even if the columns are already in …
      await fetchKanbanColumns(workspaceId, itemId)
      columns = item.kanban_columns ?? []
    }
    if (columns.length === 0) return // still empty → board has no columns
    // Fire one fetch per column in parallel.
    await Promise.all(
      columns.map((col) =>
        fetchKanbanTasks(
          workspaceId,
          itemId,
          col.id,
          limit,
          undefined, // cursor — reset to page 1 of the filtered set
          q,
          sortBy,
          direction,
        ),
      ),
    )
    // Card-first async media: every column's cards rendered from the flag-only payload; queue thumbnail loads behind them in one batch.
    queueCardMediaLoad(workspaceId, itemId)
  }

  // Load the next page of tasks for ONE column of a kanban item (per-column pagination, plan 2026-08-06-kanban-per-column- pagination.md).
  async function loadMoreTasksForColumn(workspaceId: string, itemId: string, columnId: string) {
    const workspace = workspaces.value.find((ws) => ws.id === workspaceId)
    if (!workspace) return
    const item = workspace.items.find((i) => i.id === itemId)
    if (!item) return
    const colState = item.columnPagination?.[columnId]
    if (!colState) return
    if (colState.isLoading) return
    if (!colState.hasMore) return
    if (!colState.cursor) return

    colState.isLoading = true
    try {
      // Kanban task search (Chunk 4): forward the active q so "Load more" fetches the next page of MATCHES, not the next page of everything.
      const activeQ = activeSearchQueries.get(itemId)
      // Kanban sort-by (Chunk 3): forward the active sort.
      const activeSort = activeSortBy.get(itemId)
      const activeDirection = activeSortDirection.get(itemId)
      const { tasks, has_more, next_cursor } = await api.getTasks(
        workspaceId,
        itemId,
        10, // PAGE_SIZE — keep in sync with the default in api/index.ts
        colState.cursor,
        activeSort,
        activeDirection,
        columnId, // per-column filter (the new arg)
        activeQ,
      )
      // Append the new page to the existing list.
      if (!item.tasks) item.tasks = []
      const seenIds = new Set(item.tasks.map((t) => t.id))
      for (const t of tasks.map(normalizeTaskTags)) {
        if (seenIds.has(t.id)) continue
        seenIds.add(t.id)
        item.tasks.push(t)
      }
      await runSyncVoid(
        taskEngineDb.putLocal(
          taskRequest(workspaceId, itemId, columnId, activeQ, activeSort, activeDirection),
          tasks.map((task) => ({
            id: task.id,
            sortKey: (task as unknown as { updated_at?: unknown }).updated_at as string,
            raw: task,
          })),
        ),
        'tasks.putLocal',
      )
      // Update this column's pagination state with the new cursor + hasMore.
      colState.cursor = next_cursor
      colState.hasMore = has_more
      // Card-first async media: appended cards rendered from the flag-only payload; queue their thumbnail loads behind them.
      queueCardMediaLoad(workspaceId, itemId)
    } catch (err) {
      console.error(`Failed to load more tasks for item ${itemId} column ${columnId}:`, err)
      // Leave hasMore/cursor as-is so the user can retry by clicking the button again.
    } finally {
      colState.isLoading = false
    }
  }

  return {
    fetchKanbanTasks,
    // Per-column initial fetch helper (Option B).
    fetchKanbanTasksForAllColumns,
    // Per-column pagination (kanban-per-column-pagination plan, 2026-08-06).
    loadMoreTasksForColumn,
  }
}
