import type { Ref } from 'vue'
import * as api from '../../api'
import { isIdentityResolved } from '../../helpers/userScope'
import { readWorkspacesCache } from '../../helpers/workspacesCache'
import type { Workspace } from './types'

interface InitActionsParams {
  workspaces: Ref<Workspace[]>
  isLoading: Ref<boolean>
  loadingError: Ref<string | null>
  activeWorkspaceId: Ref<string | null>
  activeWorkspaceItemId: Ref<string | null>
  activeTaskId: Ref<string | null>
  expandedItemIds: Ref<Record<string, boolean>>
  storedActiveWorkspace: () => Workspace | undefined
  resetDesignPagesCache: () => void
  setActiveWorkspace: (workspaceId: string) => Promise<void>
  fetchSystemFolder: () => Promise<unknown>
  installSessionEventHandlers: () => void
  loadExpandedWorkspaces: () => Set<string>
  loadExpandedItemIds: () => Record<string, boolean>
  saveExpandedWorkspaces: (expandedIds: Set<string>) => void
  itemLoader: {
    workspaceItemsLoaded: Set<string>
    workspaceItemsInFlight: Map<string, Promise<void>>
    ensureWorkspaceItemsLoaded: (workspaceId: string) => Promise<void>
    setCurrentInit: (pending: Promise<void> | null) => void
  }
}

export function createInitActions(p: InitActionsParams) {
  const {
    workspaces,
    isLoading,
    loadingError,
    activeWorkspaceId,
    activeWorkspaceItemId,
    activeTaskId,
    expandedItemIds,
    storedActiveWorkspace,
    resetDesignPagesCache,
    setActiveWorkspace,
    fetchSystemFolder,
    installSessionEventHandlers,
    loadExpandedWorkspaces,
    loadExpandedItemIds,
    saveExpandedWorkspaces,
    itemLoader,
  } = p
  const { workspaceItemsLoaded, workspaceItemsInFlight } = itemLoader
  const { ensureWorkspaceItemsLoaded, setCurrentInit } = itemLoader

  // Initialize the store: fetch the workspace list, seed every row with empty items, then load
  // items for the ACTIVE workspace only.
  function init(): Promise<void> {
    const run = runInit()
    setCurrentInit(run)
    return run
  }

  async function runInit(): Promise<void> {
    isLoading.value = true
    loadingError.value = null

    // Wipe the design-pages cache so re-inits don't show stale pages from the previous session (the
    // chevron-click lazy fetch remains the fallback for anything not eagerly reloaded).
    resetDesignPagesCache()
    workspaceItemsLoaded.clear()
    workspaceItemsInFlight.clear()

    // Install the bus-backed session-event listeners (idempotent — safe to call on every init,
    // including HMR re-mounts). The bus is opened once by App.vue, so we don't own the SSE
    // connection here anymore (Chunk 6 of unify-frontend-sse).
    installSessionEventHandlers()

    // Seed helper: every row starts with EMPTY items — the list
    // (dropdown, sidebar, items_count badges) is complete right away;
    // the items tree fills in per visit.
    const seedList = (wsList: Workspace[]) => {
      const expandedWorkspaces = loadExpandedWorkspaces()
      const expandedIds = loadExpandedItemIds()
      // Load expanded item IDs for tasks list from localStorage
      expandedItemIds.value = expandedIds
      workspaces.value = (wsList || []).map((ws: Workspace) => ({
        ...ws,
        // Restore expanded state from localStorage
        expanded: expandedWorkspaces.has(ws.id),
        items: [],
      }))
    }

    // Merge helper for the background revalidate: refresh rows in place without clobbering items
    // already loaded for the active workspace (or expanded UI state) while the fetch was in flight.
    const mergeList = (wsList: Workspace[]) => {
      const expandedWorkspaces = loadExpandedWorkspaces()
      const prevById = new Map(workspaces.value.map((w) => [w.id, w]))
      workspaces.value = (wsList || []).map((ws: Workspace) => {
        const prev = prevById.get(ws.id)
        if (!prev) {
          return {
            ...ws,
            expanded: expandedWorkspaces.has(ws.id),
            items: [],
          }
        }
        return Object.assign(prev, ws, {
          expanded: prev.expanded ?? expandedWorkspaces.has(ws.id),
          items: prev.items ?? [],
          items_count: ws.items_count,
        })
      })
    }

    // Stale-while-revalidate: paint the last-known list synchronously so the dropdown/sidebar shows
    // rows instantly on boot, then the live fetch below refreshes it in the same init.
    // api.getWorkspaces persists every success to the cache (fail-silent).
    const cached = isIdentityResolved() ? readWorkspacesCache() : null
    const hasCache = !!cached && cached.length > 0
    if (hasCache) {
      seedList(cached as Workspace[])
      // Drop the list spinner now — rows are already visible. The
      // active workspace items still load below.
      isLoading.value = false
    }

    try {
      // Step 1: fetch the workspaces list (no items — those come separately).
      const { workspaces: wsList } = await api.getWorkspaces()
      if (hasCache) {
        mergeList(wsList || [])
      } else {
        // Step 2 (cold boot): seed every workspace row with EMPTY items.
        seedList(wsList || [])
      }

      // Step 3: load items for the ACTIVE workspace only.
      const activeId =
        activeWorkspaceId.value ?? storedActiveWorkspace()?.id ?? workspaces.value[0]?.id
      if (activeId) {
        await ensureWorkspaceItemsLoaded(activeId)
      }
    } catch (err) {
      // With a cached paint on screen, a failed revalidate keeps the
      // stale rows (and surfaces the error) instead of wiping to [].
      if (!hasCache) {
        loadingError.value = err instanceof Error ? err.message : 'Failed to load workspaces'
        console.error('Failed to load workspaces:', err)
        // Initialize with empty array on error
        workspaces.value = []
      } else {
        loadingError.value = err instanceof Error ? err.message : 'Failed to refresh workspaces'
        console.error('Failed to refresh workspaces (keeping cached list):', err)
      }
    } finally {
      isLoading.value = false
    }
  }

  // Initialize workspace items from system folder. A deep link can pass
  // its workspace id so boot hydration does not prefer the persisted
  // selection and leave the URL-restored item inactive.
  async function initializeFromSystemFolder(preferredWorkspaceId?: string) {
    // First, load workspaces from API
    await init()
    if (preferredWorkspaceId) {
      await setActiveWorkspace(preferredWorkspaceId)
    }

    // Also fetch system folder info for navigation. Best-effort on purpose: `fetchSystemFolder`
    // records the failure in `systemFolderError` for the UI, and the boot path that calls this is
    // fire-and-forget — a rethrow here surfaced as an unhandled rejection and nothing else.
    await fetchSystemFolder().catch(() => undefined)

    // Restore active task if it was set before workspaces were loaded
    // This handles the case where setActiveTask was called before init() completed
    if (activeTaskId.value) {
      // Find and set the parent workspace item for the active task
      for (const workspace of workspaces.value) {
        for (const item of workspace.items) {
          if (item.tasks?.some((t) => t.id === activeTaskId.value)) {
            // Found the parent - ensure it's set correctly
            activeWorkspaceItemId.value = item.id
            // Expand workspace if not already expanded
            if (!workspace.expanded) {
              workspace.expanded = true
              const expandedWorkspaces = loadExpandedWorkspaces()
              expandedWorkspaces.add(workspace.id)
              saveExpandedWorkspaces(expandedWorkspaces)
            }
            return
          }
        }
      }
    }
  }

  return {
    init,
    initializeFromSystemFolder,
  }
}
