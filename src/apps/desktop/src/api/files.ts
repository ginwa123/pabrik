import { getCurrentWorkspaceId } from '../helpers/workspaceScope'
import { API_BASE, apiFetch } from './core'

// Types matching backend responses
export interface FolderEntry {
  name: string
  path: string
  is_directory: boolean
  is_symlink: boolean
}

export interface FolderInfo {
  path: string
  absolute: string
  home: string
  parent?: string
  entries: FolderEntry[]
}

// System Folder API
export async function getSystemFolder(workspaceId?: string): Promise<FolderInfo> {
  return await apiFetch<FolderInfo>(`/system/folder?action=list${workspaceQuery(workspaceId)}`)
}

export async function listFolder(path: string, workspaceId?: string): Promise<FolderInfo> {
  return await apiFetch<FolderInfo>(
    `/system/folder?path=${encodeURIComponent(path)}&action=list${workspaceQuery(workspaceId)}`,
  )
}

/** The `workspace_id` a folder request carries: SaaS mode lists a workspace's
 *  VM, so a request that does not say which workspace it means is refused.
 *  The app shows one workspace at a time — the current one, unless named. */
function workspaceQuery(workspaceId?: string): string {
  const id = workspaceId || getCurrentWorkspaceId()
  return id ? `&workspace_id=${encodeURIComponent(id)}` : ''
}

/**  * Server-side recursive file search for the ChatView `@` picker. One round-trip replaces the old
 * N-sequential-fetch full-tree walk; uses `apiFetch` for timeout/auth handling. */
export async function searchFiles(
  cwd: string,
  q: string,
  limit = 50,
  max_depth = 8,
  signal?: AbortSignal,
): Promise<{ entries: FolderEntry[] }> {
  return await apiFetch<{ entries: FolderEntry[] }>(
    `/system/folder?path=${encodeURIComponent(cwd)}&action=search&q=${encodeURIComponent(q)}&limit=${limit}&max_depth=${max_depth}${workspaceQuery()}`,
    { signal, silent: true },
  )
}

// File listing for autocomplete
export async function listFiles(cwd: string, dirPath?: string): Promise<string[]> {
  try {
    const targetPath = dirPath || cwd
    const data = await apiFetch<{ entries: FolderEntry[] }>(
      `/system/folder?path=${encodeURIComponent(targetPath)}&action=list${workspaceQuery()}`,
    )
    // Return names sorted, directories first
    const entries = data.entries || []
    return entries
      .map((e: FolderEntry) => e.name)
      .sort((a: string, b: string) => {
        const aIsDir = entries.find((e: FolderEntry) => e.name === a)?.is_directory
        const bIsDir = entries.find((e: FolderEntry) => e.name === b)?.is_directory
        if (aIsDir && !bIsDir) return -1
        if (!aIsDir && bIsDir) return 1
        return a.localeCompare(b)
      })
  } catch (error) {
    console.error('Failed to list files:', error)
    return []
  }
}

// Read file content API (for CodeEditor)
export interface ReadFileResponse {
  content: string
  encoding: string
}

export async function readFileContent(cwd: string, filePath: string): Promise<ReadFileResponse> {
  // silent: true — AppLayout shows a fullscreen error view in the
  // code editor; a toast on every read failure would be redundant noise.
  return await apiFetch<ReadFileResponse>(
    `/system/folder?path=${encodeURIComponent(cwd)}&action=read&file=${encodeURIComponent(filePath)}`,
    { silent: true },
  )
}

// File download URL builders for the `present_files` agent tool card (PresentFiles.vue).
export function fileDownloadUrl(
  sessionId: string,
  filePath: string,
  disposition: 'inline' | 'attachment' = 'attachment',
): string {
  return `${API_BASE}/files/download?session_id=${encodeURIComponent(sessionId)}&path=${encodeURIComponent(filePath)}&disposition=${disposition}`
}
