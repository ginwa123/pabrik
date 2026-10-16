/** Unit tests for the task-list API client (getTasks). 4 behavioural tests covering the `q` query
 * parameter (kanban task search feature, plan:
 * docs/superpowers/plans/2026-07-30-kanban-task-search.md Chunk 3). */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'

import { getTasks } from '../api'

describe('api.getTasks', () => {
  const originalFetch = global.fetch
  const fetchMock = vi.fn()

  beforeEach(() => {
    setActivePinia(createPinia())
    global.fetch = fetchMock
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
  }

  it('includes ?q= in the URL when q is non-empty', async () => {
    mockFetchOnce(200, { tasks: [], has_more: false, next_cursor: null })
    await getTasks('ws_1', 'item_1', 20, undefined, 'updated_at', 'desc', undefined, 'design')
    const url = (fetchMock.mock.calls[0]?.[0] ?? '') as string
    expect(url).toContain('q=design')
  })

  it('omits q param when q is undefined', async () => {
    mockFetchOnce(200, { tasks: [], has_more: false, next_cursor: null })
    await getTasks('ws_1', 'item_1')
    const url = (fetchMock.mock.calls[0]?.[0] ?? '') as string
    expect(url).not.toContain('q=')
  })

  it('omits q param when q is empty string', async () => {
    mockFetchOnce(200, { tasks: [], has_more: false, next_cursor: null })
    await getTasks('ws_1', 'item_1', 20, undefined, 'updated_at', 'desc', undefined, '')
    const url = (fetchMock.mock.calls[0]?.[0] ?? '') as string
    expect(url).not.toContain('q=')
  })

  it('URL-encodes q value (spaces)', async () => {
    mockFetchOnce(200, { tasks: [], has_more: false, next_cursor: null })
    await getTasks('ws_1', 'item_1', 20, undefined, 'updated_at', 'desc', undefined, 'fix login bug')
    const url = (fetchMock.mock.calls[0]?.[0] ?? '') as string
    // URLSearchParams encodes spaces as '+' (form encoding).
    expect(url).toContain('q=fix+login+bug')
  })

  it('returns parsed response with tasks / has_more / next_cursor', async () => {
    mockFetchOnce(200, {
      tasks: [
        {
          id: 'task_1',
          name: 'fix login',
          workspace_item_id: 'item_1',
          task_type: 'standard',
        },
      ],
      has_more: false,
      next_cursor: null,
    })
    const result = await getTasks('ws_1', 'item_1', 20, undefined, 'updated_at', 'desc', undefined, 'login')
    expect(result.tasks).toHaveLength(1)
    expect(result.tasks[0]?.id).toBe('task_1')
    expect(result.has_more).toBe(false)
    expect(result.next_cursor).toBe(null)
  })
})