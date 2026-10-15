/** Unit tests for the memories API client (getMemories, getMemoryDetail,
 * createMemory, updateMemory, deleteMemory). Mocks global.fetch to
 * assert URL, method, body shape, and error handling without hitting
 * the network. Mirrors apiDeleteProfile.spec.ts style. */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'

import {
  getMemories,
  getMemoryDetail,
  createMemory,
  updateMemory,
  deleteMemory,
} from '../api'

describe('api.memories', () => {
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

  describe('getMemories', () => {
    it('calls GET on /api/memories and returns the parsed body', async () => {
      mockFetchOnce(200, {
        memories: [
          { name: 'foo.md', title: 'Foo', path: '/home/x/.config/pabrik/memories/foo.md', size: 13 },
        ],
      })

      const result = await getMemories()

      expect(fetchMock).toHaveBeenCalledTimes(1)
      const [url] = fetchMock.mock.calls[0] as [string]
      expect(url).toContain('/api/memories')
      // GET is the default for fetch when no method is supplied
      expect(result.memories).toHaveLength(1)
      expect(result.memories[0]!.name).toBe('foo.md')
    })

    it('throws on non-2xx with the HTTP status', async () => {
      mockFetchOnce(500, { error: 'Missing environment' })
      await expect(getMemories()).rejects.toThrow(/HTTP 500/)
    })
  })

  describe('getMemoryDetail', () => {
    it('URL-encodes the name', async () => {
      mockFetchOnce(200, {
        memory: { name: 'a b.md', title: 'A b', path: '/x.md', size: 0, content: '' },
        error_message: null,
      })

      await getMemoryDetail('a b.md')

      const [url] = fetchMock.mock.calls[0] as [string, RequestInit]
      expect(url).toContain('/api/memories/a%20b.md')
    })

    it('returns structured response on 404', async () => {
      mockFetchOnce(404, { error: 'Memory not found' })

      const result = await getMemoryDetail('missing.md')

      expect(result.memory).toBeNull()
      expect(result.error_message).toBe('Memory not found')
    })

    it('throws on other non-2xx', async () => {
      mockFetchOnce(500, { error: 'oops' })
      await expect(getMemoryDetail('foo.md')).rejects.toThrow(/HTTP 500/)
    })
  })

  describe('createMemory', () => {
    it('POSTs JSON body to /api/memories and returns { memory }', async () => {
      mockFetchOnce(201, {
        memory: { name: 'new.md', title: 'New', path: '/x.md', size: 13 },
      })

      const result = await createMemory('new.md', '# New\n\nhello')

      const [url, init] = fetchMock.mock.calls[0] as [string, RequestInit]
      expect(url).toContain('/api/memories')
      expect(init.method).toBe('POST')
      const body = JSON.parse(init.body as string)
      expect(body).toEqual({ name: 'new.md', content: '# New\n\nhello' })
      expect(result.memory.name).toBe('new.md')
    })

    it('throws on 409 (duplicate) with the response body preserved on the ApiError', async () => {
      // After the apiFetch migration, the body is no longer in `err.message` (which is now `HTTP
      // 409`) — callers that want the body must read `err.body`. The toast notification also
      // surfaces the `error` field from the JSON body automatically.
      mockFetchOnce(409, { error: 'Memory already exists' })
      await expect(createMemory('dup.md', 'x')).rejects.toMatchObject({
        status: 409,
        body: expect.stringContaining('Memory already exists'),
      })
    })
  })

  describe('updateMemory', () => {
    it('PUTs JSON body to /api/memories/:name', async () => {
      mockFetchOnce(200, {
        memory: { name: 'foo.md', title: 'Foo', path: '/x.md', size: 7 },
      })

      const result = await updateMemory('foo.md', 'updated')

      const [url, init] = fetchMock.mock.calls[0] as [string, RequestInit]
      expect(url).toContain('/api/memories/foo.md')
      expect(init.method).toBe('PUT')
      const body = JSON.parse(init.body as string)
      expect(body).toEqual({ content: 'updated' })
      expect(result.memory.name).toBe('foo.md')
    })
  })

  describe('deleteMemory', () => {
    it('DELETEs /api/memories/:name and returns { success, name }', async () => {
      mockFetchOnce(200, { success: true, name: 'foo.md' })

      const result = await deleteMemory('foo.md')

      const [url, init] = fetchMock.mock.calls[0] as [string, RequestInit]
      expect(url).toContain('/api/memories/foo.md')
      expect(init.method).toBe('DELETE')
      expect(result.success).toBe(true)
      expect(result.name).toBe('foo.md')
    })
  })
})
