/** The pure half of the documents tree: how a level orders itself, how a cycle
 * is recognised, and how the folder cache is read and written. Kept out of the
 * store so the store stays about state and requests. */
import type { Document, DocumentFolder } from '../api'

export type TreeEntry =
  { kind: 'folder'; folder: DocumentFolder } | { kind: 'document'; document: Document }

const FOLDER_CACHE_PREFIX = 'pabrik.documents.folders.'

export function folderCacheKey(workspaceId: string): string {
  return FOLDER_CACHE_PREFIX + workspaceId
}

/** Within one level: folders first, then documents, each in saved order. The
 * backend keeps two ordering spaces, so this merge rule lives here only. */
export function mergeLevel(
  folders: DocumentFolder[],
  documents: Document[],
  parentId: string | null,
): TreeEntry[] {
  const levelFolders = folders
    .filter((f) => f.parent_id === parentId)
    .sort((a, b) => a.position - b.position || a.name.localeCompare(b.name))
    .map((folder) => ({ kind: 'folder' as const, folder }))
  const levelDocuments = documents
    .filter((d) => (d.folder_id ?? null) === parentId)
    .sort((a, b) => a.position - b.position || (a.updated_at < b.updated_at ? 1 : -1))
    .map((document) => ({ kind: 'document' as const, document }))
  return [...levelFolders, ...levelDocuments]
}

/** True when `candidateId` sits at or below `ancestorId`, so a cycle can be
 * refused before any request is sent. Mirrors the server's own rule. */
export function isAtOrBelow(
  folders: DocumentFolder[],
  ancestorId: string,
  candidateId: string,
): boolean {
  const parents = new Map(folders.map((f) => [f.id, f.parent_id]))
  let current: string | null = candidateId
  let steps = 0
  while (current && steps <= folders.length) {
    if (current === ancestorId) return true
    current = parents.get(current) ?? null
    steps += 1
  }
  return false
}

/** The folder names from the root down: `Split bill` inside
 * `Sales debit note` reads `['Sales debit note', 'Split bill']`. */
export function folderPath(folders: DocumentFolder[], folderId: string | null): string[] {
  const byId = new Map(folders.map((f) => [f.id, f]))
  const path: string[] = []
  let current = folderId ? byId.get(folderId) : undefined
  let steps = 0
  while (current && steps <= folders.length) {
    path.unshift(current.name)
    current = current.parent_id ? byId.get(current.parent_id) : undefined
    steps += 1
  }
  return path
}

/** A cold boot paints the placement the last session saw; the revalidate that
 * follows is the source of truth, so a cache miss is an empty answer, not an
 * error. */
export function readCachedFolders(workspaceId: string): DocumentFolder[] {
  try {
    const raw = globalThis.localStorage?.getItem(folderCacheKey(workspaceId))
    if (!raw) return []
    const parsed: unknown = JSON.parse(raw)
    return Array.isArray(parsed) ? (parsed as DocumentFolder[]) : []
  // eslint-disable-next-line local/no-try-catch, local/no-silent-fallback-catch -- a cache read cannot fail the caller, and an empty cache is a real answer
  } catch {
    return []
  }
}

export function writeCachedFolders(workspaceId: string, folders: DocumentFolder[]): void {
  try {
    globalThis.localStorage?.setItem(folderCacheKey(workspaceId), JSON.stringify(folders))
  // eslint-disable-next-line local/no-try-catch, local/no-silent-fallback-catch -- the in-memory tree is already correct; the next list read rewrites this
  } catch {}
}
