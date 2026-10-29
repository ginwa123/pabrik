import type { Ref } from 'vue'
import * as api from '../../api'
import type { Workspace } from './types'

interface WorkspaceCrudParams {
  workspaces: Ref<Workspace[]>
  activeWorkspaceId: Ref<string | null>
  activeWorkspaceItemId: Ref<string | null>
  writeActiveWorkspaceKey: (value: string | null) => void
  workspaceItemsLoaded: Set<string>
  loadExpandedWorkspaces: () => Set<string>
}

export function createWorkspaceCrud(p: WorkspaceCrudParams) {
  const {
    workspaces,
    activeWorkspaceId,
    activeWorkspaceItemId,
    writeActiveWorkspaceKey,
    workspaceItemsLoaded,
    loadExpandedWorkspaces,
  } = p

  // Returns the new workspace id on BOTH paths (API success and the
  // local offline fallback) so callers can navigate into it — the
  // /app landing pushes `/app/<id>` right after creation.
  async function addWorkspace(name: string): Promise<string> {
    const defaultIcon = '📂'
    try {
      const newWorkspace = await api.createWorkspace(name)
      const expandedWorkspaces = loadExpandedWorkspaces()
      workspaces.value.unshift({
        ...newWorkspace,
        expanded: expandedWorkspaces.has(newWorkspace.id),
        items: newWorkspace.items || [],
      })
      return newWorkspace.id
    } catch (err) {
      console.error('Failed to create workspace:', err)
      // Fallback to local creation if API fails
      const id = `workspace-${Date.now()}`
      const expandedWorkspaces = loadExpandedWorkspaces()
      workspaces.value.unshift({
        id,
        name,
        icon: defaultIcon,
        expanded: expandedWorkspaces.has(id),
        items: [],
      })
      return id
    }
  }

  // Rename a workspace
  async function renameWorkspace(workspaceId: string, newName: string) {
    const workspace = workspaces.value.find((ws) => ws.id === workspaceId)
    if (!workspace) return
    const trimmed = newName.trim()
    if (!trimmed || trimmed === workspace.name) return

    const previousName = workspace.name
    // Optimistic update
    workspace.name = trimmed

    // Sync with API
    try {
      await api.updateWorkspace(workspaceId, { name: trimmed })
    } catch (err) {
      console.error('Failed to rename workspace:', err)
      // Rollback on error
      workspace.name = previousName
    }
  }

  async function removeWorkspace(workspaceId: string) {
    const workspaceIndex = workspaces.value.findIndex((ws) => ws.id === workspaceId)
    if (workspaceIndex === -1) return

    const removedWorkspace = workspaces.value[workspaceIndex]
    workspaces.value = workspaces.value.filter((ws) => ws.id !== workspaceId)

    // Clear active if affected
    if (removedWorkspace) {
      removedWorkspace.items.forEach((item) => {
        if (activeWorkspaceItemId.value === item.id) {
          activeWorkspaceItemId.value = null
        }
      })
    }
    // Deleting the selected workspace falls back down the
    // activeWorkspace precedence chain; drop the stale persisted id
    // so the next load doesn't resurrect it.
    if (activeWorkspaceId.value === workspaceId) {
      activeWorkspaceId.value = null
      writeActiveWorkspaceKey(null)
    }

    // Sync with API
    try {
      await api.deleteWorkspace(workspaceId)
      // The row is gone — drop its lazy-load mark. Only on success:
      // the rollback below restores the in-memory items, which are
      // still a valid loaded state.
      workspaceItemsLoaded.delete(workspaceId)
    } catch (err) {
      console.error('Failed to delete workspace:', err)
      // Rollback on error
      if (removedWorkspace) {
        workspaces.value.splice(workspaceIndex, 0, removedWorkspace)
      }
    }
  }

  /** Reorder the workspaces array to match `orderedIds` and persist the new order via `POST
   * /api/workspaces/reorder`. Optimistic: the local array is reordered immediately so the UI snaps
   * to the new position on drop. */
  async function reorderWorkspaces(orderedIds: string[]) {
    const current = workspaces.value
    if (orderedIds.length === 0) return

    // Defensive: the client must send a complete ordering. A partial
    // list (e.g. drag-reordering 2 of 5 workspaces) would lose the
    // other 3. Refuse early.
    if (orderedIds.length !== current.length) {
      console.error(
        `[workspacesStore.reorderWorkspaces] orderedIds length ${orderedIds.length} != current ${current.length}; refusing reorder`,
      )
      return
    }

    // No-op: same set of IDs in (potentially) different order. The
    // set-equality check is an O(n) walk — fine for the realistic
    // sidebar size.
    const currentIdSet = new Set(current.map((w) => w.id))
    const newIdSet = new Set(orderedIds)
    const isSameSet =
      currentIdSet.size === newIdSet.size && [...currentIdSet].every((id) => newIdSet.has(id))
    if (isSameSet && current.every((w, i) => w.id === orderedIds[i])) {
      return
    }

    // Snapshot for rollback. Vue's ref returns the inner array;
    // copying the slice gives us a moment-in-time view.
    const previousOrder = current.slice()

    // Optimistic local reorder: build a new array by looking up each id in the current array. If an
    // id is missing (defensive — the length-mismatch check above should have caught this), fall
    // back to keeping the original row at its original position.
    const byId = new Map(current.map((w) => [w.id, w]))
    const reordered: Workspace[] = []
    for (const id of orderedIds) {
      const ws = byId.get(id)
      if (ws) reordered.push(ws)
    }
    // If any current rows were missed, append them at the end (should
    // not happen given the length check, but defensive).
    for (const ws of current) {
      if (!orderedIds.includes(ws.id)) reordered.push(ws)
    }
    workspaces.value = reordered

    // Persist to backend.
    try {
      await api.reorderWorkspaces(orderedIds)
    } catch (err) {
      console.error('[workspacesStore.reorderWorkspaces] API call failed, rolling back:', err)
      workspaces.value = previousOrder
    }
  }

  return {
    addWorkspace,
    renameWorkspace,
    removeWorkspace,
    reorderWorkspaces,
  }
}
