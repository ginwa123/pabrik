/** Unit tests for the single-task API client (getTask). Plan:
 * docs/superpowers/plans/2026-08-24-kanban-task-detail-single-fetch.md (Task 3). */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'

import { ApiError, getTask } from '../api'

describe('api.getTask', () => {
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

  it('GETs the single-task URL with all three ids in the path', async () => {
    mockFetchOnce(200, { task: { id: 'task_9', name: 'x' } })
    await getTask('ws_1', 'item_1', 'task_9')
    const url = (fetchMock.mock.calls[0]?.[0] ?? '') as string
    expect(url).toContain('/api/workspaces/ws_1/items/item_1/tasks/task_9')
    // No query params — the single-task endpoint takes none.
    expect(url).not.toContain('limit=')
  })

  it('resolves to the task object on 200', async () => {
    const wireTask = { id: 'task_9', name: 'my task', tags: '["bug"]' }
    mockFetchOnce(200, { task: wireTask })
    const task = await getTask('ws_1', 'item_1', 'task_9')
    expect(task).toEqual(wireTask)
  })

  it('resolves to null on 404 (task deleted / wrong item)', async () => {
    // 404 must NOT throw and must NOT fire an error toast — the store
    // treats "missing" as a no-op. silent: true keeps the notification
    // store out of it.
    mockFetchOnce(404, { error: 'task not found' })
    const task = await getTask('ws_1', 'item_1', 'task_gone')
    expect(task).toBeNull()
  })

  it('propagates non-404 errors (network/5xx surface to the caller)', async () => {
    mockFetchOnce(500, { error: 'boom' })
    await expect(getTask('ws_1', 'item_1', 'task_9')).rejects.toBeInstanceOf(ApiError)
  })

  it('encodes path segments', async () => {
    mockFetchOnce(200, { task: { id: 't' } })
    await getTask('ws with space', 'item/1', 'task 9')
    const url = (fetchMock.mock.calls[0]?.[0] ?? '') as string
    expect(url).toContain('ws%20with%20space')
    expect(url).toContain('item%2F1')
    expect(url).toContain('task%209')
  })
})
