/** Unit tests for the kanban store actions (Chunk 5 of the workspace-item-kanban plan + the
 * follow-up fetchKanbanColumns action that fixes the "board renders empty after page reload" bug). */
/** Covers: addKanbanItem, fetchKanbanColumns, addKanbanColumn, updateKanbanColumn,
 * deleteKanbanColumn, moveTaskToColumn. */
/** Each action is mocked at the api.* boundary (the apiFetch wrappers in api/index.ts) and the test
 * asserts that the store's local state is updated correctly. */
/** Mirrors the workspacesStoreTaskTypes.spec.ts pattern: a top-level `seedStore()` helper,
 * vi.spyOn(api, ...) per action, and `setActivePinia(createPinia())` in beforeEach. Plan:
 * docs/superpowers/plans/2026-06-21-workspace-item-kanban.md Chunk 5 / Task 5.1 */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'

import * as api from '../api'
import {
  useWorkspacesStore,
  type KanbanColumn,
  type Task,
  type Workspace,
  type WorkspaceItem,
} from '../stores/workspaces'
import { makeLocalStorageStub } from './helpers'

const ws = (id: string, name: string, items: WorkspaceItem[] = []): Workspace => ({
  id,
  name,
  icon: '📁',
  expanded: true,
  items,
})

const item = (
  id: string,
  name: string,
  itemType: string = 'folder',
  extras: Partial<WorkspaceItem> = {},
): WorkspaceItem => ({
  id,
  name,
  item_type: itemType,
  ...extras,
})

const column = (
  id: string,
  name: string,
  position: number,
  workspaceItemId: string = 'item_1',
  description: string = '',
): KanbanColumn => ({
  id,
  workspace_item_id: workspaceItemId,
  name,
  description,
  position,
  created_at: '2026-06-21 12:00:00',
})

const task = (
  id: string,
  name: string,
  extras: Partial<Task> = {},
): Task => ({
  id,
  name,
  ...extras,
})

describe('useWorkspacesStore — kanban actions', () => {
  let localStorageStub: Storage

  beforeEach(() => {
    setActivePinia(createPinia())
    localStorageStub = makeLocalStorageStub()
    Object.defineProperty(globalThis, 'localStorage', {
      value: localStorageStub,
      writable: true,
      configurable: true,
    })

    // init()'s other API calls — defensive in case a future test
    // triggers it. Same defensive pattern as workspacesStoreTaskTypes.
    vi.spyOn(api, 'getWorkspaces').mockResolvedValue({ workspaces: [] })
    vi.spyOn(api, 'getWorkspacesItems').mockResolvedValue({ items: [], count: 0 })
    vi.spyOn(api, 'getTasks').mockResolvedValue({
      tasks: [],
      has_more: false,
      next_cursor: null,
    })
  })

  afterEach(() => {
    vi.restoreAllMocks()
  })

  function seedStore(seedWs: Workspace[] = [ws('ws_1', 'W1')]) {
    const store = useWorkspacesStore()
    store.workspaces.splice(0, store.workspaces.length, ...seedWs)
    return store
  }

  // ─── addKanbanItem ──────────────────────────────────────────────────────
  describe('addKanbanItem', () => {
    it('calls api.createKanban and pushes the new item with its columns into the workspace', async () => {
      const store = seedStore()
      const createKanbanMock = vi
        .spyOn(api, 'createKanban')
        .mockResolvedValue({
          item: {
            id: 'kanban_1',
            item_type: 'kanban',
            name: 'My Sprint',
          },
          columns: [
            column('c1', 'todo', 0, 'kanban_1'),
            column('c2', 'in progress', 1, 'kanban_1'),
            column('c3', 'done', 2, 'kanban_1'),
          ],
        })

      const id = await store.addKanbanItem('ws_1', 'My Sprint', '/abs/project')

      expect(id).toBe('kanban_1')
      expect(createKanbanMock).toHaveBeenCalledWith('ws_1', 'My Sprint', '/abs/project')

      const wsRow = store.workspaces.find((w) => w.id === 'ws_1')!
      expect(wsRow.items).toHaveLength(1)
      const newItem = wsRow.items[0]!
      expect(newItem.id).toBe('kanban_1')
      expect(newItem.name).toBe('My Sprint')
      expect(newItem.item_type).toBe('kanban')
      expect(newItem.tasks).toEqual([])
      expect(newItem.kanban_columns).toHaveLength(3)
      expect(newItem.kanban_columns?.map((c) => c.name)).toEqual([
        'todo',
        'in progress',
        'done',
      ])
    })

    it('returns undefined and leaves state untouched when the API call fails', async () => {
      const store = seedStore()
      vi.spyOn(api, 'createKanban').mockRejectedValue(new Error('HTTP 500'))
      // Spy on console.error to silence the expected error log.
      const errorSpy = vi.spyOn(console, 'error').mockImplementation(() => {})

      const id = await store.addKanbanItem('ws_1', 'My Sprint', '/abs/project')

      expect(id).toBeUndefined()
      const wsRow = store.workspaces.find((w) => w.id === 'ws_1')!
      expect(wsRow.items).toHaveLength(0)
      expect(errorSpy).toHaveBeenCalled()
      errorSpy.mockRestore()
    })

    // ─── "Untitled project" regression ─────────────────────────────────
    //
    // The bug: the backend used to return a flat `CreateKanbanResponse`
    // (no wrapper) so the frontend's `const { item, columns } = await
    // api.createKanban(...)` got both as undefined, the local store
    // pushed an item with all fields undefined, and the sidebar
    // rendered the `{{ item.name || 'Untitled project' }}` fallback
    // until the user reloaded (the reloaded state came from
    // getWorkspacesItems which has the correct shape).
    //
    // The defense-in-depth fix: even if the API ever regresses to a
    // bare `{id, success}` envelope or omits `name`/`item_type`/`path`,
    // the store action falls back to the form's values so the
    // sidebar always renders the typed name. This test pins the
    // contract — without the fallback, the new item would have
    // `name: undefined` and the sidebar would render "Untitled
    // project" until reload.
    it('falls back to the form name when the API response omits it (regression for "Untitled project" bug)', async () => {
      const store = seedStore()
      // API returns an item with no `name` / `item_type` / `path`.
      // This mirrors the shape the backend used to return before
      // the wire envelope was introduced.
      vi.spyOn(api, 'createKanban').mockResolvedValue({
        item: {
          id: 'kanban_bare',
          // name missing — old backend shape
        // eslint-disable-next-line @typescript-eslint/no-explicit-any
        } as any,
         
        columns: [],
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      } as any)

      const id = await store.addKanbanItem('ws_1', 'My Sprint', '/abs/project')

      expect(id).toBe('kanban_bare')
      const wsRow = store.workspaces.find((w) => w.id === 'ws_1')!
      const newItem = wsRow.items[0]!
      expect(newItem.name).toBe('My Sprint')         // ← fallback fired
      expect(newItem.item_type).toBe('kanban')      // ← fallback fired
      expect(newItem.path).toBe('/abs/project')     // ← fallback fired
      expect(newItem.kanban_columns).toEqual([])    // ← never undefined
    })
  })

  // ─── addKanbanColumn ────────────────────────────────────────────────────
  describe('addKanbanColumn', () => {
    it('calls api.addKanbanColumn and appends the new column sorted by position', async () => {
      const store = seedStore([
        ws('ws_1', 'W1', [
          item('item_1', 'Sprint', 'kanban', {
            kanban_columns: [
              column('c1', 'todo', 0, 'item_1'),
              column('c3', 'done', 2, 'item_1'),
            ],
          }),
        ]),
      ])
      const addKanbanColumnMock = vi
        .spyOn(api, 'addKanbanColumn')
        .mockResolvedValue(column('c2', 'in progress', 1, 'item_1'))

      await store.addKanbanColumn('ws_1', 'item_1', 'in progress')

      // The store defaults description to '' when not provided so
      // existing callers (e.g. AppLayout's addColumn handler) keep
      // working unchanged.
      expect(addKanbanColumnMock).toHaveBeenCalledWith(
        'ws_1',
        'item_1',
        'in progress',
        '',
      )
      const wsRow = store.workspaces.find((w) => w.id === 'ws_1')!
      const updatedItem = wsRow.items.find((i) => i.id === 'item_1')!
      expect(updatedItem.kanban_columns?.map((c) => c.id)).toEqual(['c1', 'c2', 'c3'])
    })

    it('forwards description to api.addKanbanColumn when provided', async () => {
      const store = seedStore([
        ws('ws_1', 'W1', [
          item('item_1', 'Sprint', 'kanban', {
            kanban_columns: [column('c1', 'todo', 0, 'item_1')],
          }),
        ]),
      ])
      const addKanbanColumnMock = vi
        .spyOn(api, 'addKanbanColumn')
        .mockResolvedValue(
          column('c2', 'review', 1, 'item_1', 'Awaiting code review'),
        )

      await store.addKanbanColumn(
        'ws_1',
        'item_1',
        'review',
        'Awaiting code review',
      )

      expect(addKanbanColumnMock).toHaveBeenCalledWith(
        'ws_1',
        'item_1',
        'review',
        'Awaiting code review',
      )
      const wsRow = store.workspaces.find((w) => w.id === 'ws_1')!
      const updatedItem = wsRow.items.find((i) => i.id === 'item_1')!
      const c2 = updatedItem.kanban_columns?.find((c) => c.id === 'c2')
      expect(c2?.description).toBe('Awaiting code review')
    })

    it('creates kanban_columns array when the item did not have one (defensive)', async () => {
      const store = seedStore([
        ws('ws_1', 'W1', [item('item_1', 'Sprint', 'kanban')]),
      ])
      vi.spyOn(api, 'addKanbanColumn').mockResolvedValue(column('c1', 'todo', 0, 'item_1'))

      await store.addKanbanColumn('ws_1', 'item_1', 'todo')

      const wsRow = store.workspaces.find((w) => w.id === 'ws_1')!
      const updatedItem = wsRow.items.find((i) => i.id === 'item_1')!
      expect(updatedItem.kanban_columns).toHaveLength(1)
      expect(updatedItem.kanban_columns?.[0]?.name).toBe('todo')
    })
  })

  // ─── updateKanbanColumn ────────────────────────────────────────────────
  describe('updateKanbanColumn', () => {
    it('calls api.updateKanbanColumn and replaces the local board with the backend\'s full response', async () => {
      const store = seedStore([
        ws('ws_1', 'W1', [
          item('item_1', 'Sprint', 'kanban', {
            kanban_columns: [
              column('c1', 'todo', 0, 'item_1', 'Not started'),
              column('c2', 'in progress', 1, 'item_1', 'In flight'),
            ],
          }),
        ]),
      ])
      // Backend returns the full board (same {columns, count}
      // envelope as listKanbanColumns). Mirror that shape so the
      // store code under test exercises the real wire format.
      const updateKanbanColumnMock = vi
        .spyOn(api, 'updateKanbanColumn')
        .mockResolvedValue({
          columns: [
            column('c1', 'backlog', 0, 'item_1', 'Not started'),
            column('c2', 'in progress', 1, 'item_1', 'In flight'),
          ],
          count: 2,
        })

      await store.updateKanbanColumn('ws_1', 'item_1', 'c1', { name: 'backlog' })

      expect(updateKanbanColumnMock).toHaveBeenCalledWith('ws_1', 'item_1', 'c1', {
        name: 'backlog',
      })
      const wsRow = store.workspaces.find((w) => w.id === 'ws_1')!
      const updatedItem = wsRow.items.find((i) => i.id === 'item_1')!
      const c1 = updatedItem.kanban_columns?.find((c) => c.id === 'c1')
      expect(c1?.name).toBe('backlog')
      // Description survives the PATCH — this is the regression
      // assertion for the "No description shown after save" bug.
      expect(c1?.description).toBe('Not started')
      // Sibling column is untouched.
      const c2 = updatedItem.kanban_columns?.find((c) => c.id === 'c2')
      expect(c2?.name).toBe('in progress')
      expect(c2?.description).toBe('In flight')
    })

    it('mirrors sibling renumbering from the PATCH response (no follow-up GET needed)', async () => {
      const store = seedStore([
        ws('ws_1', 'W1', [
          item('item_1', 'Sprint', 'kanban', {
            kanban_columns: [
              column('c1', 'todo', 0, 'item_1'),
              column('c2', 'in progress', 1, 'item_1'),
              column('c3', 'done', 2, 'item_1'),
            ],
          }),
        ]),
      ])
      // Simulate the backend's dense renumber when c3 moves to
      // position 0: c2 → 1, c1 → 2, c3 → 0 (the actual algorithm
      // is irrelevant here — what matters is the response shape).
      const updateKanbanColumnMock = vi
        .spyOn(api, 'updateKanbanColumn')
        .mockResolvedValue({
          columns: [
            column('c3', 'done', 0, 'item_1'),
            column('c2', 'in progress', 1, 'item_1'),
            column('c1', 'todo', 2, 'item_1'),
          ],
          count: 3,
        })

      await store.updateKanbanColumn('ws_1', 'item_1', 'c3', { position: 0 })

      expect(updateKanbanColumnMock).toHaveBeenCalledWith('ws_1', 'item_1', 'c3', {
        position: 0,
      })
      const wsRow = store.workspaces.find((w) => w.id === 'ws_1')!
      const updatedItem = wsRow.items.find((i) => i.id === 'item_1')!
      // Local positions match the backend's renumbered order.
      expect(updatedItem.kanban_columns?.[0]?.id).toBe('c3')
      expect(updatedItem.kanban_columns?.[0]?.position).toBe(0)
      expect(updatedItem.kanban_columns?.[1]?.id).toBe('c2')
      expect(updatedItem.kanban_columns?.[1]?.position).toBe(1)
      expect(updatedItem.kanban_columns?.[2]?.id).toBe('c1')
      expect(updatedItem.kanban_columns?.[2]?.position).toBe(2)
    })

    it('preserves the description of the patched column across the round-trip (regression for "empty after save" bug)', async () => {
      // The original bug: the store assigned the PATCH response (which is the full board, NOT a
      // single column) to the single-column slot, so col.description read as undefined and the
      // settings dialog rendered "No description" until the user refreshed the page.
      const store = seedStore([
        ws('ws_1', 'W1', [
          item('item_1', 'Sprint', 'kanban', {
            kanban_columns: [
              column('c1', 'todo', 0, 'item_1', 'Old description'),
            ],
          }),
        ]),
      ])
      vi.spyOn(api, 'updateKanbanColumn').mockResolvedValue({
        columns: [
          column('c1', 'todo', 0, 'item_1', 'New description'),
        ],
        count: 1,
      })

      await store.updateKanbanColumn('ws_1', 'item_1', 'c1', {
        description: 'New description',
      })

      const wsRow = store.workspaces.find((w) => w.id === 'ws_1')!
      const updatedItem = wsRow.items.find((i) => i.id === 'item_1')!
      const c1 = updatedItem.kanban_columns?.find((c) => c.id === 'c1')
      // The bug would fail this assertion (description was undefined).
      expect(c1?.description).toBe('New description')
      expect(c1?.name).toBe('todo')
      expect(c1?.position).toBe(0)
    })
  })

  // ─── reorderKanbanColumn ──────────────────────────────────────────────── The column header
  // drag-and-drop reorder action.
  describe('reorderKanbanColumn', () => {
    it('calls api.updateKanbanColumn with the target column\'s position and re-fetches via listKanbanColumns', async () => {
      const store = seedStore([
        ws('ws_1', 'W1', [
          item('item_1', 'Sprint', 'kanban', {
            kanban_columns: [
              column('c1', 'todo', 0, 'item_1'),
              column('c2', 'in progress', 1, 'item_1'),
              column('c3', 'done', 2, 'item_1'),
            ],
          }),
        ]),
      ])
      const updateMock = vi
        .spyOn(api, 'updateKanbanColumn')
        // Backend returns the full board on PATCH; the store
        // discards it and uses the follow-up listKanbanColumns
        // response to mirror sibling renumbering.
        .mockResolvedValue({
          columns: [
            column('c3', 'done', 0, 'item_1'),
            column('c1', 'todo', 1, 'item_1'),
            column('c2', 'in progress', 2, 'item_1'),
          ],
          count: 3,
        })
      // Re-fetch returns the post-renumber ordering (c3 is now at 0;
      // c1 and c2 shifted to 1 and 2).
      const listMock = vi.spyOn(api, 'listKanbanColumns').mockResolvedValue({
        columns: [
          column('c3', 'done', 0, 'item_1'),
          column('c1', 'todo', 1, 'item_1'),
          column('c2', 'in progress', 2, 'item_1'),
        ],
        count: 3,
      })

      // Drag c3 onto c1 (which is at position 0) → c3 should land at 0.
      await store.reorderKanbanColumn('ws_1', 'item_1', 'c3', 'c1')

      // PATCH must use c1's position (0), not c3's.
      expect(updateMock).toHaveBeenCalledWith('ws_1', 'item_1', 'c3', {
        position: 0,
      })
      // The re-fetch must follow the PATCH (so the local state
      // mirrors the backend's full renumber result).
      expect(listMock).toHaveBeenCalledWith('ws_1', 'item_1')

      // The two API calls must happen in the right order:
      // PATCH first (so the backend can renumber), then list.
      const updateOrder = updateMock.mock.invocationCallOrder[0]!
      const listOrder = listMock.mock.invocationCallOrder[0]!
      expect(updateOrder).toBeLessThan(listOrder)

      // Local state reflects the post-renumber columns.
      const wsRow = store.workspaces.find((w) => w.id === 'ws_1')!
      const updatedItem = wsRow.items.find((i) => i.id === 'item_1')!
      expect(updatedItem.kanban_columns?.map((c) => c.id)).toEqual([
        'c3',
        'c1',
        'c2',
      ])
    })

    it('is a no-op when the target column does not exist locally', async () => {
      const store = seedStore([
        ws('ws_1', 'W1', [
          item('item_1', 'Sprint', 'kanban', {
            kanban_columns: [
              column('c1', 'todo', 0, 'item_1'),
              // No 'c2' here — that's the "target" we'll pass.
            ],
          }),
        ]),
      ])
      const updateMock = vi.spyOn(api, 'updateKanbanColumn')
      const listMock = vi.spyOn(api, 'listKanbanColumns')

      await store.reorderKanbanColumn('ws_1', 'item_1', 'c1', 'c_missing')

      // Neither API call should happen — the action bails out before
      // touching the network.
      expect(updateMock).not.toHaveBeenCalled()
      expect(listMock).not.toHaveBeenCalled()
    })

    it('is a no-op when the item has no kanban_columns array', async () => {
      const store = seedStore([
        ws('ws_1', 'W1', [item('item_1', 'Sprint', 'kanban')]),
      ])
      const updateMock = vi.spyOn(api, 'updateKanbanColumn')
      const listMock = vi.spyOn(api, 'listKanbanColumns')

      await store.reorderKanbanColumn('ws_1', 'item_1', 'c1', 'c2')

      expect(updateMock).not.toHaveBeenCalled()
      expect(listMock).not.toHaveBeenCalled()
    })
  })

  // ─── deleteKanbanColumn ─────────────────────────────────────────────────
  describe('deleteKanbanColumn', () => {
    it('calls api.deleteKanbanColumn, removes the column, and unassigns tasks in that column', async () => {
      const store = seedStore([
        ws('ws_1', 'W1', [
          item('item_1', 'Sprint', 'kanban', {
            kanban_columns: [
              column('c1', 'todo', 0, 'item_1'),
              column('c2', 'in progress', 1, 'item_1'),
            ],
            tasks: [
              task('t1', 'Task A', { kanban_column_id: 'c1', kanban_position: 0 }),
              task('t2', 'Task B', { kanban_column_id: 'c2', kanban_position: 0 }),
              task('t3', 'Task C', { kanban_column_id: 'c1', kanban_position: 1 }),
            ],
          }),
        ]),
      ])
      const deleteKanbanColumnMock = vi
        .spyOn(api, 'deleteKanbanColumn')
        .mockResolvedValue({ success: true })

      await store.deleteKanbanColumn('ws_1', 'item_1', 'c1')

      expect(deleteKanbanColumnMock).toHaveBeenCalledWith('ws_1', 'item_1', 'c1')
      const wsRow = store.workspaces.find((w) => w.id === 'ws_1')!
      const updatedItem = wsRow.items.find((i) => i.id === 'item_1')!
      // Column c1 is gone.
      expect(updatedItem.kanban_columns?.map((c) => c.id)).toEqual(['c2'])
      // Tasks that were in c1 are unassigned (null).
      const t1 = updatedItem.tasks?.find((t) => t.id === 't1')
      expect(t1?.kanban_column_id).toBeNull()
      const t3 = updatedItem.tasks?.find((t) => t.id === 't3')
      expect(t3?.kanban_column_id).toBeNull()
      // Task in the other column is untouched.
      const t2 = updatedItem.tasks?.find((t) => t.id === 't2')
      expect(t2?.kanban_column_id).toBe('c2')
    })
  })

  // ─── moveTaskToColumn ───────────────────────────────────────────────────
  describe('moveTaskToColumn', () => {
    it('calls api.moveTask and updates the local task\'s kanban_column_id and kanban_position', async () => {
      const store = seedStore([
        ws('ws_1', 'W1', [
          item('item_1', 'Sprint', 'kanban', {
            kanban_columns: [
              column('c1', 'todo', 0, 'item_1'),
              column('c2', 'in progress', 1, 'item_1'),
            ],
            tasks: [
              task('t1', 'Task A', { kanban_column_id: 'c1', kanban_position: 0 }),
            ],
          }),
        ]),
      ])
      const moveTaskMock = vi.spyOn(api, 'moveTask').mockResolvedValue({
        id: 't1',
        name: 'Task A',
        kanban_column_id: 'c2',
        kanban_position: 1,
      })

      await store.moveTaskToColumn('ws_1', 'item_1', 't1', 'c2', 1)

      expect(moveTaskMock).toHaveBeenCalledWith('ws_1', 'item_1', 't1', 'c2', 1)
      const wsRow = store.workspaces.find((w) => w.id === 'ws_1')!
      const updatedItem = wsRow.items.find((i) => i.id === 'item_1')!
      const t1 = updatedItem.tasks?.find((t) => t.id === 't1')
      expect(t1?.kanban_column_id).toBe('c2')
      expect(t1?.kanban_position).toBe(1)
    })
  })

  // ─── fetchKanbanColumns ───────────────────────────────────────────────── The "board renders
  // empty after page reload" fix.
  describe('fetchKanbanColumns', () => {
    it('calls api.listKanbanColumns and populates item.kanban_columns', async () => {
      const store = seedStore([
        ws('ws_1', 'W1', [
          // Start with NO columns (simulates the initial page-load
          // state where the workspaces/items endpoint didn't embed
          // columns).
          item('item_1', 'Sprint', 'kanban'),
        ]),
      ])
      const listKanbanColumnsMock = vi
        .spyOn(api, 'listKanbanColumns')
        .mockResolvedValue({
          columns: [
            {
              id: 'c1',
              workspace_item_id: 'item_1',
              name: 'todo',
              position: 0,
              created_at: '2026-06-21 00:00:00',
            },
            {
              id: 'c2',
              workspace_item_id: 'item_1',
              name: 'in progress',
              position: 1,
              created_at: '2026-06-21 00:00:00',
            },
            {
              id: 'c3',
              workspace_item_id: 'item_1',
              name: 'done',
              position: 2,
              created_at: '2026-06-21 00:00:00',
            },
          ],
          count: 3,
        })

      await store.fetchKanbanColumns('ws_1', 'item_1')

      expect(listKanbanColumnsMock).toHaveBeenCalledWith('ws_1', 'item_1')
      const wsRow = store.workspaces.find((w) => w.id === 'ws_1')!
      const updatedItem = wsRow.items.find((i) => i.id === 'item_1')!
      expect(updatedItem.kanban_columns).toHaveLength(3)
      expect(updatedItem.kanban_columns?.map((c) => c.name)).toEqual([
        'todo',
        'in progress',
        'done',
      ])
    })

    it('sorts columns by position defensively (backend already orders, but a stale local snapshot is healed)', async () => {
      const store = seedStore([
        ws('ws_1', 'W1', [
          // Pre-existing (wrong-order) local snapshot.
          item('item_1', 'Sprint', 'kanban', {
            kanban_columns: [column('c3', 'done', 2, 'item_1')],
          }),
        ]),
      ])
      vi.spyOn(api, 'listKanbanColumns').mockResolvedValue({
        columns: [
          column('c2', 'in progress', 1, 'item_1'),
          column('c1', 'todo', 0, 'item_1'),
        ],
        count: 2,
      })

      await store.fetchKanbanColumns('ws_1', 'item_1')

      const wsRow = store.workspaces.find((w) => w.id === 'ws_1')!
      const updatedItem = wsRow.items.find((i) => i.id === 'item_1')!
      expect(updatedItem.kanban_columns?.map((c) => c.id)).toEqual(['c1', 'c2'])
    })

    it('leaves existing columns untouched if the API call fails (graceful degradation)', async () => {
      const consoleErrorSpy = vi.spyOn(console, 'error').mockImplementation(() => {})
      const store = seedStore([
        ws('ws_1', 'W1', [
          // Pre-existing snapshot (stale but not empty).
          item('item_1', 'Sprint', 'kanban', {
            kanban_columns: [column('c1', 'todo', 0, 'item_1')],
          }),
        ]),
      ])
      vi.spyOn(api, 'listKanbanColumns').mockRejectedValue(new Error('network'))

      await store.fetchKanbanColumns('ws_1', 'item_1')

      const wsRow = store.workspaces.find((w) => w.id === 'ws_1')!
      const updatedItem = wsRow.items.find((i) => i.id === 'item_1')!
      // Existing columns preserved on failure (not cleared).
      expect(updatedItem.kanban_columns?.map((c) => c.id)).toEqual(['c1'])
      expect(consoleErrorSpy).toHaveBeenCalled()
      consoleErrorSpy.mockRestore()
    })
  })

  // ─── updateKanbanItemName ─────────────────────────────────────────────── The kanban header
  // rename (from KanbanSettingsDialog's inline pencil or KanbanView's header pencil) hits the store
  // via this action.
  describe('updateKanbanItemName', () => {
    it('calls api.updateWorkspaceItem with the new name and optimistic-updates the local store', async () => {
      const store = seedStore([
        ws('ws_1', 'W1', [item('item_1', 'Old Name', 'kanban')]),
      ])
      const updateWorkspaceItemMock = vi
        .spyOn(api, 'updateWorkspaceItem')
        .mockResolvedValueOnce({
          id: 'item_1',
          name: 'New Name',
           
          item_type: 'kanban',
          path: null,
        // eslint-disable-next-line @typescript-eslint/no-explicit-any
        } as any)

      await store.updateKanbanItemName('ws_1', 'item_1', 'New Name')

      expect(updateWorkspaceItemMock).toHaveBeenCalledWith('ws_1', 'item_1', {
        name: 'New Name',
      })
      // Optimistic update: the local item reflects the new name.
      const wsRow = store.workspaces.find((w) => w.id === 'ws_1')!
      const updatedItem = wsRow.items.find((i) => i.id === 'item_1')!
      expect(updatedItem.name).toBe('New Name')
    })

    it('rolls back the local name and rethrows when the API fails', async () => {
      const consoleErrorSpy = vi
        .spyOn(console, 'error')
        .mockImplementation(() => {})
      const store = seedStore([
        ws('ws_1', 'W1', [item('item_1', 'Old Name', 'kanban')]),
      ])
      vi.spyOn(api, 'updateWorkspaceItem').mockRejectedValueOnce(
        new Error('boom'),
      )

      await expect(
        store.updateKanbanItemName('ws_1', 'item_1', 'New Name'),
      ).rejects.toThrow('boom')

      // Optimistic update was rolled back.
      const wsRow = store.workspaces.find((w) => w.id === 'ws_1')!
      const updatedItem = wsRow.items.find((i) => i.id === 'item_1')!
      expect(updatedItem.name).toBe('Old Name')
      expect(consoleErrorSpy).toHaveBeenCalled()
      consoleErrorSpy.mockRestore()
    })
  })
})
