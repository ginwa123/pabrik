import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { createPinia, setActivePinia } from 'pinia'

import {
  createWorkspaceMemory,
  deleteWorkspaceMemory,
  getWorkspaceMemory,
  listWorkspaceMemories,
} from '../api'

describe('api.workspaceMemories', () => {
  const originalFetch = global.fetch
  const fetchMock = vi.fn()

  beforeEach(() => {
    setActivePinia(createPinia())
  })

  afterEach(() => {
    fetchMock.mockReset()
    global.fetch = originalFetch
  })

  function mockFetchOnce(status: number, body: unknown) {
    fetchMock.mockResolvedValueOnce({
      ok: status >= 200 && status < 300,
      status,
      json: () => Promise.resolve(body),
      text: () => Promise.resolve(JSON.stringify(body)),
    } as Response)
    global.fetch = fetchMock as unknown as typeof fetch
  }

  function lastUrl(): string {
    return (fetchMock.mock.calls[0] as [string])[0]
  }

  function lastInit(): RequestInit {
    return (fetchMock.mock.calls[0] as [string, RequestInit])[1]
  }

  it('lists a workspace memories from the workspace-scoped route', async () => {
    mockFetchOnce(200, {
      workspace_id: 'ws_1',
      query: '',
      memories: [
        {
          id: 'mem_1',
          content: 'the deploy target is staging',
          tags: ['ops'],
          created_at: '2026-11-01 10:00:00',
          updated_at: '2026-11-01 10:00:00',
        },
      ],
      total_count: 1,
      limit: 50,
      offset: 0,
    })

    const result = await listWorkspaceMemories('ws_1')

    expect(lastUrl()).toBe('/api/workspaces/ws_1/memories')
    expect(result.memories).toHaveLength(1)
    expect(result.memories[0]!.content).toBe('the deploy target is staging')
    expect(result.total_count).toBe(1)
  })

  it('sends the search term, the page size and the offset as query parameters', async () => {
    mockFetchOnce(200, {
      workspace_id: 'ws_1',
      query: 'deploy',
      memories: [],
      total_count: 0,
      limit: 10,
      offset: 20,
    })

    await listWorkspaceMemories('ws_1', { query: 'deploy', limit: 10, offset: 20 })

    const url = lastUrl()
    expect(url).toContain('q=deploy')
    expect(url).toContain('limit=10')
    expect(url).toContain('offset=20')
  })

  it('URL-encodes the workspace id and the memory id', async () => {
    mockFetchOnce(200, { memory: null })

    await getWorkspaceMemory('ws 1', 'mem/1')

    expect(lastUrl()).toBe('/api/workspaces/ws%201/memories/mem%2F1')
  })

  it('creates a memory with its body and tags', async () => {
    mockFetchOnce(201, {
      memory: {
        id: 'mem_2',
        content: 'cut releases on fridays',
        tags: ['ops', 'release'],
        created_at: '2026-11-02 09:00:00',
        updated_at: '2026-11-02 09:00:00',
      },
    })

    const result = await createWorkspaceMemory('ws_1', 'cut releases on fridays', [
      'ops',
      'release',
    ])

    expect(lastUrl()).toBe('/api/workspaces/ws_1/memories')
    expect(lastInit().method).toBe('POST')
    expect(JSON.parse(String(lastInit().body))).toEqual({
      content: 'cut releases on fridays',
      tags: ['ops', 'release'],
    })
    expect(result.memory.id).toBe('mem_2')
  })

  it('deletes a memory by id', async () => {
    mockFetchOnce(200, { success: true, id: 'mem_2' })

    const result = await deleteWorkspaceMemory('ws_1', 'mem_2')

    expect(lastUrl()).toBe('/api/workspaces/ws_1/memories/mem_2')
    expect(lastInit().method).toBe('DELETE')
    expect(result.success).toBe(true)
  })

  it('surfaces a 404 as an ApiError so the caller can show it', async () => {
    mockFetchOnce(404, { error: 'Memory not found' })

    await expect(deleteWorkspaceMemory('ws_1', 'mem_missing')).rejects.toThrow(/HTTP 404/)
  })
})
