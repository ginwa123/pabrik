/**
 * workspacesStore — wire→in-memory image_urls normalization for tasks.
 *
 * Bug (2026-08-24, "theres a image urls but the image attachment not
 * showup"): the backend's `GET .../tasks` + `GET .../tasks/:id` return
 * `image_urls` as a snake_case `||`-delimited base64 data URL string
 * (visible in the browser Network tab). The frontend `Task` interface
 * declares camelCase `imageUrls?: string[]`, and
 * `normalizeTaskImageUrlsInPlace` only read the camelCase field — so on
 * every freshly-fetched task the camelCase field was `undefined`, the
 * normalizer early-returned, and the wire string leaked through
 * unsplit. Result: the Task details dialog gallery
 * (`kanban-task-detail-image-gallery`) and the board card thumbnail
 * strip (`WorkspaceItemTaskCard`) never rendered any images.
 *
 * Fix: bridge the snake_case wire field inside
 * `normalizeTaskImageUrlsInPlace` (same pattern as
 * `normalizeTaskDatesInPlace`, which reads `updated_at`/`created_at`
 * wire fields). Tags don't need a bridge because the name is identical
 * on both sides of the wire.
 *
 * Test strategy: `normalizeTaskTags` is module-private, so we exercise
 * it through the store's public `fetchKanbanTasks` action with a
 * mocked `api.getTasks` returning wire-shaped payloads (same pattern
 * as workspacesStoreNormalizeTaskDates.spec.ts).
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

const DATA_URL_A = 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABC'
const DATA_URL_B = 'data:image/jpeg;base64,/9j/4AAQSkZJRgABAQEAYABgAAD'

function seedStore() {
  return { id: 'ws_1', name: 'Test', icon: '📁', expanded: true, items: [
    {
      id: 'item_1',
      name: 'Sprint',
      item_type: 'kanban',
      tasks: [],
      kanban_columns: [{ id: 'col_a', name: 'Todo', position: 0 }],
    },
  ] } as never
}

describe('normalizeTaskTags — wire image_urls → imageUrls mapping', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    vi.clearAllMocks()
  })

  it('splits wire image_urls (snake_case ||-joined string) into imageUrls array', async () => {
    const { useWorkspacesStore } = await import('../stores/workspaces')
    const store = useWorkspacesStore()
    store.workspaces.push(seedStore())

    vi.mocked(api.getTasks).mockResolvedValueOnce({
      tasks: [
        {
          id: 'task_img',
          name: 'With images',
          image_urls: `${DATA_URL_A}||${DATA_URL_B}`,
          tags: '',
          git_branch: null,
        } as unknown as Task,
      ],
      has_more: false,
      next_cursor: null,
    })

    await store.fetchKanbanTasks('ws_1', 'item_1', 'col_a', 100)

    const task = store.workspaces[0]!.items[0]!.tasks![0]!
    expect(Array.isArray(task.imageUrls)).toBe(true)
    expect(task.imageUrls).toEqual([DATA_URL_A, DATA_URL_B])
  })

  it('handles a single wire image (no || delimiter)', async () => {
    const { useWorkspacesStore } = await import('../stores/workspaces')
    const store = useWorkspacesStore()
    store.workspaces.push(seedStore())

    vi.mocked(api.getTasks).mockResolvedValueOnce({
      tasks: [
        {
          id: 'task_img1',
          name: 'One image',
          image_urls: DATA_URL_A,
          tags: '',
          git_branch: null,
        } as unknown as Task,
      ],
      has_more: false,
      next_cursor: null,
    })

    await store.fetchKanbanTasks('ws_1', 'item_1', 'col_a', 100)

    const task = store.workspaces[0]!.items[0]!.tasks![0]!
    expect(task.imageUrls).toEqual([DATA_URL_A])
  })

  it('maps empty wire image_urls string to empty array (no images)', async () => {
    const { useWorkspacesStore } = await import('../stores/workspaces')
    const store = useWorkspacesStore()
    store.workspaces.push(seedStore())

    vi.mocked(api.getTasks).mockResolvedValueOnce({
      tasks: [
        {
          id: 'task_noimg',
          name: 'No images',
          image_urls: '',
          tags: '',
          git_branch: null,
        } as unknown as Task,
      ],
      has_more: false,
      next_cursor: null,
    })

    await store.fetchKanbanTasks('ws_1', 'item_1', 'col_a', 100)

    const task = store.workspaces[0]!.items[0]!.tasks![0]!
    expect(task.imageUrls).toEqual([])
  })

  it('filters empty segments from consecutive || delimiters', async () => {
    const { useWorkspacesStore } = await import('../stores/workspaces')
    const store = useWorkspacesStore()
    store.workspaces.push(seedStore())

    vi.mocked(api.getTasks).mockResolvedValueOnce({
      tasks: [
        {
          id: 'task_gap',
          name: 'Gappy',
          image_urls: `${DATA_URL_A}||||${DATA_URL_B}||`,
          tags: '',
          git_branch: null,
        } as unknown as Task,
      ],
      has_more: false,
      next_cursor: null,
    })

    await store.fetchKanbanTasks('ws_1', 'item_1', 'col_a', 100)

    const task = store.workspaces[0]!.items[0]!.tasks![0]!
    expect(task.imageUrls).toEqual([DATA_URL_A, DATA_URL_B])
  })

  it('does not overwrite an existing camelCase imageUrls array (optimistic writes)', async () => {
    const { useWorkspacesStore } = await import('../stores/workspaces')
    const store = useWorkspacesStore()
    const optimistic = [DATA_URL_A]
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
              imageUrls: optimistic,
            } as Task,
          ],
          kanban_columns: [{ id: 'col_a', name: 'Todo', position: 0 }],
        },
      ],
    } as never)

    vi.mocked(api.getTasks).mockResolvedValueOnce({
      tasks: [
        {
          id: 'task_existing',
          name: 'Existing',
          image_urls: DATA_URL_B,
          tags: '',
          git_branch: null,
        } as unknown as Task,
      ],
      has_more: false,
      next_cursor: null,
    })

    await store.fetchKanbanTasks('ws_1', 'item_1', 'col_a', 100)

    const task = store.workspaces[0]!.items[0]!.tasks![0]!
    // The optimistic array survives — the bridge only fires when the
    // camelCase field is undefined. (Value equality, not reference:
    // the store's reactivity wraps arrays in a Proxy.)
    expect(task.imageUrls).toEqual(optimistic)
  })

  it('leaves tasks without any image field untouched (legacy fixtures)', async () => {
    const { useWorkspacesStore } = await import('../stores/workspaces')
    const store = useWorkspacesStore()
    store.workspaces.push(seedStore())

    vi.mocked(api.getTasks).mockResolvedValueOnce({
      tasks: [
        {
          id: 'task_legacy',
          name: 'Legacy',
          tags: '',
          git_branch: null,
        } as unknown as Task,
      ],
      has_more: false,
      next_cursor: null,
    })

    await store.fetchKanbanTasks('ws_1', 'item_1', 'col_a', 100)

    const task = store.workspaces[0]!.items[0]!.tasks![0]!
    expect(task.imageUrls).toBeUndefined()
  })
})
