/** workspacesStore — wire→in-memory image_urls normalization for tasks. */
import { describe, it, expect, beforeEach, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import * as api from '../api'
import type { Task } from '../api'
import { normalizeTaskTags } from '../stores/workspaces/normalize'

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

  it('keeps an existing camelCase imageUrls array instead of the wire string', () => {
    // Same rule as the dates: the wire→camel bridge only fires when the camelCase field is absent, so
    // an optimistic local array is never replaced by a stale wire value.
    const task = normalizeTaskTags({
      id: 'task_existing',
      name: 'Existing',
      imageUrls: [DATA_URL_A],
      image_urls: DATA_URL_B,
    } as unknown as Task)

    expect(task.imageUrls).toEqual([DATA_URL_A])
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
