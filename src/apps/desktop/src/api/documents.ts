import { apiFetch } from './client'

// ─── Documents (Migration 095) ─────────────────────────────────────────── Workspace-scoped
// markdown documents. A document belongs to a workspace directly — it is NOT a `workspace_items`
// row and never appears in the project tree; the sidebar's Documents section is its only home.
export interface Document {
  id: string
  workspace_id: string
  title: string
  /** The markdown body. Always a string — the backend flattens SQL NULL to
   * `''`, so there is no null case to handle here. */
  content: string
  /** `'markdown'` in v1. Reserved for future formats. */
  format: string
  created_at: string
  updated_at: string
  position: number
}

/**  * GET /api/workspaces/:workspaceId/documents All documents in one workspace in the saved sidebar
 * order. Backs the sidebar's Documents section, so it runs on every sidebar load. */
export async function listDocuments(
  workspaceId: string,
): Promise<{ documents: Document[]; count: number }> {
  return await apiFetch<{ documents: Document[]; count: number }>(
    `/workspaces/${encodeURIComponent(workspaceId)}/documents`,
    { track: false },
  )
}

/**  * GET /api/workspaces/:workspaceId/documents/:documentId Returns 404 for an id that does not exist
 * AND for one that belongs to another workspace — the backend reports both identically so this call
 * cannot be used to probe another workspace's row ids. */
export async function getDocument(
  workspaceId: string,
  documentId: string,
): Promise<{ document: Document }> {
  return await apiFetch<{ document: Document }>(
    `/workspaces/${encodeURIComponent(workspaceId)}/documents/${encodeURIComponent(documentId)}`,
    { track: false },
  )
}

/** POST /api/workspaces/:workspaceId/documents Body: `{ title, content?, format? }`. `title` is
 * required and must be non-blank; `content` may be empty (a blank note is a legitimate starting
 * state and round-trips as `''` rather than tripping the column's NOT NULL). */
export async function createDocument(
  workspaceId: string,
  title: string,
  content = '',
): Promise<{ document: Document }> {
  return await apiFetch<{ document: Document }>(
    `/workspaces/${encodeURIComponent(workspaceId)}/documents`,
    { method: 'POST', body: { title, content } },
  )
}

/**  * PATCH /api/workspaces/:workspaceId/documents/:documentId Partial update. An OMITTED field keeps
 * its current value; `content: ''` genuinely clears the body. Omitting `content` does not clear it
 * — the two are different and the backend treats them differently. */
export async function updateDocument(
  workspaceId: string,
  documentId: string,
  patch: { title?: string; content?: string },
): Promise<{ document: Document }> {
  return await apiFetch<{ document: Document }>(
    `/workspaces/${encodeURIComponent(workspaceId)}/documents/${encodeURIComponent(documentId)}`,
    { method: 'PATCH', body: patch },
  )
}

export async function reorderDocuments(
  workspaceId: string,
  orderedIds: string[],
): Promise<{ documents: Document[]; count: number }> {
  return await apiFetch<{ documents: Document[]; count: number }>(
    `/workspaces/${encodeURIComponent(workspaceId)}/documents/reorder`,
    { method: 'PATCH', body: { ordered_ids: orderedIds } },
  )
}

/**  * DELETE /api/workspaces/:workspaceId/documents/:documentId Returns 404 for another workspace's id,
 * and deletes nothing in that case. */
export async function deleteDocument(
  workspaceId: string,
  documentId: string,
): Promise<{ id: string; success: boolean }> {
  return await apiFetch<{ id: string; success: boolean }>(
    `/workspaces/${encodeURIComponent(workspaceId)}/documents/${encodeURIComponent(documentId)}`,
    { method: 'DELETE' },
  )
}
