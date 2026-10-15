/**
 * Kanban task dependencies — API wire rules.
 *
 * Covers: `moveTask` sends `force` only when truthy;
 * `updateTaskSimple` omits `depends_on` unless the caller
 * provides it (`[]` clears); `updateKanbanColumn` forwards
 * `is_done`; `parseMoveBlockers` reads the 409 body; and
 * `normalizeTaskDependsOn` coerces the wire shape.
 *
 * Mock style mirrors `apiTasks.spec.ts` (pinia for the apiFetch
 * error-toast path, fetch mock with `text()` for error bodies).
 */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'

import {
  ApiError,
  moveTask,
  normalizeTaskDependsOn,
  parseMoveBlockers,
  updateKanbanColumn,
  updateTaskSimple,
} from '../api'

describe('api kanban dependencies', () => {
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
      statusText: status === 409 ? 'Conflict' : 'OK',
      json: () => Promise.resolve(body),
      text: () => Promise.resolve(JSON.stringify(body)),
    } as Response)
  }

  function lastBody(): Record<string, unknown> {
    const calls = fetchMock.mock.calls
    const init = calls[calls.length - 1]?.[1] as RequestInit | undefined
    return JSON.parse(init?.body as string) as Record<string, unknown>
  }

  it('moveTask omits force from the body when not passed', async () => {
    mockFetchOnce(200, { id: 't1' })
    await moveTask('ws_1', 'item_1', 't1', 'col_b', 0)
    expect(lastBody()).toEqual({ column_id: 'col_b', position: 0 })
  })

  it('moveTask sends force:true only when passed truthy', async () => {
    mockFetchOnce(200, { id: 't1' })
    await moveTask('ws_1', 'item_1', 't1', 'col_b', 0, true)
    expect(lastBody()).toEqual({ column_id: 'col_b', position: 0, force: true })
  })

  it('updateTaskSimple omits depends_on when the caller did not supply it', async () => {
    mockFetchOnce(200, { success: true })
    await updateTaskSimple('t1', { name: 'Renamed' })
    const body = lastBody()
    expect(body).toEqual({ name: 'Renamed' })
    expect('depends_on' in body).toBe(false)
  })

  it('updateTaskSimple forwards depends_on verbatim, including [] (clear)', async () => {
    mockFetchOnce(200, { success: true })
    await updateTaskSimple('t1', { depends_on: ['a', 'b'] })
    expect(lastBody()).toEqual({ depends_on: ['a', 'b'] })

    mockFetchOnce(200, { success: true })
    await updateTaskSimple('t1', { depends_on: [] })
    expect(lastBody()).toEqual({ depends_on: [] })
  })

  it('updateKanbanColumn forwards is_done', async () => {
    mockFetchOnce(200, { columns: [], count: 0 })
    await updateKanbanColumn('ws_1', 'item_1', 'col_a', { is_done: true })
    expect(lastBody()).toEqual({ is_done: true })
  })

  it('parseMoveBlockers returns the blocker list on a 409 ApiError', () => {
    const blockers = [{ task_id: 'a', name: 'Fix login', column_id: 'c', column_name: 'todo' }]
    const err = new ApiError(409, 'Conflict', JSON.stringify({ error: 'blocked', blockers }))
    expect(parseMoveBlockers(err)).toEqual(blockers)
  })

  it('parseMoveBlockers returns null for non-409 errors and garbage bodies', () => {
    expect(parseMoveBlockers(new Error('boom'))).toBeNull()
    expect(parseMoveBlockers(new ApiError(500, 'x', '{}'))).toBeNull()
    expect(parseMoveBlockers(new ApiError(409, 'Conflict', 'not-json'))).toBeNull()
    expect(parseMoveBlockers(new ApiError(409, 'Conflict', '{}'))).toBeNull()
  })

  it('normalizeTaskDependsOn keeps arrays, parses JSON strings, clears garbage', () => {
    const a: { depends_on?: unknown } = { depends_on: ['x', 1, 'y'] }
    normalizeTaskDependsOn(a)
    expect(a.depends_on).toEqual(['x', 'y'])

    const b: { depends_on?: unknown } = { depends_on: '["x","y"]' }
    normalizeTaskDependsOn(b)
    expect(b.depends_on).toEqual(['x', 'y'])

    const c: { depends_on?: unknown } = { depends_on: 'garbage' }
    normalizeTaskDependsOn(c)
    expect(c.depends_on).toEqual([])

    const d: { depends_on?: unknown } = {}
    normalizeTaskDependsOn(d)
    expect('depends_on' in d).toBe(false)
  })
})
