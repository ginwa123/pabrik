import { API_BASE, ApiError, apiFetch } from './client'
import { MARKDOWN_FORMAT } from '../helpers/officeDocument'

// ─── Documents (Migration 095) ───────────────────────────────────────────
export interface Document {
  id: string
  workspace_id: string
  title: string
  /** The markdown body. */
  content?: string
  /** The first ~512 bytes of the body. */
  preview?: string
  /** Body length in bytes, so a row can be sized without reading it. */
  content_bytes?: number
  /** `'markdown'` (a text body) or `'office'` (a Univer snapshot envelope). */
  format: string
  created_at: string
  updated_at: string
  position: number
  /** The folder this document sits in; `null` (or absent, in a row cached before Migration 140) means the root of the section. */
  folder_id?: string | null
  /** Migration 148 — the document's own glyph name, or null/absent for "no override" (the row then draws `file`). */
  icon?: string | null
}

/** One folder in the documents tree (Migration 140). */
export interface DocumentFolder {
  id: string
  workspace_id: string
  parent_id: string | null
  name: string
  position: number
  /** Migration 148 — the folder's own glyph name, or null/absent for "no override" (the row then draws `folder` / `folder-open`). */
  icon?: string | null
}

/** GET /api/workspaces/:workspaceId/documents All documents in one workspace in the saved sidebar order. */
export async function listDocuments(
  workspaceId: string,
  opts: { includeContent?: boolean } = {},
): Promise<{
  documents: Document[]
  /** Absent against a server older than Migration 140; the store then paints every document at the root. */
  folders?: DocumentFolder[]
  count: number
  folder_count?: number
}> {
  const query = opts.includeContent ? '?include=content' : ''
  return await apiFetch<{
    documents: Document[]
    folders?: DocumentFolder[]
    count: number
    folder_count?: number
  }>(`/workspaces/${encodeURIComponent(workspaceId)}/documents${query}`, { track: false })
}

/** GET /api/workspaces/:workspaceId/documents/:documentId Returns 404 for an id that does not exist AND for one that belongs to another workspace — the backend … */
export async function getDocument(
  workspaceId: string,
  documentId: string,
): Promise<{ document: Document }> {
  return await apiFetch<{ document: Document }>(
    `/workspaces/${encodeURIComponent(workspaceId)}/documents/${encodeURIComponent(documentId)}`,
    { track: false },
  )
}

/** POST /api/workspaces/:workspaceId/documents Body: `{ title, content?, format?, folder_id? }`. */
export async function createDocument(
  workspaceId: string,
  title: string,
  content = '',
  folderId: string | null = null,
  format: string = MARKDOWN_FORMAT,
): Promise<{ document: Document }> {
  const body: Record<string, unknown> = { title, content }
  // The default is omitted rather than sent: the server already defaults to markdown, and a body that names only what it changes is easier to read.
  if (format !== MARKDOWN_FORMAT) body.format = format
  // `folder_id` is omitted at the root: the column is nullable and an absent key is the documented "top level" body shape.
  if (folderId) body.folder_id = folderId

  return await apiFetch<{ document: Document }>(
    `/workspaces/${encodeURIComponent(workspaceId)}/documents`,
    { method: 'POST', body },
  )
}

/** PATCH /api/workspaces/:workspaceId/documents/:documentId Partial update. */
export async function updateDocument(
  workspaceId: string,
  documentId: string,
  patch: {
    title?: string
    content?: string
    folder_id?: string | null
    /** A glyph name sets the override, `null` clears it. */
    icon?: string | null
  },
): Promise<{ document: Document }> {
  return await apiFetch<{ document: Document }>(
    `/workspaces/${encodeURIComponent(workspaceId)}/documents/${encodeURIComponent(documentId)}`,
    { method: 'PATCH', body: patch },
  )
}

/** Renumber ONE level: `folderId` null is the root. */
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

/** PATCH /api/workspaces/:workspaceId/document-folders/:folderId Renames when `name` is given; `parent_id` present (even null) moves the folder. */
export async function updateFolder(
  workspaceId: string,
  folderId: string,
  patch: {
    name?: string
    parent_id?: string | null
    /** A glyph name sets the override, `null` clears it. */
    icon?: string | null
  },
): Promise<{ folder: DocumentFolder }> {
  return await apiFetch<{ folder: DocumentFolder }>(
    `/workspaces/${encodeURIComponent(workspaceId)}/document-folders/${encodeURIComponent(folderId)}`,
    { method: 'PATCH', body: patch },
  )
}

/** DELETE /api/workspaces/:workspaceId/document-folders/:folderId Deletes the folder only: its children move one level up and the count says how many. */
export async function deleteFolder(
  workspaceId: string,
  folderId: string,
): Promise<{ id: string; success: boolean; reparented_documents: number }> {
  return await apiFetch<{ id: string; success: boolean; reparented_documents: number }>(
    `/workspaces/${encodeURIComponent(workspaceId)}/document-folders/${encodeURIComponent(folderId)}`,
    { method: 'DELETE' },
  )
}

/** DELETE /api/workspaces/:workspaceId/documents/:documentId Returns 404 for another workspace's id, and deletes nothing in that case. */
export async function deleteDocument(
  workspaceId: string,
  documentId: string,
): Promise<{ id: string; success: boolean }> {
  return await apiFetch<{ id: string; success: boolean }>(
    `/workspaces/${encodeURIComponent(workspaceId)}/documents/${encodeURIComponent(documentId)}`,
    { method: 'DELETE' },
  )
}

/** The URL one document exports from. */
export function exportDocumentUrl(workspaceId: string, documentId: string): string {
  return `${API_BASE}/workspaces/${encodeURIComponent(workspaceId)}/documents/${encodeURIComponent(documentId)}/export`
}

/** The name a download should be saved under, read from a `Content-Disposition` header. */
export function filenameFromDisposition(header: string | null, fallback: string): string {
  if (!header) return fallback

  const encoded = /filename\*=UTF-8''([^;]+)/i.exec(header)
  if (encoded?.[1]) {
    const decoded = decodeURIComponent(encoded[1].trim())
    if (decoded.length > 0) return decoded
  }

  const plain = /filename="([^"]*)"/i.exec(header) ?? /filename=([^;]+)/i.exec(header)
  const name = plain?.[1]?.trim()
  return name && name.length > 0 ? name : fallback
}

export interface ExportedDownload {
  blob: Blob
  /** The name the server chose, or `fallback` when it named none. */
  filename: string
}

/** One document, as a downloadable file. */
export async function exportDocument(
  workspaceId: string,
  documentId: string,
  fallbackName = 'document',
): Promise<ExportedDownload> {
  const response = await fetch(exportDocumentUrl(workspaceId, documentId))
  if (!response.ok) {
    throw new ApiError(response.status, response.statusText, await response.text().catch(() => ''))
  }
  return {
    blob: await response.blob(),
    filename: filenameFromDisposition(response.headers.get('Content-Disposition'), fallbackName),
  }
}

/** Several documents, as one zip. */
export async function exportDocuments(
  workspaceId: string,
  documentIds: string[],
  fallbackName = 'documents.zip',
): Promise<ExportedDownload> {
  const response = await fetch(`${API_BASE}/workspaces/${encodeURIComponent(workspaceId)}/documents/export`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ document_ids: documentIds }),
  })
  if (!response.ok) {
    throw new ApiError(response.status, response.statusText, await response.text().catch(() => ''))
  }
  return {
    blob: await response.blob(),
    filename: filenameFromDisposition(response.headers.get('Content-Disposition'), fallbackName),
  }
}
