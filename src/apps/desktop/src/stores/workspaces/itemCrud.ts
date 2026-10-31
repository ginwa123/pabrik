import type { Ref } from 'vue'
import * as api from '../../api'
import type { Workspace, WorkspaceItem } from './types'

interface ItemCrudParams {
  workspaces: Ref<Workspace[]>
  activeWorkspaceItemId: Ref<string | null>
  expandedItemIds: Ref<Record<string, boolean>>
  loadExpandedWorkspaces: () => Set<string>
  loadExpandedItems: () => Set<string>
  saveExpandedWorkspaces: (expandedIds: Set<string>) => void
  saveExpandedItemIds: (expandedIds: Record<string, boolean>) => void
}

export function createItemCrud(p: ItemCrudParams) {
  const {
    workspaces,
    activeWorkspaceItemId,
    expandedItemIds,
    loadExpandedWorkspaces,
    loadExpandedItems,
    saveExpandedWorkspaces,
    saveExpandedItemIds,
  } = p

  async function addWorkspaceItem(
    workspaceId: string,
    name: string,
    path: string,
    itemType: string = 'folder',
  ): Promise<string | undefined> {
    const workspace = workspaces.value.find((ws) => ws.id === workspaceId)
    if (!workspace) return undefined

    try {
      const newItem = await api.createWorkspaceItem(workspaceId, name, path, itemType)
      const expandedItems = loadExpandedItems()
      workspace.items.push({
        ...newItem,
        expanded: expandedItems.has(newItem.id),
      })
      // Auto-expand workspace to show new item and persist
      if (!workspace.expanded) {
        workspace.expanded = true
        const expandedWorkspaces = loadExpandedWorkspaces()
        expandedWorkspaces.add(workspace.id)
        saveExpandedWorkspaces(expandedWorkspaces)
      }
      return newItem.id
    } catch (err) {
      console.error('Failed to create workspace item:', err)
      // Fallback to local creation if API fails
      const itemId = `item-${Date.now()}`
      const expandedItems = loadExpandedItems()
      workspace.items.push({
        id: itemId,
        name,
        item_type: itemType,
        path,
        expanded: expandedItems.has(itemId),
      })
      // Auto-expand workspace to show new item and persist
      if (!workspace.expanded) {
        workspace.expanded = true
        const expandedWorkspaces = loadExpandedWorkspaces()
        expandedWorkspaces.add(workspace.id)
        saveExpandedWorkspaces(expandedWorkspaces)
      }
      return itemId
    }
  }

  // Return the workspace's default project — the agent-mode item whose `path` is the server user's
  // home directory, and where the "New Chat" action creates its chat (Migration 094).
  async function ensureDefaultProject(workspaceId: string): Promise<WorkspaceItem | undefined> {
    const workspace = workspaces.value.find((ws) => ws.id === workspaceId)
    if (!workspace) return undefined

    const existing = workspace.items.find((item) => item.is_default === 1)
    if (existing) return existing

    try {
      const { item } = await api.getOrCreateDefaultProject(workspaceId)
      // Adopt the response's own fields when the store already holds a row
      // for that id, so an item's fetched `tasks` array is not clobbered.
      const known = workspace.items.find((it) => it.id === item.id)
      if (known) {
        Object.assign(known, item)
        return known
      }
      workspace.items.unshift(item)
      return item
    } catch (err) {
      console.error('Failed to resolve the default project for workspace', workspaceId, err)
      return undefined
    }
  }

  // Create a new kanban workspace item. The backend seeds three default columns (todo / in progress
  // / done) and returns them alongside the item. We push the item into the workspace's items array
  // and pre-populate `kanban_columns` + `tasks` so the board renders immediately.
  async function addKanbanItem(
    workspaceId: string,
    name: string,
    path: string,
  ): Promise<string | undefined> {
    try {
      const { item, columns } = await api.createKanban(workspaceId, name, path)
      const ws = workspaces.value.find((w) => w.id === workspaceId)
      if (ws) {
        ws.items.push({
          ...item,
          // Defensive merge: mirror the `addDesignItem` pattern (workspaces.ts:721-748).
          name: item.name ?? name,
          item_type: item.item_type ?? 'kanban',
          path: item.path ?? path,
          kanban_columns: columns || [],
          tasks: [],
        })
        // Auto-expand the workspace to surface the new kanban and
        // persist the expansion (same UX as addWorkspaceItem).
        if (!ws.expanded) {
          ws.expanded = true
          const expandedWorkspaces = loadExpandedWorkspaces()
          expandedWorkspaces.add(ws.id)
          saveExpandedWorkspaces(expandedWorkspaces)
        }
      }
      return item.id
    } catch (err) {
      console.error('[workspacesStore.addKanbanItem] API call failed:', err)
      return undefined
    }
  }

  /** Create a new design workspace item and select it. `path` is REQUIRED — design elements live as
   * HTML files at `<path>/.pabrik/design/<page>/<element>.html`. */
  async function addDesignItem(
    workspaceId: string,
    name: string,
    path: string,
  ): Promise<string | undefined> {
    try {
      const item = await api.createDesign(workspaceId, name, path)
      const ws = workspaces.value.find((w) => w.id === workspaceId)
      if (ws) {
        // Defensive merge: the backend now returns the full CreateDesignResponse (id, workspace_id,
        // item_type, name, path, position).
        ws.items.push({
          ...item,
          // WorkspaceItem interface fields — fall back to the form values when the response is
          // missing them.
          name: item.name ?? name,
          item_type: item.item_type ?? 'design',
          path: item.path ?? path,
          tasks: [],
          design_elements: [],
        })
        // Auto-expand the workspace + select the new item so the
        // user lands in the new DesignView (mirror addKanbanItem).
        if (!ws.expanded) {
          ws.expanded = true
          const expandedWorkspaces = loadExpandedWorkspaces()
          expandedWorkspaces.add(ws.id)
          saveExpandedWorkspaces(expandedWorkspaces)
        }
      }
      activeWorkspaceItemId.value = item.id
      return item.id
    } catch (err) {
      console.error('[workspacesStore.addDesignItem] API call failed:', err)
      return undefined
    }
  }

  // Agent Mode (plan 2026-08-15-agent-mode, task_1786962724740_0). Mirrors addDesignItem — POST
  // /api/workspaces/:wsId/items/agent and push the new item + a default Agent metadata block into
  // the local store.
  async function addAgentItem(
    workspaceId: string,
    name: string,
    path: string,
  ): Promise<string | undefined> {
    try {
      const { item, agent } = await api.createAgent(workspaceId, name, path)
      const ws = workspaces.value.find((w) => w.id === workspaceId)
      if (ws) {
        ws.items.push({
          ...item,
          name: item.name ?? name,
          item_type: item.item_type ?? 'agent',
          path: item.path ?? path,
          tasks: [],
          design_elements: [],
        })
        if (!ws.expanded) {
          ws.expanded = true
          const expandedWorkspaces = loadExpandedWorkspaces()
          expandedWorkspaces.add(ws.id)
          saveExpandedWorkspaces(expandedWorkspaces)
        }
      }
      activeWorkspaceItemId.value = item.id
      // Agent metadata is fetched lazily by AgentView via api.getAgent
      // on mount; no eager push here. We just return the new item id.
      void agent // silence unused-variable lint
      return item.id
    } catch (err) {
      console.error('[workspacesStore.addAgentItem] API call failed:', err)
      return undefined
    }
  }

  // Workspace routine item (Migration 084, plan 2026-09-10-workspace-items-routines). Mirrors
  // addAgentItem — POST /api/workspaces/:wsId/items/routine and push the new item into the local
  // store. Routine metadata is fetched lazily by RoutineView via api.getRoutineItem on mount.
  async function addRoutineItem(
    workspaceId: string,
    name: string,
    path: string,
    options?: { instruction?: string; schedule?: string },
  ): Promise<string | undefined> {
    try {
      const { item, routine } = await api.createRoutineItem(workspaceId, name, path, options)
      const ws = workspaces.value.find((w) => w.id === workspaceId)
      if (ws) {
        ws.items.push({
          ...item,
          name: item.name ?? name,
          item_type: item.item_type ?? 'routine',
          path: item.path ?? path,
          tasks: [],
          design_elements: [],
        })
        if (!ws.expanded) {
          ws.expanded = true
          const expandedWorkspaces = loadExpandedWorkspaces()
          expandedWorkspaces.add(ws.id)
          saveExpandedWorkspaces(expandedWorkspaces)
        }
      }
      activeWorkspaceItemId.value = item.id
      void routine // silence unused-variable lint
      return item.id
    } catch (err) {
      console.error('[workspacesStore.addRoutineItem] API call failed:', err)
      return undefined
    }
  }

  async function removeWorkspaceItem(workspaceId: string, itemId: string) {
    const workspace = workspaces.value.find((ws) => ws.id === workspaceId)
    if (!workspace) return

    // Store for potential rollback
    const itemIndex = workspace.items.findIndex((i) => i.id === itemId)
    if (itemIndex === -1) return

    const removedItem = workspace.items[itemIndex]
    workspace.items = workspace.items.filter((item) => item.id !== itemId)

    if (activeWorkspaceItemId.value === itemId) {
      activeWorkspaceItemId.value = null
    }

    // Remove from expandedItemIds if present
    if (expandedItemIds.value[itemId]) {
      delete expandedItemIds.value[itemId]
      expandedItemIds.value = { ...expandedItemIds.value }
      saveExpandedItemIds(expandedItemIds.value)
    }

    // Sync with API
    try {
      await api.deleteWorkspaceItem(workspaceId, itemId)
    } catch (err) {
      console.error('Failed to delete workspace item:', err)
      // Rollback on error
      if (removedItem) {
        workspace.items.splice(itemIndex, 0, removedItem)
      }
    }
  }

  /** Reorder the items of one workspace to match `orderedIds` and persist the new order via `POST
   * /api/workspaces/:workspace_id/items/reorder`. Mirrors `reorderWorkspaces` but scoped to a
   * single workspace's items. */
  async function reorderWorkspaceItems(workspaceId: string, orderedIds: string[]) {
    const workspace = workspaces.value.find((w) => w.id === workspaceId)
    if (!workspace) {
      console.error(`[workspacesStore.reorderWorkspaceItems] workspace ${workspaceId} not found`)
      return
    }
    const current = workspace.items
    if (orderedIds.length === 0) return
    if (orderedIds.length !== current.length) {
      console.error(
        `[workspacesStore.reorderWorkspaceItems] orderedIds length ${orderedIds.length} != current ${current.length}; refusing reorder`,
      )
      return
    }

    // No-op: same set of IDs in (potentially) different order. The
    // set-equality check is an O(n) walk — fine for the realistic
    // items-per-workspace count.
    const currentIdSet = new Set(current.map((i) => i.id))
    const newIdSet = new Set(orderedIds)
    const isSameSet =
      currentIdSet.size === newIdSet.size && [...currentIdSet].every((id) => newIdSet.has(id))
    if (isSameSet && current.every((i, idx) => i.id === orderedIds[idx])) {
      return
    }

    // Snapshot for rollback.
    const previousOrder = current.slice()

    // Optimistic local reorder. The workspace is a ref inside the workspaces array; mutating
    // `workspace.items` in place preserves Vue reactivity (the workspace's items array is what the
    // sidebar's v-for is bound to).
    const byId = new Map(current.map((i) => [i.id, i]))
    const reordered: WorkspaceItem[] = []
    for (const id of orderedIds) {
      const item = byId.get(id)
      if (item) reordered.push(item)
    }
    // If any current rows were missed, append them at the end
    // (should not happen given the length check, but defensive).
    for (const item of current) {
      if (!orderedIds.includes(item.id)) reordered.push(item)
    }
    workspace.items = reordered

    // Persist to backend.
    try {
      await api.reorderWorkspaceItems(workspaceId, orderedIds)
    } catch (err) {
      console.error('[workspacesStore.reorderWorkspaceItems] API call failed, rolling back:', err)
      workspace.items = previousOrder
    }
  }

  return {
    addWorkspaceItem,
    ensureDefaultProject,
    addKanbanItem,
    // NEW (design-mode feature): creates a design-mode workspace item.
    addDesignItem,
    // Agent Mode (plan 2026-08-15-agent-mode, task_1786962724740_0):
    // creates an agent-mode workspace item. POSTs to
    // /api/workspaces/:wsId/items/agent and pushes the new item.
    addAgentItem,
    // Workspace routines (Migration 084, plan 2026-09-10-workspace-items-routines): creates a
    // routine-mode workspace item. POSTs to /api/workspaces/:wsId/items/routine and pushes the new
    // item.
    addRoutineItem,
    removeWorkspaceItem,
    reorderWorkspaceItems,
  }
}
