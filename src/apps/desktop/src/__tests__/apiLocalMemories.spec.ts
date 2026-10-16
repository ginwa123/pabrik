/** Unit tests for the LOCAL memories API client (listLocalMemories, getLocalMemoryDetail,
 * createLocalMemory, updateLocalMemory, deleteLocalMemory). Mocks global.fetch to assert URL,
 * method, body shape, and the cwd query/body parameter handling without hitting the network. */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'

import {
  listLocalMemories,
  getLocalMemoryDetail,
  createLocalMemory,
  updateLocalMemory,
  deleteLocalMemory,
} from '../api'

describe('api.localMemories', () => {
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

  describe('listLocalMemories', () => {
    it('calls GET on /api/local-memories with cwd query param', async () => {
      mockFetchOnce(200, {
        memories: [
          { name: 'foo.md', title: 'Foo', path: '/proj/.pabrik/memories/foo.md', size: 13 },
        ],
      })

      const result = await listLocalMemories('/proj')

      expect(fetchMock).toHaveBeenCalledTimes(1)
      const [url] = fetchMock.mock.calls[0] as [string]
      expect(url).toContain('/api/local-memories')
      expect(url).toContain('cwd=')
      expect(url).toContain(encodeURIComponent('/proj'))
      expect(result.memories).toHaveLength(1)
      expect(result.memories[0]!.name).toBe('foo.md')
    })

    it('omits the cwd query param when no cwd is provided', async () => {
      mockFetchOnce(200, { memories: [] })

      await listLocalMemories()

      const [url] = fetchMock.mock.calls[0] as [string]
      expect(url).toBe('/api/local-memories')
    })
  })

  describe('getLocalMemoryDetail', () => {
    it('URL-encodes the name and includes cwd', async () => {
      mockFetchOnce(200, {
        memory: { name: 'a b.md', title: 'A b', path: '/x.md', size: 0, content: '' },
        error_message: null,
      })

      await getLocalMemoryDetail('a b.md', '/proj')

      const [url] = fetchMock.mock.calls[0] as [string, RequestInit]
      expect(url).toContain('/api/local-memories/a%20b.md')
      expect(url).toContain('cwd=')
    })

    it('returns structured response on 404', async () => {
      mockFetchOnce(404, { error: 'Memory not found' })

      const result = await getLocalMemoryDetail('missing.md', '/proj')

      expect(result.memory).toBeNull()
      expect(result.error_message).toBe('Memory not found')
    })
  })

  describe('createLocalMemory', () => {
    it('POSTs to /api/local-memories with name, content, and cwd in the body', async () => {
      mockFetchOnce(201, {
        memory: {
          name: 'new.md',
          title: 'New',
          path: '/proj/.pabrik/memories/new.md',
          size: 5,
        },
      })

      const result = await createLocalMemory('new.md', '# Hi\n', '/proj')

      expect(fetchMock).toHaveBeenCalledTimes(1)
      const [url, init] = fetchMock.mock.calls[0] as [string, RequestInit]
      expect(url).toBe('/api/local-memories')
      expect(init.method).toBe('POST')
      const body = JSON.parse(init.body as string)
      expect(body).toEqual({ name: 'new.md', content: '# Hi\n', cwd: '/proj' })
      expect(result.memory.name).toBe('new.md')
    })

    it('throws on non-2xx with the HTTP status', async () => {
      mockFetchOnce(400, { error: 'Invalid memory name' })
      await expect(createLocalMemory('bad', 'x', '/proj')).rejects.toThrow(/HTTP 400/)
    })

    it('returns 409 on duplicate (memory already exists)', async () => {
      mockFetchOnce(409, { error: 'Memory already exists' })
      await expect(createLocalMemory('dup.md', 'x', '/proj')).rejects.toThrow(/HTTP 409/)
    })
  })

  describe('updateLocalMemory', () => {
    it('PUTs to /api/local-memories/:name with content and cwd', async () => {
      mockFetchOnce(200, {
        memory: { name: 'foo.md', title: 'Foo', path: '/x.md', size: 10 },
      })

      await updateLocalMemory('foo.md', 'updated content', '/proj')

      const [url, init] = fetchMock.mock.calls[0] as [string, RequestInit]
      expect(url).toContain('/api/local-memories/foo.md')
      expect(url).toContain('cwd=')
      expect(init.method).toBe('PUT')
      const body = JSON.parse(init.body as string)
      expect(body).toEqual({ content: 'updated content', cwd: '/proj' })
    })
  })

  describe('deleteLocalMemory', () => {
    it('DELETEs /api/local-memories/:name with cwd query', async () => {
      mockFetchOnce(200, { success: true, name: 'foo.md', error_message: null })

      await deleteLocalMemory('foo.md', '/proj')

      const [url, init] = fetchMock.mock.calls[0] as [string, RequestInit]
      expect(url).toContain('/api/local-memories/foo.md')
      expect(url).toContain('cwd=')
      expect(init.method).toBe('DELETE')
    })
  })
})
