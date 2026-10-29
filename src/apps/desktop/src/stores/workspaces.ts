import { defineStore } from 'pinia'
import { ref, computed } from 'vue'
import * as api from '../api'
import { createAgentRuns } from './workspaces/agentRuns'
import { createDesignElements } from './workspaces/designElements'
import { createDesignGeometry } from './workspaces/designGeometry'
import { createDesignPages } from './workspaces/designPages'
import { createInitActions } from './workspaces/initActions'
import { createItemCrud } from './workspaces/itemCrud'
import { createItemLoader } from './workspaces/itemLoader'
import { createKanbanColumns } from './workspaces/kanbanColumns'
import { createKanbanTasks } from './workspaces/kanbanTasks'
import { createMediaActions } from './workspaces/media'
import { createSelectionActions } from './workspaces/selection'
import { createSessionEvents } from './workspaces/sessionEvents'
import { createTaskCache } from './workspaces/taskCache'
import { createTaskCrud } from './workspaces/taskCrud'
import { createTaskEdit } from './workspaces/taskEdit'
import { createTaskMoves } from './workspaces/taskMoves'
import { createWorkspaceCrud } from './workspaces/workspaceCrud'
import {
  loadExpandedItemIds,
  loadExpandedItems,
  loadExpandedWorkspaces,
  readActiveWorkspaceKey,
  saveExpandedItemIds,
  saveExpandedItems,
  saveExpandedWorkspaces,
  writeActiveWorkspaceKey,
} from './workspaces/persistence'
import type { DesignPage } from '../api'
import type { SystemFolderInfo, Workspace, WorkspaceItem } from './workspaces/types'
export type {
  ColumnPaginationState,
  FolderEntry,
  KanbanColumn,
  Task,
  Workspace,
  WorkspaceItem,
  SystemFolderInfo,
} from './workspaces/types'
export {
  RECENT_MUTATION_TTL_MS,
  _clearRecentLocalMutationsForTests,
  isRecentLocalMutation,
  registerRecentLocalMutations,
} from './workspaces/mutationDedupe'
export type { TaskDependencyBlocker } from '../api'

export const useWorkspacesStore = defineStore('workspaces', () => {
  // Loading state
  const isLoading = ref(false)
  const loadingError = ref<string | null>(null)

  // Current active workspace item (for main content/FolderExplorer)
  const activeWorkspaceItemId = ref<string | null>(null)

  // Explicitly selected workspace (header dropdown + Projects section).
  const activeWorkspaceId = ref<string | null>(null)

  // Set of expanded workspace item IDs (for showing tasks list - allows multiple)
  const expandedItemIds = ref<Record<string, boolean>>({})

  // Active task within the selected workspace item
  const activeTaskId = ref<string | null>(null)

  // FIX (task-url-overwrite, task_1785959660154, 2026-08-06): Navigation flag the AppLayout URL
  // sync watcher checks before mirroring activeWorkspaceItemId / activeDesignPageId to the URL. Set
  // true at the start of Sidebar.handleSelectTask and cleared after the router.push resolves.
  const isNavigatingToTask = ref(false)

  // Kanban sort-by round-trip preservation (plan 2026-08-06-kanban- sort-by.md): when the user
  // opens a kanban task from the kanban board, Sidebar snapshots the current `?sorts=` into this
  // field.
  const savedSortsParam = ref<string>('')

  // NEW (Chunk 1 of design-element-drag-and-drop plan). The currently active design page id, set by
  // DesignView on mount / tab switch and cleared on unmount.
  const activeDesignPageId = ref<string>('')
  function setActiveDesignPage(pageId: string): void {
    activeDesignPageId.value = pageId
  }

  // NEW (design-pages-in-workspace-tree plan, 2026-08-06): single source of truth for design pages,
  // keyed by workspace item id. Both the sidebar tree (WorkspaceItem.vue) and the design canvas
  // (DesignView.vue) read from this map.
  const designPagesByItemId = ref<Record<string, DesignPage[]>>({})

  // In-flight guard for `fetchDesignPages` — if a fetch is already pending for the same
  // workspaceItemId, return its promise instead of starting a second one.
  const designPagesInFlight = new Map<string, Promise<DesignPage[]>>()

  // NEW (kanban task search feature). Map<itemId, q> — the active search query per board.
  const activeSearchQueries: Map<string, string> = new Map()

  // NEW (kanban-sort-by).
  // Map<itemId, sortField> + Map<itemId, direction> — the active per-board sort.
  const activeSortBy: Map<string, 'created_at' | 'updated_at' | 'name'> = new Map()
  const activeSortDirection: Map<string, 'asc' | 'desc'> = new Map()

  // Per-column FIRST-PAGE loading signal. A reactive Set of `${itemId}:${columnId}` keys, true
  // while that column's page-1 fetch is in flight.
  const firstPageLoadingColumns = ref<Set<string>>(new Set())

  const firstPageLoadingKey = (itemId: string, columnId: string) => `${itemId}:${columnId}`

  function isFirstPageLoading(itemId: string, columnId: string): boolean {
    return firstPageLoadingColumns.value.has(firstPageLoadingKey(itemId, columnId))
  }

  // Design-element fetch signal. Holds `${itemId}:${pageId}` while that page's elements are in
  // flight, null otherwise.
  const designElementsLoadingKey = ref<string | null>(null)

  function isDesignElementsLoading(itemId: string, pageId: string): boolean {
    return designElementsLoadingKey.value === `${itemId}:${pageId}`
  }

  // System folder info from API
  const systemFolderInfo = ref<SystemFolderInfo | null>(null)
  const systemFolderLoading = ref(false)
  const systemFolderError = ref<string | null>(null)

  // Workspaces with their items
  const workspaces = ref<Workspace[]>([])

  // The persisted dropdown selection, validated against the loaded
  // list — a stale id (workspace deleted in another tab / by API)
  // falls through to the item-derived / first-workspace fallbacks.
  function storedActiveWorkspace(): Workspace | undefined {
    const saved = readActiveWorkspaceKey()
    if (!saved) return undefined
    return workspaces.value.find((ws) => ws.id === saved)
  }

  // ─── Kanban actions (Chunk 5 of workspace-item-kanban plan) ───────────── These five actions
  // back the kanban board UI.
  function findItem(workspaceId: string, itemId: string): WorkspaceItem | undefined {
    const workspace = workspaces.value.find((ws) => ws.id === workspaceId)
    if (!workspace) return undefined
    return workspace.items.find((i) => i.id === itemId)
  }

  // Computed: get flattened list of all workspace items
  const allWorkspaceItems = computed(() => {
    return workspaces.value.flatMap((ws) => ws.items)
  })

  // Get active workspace item details
  const activeWorkspaceItem = computed(() => {
    return allWorkspaceItems.value.find((item) => item.id === activeWorkspaceItemId.value)
  })

  // Get active workspace. Precedence (plan decision log): explicit selection (dropdown / URL
  // restore) → persisted choice → workspace owning the active item (legacy fallback) → first
  // workspace, so the dropdown and Projects section always have a target once any workspace exists.
  const activeWorkspace = computed(() => {
    return (
      workspaces.value.find((ws) => ws.id === activeWorkspaceId.value) ||
      storedActiveWorkspace() ||
      workspaces.value.find((ws) =>
        ws.items.some((item) => item.id === activeWorkspaceItemId.value),
      ) ||
      workspaces.value[0]
    )
  })

  // Get active task details
  const activeTask = computed(() => {
    if (!activeTaskId.value || !activeWorkspaceItemId.value) return null

    const workspace = workspaces.value.find((ws) =>
      ws.items.some((item) => item.id === activeWorkspaceItemId.value),
    )
    if (!workspace) return null

    const item = workspace.items.find((i) => i.id === activeWorkspaceItemId.value)
    if (!item?.tasks) return null

    return item.tasks.find((t) => t.id === activeTaskId.value) || null
  })

  // NEW (kanban-embed-chatview plan, Task 1): "which item owns the active task". Walks every
  // workspace's items + tasks looking for activeTaskId; returns the containing item's id or null.
  const activeTaskWorkspaceItemId = computed(() => {
    const taskId = activeTaskId.value
    if (!taskId) return null
    for (const ws of workspaces.value) {
      for (const item of ws.items) {
        if (item.tasks?.some((t) => t.id === taskId)) {
          return item.id
        }
      }
    }
    return null
  })

  // Actions
  async function fetchSystemFolder(folderPath?: string) {
    systemFolderLoading.value = true
    systemFolderError.value = null

    try {
      const data = folderPath ? await api.listFolder(folderPath) : await api.getSystemFolder()
      systemFolderInfo.value = {
        path: data.path,
        absolute: data.absolute,
        home: data.home,
        parent: data.parent,
        entries: data.entries,
      }
      return data
    } catch (err) {
      systemFolderError.value = err instanceof Error ? err.message : 'Failed to fetch'
      console.error('Failed to fetch system folder:', err)
      throw err
    } finally {
      systemFolderLoading.value = false
    }
  }

  // Fetch folder contents for a specific workspace item
  async function fetchFolderContents(workspaceId: string, itemId: string) {
    const workspace = workspaces.value.find((ws) => ws.id === workspaceId)
    if (!workspace) return

    const item = workspace.items.find((i) => i.id === itemId)
    if (!item || !item.path) return

    // Mark as loading
    item.isLoading = true

    try {
      const data = await fetchSystemFolder(item.path)

      // Update entries
      item.entries = data.entries || []
      item.isLoaded = true
      // Don't auto-expand - let user control expanded state
    } catch (err) {
      console.error('Failed to fetch folder contents:', err)
      item.entries = []
    } finally {
      item.isLoading = false
    }
  }

  // Toggle workspace item expansion (for nested folder contents)
  function toggleWorkspaceItem(workspaceId: string, itemId: string) {
    const workspace = workspaces.value.find((ws) => ws.id === workspaceId)
    if (!workspace) return

    const item = workspace.items.find((i) => i.id === itemId)
    if (!item) return

    item.expanded = !item.expanded
    // Persist to localStorage
    const expandedItems = loadExpandedItems()
    if (item.expanded) {
      expandedItems.add(itemId)
    } else {
      expandedItems.delete(itemId)
    }
    saveExpandedItems(expandedItems)
  }

  function updateWorkspaceItemPath(workspaceId: string, itemId: string, newPath: string) {
    const workspace = workspaces.value.find((ws) => ws.id === workspaceId)
    if (workspace) {
      const item = workspace.items.find((i) => i.id === itemId)
      if (item) {
        item.path = newPath
      }
    }
  }

  const taskCache = createTaskCache()
  const media = createMediaActions({
    workspaces,
    findItem,
    cacheTaskMutation: taskCache.cacheTaskMutation,
  })
  const designPages = createDesignPages({
    designPagesByItemId,
    designPagesInFlight,
    activeDesignPageId,
  })
  const itemLoader = createItemLoader({
    workspaces,
    isLoading,
    taskCache,
    queueCardMediaLoad: media.queueCardMediaLoad,
    fetchDesignPages: designPages.fetchDesignPages,
    loadExpandedItems,
  })
  const selection = createSelectionActions({
    workspaces,
    activeWorkspaceId,
    activeWorkspaceItemId,
    activeTaskId,
    expandedItemIds,
    writeActiveWorkspaceKey,
    ensureWorkspaceItemsLoaded: itemLoader.ensureWorkspaceItemsLoaded,
    loadExpandedWorkspaces,
    saveExpandedWorkspaces,
    saveExpandedItemIds,
  })
  const sessionEvents = createSessionEvents({
    workspaces,
    activeTaskId,
    cacheTaskMutation: taskCache.cacheTaskMutation,
    removeTaskFromCache: taskCache.removeTaskFromCache,
  })
  const kanbanColumns = createKanbanColumns({
    workspaces,
    findItem,
    cacheTaskMutation: taskCache.cacheTaskMutation,
    removeTaskFromCache: taskCache.removeTaskFromCache,
  })
  const kanbanTasks = createKanbanTasks({
    workspaces,
    findItem,
    taskCache,
    firstPageLoadingColumns,
    firstPageLoadingKey,
    activeSearchQueries,
    activeSortBy,
    activeSortDirection,
    queueCardMediaLoad: media.queueCardMediaLoad,
    fetchKanbanColumns: kanbanColumns.fetchKanbanColumns,
  })
  const taskMoves = createTaskMoves({
    workspaces,
    findItem,
    cacheTaskMutation: taskCache.cacheTaskMutation,
  })
  const workspaceCrud = createWorkspaceCrud({
    workspaces,
    activeWorkspaceId,
    activeWorkspaceItemId,
    writeActiveWorkspaceKey,
    workspaceItemsLoaded: itemLoader.workspaceItemsLoaded,
    loadExpandedWorkspaces,
  })
  const itemCrud = createItemCrud({
    workspaces,
    activeWorkspaceItemId,
    expandedItemIds,
    loadExpandedWorkspaces,
    loadExpandedItems,
    saveExpandedWorkspaces,
    saveExpandedItemIds,
  })
  const taskCrud = createTaskCrud({
    workspaces,
    activeTaskId,
    cacheTaskMutation: taskCache.cacheTaskMutation,
    removeTaskFromCache: taskCache.removeTaskFromCache,
  })
  const taskEdit = createTaskEdit({
    workspaces,
    activeTaskId,
    cacheTaskMutation: taskCache.cacheTaskMutation,
  })
  const agentRuns = createAgentRuns()
  const designElements = createDesignElements({
    workspaces,
    findItem,
    designElementsLoadingKey,
    activeDesignPageId,
  })
  const designGeometry = createDesignGeometry({ workspaces, findItem })
  const initActions = createInitActions({
    workspaces,
    isLoading,
    loadingError,
    activeWorkspaceId,
    activeWorkspaceItemId,
    activeTaskId,
    expandedItemIds,
    storedActiveWorkspace,
    resetDesignPagesCache: designPages.resetDesignPagesCache,
    setActiveWorkspace: selection.setActiveWorkspace,
    fetchSystemFolder,
    installSessionEventHandlers: sessionEvents.installSessionEventHandlers,
    itemLoader,
    loadExpandedWorkspaces,
    loadExpandedItemIds,
    saveExpandedWorkspaces,
  })

  return {
    // State
    workspaces,
    activeWorkspaceItemId,
    expandedItemIds,
    activeTaskId,
    // FIX (task-url-overwrite, task_1785959660154, 2026-08-06): Navigation flag the AppLayout URL
    // sync watcher checks before mirroring activeWorkspaceItemId / activeDesignPageId to the URL.
    // Set true at the start of Sidebar.handleSelectTask and cleared after the router.push resolves.
    isNavigatingToTask,
    // Kanban sort-by round-trip preservation (plan 2026-08-06): snapshots the active `?sorts=` when
    // the user enters a task view, read back by AppLayout.handleCloseTaskView to restore the sort
    // URL on close.
    savedSortsParam,
    // NEW (Chunk 1 of design-element-drag-and-drop plan): the currently
    // active design page id, mirrored from DesignView so AppLayout's
    // design handlers can route PATCH/PUT/DELETE to the right page.
    activeDesignPageId,
    // Kanban task search (Chunk 4): exposed so SSE handlers can read
    // the active q and forward it on refetch.
    activeSearchQueries,
    // Kanban sort-by (Chunk 3): exposed so SSE handlers can read the active sort and forward it on
    // refetch. The cursor is tied to the sort order — using a different sort on a refetch would
    // fetch a meaningless page.
    activeSortBy,
    activeSortDirection,
    // Per-column first-page loading signal (see the declaration above
    // for why it is not `columnPagination[colId].isLoading`).
    firstPageLoadingColumns,
    isFirstPageLoading,
    // Design-element fetch signal (see the declaration above).
    designElementsLoadingKey,
    isDesignElementsLoading,
    systemFolderInfo,
    systemFolderLoading,
    systemFolderError,
    isLoading,
    loadingError,
    // Computed
    allWorkspaceItems,
    activeWorkspaceItem,
    activeWorkspace,
    activeTask,
    activeTaskWorkspaceItemId,
    // Actions
    ...initActions,
    // Lazy per-workspace items (plan: 2026-09-22-revamp-ui-chats): loads one workspace's
    // items/tasks/design pages on demand; runInit uses it for the active workspace,
    // setActiveWorkspace for every switch. Idempotent + in-flight deduped.
    ensureWorkspaceItemsLoaded: itemLoader.ensureWorkspaceItemsLoaded,
    toggleWorkspaceItem,
    ...selection,
    // NEW (Chunk 1 of design-element-drag-and-drop plan): mirror the
    // active design page id from DesignView. Called on mount + tab
    // switch, and cleared on unmount.
    setActiveDesignPage,
    // NEW (design-pages-in-workspace-tree plan, 2026-08-06): the design-pages cache + the actions
    // that mutate it. Both WorkspaceItem.vue (sidebar tree) and DesignView.vue consume
    // `designPagesByItemId.value[itemId]` directly.
    designPagesByItemId,
    ...designPages,
    ...workspaceCrud,
    activeWorkspaceId,
    ...itemCrud,
    updateWorkspaceItemPath,
    ...taskCrud,
    ...kanbanTasks,
    ...taskEdit,
    fetchTaskMedia: media.fetchTaskMedia,
    fetchTasksMedia: media.fetchTasksMedia,
    ...agentRuns,
    ...kanbanColumns,
    ...taskMoves,
    // Read helper for the kanbanSse single-row fast path: a moved/assigned task that is already
    // cached needs only a refreshTask (1 row), while an uncached one still needs the full column
    // fetch to materialize the missing row.
    findCachedTask: media.findCachedTask,
    ...designElements,
    ...designGeometry,
    onSessionEvent: sessionEvents.onSessionEvent,
    fetchSystemFolder,
    fetchFolderContents,
  }
})
