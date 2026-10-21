/** Tests for workspacesStore.activeTaskWorkspaceItemId (added by
 * , Task 1). The "which kanban item owns
 * the active task" lookup used to be a local computed in AppLayout.vue (lines 701-712). */
import { beforeEach, describe, expect, it } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'

import {
  useWorkspacesStore,
  type Workspace,
  type WorkspaceItem,
  type Task,
} from '../stores/workspaces'
import { makeLocalStorageStub } from './helpers'

const WS_ID = 'ws_1'
const KANBAN_ID = 'item_kanban_1'
const FOLDER_ID = 'item_folder_1'
const TASK_ID = 'task_in_kanban'

const makeTask = (overrides: Partial<Task> = {}): Task => ({
  id: TASK_ID,
  name: 'Hello',
  ...overrides,
})

const makeKanbanItem = (overrides: Partial<WorkspaceItem> = {}): WorkspaceItem => ({
  id: KANBAN_ID,
  name: 'Sprint A',
  item_type: 'kanban',
  tasks: [],
  ...overrides,
})

const makeFolderItem = (overrides: Partial<WorkspaceItem> = {}): WorkspaceItem => ({
  id: FOLDER_ID,
  name: 'Docs',
  item_type: 'folder',
  tasks: [],
  ...overrides,
})

const makeWorkspace = (items: WorkspaceItem[]): Workspace => ({
  id: WS_ID,
  name: 'WS',
  icon: '📁',
  expanded: true,
  items,
})

describe('workspacesStore.activeTaskWorkspaceItemId', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    // The store calls localStorage on init / setActiveWorkspaceItem,
    // so install a stub before any store mutation.
    Object.defineProperty(globalThis, 'localStorage', {
      value: makeLocalStorageStub(),
      writable: true,
      configurable: true,
    })
  })

  it('returns null when activeTaskId is null', () => {
    const store = useWorkspacesStore()
    store.workspaces = [
      makeWorkspace([
        makeKanbanItem({ tasks: [makeTask()] }),
        makeFolderItem(),
      ]),
    ]
    // No setActiveTask call — activeTaskId stays null.
    expect(store.activeTaskWorkspaceItemId).toBeNull()
  })

  it('returns the owning item.id when activeTaskId matches a task under an item', () => {
    const store = useWorkspacesStore()
    store.workspaces = [
      makeWorkspace([
        makeKanbanItem({ tasks: [makeTask()] }),
        makeFolderItem(),
      ]),
    ]
    store.setActiveWorkspaceItem(KANBAN_ID)
    store.setActiveTask(TASK_ID)

    expect(store.activeTaskWorkspaceItemId).toBe(KANBAN_ID)
  })

  it('returns null when activeTaskId does not match any task', () => {
    const store = useWorkspacesStore()
    store.workspaces = [
      makeWorkspace([
        makeKanbanItem({ tasks: [makeTask()] }),
        makeFolderItem(),
      ]),
    ]
    store.setActiveWorkspaceItem(KANBAN_ID)
    // Set an active task id that no workspace has.
    store.setActiveTask('task_does_not_exist')

    expect(store.activeTaskWorkspaceItemId).toBeNull()
  })
})
