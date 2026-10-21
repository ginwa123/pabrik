/** Unit tests for the kanban tag suggestions API client (getKanbanTagSuggestions)./ Tasks 2.1 + 2.2 */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'

import * as api from '../api'

describe('getKanbanTagSuggestions', () => {
  const originalFetch = global.fetch
  const fetchMock = vi.fn()

  beforeEach(() => {
    // apiFetch calls useNotificationStore() on every non-2xx response to fire an error toast.
    // Without an active Pinia the call throws. setActivePinia(createPinia()) mounts a fresh store
    // for each test so the toast path can run without crashing.
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
      // text() is what apiFetch calls on every non-OK response to
      // extract the body for the error notification — see the
      // apiFetch-mock-must-include-text-and-pinia memory.
      text: () => Promise.resolve(JSON.stringify(body)),
    } as Response)
    global.fetch = fetchMock as unknown as typeof fetch
  }

  it('returns the tags + has_more from the response', async () => {
    mockFetchOnce(200, {
      tags: [{ name: 'bug', count: 3, last_used_at: '2026-12-31 23:59:59' }],
      has_more: true,
    })
    const result = await api.getKanbanTagSuggestions('ws_x', 'item_x')
    expect(result.tags).toHaveLength(1)
    expect(result.tags[0]!.name).toBe('bug')
    expect(result.has_more).toBe(true)
  })

  it('hits /api/.../kanban/tags with default limit=8 and offset=0', async () => {
    mockFetchOnce(200, { tags: [], has_more: false })
    await api.getKanbanTagSuggestions('ws_x', 'item_x')
    expect(fetchMock).toHaveBeenCalledWith(
      expect.stringContaining('/api/workspaces/ws_x/items/item_x/kanban/tags?limit=8&offset=0'),
      expect.any(Object),
    )
  })

  it('passes through limit and offset when provided', async () => {
    mockFetchOnce(200, { tags: [], has_more: false })
    await api.getKanbanTagSuggestions('ws_x', 'item_x', { limit: 20, offset: 8 })
    expect(fetchMock).toHaveBeenCalledWith(
      expect.stringContaining('limit=20&offset=8'),
      expect.any(Object),
    )
  })

  it('returns empty + has_more=false on non-2xx (graceful degradation)', async () => {
    mockFetchOnce(500, { error: 'internal' })
    const result = await api.getKanbanTagSuggestions('ws_x', 'item_x')
    expect(result.tags).toEqual([])
    expect(result.has_more).toBe(false)
  })

  it('returns empty + has_more=false when workspaceId is empty (no fetch)', async () => {
    const result = await api.getKanbanTagSuggestions('', 'item_x')
    expect(result.tags).toEqual([])
    expect(result.has_more).toBe(false)
    expect(fetchMock).not.toHaveBeenCalled()
  })

  it('returns empty + has_more=false when itemId is empty (no fetch)', async () => {
    const result = await api.getKanbanTagSuggestions('ws_x', '')
    expect(result.tags).toEqual([])
    expect(result.has_more).toBe(false)
    expect(fetchMock).not.toHaveBeenCalled()
  })
})
