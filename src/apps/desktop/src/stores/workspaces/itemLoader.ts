import type { Ref } from 'vue'
import * as api from '../../api'
import type { createTaskCache } from './taskCache'
import type { DesignPage } from '../../api'
import type { ColumnPaginationState, Task, Workspace, WorkspaceItem } from './types'

interface ItemLoaderParams {
  workspaces: Ref<Workspace[]>
  isLoading: Ref<boolean>
  taskCache: ReturnType<typeof createTaskCache>
  queueCardMediaLoad: (workspaceId: string, itemId: string) => void
  fetchDesignPages: (workspaceId: string, itemId: string) => Promise<DesignPage[]>
  loadExpandedItems: () => Set<string>
}

export function createItemLoader(p: ItemLoaderParams) {
  const {
    workspaces,
    isLoading,
    taskCache,
    fetchDesignPages,
    loadExpandedItems,
  } = p
  const { primeTaskCache, revalidateTaskCache, replaceItemTasksForColumn } = taskCache

  // ─── Lazy per-workspace item loading ──────────────────────────────── init seeds every workspace row
  // with `items: []` and loads items only for the ACTIVE workspace.
  let currentInit: Promise<void> | null = null
  const workspaceItemsLoaded = new Set<string>()
  const workspaceItemsInFlight = new Map<string, Promise<void>>()

  /** Fetch + attach ONE workspace's items: per-item tasks (kanban and design skip — kanban
   * populates per-column on mount, design has no task list), eager design pages, and kanban
   * column/task prefetch. */
  async function loadWorkspaceItems(ws: Workspace): Promise<void> {
    // Items for this workspace.
    const { items } = await api.getWorkspacesItems(ws.id)
    const expandedItems = loadExpandedItems()

    // Tasks for each item in this workspace (per-item, in parallel).
    const tasksByItem = new Map<string, Task[]>()
    await Promise.all(
      (items || []).map(async (item: WorkspaceItem) => {
        if (item.item_type === 'kanban' || item.item_type === 'design') {
          // Kanban: defer to KanbanView onMount — fires per-column fetches with column_id set (per
          // Option B). Design: design items have no tasks list; the sidebar shows design pages
          // instead (see design-pages-in-workspace-tree plan).
          return
        }
        try {
          const cached = await primeTaskCache(ws.id, item.id, undefined, 10)
          if (cached.length > 0) tasksByItem.set(item.id, cached)
          const fresh = await revalidateTaskCache(ws.id, item.id, undefined, 10)
          if (fresh) {
            // A complete page (has_more=false) lists every row in this context —
            // cached rows it omits were deleted or moved out, so they are dropped
            // instead of merged back in.
            const merged = new Map((fresh.has_more ? cached : []).map((task) => [task.id, task]))
            for (const task of fresh.tasks) merged.set(task.id, task)
            tasksByItem.set(item.id, [...merged.values()])
          } else if (cached.length > 0) {
            tasksByItem.set(item.id, cached)
          }
        } catch (err) {
          console.error(`Failed to fetch tasks for item ${item.id}:`, err)
        }
      }),
    )

    // NEW (auto-expand-design-pages plan, 2026-08-06): design pages for each design item.
    // Best-effort — a single bad fetch logs but doesn't block init (the chevron-toggle lazy fetch
    // still works as a fallback).
    await Promise.all(
      (items || []).map(async (item: WorkspaceItem) => {
        if (item.item_type !== 'design') return
        try {
          await fetchDesignPages(ws.id, item.id)
        } catch (err) {
          console.error(`Failed to fetch design pages for item ${item.id}:`, err)
        }
      }),
    )

    // NEW (kanban-prefetch-on-init plan, 2026-08-06): kanban columns + per-column task fetches for
    // each kanban item.
    await Promise.all(
      (items || []).map(async (item: WorkspaceItem) => {
        if (item.item_type !== 'kanban') return
        try {
          // Step 1: load columns (id list for per-column fetches).
          const { columns } = await api.listKanbanColumns(ws.id, item.id)
          item.kanban_columns = [...columns].sort((a, b) => a.position - b.position)
          // Step 2: fire per-column task fetches with DEFAULT sort (page 1). Same inline reason as
          // Step 1 — fetchKanTasks uses findItem too.
          await Promise.all(
            item.kanban_columns.map(async (col) => {
              const cached = await primeTaskCache(ws.id, item.id, col.id, 10)
              if (cached.length > 0) replaceItemTasksForColumn(item, col.id, cached)
              const fresh = await revalidateTaskCache(ws.id, item.id, col.id, 10)
              if (fresh) {
                // A complete page (has_more=false) lists every row in this context —
                // cached rows it omits were deleted or moved out, so they are dropped
                // instead of merged back in.
                const merged = new Map(
                  (fresh.has_more ? cached : []).map((task) => [task.id, task]),
                )
                for (const task of fresh.tasks) merged.set(task.id, task)
                replaceItemTasksForColumn(item, col.id, [...merged.values()])
                item.columnPagination ??= {} as Record<string, ColumnPaginationState>
                item.columnPagination[col.id] = {
                  cursor: fresh.next_cursor,
                  hasMore: fresh.has_more,
                  isLoading: false,
                }
              } else if (cached.length > 0) {
                item.columnPagination ??= {} as Record<string, ColumnPaginationState>
                item.columnPagination[col.id] = {
                  cursor: null,
                  hasMore: false,
                  isLoading: false,
                }
              }
            }),
          )
        } catch (err) {
          console.error(`Failed to fetch kanban tasks for item ${item.id}:`, err)
        }
      }),
    )

    ws.items = (items || []).map((item: WorkspaceItem) => ({
      ...item,
      // Restore expanded state from localStorage
      expanded: expandedItems.has(item.id),
      // Attach tasks for this item: - Non-kanban: from tasksByItem (the api response). - Kanban:
      // PRESERVE the input's tasks (test fixtures inject tasks directly; per-column fetches via
      // KanbanView onMount will eventually replace this).
      tasks: item.item_type === 'kanban' ? (item.tasks ?? []) : (tasksByItem.get(item.id) ?? []),
      // Per-column pagination state — empty for non-kanban / non-pre-fetched items; PRESERVE the
      // kanban-prefetch entries for kanban items so the onMount loadColumnsAndTasks `needFetch`
      // filter excludes them (no redundant fetch on the user's first click).
      columnPagination:
        item.item_type === 'kanban' &&
        item.columnPagination &&
        Object.keys(item.columnPagination).length > 0
          ? item.columnPagination
          : ({} as Record<string, ColumnPaginationState>),
    }))
  }

  /** Idempotent loader for ONE workspace's items (lazy loading — plan above). Already loaded →
   * no-op; in flight → shares the same promise (dedupe); not yet loaded → loadWorkspaceItems +
   * mark. */
  async function ensureWorkspaceItemsLoaded(workspaceId: string): Promise<void> {
    if (workspaceItemsLoaded.has(workspaceId)) return
    const pending = workspaceItemsInFlight.get(workspaceId)
    if (pending) return pending

    let target = workspaces.value.find((ws) => ws.id === workspaceId)
    if (!target && isLoading.value && currentInit) {
      // Called before init() seeded the list (URL restore racing boot) — wait for init, then
      // re-check (init's own load may cover this id meanwhile). Without this, the await below would
      // resolve while the workspace's items are still unloaded.
      try {
        await currentInit
      } catch {
        // init reports its own loadingError; nothing to do here.
      }
      if (workspaceItemsLoaded.has(workspaceId)) return
      const raced = workspaceItemsInFlight.get(workspaceId)
      if (raced) return raced
      target = workspaces.value.find((ws) => ws.id === workspaceId)
    }
    if (!target) return

    // Seeded rows already carry items (spec fixtures that assign `ws.workspaces` directly, or a row
    // populated before the loaded set was cleared): treat them as loaded so the fetch below does
    // not clobber fixture data with a mocked-empty response.
    if (target.items && target.items.length > 0) {
      workspaceItemsLoaded.add(workspaceId)
      return
    }

    const ws = target
    const run = (async () => {
      try {
        await loadWorkspaceItems(ws)
        workspaceItemsLoaded.add(workspaceId)
      } catch (err) {
        console.error(`Failed to load items for workspace ${workspaceId}:`, err)
      } finally {
        workspaceItemsInFlight.delete(workspaceId)
      }
    })()
    workspaceItemsInFlight.set(workspaceId, run)
    return run
  }

  function setCurrentInit(pending: Promise<void> | null): void {
    currentInit = pending
  }

  return {
    workspaceItemsLoaded,
    workspaceItemsInFlight,
    ensureWorkspaceItemsLoaded,
    setCurrentInit,
  }
}
