/**
 * workspacesStore — wire→in-memory date normalization for tasks.
 *
 * Bug: the backend's `GET .../tasks` returns `updated_at` and `created_at`
 * as snake_case UTC strings (e.g. "2026-08-05 04:24:56"). The frontend
 * `Task` interface declares `updatedAt?: Date` and `createdAt?: Date`
 * (camelCase, Date object). Without mapping, the kanban card's meta-row
 * time pill (`lastUpdatedLabel` in WorkspaceItemTaskCard.vue) is always
 * empty — `props.task.updatedAt` is undefined for every wire task.
 *
 * Fix: extend `normalizeTaskTags` in `workspaces.ts` (already runs at
 * every fetch site + addTask optimistic write) to:
 *   1. parse `updated_at` string → `updatedAt` Date (only when missing)
 *   2. parse `created_at` string → `createdAt` Date (only when missing)
 *
 * The "only when missing" guard preserves the optimistic-write path:
 * `addTask` (workspaces.ts:1147) sets `updatedAt: new Date()` directly.
 * A re-fetch shouldn't overwrite a fresh Date with a stale parsed string.
 *
 * Wire format: `"YYYY-MM-DD HH:MM:SS"` in UTC. Backend emits this from
 * SQLite's DATETIME columns (TEXT, UTC). The frontend's
 * `formatRelativeTime` already tolerates this format (with explicit `Z`
 * injection for the Date ctor), so the parse helper centralises the
 * same convention.
 */
import { describe, it, expect, beforeEach, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import * as api from '../api'
import type { Task } from '../api'

vi.mock('../api', async (importOriginal) => {
  const actual = await importOriginal<typeof api>()
  return {
    ...actual,
    getTasks: vi.fn(),
  }
})

/** The actual fixtures need to round-trip through the store. We use a minimal stub of
 * `useWorkspacesStore.normalizeTaskTags` — but the helper is module-private. So we test it
 * indirectly via the store's public action surface (`fetchKanbanTasks` + `init`) which calls it. */
/** The pattern: mock `api.getTasks` to return a wire-shaped payload, call the store action, then
 * read the resulting tasks out of the store and assert their `updatedAt` / `createdAt` are real
 * Date instances derived from the wire strings. */
describe('normalizeTaskTags — wire→in-memory date mapping', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    vi.clearAllMocks()
  })

  it('maps wire updated_at (snake_case string) to updatedAt Date', async () => {
    const { useWorkspacesStore } = await import('../stores/workspaces')
    const store = useWorkspacesStore()

    // Workspace + item fixture
    store.workspaces.push({
      id: 'ws_1',
      name: 'Test',
      icon: '📁',
      expanded: true,
      items: [
        {
          id: 'item_1',
          name: 'Sprint',
          item_type: 'kanban',
          tasks: [],
          kanban_columns: [
            { id: 'col_a', name: 'Todo', position: 0 },
            { id: 'col_b', name: 'Done', position: 1 },
          ],
        } as never,
      ],
    })

    vi.mocked(api.getTasks).mockResolvedValueOnce({
      tasks: [
        {
          id: 'task_a',
          name: 'Wire task',
          created_at: '2026-08-05 04:22:09',
          updated_at: '2026-08-05 04:24:56',
          tags: '["kanban"]',
          git_branch: null,
        } as unknown as Task,
      ],
      has_more: false,
      next_cursor: null,
    })

    await store.fetchKanbanTasks('ws_1', 'item_1', 'col_a', 100)

    const task = store.workspaces[0]!.items[0]!.tasks![0]!
    // The fixture shape returned by the wire uses snake_case strings.
    // After normalization, the camelCase Date fields should be set.
    expect(task.updatedAt).toBeInstanceOf(Date)
    expect(task.createdAt).toBeInstanceOf(Date)
    // The parsed values match the wire strings (treated as UTC).
    expect((task.updatedAt as Date).toISOString()).toBe('2026-08-05T04:24:56.000Z')
    expect((task.createdAt as Date).toISOString()).toBe('2026-08-05T04:22:09.000Z')
  })

  it('tolerates ISO datetime strings with explicit Z on the wire', async () => {
    const { useWorkspacesStore } = await import('../stores/workspaces')
    const store = useWorkspacesStore()

    store.workspaces.push({
      id: 'ws_1',
      name: 'Test',
      icon: '📁',
      expanded: true,
      items: [
        {
          id: 'item_1',
          name: 'Sprint',
          item_type: 'kanban',
          tasks: [],
          kanban_columns: [{ id: 'col_a', name: 'Todo', position: 0 }],
        } as never,
      ],
    })

    vi.mocked(api.getTasks).mockResolvedValueOnce({
      tasks: [
        {
          id: 'task_iso',
          name: 'ISO task',
          created_at: '2026-08-05T04:22:09Z',
          updated_at: '2026-08-05T04:24:56Z',
          tags: '',
          git_branch: null,
        } as unknown as Task,
      ],
      has_more: false,
      next_cursor: null,
    })

    await store.fetchKanbanTasks('ws_1', 'item_1', 'col_a', 100)

    const task = store.workspaces[0]!.items[0]!.tasks![0]!
    expect(task.updatedAt).toBeInstanceOf(Date)
    expect(task.createdAt).toBeInstanceOf(Date)
    expect((task.updatedAt as Date).toISOString()).toBe('2026-08-05T04:24:56.000Z')
  })

  it('does not overwrite an existing updatedAt Date (preserves optimistic writes)', async () => {
    const { useWorkspacesStore } = await import('../stores/workspaces')
    const store = useWorkspacesStore()

    // Pre-populate the store with an optimistic task that has a Date
    // updatedAt. After fetch, the wire's stale string should NOT
    // overwrite this fresh Date.
    const freshDate = new Date('2026-08-06T10:00:00Z')
    store.workspaces.push({
      id: 'ws_1',
      name: 'Test',
      icon: '📁',
      expanded: true,
      items: [
        {
          id: 'item_1',
          name: 'Sprint',
          item_type: 'kanban',
          tasks: [
            {
              id: 'task_existing',
              name: 'Existing',
              updatedAt: freshDate,
            } as Task,
          ],
          kanban_columns: [{ id: 'col_a', name: 'Todo', position: 0 }],
        } as never,
      ],
    })

    vi.mocked(api.getTasks).mockResolvedValueOnce({
      tasks: [
        {
          id: 'task_existing',
          name: 'Existing',
          created_at: '2026-08-05 04:22:09',
          updated_at: '2026-08-05 04:24:56', // older than freshDate
          tags: '',
          git_branch: null,
        } as unknown as Task,
      ],
      has_more: false,
      next_cursor: null,
    })

    await store.fetchKanbanTasks('ws_1', 'item_1', 'col_a', 100)

    const task = store.workspaces[0]!.items[0]!.tasks![0]!
    // The fresh Date survives — fetch cannot regress updatedAt
    expect(task.updatedAt).toBe(freshDate)
  })

  it('handles legacy tasks without updated_at (returns undefined, no crash)', async () => {
    const { useWorkspacesStore } = await import('../stores/workspaces')
    const store = useWorkspacesStore()

    store.workspaces.push({
      id: 'ws_1',
      name: 'Test',
      icon: '📁',
      expanded: true,
      items: [
        {
          id: 'item_1',
          name: 'Sprint',
          item_type: 'kanban',
          tasks: [],
          kanban_columns: [{ id: 'col_a', name: 'Todo', position: 0 }],
        } as never,
      ],
    })

    vi.mocked(api.getTasks).mockResolvedValueOnce({
      tasks: [
        {
          id: 'task_legacy',
          name: 'Legacy task',
          // No created_at / updated_at — older fixture or mock
          tags: '',
          git_branch: null,
        } as unknown as Task,
      ],
      has_more: false,
      next_cursor: null,
    })

    await store.fetchKanbanTasks('ws_1', 'item_1', 'col_a', 100)

    const task = store.workspaces[0]!.items[0]!.tasks![0]!
    // No crash; updatedAt is undefined.
    expect(task.updatedAt).toBeUndefined()
    expect(task.createdAt).toBeUndefined()
  })

  it('handles malformed wire string (returns undefined for that field)', async () => {
    const { useWorkspacesStore } = await import('../stores/workspaces')
    const store = useWorkspacesStore()

    store.workspaces.push({
      id: 'ws_1',
      name: 'Test',
      icon: '📁',
      expanded: true,
      items: [
        {
          id: 'item_1',
          name: 'Sprint',
          item_type: 'kanban',
          tasks: [],
          kanban_columns: [{ id: 'col_a', name: 'Todo', position: 0 }],
        } as never,
      ],
    })

    vi.mocked(api.getTasks).mockResolvedValueOnce({
      tasks: [
        {
          id: 'task_bad',
          name: 'Bad date',
          created_at: 'not-a-date',
          updated_at: '2026-08-05 04:24:56', // valid
          tags: '',
          git_branch: null,
        } as unknown as Task,
      ],
      has_more: false,
      next_cursor: null,
    })

    await store.fetchKanbanTasks('ws_1', 'item_1', 'col_a', 100)

    const task = store.workspaces[0]!.items[0]!.tasks![0]!
    // Valid updated_at parsed; invalid created_at falls back to undefined.
    expect(task.updatedAt).toBeInstanceOf(Date)
    expect((task.updatedAt as Date).toISOString()).toBe('2026-08-05T04:24:56.000Z')
    expect(task.createdAt).toBeUndefined()
  })
})
