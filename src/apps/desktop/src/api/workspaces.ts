import { apiFetch } from './core'
import type { FolderEntry } from './files'
import type { KanbanColumn } from './kanban'
import type { Task } from './tasks'

export interface Workspace {
  id: string
  name: string
  icon: string
  items: WorkspaceItem[]
  // Server-side item count, present on GET /api/workspaces rows even
  // when `is_include_items=false` (items stay `[]` until lazily
  // loaded) — keeps count badges truthful for unvisited workspaces.
  items_count?: number
  // Whether the workspace's work runs in a microVM on this server. False on
  // a local server (no Firecracker at all), true for the VM-backed workspaces
  // of a `--saas` server.
  is_vm?: boolean
  expanded: boolean
}

export interface WorkspaceItem {
  id: string
  name: string
  item_type: string
  // The on-disk cwd for kanban items. Optional: legacy kanbans predate the field, folder items keep
  // their path on each child, and test fixtures omit it. `null` is allowed so the SQLite NULL →
  // JSON null round-trip type-checks; `v-if="!item.path"` treats null/undefined/"" alike.
  path?: string | null
  entries?: FolderEntry[]
  isLoaded?: boolean
  isLoading?: boolean
  expanded?: boolean
  tasks?: Task[]
  // NEW (Chunk 4 of workspace-item-kanban plan). Populated for
  // `item_type === 'kanban'`, omitted otherwise. Optional so legacy
  // workspace-item literals in tests keep type-checking.
  kanban_columns?: KanbanColumn[]
}

// Workspace API
export async function getWorkspaces(): Promise<{ workspaces: Workspace[] }> {
  // Items are loaded separately via getWorkspacesItems(workspace_id) — this keeps the workspaces
  // list small and lets us fetch items lazily. Persists the list to the workspacesCache
  // (fail-silent) so the next init can paint instantly and revalidate in the background.
  const res = await apiFetch<{ workspaces: Workspace[] }>('/workspaces?is_include_items=false')
  try {
    const { writeWorkspacesCache } = await import('../helpers/workspacesCache')
    writeWorkspacesCache(res?.workspaces ?? [])
  } catch {
    // cache write is best-effort — the live response still wins.
  }
  return res
}

export async function getWorkspacesItems(
  workspace_id: string,
): Promise<{ items: WorkspaceItem[]; count: number }> {
  return await apiFetch<{ items: WorkspaceItem[]; count: number }>(
    `/workspaces/${workspace_id}/items`,
  )
}

// Cold-start fallback for the "New Chat" action. This endpoint covers the one case the list cannot:
// the app was open when Migration 094 ran, so the store's list predates `is_default`.
export async function getOrCreateDefaultProject(
  workspace_id: string,
): Promise<{ item: WorkspaceItem; created: boolean }> {
  return await apiFetch<{ item: WorkspaceItem; created: boolean }>(
    `/workspaces/${workspace_id}/default-project`,
    { method: 'POST' },
  )
}

export async function createWorkspace(name: string): Promise<Workspace> {
  return await apiFetch<Workspace>('/workspaces', {
    method: 'POST',
    body: { name },
  })
}

export async function getWorkspace(id: string): Promise<Workspace> {
  return await apiFetch<Workspace>(`/workspaces/${id}`)
}

export async function deleteWorkspace(id: string): Promise<{ success: boolean }> {
  return await apiFetch<{ success: boolean }>(`/workspaces/${id}`, {
    method: 'DELETE',
  })
}

export async function updateWorkspace(id: string, data: Partial<Workspace>): Promise<Workspace> {
  return await apiFetch<Workspace>(`/workspaces/${id}`, {
    method: 'PUT',
    body: data,
  })
}

/** Persist a new top-to-bottom display order for workspaces. POST /api/workspaces/reorder
 * with body `{ordered_ids: [...]}`. The server reverses the array (top of list = highest
 * position) and throws on non-2xx so the caller can roll back its optimistic update. */
export async function reorderWorkspaces(
  orderedIds: string[],
): Promise<{ success: boolean; count: number }> {
  return await apiFetch<{ success: boolean; count: number }>('/workspaces/reorder', {
    method: 'POST',
    body: { ordered_ids: orderedIds },
  })
}

/** Persist a new top-to-bottom display order for one workspace's items. POST
 * /api/workspaces/:workspace_id/items/reorder with body `{ordered_ids: [...]}`. Mirrors
 * `reorderWorkspaces` but scoped to a single workspace; the list is the full ordered set. */
export async function reorderWorkspaceItems(
  workspaceId: string,
  orderedIds: string[],
): Promise<{ success: boolean; count: number }> {
  return await apiFetch<{ success: boolean; count: number }>(
    `/workspaces/${encodeURIComponent(workspaceId)}/items/reorder`,
    {
      method: 'POST',
      body: { ordered_ids: orderedIds },
    },
  )
}

// Workspace Item API
export async function createWorkspaceItem(
  workspaceId: string,
  name: string,
  path: string,
  itemType: string = 'folder',
): Promise<WorkspaceItem> {
  return await apiFetch<WorkspaceItem>(`/workspaces/${workspaceId}/items`, {
    method: 'POST',
    body: { name, path, item_type: itemType },
  })
}

/** Create a new design workspace item (`item_type='design'`). The `path` is REQUIRED because design
 * elements live as HTML files under `<path>/.pabrik/design/...` (the model layer rejects
 * element-add with `ItemPathMissing` if path is NULL — see design_model.zig). */
export async function createDesign(
  workspaceId: string,
  name: string,
  path: string,
): Promise<WorkspaceItem> {
  return await apiFetch<WorkspaceItem>(`/workspaces/${workspaceId}/items/design`, {
    method: 'POST',
    body: { name, path },
  })
}

export async function deleteWorkspaceItem(
  workspaceId: string,
  itemId: string,
): Promise<{ success: boolean }> {
  return await apiFetch<{ success: boolean }>(`/workspaces/${workspaceId}/items/${itemId}`, {
    method: 'DELETE',
  })
}

/** Update a workspace item. Supports partial updates — pass only the fields you want to change.
 * Fields: - `item_type`: new type (kanban / folder / chat / memory). */
export async function updateWorkspaceItem(
  workspaceId: string,
  itemId: string,
  data: {
    item_type?: string
    path?: string | null
    name?: string
  },
): Promise<WorkspaceItem> {
  return await apiFetch<WorkspaceItem>(`/workspaces/${workspaceId}/items/${itemId}`, {
    method: 'PUT',
    body: data,
  })
}
