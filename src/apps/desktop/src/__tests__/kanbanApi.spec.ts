/**
 * Unit tests for the kanban API client (createKanban, listKanbanColumns,
 * addKanbanColumn, updateKanbanColumn, deleteKanbanColumn, moveTask).
 * Mocks global.fetch to assert URL, method, body shape, and error
 * handling without hitting the network. Mirrors the apiMemories.spec.ts
 * style: same mockFetchOnce helper (with `text()` so apiFetch's
 * non-OK path can extract the body for the error toast) and
 * `setActivePinia(createPinia())` in `beforeEach` (apiFetch calls
 * `useNotificationStore()` on every non-2xx).
 *
 * Plan: docs/superpowers/plans/2026-06-21-workspace-item-kanban.md
 *   Chunk 4 / Task 4.2
 */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'

import {
  createKanban,
  listKanbanColumns,
  addKanbanColumn,
  updateKanbanColumn,
  deleteKanbanColumn,
  moveTask,
} from '../api'

describe('api.kanban', () => {
  const originalFetch = global.fetch
  const fetchMock = vi.fn()

  beforeEach(() => {
    // apiFetch calls useNotificationStore() on every non-2xx response
    // to fire an error toast. Without an active Pinia the call
    // throws. setActivePinia(createPinia()) mounts a fresh store for
    // each test so the toast path can run without crashing.
    // (See project memory apiFetch-mock-must-include-text-and-pinia.)
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

  describe('createKanban', () => {
    it('POSTs the name to /api/workspaces/:wsId/items/kanban and returns item+columns', async () => {
      mockFetchOnce(201, {
        item: {
          id: 'kanban_1',
          workspace_id: 'ws_1',
          item_type: 'kanban',
          name: 'My Sprint',
        },
        columns: [
          { id: 'c1', workspace_item_id: 'kanban_1', name: 'todo', position: 0, created_at: '2026-06-21 12:00:00' },
          { id: 'c2', workspace_item_id: 'kanban_1', name: 'in progress', position: 1, created_at: '2026-06-21 12:00:00' },
          { id: 'c3', workspace_item_id: 'kanban_1', name: 'done', position: 2, created_at: '2026-06-21 12:00:00' },
        ],
      })

      const result = await createKanban('ws_1', 'My Sprint')

      const [url, init] = fetchMock.mock.calls[0] as [string, RequestInit]
      expect(url).toContain('/api/workspaces/ws_1/items/kanban')
      expect(init.method).toBe('POST')
      const body = JSON.parse(init.body as string)
      // path defaults to '' when omitted (matches the API: NULLIF(?, '') turns '' into NULL on the
      // backend). The frontend always passes a non-empty path via the AddKanbanDialog picker; the
      // '' fallback is just for direct API callers / tests.
      expect(body).toEqual({ name: 'My Sprint', path: '' })
      expect(result.item.id).toBe('kanban_1')
      expect(result.item.name).toBe('My Sprint')
      expect(result.columns).toHaveLength(3)
      expect(result.columns[0]!.name).toBe('todo')
    })

    it('throws ApiError on 4xx/5xx with the body preserved', async () => {
      mockFetchOnce(409, { error: 'workspace not found' })

      await expect(createKanban('ws_does_not_exist', 'X')).rejects.toMatchObject({
        status: 409,
        body: expect.stringContaining('workspace not found'),
      })
    })

    it('forwards the optional path in the request body when supplied', async () => {
      mockFetchOnce(201, {
        item: { id: 'kanban_2', workspace_id: 'ws_1', item_type: 'kanban', name: 'My Sprint' },
        columns: [],
      })

      await createKanban('ws_1', 'My Sprint', '/abs/projects/sprint')

      const [, init] = fetchMock.mock.calls[0] as [string, RequestInit]
      const body = JSON.parse(init.body as string)
      // The cwd path round-trips through the API unchanged. The
      // backend's NULLIF guards against the empty-string-to-NULL
      // conversion, but a real path passes through verbatim.
      expect(body).toEqual({ name: 'My Sprint', path: '/abs/projects/sprint' })
    })
  })

  describe('listKanbanColumns', () => {
    it('GETs /api/workspaces/:wsId/items/:itemId/kanban/columns and returns {columns, count}', async () => {
      mockFetchOnce(200, {
        columns: [
          { id: 'c1', workspace_item_id: 'item_1', name: 'todo', position: 0, created_at: '2026-06-21 12:00:00' },
          { id: 'c2', workspace_item_id: 'item_1', name: 'done', position: 1, created_at: '2026-06-21 12:00:00' },
        ],
        count: 2,
      })

      const result = await listKanbanColumns('ws_1', 'item_1')

      const [url, init] = fetchMock.mock.calls[0] as [string, RequestInit]
      expect(url).toContain('/api/workspaces/ws_1/items/item_1/kanban/columns')
      // GET is the default for fetch when no method is supplied.
      expect(init.method).toBeUndefined()
      expect(result.columns).toHaveLength(2)
      expect(result.count).toBe(2)
      expect(result.columns[1]!.name).toBe('done')
    })

    it('throws ApiError on non-2xx', async () => {
      mockFetchOnce(404, { error: 'item not found' })

      await expect(listKanbanColumns('ws_1', 'item_missing')).rejects.toMatchObject({
        status: 404,
        body: expect.stringContaining('item not found'),
      })
    })
  })

  describe('addKanbanColumn', () => {
    it('POSTs {name, description, position?} to the columns endpoint and returns the new column', async () => {
      mockFetchOnce(201, {
        id: 'c_new',
        workspace_item_id: 'item_1',
        name: 'review',
        description: 'Awaiting code review',
        position: 3,
        created_at: '2026-06-21 12:00:00',
      })

      const result = await addKanbanColumn(
        'ws_1',
        'item_1',
        'review',
        'Awaiting code review',
        3,
      )

      const [url, init] = fetchMock.mock.calls[0] as [string, RequestInit]
      expect(url).toContain('/api/workspaces/ws_1/items/item_1/kanban/columns')
      expect(init.method).toBe('POST')
      const body = JSON.parse(init.body as string)
      expect(body).toEqual({
        name: 'review',
        description: 'Awaiting code review',
        position: 3,
      })
      expect(result.id).toBe('c_new')
      expect(result.name).toBe('review')
      expect(result.description).toBe('Awaiting code review')
      expect(result.position).toBe(3)
    })

    it('omits position from the body when not provided (backend appends) and defaults description to ""', async () => {
      mockFetchOnce(201, {
        id: 'c_new',
        workspace_item_id: 'item_1',
        name: 'review',
        description: '',
        position: 0,
        created_at: '2026-06-21 12:00:00',
      })

      await addKanbanColumn('ws_1', 'item_1', 'review')

      const [, init] = fetchMock.mock.calls[0] as [string, RequestInit]
      const body = JSON.parse(init.body as string)
      // apiFetch wraps via JSON.stringify(body), and JSON.stringify
      // strips `undefined` values from objects — so the optional
      // `position` is omitted from the wire payload when the caller
      // didn't supply it. `description` defaults to the empty
      // string ("no description" sentinel) so the backend's
      // parseFromSliceLeaky sees a string (not null) for the
      // NOT NULL DEFAULT '' column. The backend's parseFromSliceLeaky
      // treats the absent field as `null` for `?i64` / `?[]const u8`
      // types (matches how addColumn / addTask do it elsewhere).
      expect(body).toEqual({ name: 'review', description: '' })
    })
  })

  describe('updateKanbanColumn', () => {
    it('PATCHes the column with the patch and returns the full updated board', async () => {
      // The backend's PATCH handler returns the full kanban board (same {columns, count} envelope
      // as listKanbanColumns) on success so the frontend can mirror sibling renumbering in a single
      // round-trip. Assert the wire shape here so any future drift is caught at the API boundary.
      mockFetchOnce(200, {
        columns: [
          {
            id: 'c1',
            workspace_item_id: 'item_1',
            name: 'backlog',
            description: '',
            position: 0,
            created_at: '2026-06-21 12:00:00',
          },
        ],
        count: 1,
      })

      const result = await updateKanbanColumn('ws_1', 'item_1', 'c1', { name: 'backlog' })

      const [url, init] = fetchMock.mock.calls[0] as [string, RequestInit]
      expect(url).toContain('/api/workspaces/ws_1/items/item_1/kanban/columns/c1')
      expect(init.method).toBe('PATCH')
      const body = JSON.parse(init.body as string)
      expect(body).toEqual({ name: 'backlog' })
      // Full board shape — the store slices result.columns for the
      // patched column; the test asserts the envelope type here so
      // a regression to the old single-column shape would fail.
      expect(result.count).toBe(1)
      expect(result.columns).toHaveLength(1)
      expect(result.columns[0]!.name).toBe('backlog')
      expect(result.columns[0]!.description).toBe('')
    })

    it('supports renaming + repositioning in a single PATCH and reflects the renumbered siblings', async () => {
      mockFetchOnce(200, {
        columns: [
          {
            id: 'c2',
            workspace_item_id: 'item_1',
            name: 'in progress',
            description: '',
            position: 0,
            created_at: '2026-06-21 12:00:00',
          },
          {
            id: 'c1',
            workspace_item_id: 'item_1',
            name: 'urgent',
            description: 'Top priority',
            position: 1,
            created_at: '2026-06-21 12:00:00',
          },
          {
            id: 'c3',
            workspace_item_id: 'item_1',
            name: 'done',
            description: '',
            position: 2,
            created_at: '2026-06-21 12:00:00',
          },
        ],
        count: 3,
      })

      await updateKanbanColumn('ws_1', 'item_1', 'c1', {
        name: 'urgent',
        description: 'Top priority',
        position: 1,
      })

      const [, init] = fetchMock.mock.calls[0] as [string, RequestInit]
      const body = JSON.parse(init.body as string)
      expect(body).toEqual({
        name: 'urgent',
        description: 'Top priority',
        position: 1,
      })
    })

    it('forwards description-only patch without name or position', async () => {
      mockFetchOnce(200, {
        columns: [
          {
            id: 'c1',
            workspace_item_id: 'item_1',
            name: 'review',
            description: 'Updated meaning',
            position: 0,
            created_at: '2026-06-21 12:00:00',
          },
        ],
        count: 1,
      })

      await updateKanbanColumn('ws_1', 'item_1', 'c1', {
        description: 'Updated meaning',
      })

      const [, init] = fetchMock.mock.calls[0] as [string, RequestInit]
      const body = JSON.parse(init.body as string)
      expect(body).toEqual({ description: 'Updated meaning' })
    })
  })

  describe('deleteKanbanColumn', () => {
    it('DELETEs the column and returns { success: true }', async () => {
      mockFetchOnce(200, { success: true })

      const result = await deleteKanbanColumn('ws_1', 'item_1', 'c1')

      const [url, init] = fetchMock.mock.calls[0] as [string, RequestInit]
      expect(url).toContain('/api/workspaces/ws_1/items/item_1/kanban/columns/c1')
      expect(init.method).toBe('DELETE')
      expect(result.success).toBe(true)
    })

    it('throws ApiError on 4xx/5xx', async () => {
      mockFetchOnce(500, { error: 'DB write failed' })

      await expect(deleteKanbanColumn('ws_1', 'item_1', 'c1')).rejects.toMatchObject({
        status: 500,
        body: expect.stringContaining('DB write failed'),
      })
    })
  })

  describe('moveTask', () => {
    it('PATCHes the task with {column_id, position} and returns the updated task', async () => {
      mockFetchOnce(200, {
        id: 't1',
        name: 'Task A',
        kanban_column_id: 'c2',
        kanban_position: 0,
      })

      const result = await moveTask('ws_1', 'item_1', 't1', 'c2', 0)

      const [url, init] = fetchMock.mock.calls[0] as [string, RequestInit]
      expect(url).toContain('/api/workspaces/ws_1/items/item_1/tasks/t1/move')
      expect(init.method).toBe('PATCH')
      const body = JSON.parse(init.body as string)
      expect(body).toEqual({ column_id: 'c2', position: 0 })
      expect(result.id).toBe('t1')
      expect(result.kanban_column_id).toBe('c2')
      expect(result.kanban_position).toBe(0)
    })

    it('throws ApiError when the task or column does not exist', async () => {
      mockFetchOnce(404, { error: 'task not found' })

      await expect(moveTask('ws_1', 'item_1', 't_missing', 'c1', 0)).rejects.toMatchObject({
        status: 404,
        body: expect.stringContaining('task not found'),
      })
    })
  })
})
