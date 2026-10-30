import type { Ref } from 'vue'
import * as api from '../../api'
import type { Task, Workspace, WorkspaceItem } from './types'

interface KanbanColumnsParams {
  workspaces: Ref<Workspace[]>
  findItem: (workspaceId: string, itemId: string) => WorkspaceItem | undefined
  cacheTaskMutation: (
    workspaceId: string,
    itemId: string,
    task: Task,
    columnId?: string,
  ) => Promise<void>
  removeTaskFromCache: (
    workspaceId: string,
    itemId: string,
    taskId: string,
    columnId?: string,
  ) => Promise<void>
}

export function createKanbanColumns(p: KanbanColumnsParams) {
  const { workspaces, findItem, cacheTaskMutation, removeTaskFromCache } = p

  // Backfill (or change) the `path` of a kanban workspace item. Used by the KanbanView "Set project
  // root" banner that surfaces when a kanban was created before the path field existed (the user's
  // existing kanbans all have `path = NULL`).
  async function updateKanbanItemPath(
    workspaceId: string,
    itemId: string,
    path: string,
  ): Promise<void> {
    const ws = workspaces.value.find((w) => w.id === workspaceId)
    const item = ws?.items.find((i) => i.id === itemId)
    try {
      await api.updateWorkspaceItem(workspaceId, itemId, { path })
      if (item) item.path = path
    } catch (err) {
      console.error('[workspacesStore.updateKanbanItemPath] API call failed:', err)
      throw err
    }
  }

  // Update kanban item name from the Settings dialog or KanbanView inline-rename pencil.
  // Optimistic: mutate `item.name` BEFORE the API call resolves so the UI updates immediately; roll
  // back on error.
  async function updateKanbanItemName(
    workspaceId: string,
    itemId: string,
    newName: string,
  ): Promise<void> {
    const ws = workspaces.value.find((w) => w.id === workspaceId)
    const item = ws?.items.find((i) => i.id === itemId)
    const previousName = item?.name
    // Optimistic update.
    if (item) item.name = newName
    try {
      await api.updateWorkspaceItem(workspaceId, itemId, { name: newName })
    } catch (err) {
      // Restore the previous name on failure so the UI doesn't lie.
      if (item && previousName !== undefined) item.name = previousName
      console.error('[workspacesStore.updateKanbanItemName] API call failed:', err)
      throw err
    }
  }

  // Fetch the columns for a kanban from the backend and populate `item.kanban_columns`. Called when
  // a kanban item is expanded (mirrors the folder-item `fetchFolderContents` pattern).
  async function fetchKanbanColumns(workspaceId: string, itemId: string): Promise<void> {
    const item = findItem(workspaceId, itemId)
    if (!item) return
    try {
      const { columns } = await api.listKanbanColumns(workspaceId, itemId)
      // Sort defensively (the backend already orders by position, but
      // a stale local snapshot from before a backend reorder would
      // otherwise keep the old ordering).
      item.kanban_columns = [...columns].sort((a, b) => a.position - b.position)
    } catch (err) {
      console.error('[workspacesStore.fetchKanbanColumns] API call failed:', err)
      // Leave whatever columns we have (or undefined) so the UI can
      // show an empty-state rather than a hard error.
    }
  }

  // Add a column to a kanban and append it to the local item's `kanban_columns` array, sorted by
  // position. The backend returns the column with its server-assigned id and position.
  async function addKanbanColumn(
    workspaceId: string,
    itemId: string,
    name: string,
    description: string = '',
  ): Promise<void> {
    const col = await api.addKanbanColumn(workspaceId, itemId, name, description)
    const item = findItem(workspaceId, itemId)
    if (item) {
      item.kanban_columns = [...(item.kanban_columns ?? []), col].sort(
        (a, b) => a.position - b.position,
      )
    }
  }

  // Patch a kanban column's name, description, and/or position.
  async function updateKanbanColumn(
    workspaceId: string,
    itemId: string,
    columnId: string,
    patch: { name?: string; description?: string; position?: number; is_done?: boolean },
  ): Promise<void> {
    const result = await api.updateKanbanColumn(workspaceId, itemId, columnId, patch)
    const item = findItem(workspaceId, itemId)
    if (!item) return
    // Mirror the backend's full board — replaces the previous `item.kanban_columns[i] = result`
    // bug, which corrupted the single-column slot with the `{columns, count}` envelope and made
    // every UI field on the saved column read as undefined.
    item.kanban_columns = [...result.columns].sort((a, b) => a.position - b.position)
  }

  // Copy the column spec from `sourceItemId` to `targetItemId`. Destructive for the target in
  // 'replace' mode (existing columns are deleted via the backend's `deleteColumn` path which
  // unassigns tasks).
  async function copyKanbanSpecFrom(
    workspaceId: string,
    targetItemId: string,
    sourceItemId: string,
    mode: 'replace' | 'append' = 'replace',
  ): Promise<void> {
    const result = await api.copyKanbanSpec(workspaceId, targetItemId, sourceItemId, mode)
    const item = findItem(workspaceId, targetItemId)
    if (!item) return
    item.kanban_columns = [...result.columns].sort((a, b) => a.position - b.position)
  }

  // Reorder a kanban column via drag-and-drop.
  async function reorderKanbanColumn(
    workspaceId: string,
    itemId: string,
    columnId: string,
    targetColumnId: string,
  ): Promise<void> {
    const item = findItem(workspaceId, itemId)
    if (!item?.kanban_columns) return
    const target = item.kanban_columns.find((c) => c.id === targetColumnId)
    if (!target) return
    // PATCH the moved column to the target's position. The backend's reorderColumn shifts the
    // siblings (dense renumber) and returns the moved column's NEW position; we ignore the return
    // value because we'll re-fetch the whole list next.
    await api.updateKanbanColumn(workspaceId, itemId, columnId, {
      position: target.position,
    })
    // Re-fetch so local state matches the backend's renumbered
    // sibling positions.
    await fetchKanbanColumns(workspaceId, itemId)
  }

  // Delete a kanban column. The backend unassigns tasks in the column (sets kanban_column_id to
  // NULL) — we mirror that by clearing `kanban_column_id` on any matching tasks in the local store
  // so the "Unassigned" view is consistent.
  async function deleteKanbanColumn(
    workspaceId: string,
    itemId: string,
    columnId: string,
  ): Promise<void> {
    await api.deleteKanbanColumn(workspaceId, itemId, columnId)
    const item = findItem(workspaceId, itemId)
    if (item) {
      item.kanban_columns = (item.kanban_columns ?? []).filter((c) => c.id !== columnId)
      // Mirror the backend's NULL-unassign for tasks in the column.
      if (item.tasks) {
        const unassigned: Task[] = []
        for (const t of item.tasks) {
          if (t.kanban_column_id === columnId) {
            t.kanban_column_id = null
            unassigned.push(t)
          }
        }
        for (const t of unassigned) {
          await removeTaskFromCache(workspaceId, itemId, t.id, columnId)
          await cacheTaskMutation(workspaceId, itemId, t)
        }
      }
    }
  }

  return {
    updateKanbanItemPath,
    updateKanbanItemName,
    fetchKanbanColumns,
    addKanbanColumn,
    updateKanbanColumn,
    copyKanbanSpecFrom,
    reorderKanbanColumn,
    deleteKanbanColumn,
  }
}
