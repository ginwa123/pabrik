import { apiFetch } from './client'

export interface WorkspaceMemory {
  id: string
  content: string
  tags: string[]
  created_at: string
  updated_at: string
}

export interface WorkspaceMemoryListResponse {
  workspace_id: string
  query: string
  memories: WorkspaceMemory[]
  total_count: number
  limit: number
  offset: number
}

export interface WorkspaceMemoryGetResponse {
  memory: WorkspaceMemory | null
}

export interface WorkspaceMemoryCreateResponse {
  memory: WorkspaceMemory
}

export interface WorkspaceMemoryDeleteResponse {
  success: boolean
  id: string
}

export interface ListWorkspaceMemoriesOptions {
  query?: string
  limit?: number
  offset?: number
}

function memoriesUrl(workspaceId: string, opts: ListWorkspaceMemoriesOptions = {}): string {
  const params = new URLSearchParams()
  if (opts.query) params.set('q', opts.query)
  if (opts.limit !== undefined) params.set('limit', String(opts.limit))
  if (opts.offset !== undefined) params.set('offset', String(opts.offset))
  const suffix = params.toString()
  const base = `/workspaces/${encodeURIComponent(workspaceId)}/memories`
  return suffix ? `${base}?${suffix}` : base
}

export async function listWorkspaceMemories(
  workspaceId: string,
  opts: ListWorkspaceMemoriesOptions = {},
): Promise<WorkspaceMemoryListResponse> {
  return await apiFetch<WorkspaceMemoryListResponse>(memoriesUrl(workspaceId, opts))
}

export async function getWorkspaceMemory(
  workspaceId: string,
  id: string,
): Promise<WorkspaceMemoryGetResponse> {
  return await apiFetch<WorkspaceMemoryGetResponse>(
    `/workspaces/${encodeURIComponent(workspaceId)}/memories/${encodeURIComponent(id)}`,
  )
}

export async function createWorkspaceMemory(
  workspaceId: string,
  content: string,
  tags: string[] = [],
): Promise<WorkspaceMemoryCreateResponse> {
  return await apiFetch<WorkspaceMemoryCreateResponse>(
    `/workspaces/${encodeURIComponent(workspaceId)}/memories`,
    { method: 'POST', body: { content, tags } },
  )
}

export async function deleteWorkspaceMemory(
  workspaceId: string,
  id: string,
): Promise<WorkspaceMemoryDeleteResponse> {
  return await apiFetch<WorkspaceMemoryDeleteResponse>(
    `/workspaces/${encodeURIComponent(workspaceId)}/memories/${encodeURIComponent(id)}`,
    { method: 'DELETE' },
  )
}
