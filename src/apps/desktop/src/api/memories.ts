import { ApiError, apiFetch } from './core'

// Memories API
export interface Memory {
  name: string
  title: string
  path: string
  size: number
}

export interface MemoryDetail extends Memory {
  content: string
}

export interface MemoryDetailResponse {
  memory: MemoryDetail | null
  error_message: string | null
}

export interface MemoryDeleteResponse {
  success: boolean
  name: string
  error_message: string | null
}

export async function getMemories(): Promise<{ memories: Memory[] }> {
  return await apiFetch<{ memories: Memory[] }>('/memories')
}

export async function getMemoryDetail(name: string): Promise<MemoryDetailResponse> {
  try {
    return await apiFetch<MemoryDetailResponse>(`/memories/${encodeURIComponent(name)}`)
  } catch (err) {
    // Preserve the "404 = not found" semantics — the caller uses the returned shape to decide
    // whether to show a "create new memory" prompt vs. an error toast. apiFetch surfaces 404 as
    // ApiError, so we translate it back into the original { memory: null, error_message } shape.
    if (err instanceof ApiError && err.status === 404) {
      return { memory: null, error_message: 'Memory not found' }
    }
    throw err
  }
}

export async function createMemory(name: string, content: string): Promise<{ memory: Memory }> {
  return await apiFetch<{ memory: Memory }>('/memories', {
    method: 'POST',
    body: { name, content },
  })
}

export async function updateMemory(name: string, content: string): Promise<{ memory: Memory }> {
  return await apiFetch<{ memory: Memory }>(`/memories/${encodeURIComponent(name)}`, {
    method: 'PUT',
    body: { content },
  })
}

export async function deleteMemory(name: string): Promise<MemoryDeleteResponse> {
  return await apiFetch<MemoryDeleteResponse>(`/memories/${encodeURIComponent(name)}`, {
    method: 'DELETE',
  })
}

// Local Memories API (per-cwd memories at `<cwd>/.pabrik/memories/`).
/** Build the `cwd` query string for a local-memory request.
 * Returns the `?cwd=...` suffix, or `''` if `cwd` is empty. */
function cwdQuery(cwd?: string): string {
  if (!cwd) return ''
  const encoded = encodeURIComponent(cwd)
  return `?cwd=${encoded}`
}

export async function listLocalMemories(cwd?: string): Promise<{ memories: Memory[] }> {
  return await apiFetch<{ memories: Memory[] }>(`/local-memories${cwdQuery(cwd)}`)
}

export async function getLocalMemoryDetail(
  name: string,
  cwd?: string,
): Promise<MemoryDetailResponse> {
  try {
    return await apiFetch<MemoryDetailResponse>(
      `/local-memories/${encodeURIComponent(name)}${cwdQuery(cwd)}`,
    )
  } catch (err) {
    // Preserve the "404 = not found" semantics — the caller uses the returned shape to decide
    // whether to show a "create new memory" prompt vs. an error toast. apiFetch surfaces 404 as
    // ApiError, so we translate it back into the original { memory: null, error_message } shape.
    if (err instanceof ApiError && err.status === 404) {
      return { memory: null, error_message: 'Memory not found' }
    }
    throw err
  }
}

export async function createLocalMemory(
  name: string,
  content: string,
  cwd: string,
): Promise<{ memory: Memory }> {
  return await apiFetch<{ memory: Memory }>('/local-memories', {
    method: 'POST',
    body: { name, content, cwd },
  })
}

export async function updateLocalMemory(
  name: string,
  content: string,
  cwd?: string,
): Promise<{ memory: Memory }> {
  return await apiFetch<{ memory: Memory }>(
    `/local-memories/${encodeURIComponent(name)}${cwdQuery(cwd)}`,
    {
      method: 'PUT',
      body: { content, cwd },
    },
  )
}

export async function deleteLocalMemory(name: string, cwd?: string): Promise<MemoryDeleteResponse> {
  return await apiFetch<MemoryDeleteResponse>(
    `/local-memories/${encodeURIComponent(name)}${cwdQuery(cwd)}`,
    { method: 'DELETE' },
  )
}
