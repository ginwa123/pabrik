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
  /** The folder this document sits in; `null` (or absent, in a row cached
   * before Migration 140) means the root of the section. */
  folder_id?: string | null
}

/** One folder in the documents tree (Migration 140). `parent_id: null` is a
 * root folder; a folder's children are the folders and documents that point
 * at it. */
export interface DocumentFolder {
  id: string
  workspace_id: string
  parent_id: string | null
  name: string
  position: number
}

/**  * GET /api/workspaces/:workspaceId/documents All documents in one workspace in the saved sidebar
 * order. Backs the sidebar's Documents section, so it runs on every sidebar load. */
export async function listDocuments(
  workspaceId: string,
): Promise<{
  documents: Document[]
  /** Absent against a server older than Migration 140; the store then paints
   * every document at the root. */
  folders?: DocumentFolder[]
  count: number
  folder_count?: number
}> {
  return await apiFetch<{
    documents: Document[]
    folders?: DocumentFolder[]
    count: number
    folder_count?: number
  }>(`/workspaces/${encodeURIComponent(workspaceId)}/documents`, { track: false })
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
  folderId: string | null = null,
): Promise<{ document: Document }> {
  return await apiFetch<{ document: Document }>(
    `/workspaces/${encodeURIComponent(workspaceId)}/documents`,
    {
      method: 'POST',
      // `folder_id` is omitted at the root: the column is nullable and an
      // absent key is the documented "top level" body shape.
      body: folderId ? { title, content, folder_id: folderId } : { title, content },
    },
  )
}

/**  * PATCH /api/workspaces/:workspaceId/documents/:documentId Partial update. An OMITTED field keeps
 * its current value; `content: ''` genuinely clears the body. Omitting `content` does not clear it
 * — the two are different and the backend treats them differently. */
export async function updateDocument(
  workspaceId: string,
  documentId: string,
  patch: { title?: string; content?: string; folder_id?: string | null },
): Promise<{ document: Document }> {
  return await apiFetch<{ document: Document }>(
    `/workspaces/${encodeURIComponent(workspaceId)}/documents/${encodeURIComponent(documentId)}`,
    { method: 'PATCH', body: patch },
  )
}

/** Renumber ONE level: `folderId` null is the root. Sibling order is per
 * level, so the level is part of the request, not an inference. */
export async function reorderDocuments(
  workspaceId: string,
  folderId: string | null,
  orderedIds: string[],
): Promise<{ documents: Document[]; folders: DocumentFolder[]; count: number }> {
  return await apiFetch<{ documents: Document[]; folders: DocumentFolder[]; count: number }>(
    `/workspaces/${encodeURIComponent(workspaceId)}/documents/reorder`,
    { method: 'PATCH', body: { folder_id: folderId, ordered_ids: orderedIds } },
  )
}

/** POST /api/workspaces/:workspaceId/document-folders */
export async function createFolder(
  workspaceId: string,
  name: string,
  parentId: string | null = null,
): Promise<{ folder: DocumentFolder }> {
  return await apiFetch<{ folder: DocumentFolder }>(
    `/workspaces/${encodeURIComponent(workspaceId)}/document-folders`,
    { method: 'POST', body: { name, parent_id: parentId } },
  )
}

/** PATCH /api/workspaces/:workspaceId/document-folders/:folderId Renames when
 * `name` is given; `parent_id` present (even null) moves the folder. */
export async function updateFolder(
  workspaceId: string,
  folderId: string,
  patch: { name?: string; parent_id?: string | null },
): Promise<{ folder: DocumentFolder }> {
  return await apiFetch<{ folder: DocumentFolder }>(
    `/workspaces/${encodeURIComponent(workspaceId)}/document-folders/${encodeURIComponent(folderId)}`,
    { method: 'PATCH', body: patch },
  )
}

/** DELETE /api/workspaces/:workspaceId/document-folders/:folderId Deletes the
 * folder only: its children move one level up and the count says how many. */
export async function deleteFolder(
  workspaceId: string,
  folderId: string,
): Promise<{ id: string; success: boolean; reparented_documents: number }> {
  return await apiFetch<{ id: string; success: boolean; reparented_documents: number }>(
    `/workspaces/${encodeURIComponent(workspaceId)}/document-folders/${encodeURIComponent(folderId)}`,
    { method: 'DELETE' },
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
