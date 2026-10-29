import { apiFetch } from './core'
import type { Task } from './tasks'
import type { WorkspaceItem } from './workspaces'

export interface KanbanColumn {
  id: string
  workspace_item_id: string
  name: string
  /**    * Free-text description of the column's meaning. Empty string when unset; the Settings UI renders
   * an "Add a description..." placeholder. Optional for backwards compat with legacy column
   * literals in test files. */
  description?: string | null
  position: number
  created_at: string
  // NEW (kanban task dependencies). `is_done` marks a column as
  // completing: cards here no longer block their dependents.
  is_done?: boolean
}

// Kanban API Backend endpoints (Chunk 3 of the workspace-item-kanban plan): POST
// /api/workspaces/:wsId/items/kanban → 201 GET /api/workspaces/:wsId/items/:itemId/kanban/columns →
// 200 POST /api/workspaces/:wsId/items/:itemId/kanban/columns → 201 PATCH.
export async function createKanban(
  workspaceId: string,
  name: string,
  path?: string,
): Promise<{ item: WorkspaceItem; columns: KanbanColumn[] }> {
  return await apiFetch<{ item: WorkspaceItem; columns: KanbanColumn[] }>(
    `/workspaces/${workspaceId}/items/kanban`,
    {
      method: 'POST',
      body: { name, path: path ?? '' },
    },
  )
}

/**  * List the kanban columns for a single workspace item, ordered by `position` ASC. GET
 * /api/workspaces/:workspaceId/items/:itemId/kanban/columns */
export async function listKanbanColumns(
  workspaceId: string,
  itemId: string,
): Promise<{ columns: KanbanColumn[]; count: number }> {
  return await apiFetch<{ columns: KanbanColumn[]; count: number }>(
    `/workspaces/${workspaceId}/items/${itemId}/kanban/columns`,
  )
}

/** Add a new column to a kanban. `position` is optional — when omitted the backend appends at the
 * end of the existing sequence (max(position)+1). Returns the newly-created column (with its
 * server-assigned `id` and `position`). */
export async function addKanbanColumn(
  workspaceId: string,
  itemId: string,
  name: string,
  description?: string,
  position?: number,
): Promise<KanbanColumn> {
  return await apiFetch<KanbanColumn>(`/workspaces/${workspaceId}/items/${itemId}/kanban/columns`, {
    method: 'POST',
    body: { name, description: description ?? '', position },
  })
}

/** Copy a kanban's column spec (names + descriptions, preserving order) from a source kanban to a
 * target kanban. Tasks are NOT copied — only the column "template". */
export async function copyKanbanSpec(
  workspaceId: string,
  targetItemId: string,
  sourceItemId: string,
  mode: 'replace' | 'append' = 'replace',
): Promise<{ columns: KanbanColumn[]; count: number }> {
  return await apiFetch<{ columns: KanbanColumn[]; count: number }>(
    `/workspaces/${workspaceId}/items/${targetItemId}/kanban/copy_spec_from/${sourceItemId}`,
    {
      method: 'POST',
      body: { mode },
    },
  )
}

/** Patch a kanban column. Both `name` and `position` are optional; pass only the fields you want to
 * change. The backend applies the patch and re-numbers sibling positions when `position` changes.
 * Returns the FULL updated board (`{columns, count}`) — same envelope as `listKanbanColumns`. */
export async function updateKanbanColumn(
  workspaceId: string,
  itemId: string,
  columnId: string,
  patch: { name?: string; description?: string; position?: number; is_done?: boolean },
): Promise<{ columns: KanbanColumn[]; count: number }> {
  return await apiFetch<{ columns: KanbanColumn[]; count: number }>(
    `/workspaces/${workspaceId}/items/${itemId}/kanban/columns/${columnId}`,
    {
      method: 'PATCH',
      body: patch,
    },
  )
}

/** Delete a kanban column. Tasks in the column are unassigned (kanban_column_id set to NULL) — they
 * remain visible in the folder-list view as "Unassigned". Idempotent: a 200 is returned whether the
 * column existed or not (handled by the backend). */
export async function deleteKanbanColumn(
  workspaceId: string,
  itemId: string,
  columnId: string,
): Promise<{ success: boolean }> {
  return await apiFetch<{ success: boolean }>(
    `/workspaces/${workspaceId}/items/${itemId}/kanban/columns/${columnId}`,
    { method: 'DELETE' },
  )
}

/** Move a task to a new column and position within that column. The backend's `moveTask` does the
 * move + sibling re-numbering in a single transaction. */
export async function moveTask(
  workspaceId: string,
  itemId: string,
  taskId: string,
  columnId: string,
  position: number,
  force?: boolean,
): Promise<Task> {
  // `force` rides the body only when truthy — the backend
  // defaults it to false, so omitting keeps old payloads intact.
  const body: Record<string, unknown> = { column_id: columnId, position }
  if (force) body.force = true
  return await apiFetch<Task>(`/workspaces/${workspaceId}/items/${itemId}/tasks/${taskId}/move`, {
    method: 'PATCH',
    body,
  })
}

export interface KanbanTagSuggestion {
  name: string
  count: number
  last_used_at: string | null
}

export interface KanbanTagSuggestionsResponse {
  tags: KanbanTagSuggestion[]
  has_more: boolean
}

export interface GetKanbanTagSuggestionsOptions {
  limit?: number
  offset?: number
}

export async function getKanbanTagSuggestions(
  workspaceId: string,
  itemId: string,
  options?: GetKanbanTagSuggestionsOptions,
): Promise<KanbanTagSuggestionsResponse> {
  const limit = options?.limit ?? 8
  const offset = options?.offset ?? 0
  // Defensive: empty args = no-op (returns empty + has_more=false).
  // Prevents 400s when the caller passes placeholder values during
  // the render tick (e.g. dialog opens before column is resolved).
  if (!workspaceId || !itemId) {
    return { tags: [], has_more: false }
  }
  const url = `/workspaces/${encodeURIComponent(workspaceId)}/items/${encodeURIComponent(itemId)}/kanban/tags?limit=${limit}&offset=${offset}`
  // Graceful degradation: a 5xx returns empty + has_more=false so a
  // broken server doesn't block the user from typing tags.
  try {
    const res = await apiFetch<KanbanTagSuggestionsResponse>(url, { method: 'GET' })
    return {
      tags: res.tags ?? [],
      has_more: res.has_more ?? false,
    }
  } catch {
    return { tags: [], has_more: false }
  }
}
