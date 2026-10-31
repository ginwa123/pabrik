/** Behavioural test for the design-items-hide-tasks-section change.4 tests: 1. */
import { beforeEach, describe, expect, it } from 'vitest'
import { flushPromises, mount } from '@vue/test-utils'
import { setActivePinia, createPinia } from 'pinia'
import WorkspaceItem from '../components/workspace/WorkspaceItem.vue'
import { useWorkspacesStore } from '../stores/workspaces'
import type { WorkspaceItem as WorkspaceItemType } from '../stores/workspaces'

const WS_ID = 'ws_1'
const ITEM_ID = 'item_1'

function makeDesignItem(overrides: Partial<WorkspaceItemType> = {}): WorkspaceItemType {
  return {
    id: ITEM_ID,
    name: 'design',
    item_type: 'design',
    path: '/tmp/test',
    design_elements: [],
    tasks: [
      // chat tasks linked 1:1 to each design page (the noise we
      // want to hide).
      {
        id: 'task_design_chat_1',
        name: 'Design Chat: AI Chat View',
        description: '',
        tags: [],
        
        
        
        is_pinned: false,
        task_type: 'standard',
        kanban_column_id: null,
      },
      {
        id: 'task_design_chat_2',
        name: 'fix-layout',
        description: '',
        tags: [],
        
        
        
        is_pinned: false,
        task_type: 'standard',
        kanban_column_id: null,
      },
    ],
    ...overrides,
  }
}

function makeKanbanItem(overrides: Partial<WorkspaceItemType> = {}): WorkspaceItemType {
  return {
    id: ITEM_ID,
    name: 'kanban',
    item_type: 'kanban',
    path: '/tmp/test',
    tasks: [
      {
        id: 'task_k1',
        name: 'Task Alpha',
        description: '',
        tags: [],
        
        
        
        is_pinned: false,
        task_type: 'standard',
        kanban_column_id: null,
      },
    ],
    ...overrides,
  }
}

function makeFolderItem(overrides: Partial<WorkspaceItemType> = {}): WorkspaceItemType {
  return {
    id: ITEM_ID,
    name: 'folder',
    item_type: 'folder',
    path: '/tmp/test',
    tasks: [
      {
        id: 'task_f1',
        name: 'task in folder',
        description: '',
        tags: [],
        
        
        
        is_pinned: false,
        task_type: 'standard',
        kanban_column_id: null,
      },
    ],
    ...overrides,
  }
}

function mountItem(item: WorkspaceItemType, _expanded: boolean) {
  return mount(WorkspaceItem, {
    props: {
      item,
      isActive: true,
      workspaceId: WS_ID,
    },
  })
}

describe('WorkspaceItem — design items hide the tasks list section', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
  })

  it('expanded DESIGN item: tasks section absent, design pages section present', async () => {
    // Force the design item to be expanded.
    const store = useWorkspacesStore()
    store.expandedItemIds[ITEM_ID] = true

    const item = makeDesignItem()
    const wrapper = mountItem(item, true)

    await flushPromises()

    // The pre-fix Tasks List block has data-testid-bearing task rows
    // (data-task-id). For design items, NONE of those should exist.
    const taskRows = wrapper.findAll('[data-task-id]')
    expect(taskRows).toHaveLength(0)

    // The new Design Pages section should be present. The pre-fix
    // had no testid on the container; check for the + Add Page
    // button instead (only rendered in the design pages section).
    expect(wrapper.find('[data-testid="design-sidebar-add-page-button"]').exists()).toBe(true)

    wrapper.unmount()
  })

  it('expanded KANBAN item: no sidebar task list — the board owns its tasks', async () => {
    const store = useWorkspacesStore()
    store.expandedItemIds[ITEM_ID] = true

    const item = makeKanbanItem()
    const wrapper = mountItem(item, true)

    await flushPromises()

    // Kanban rows are excluded from the sidebar task list for the same reason they get no Add-task
    // entry: the board is where a board's tasks are read and created.
    expect(wrapper.findAll('[data-task-id]')).toHaveLength(0)

    // No design pages section for kanban items.
    expect(wrapper.find('[data-testid="design-sidebar-add-page-button"]').exists()).toBe(false)

    wrapper.unmount()
  })

  it('expanded FOLDER item: tasks section rendered as before (regression)', async () => {
    const store = useWorkspacesStore()
    store.expandedItemIds[ITEM_ID] = true

    const item = makeFolderItem()
    const wrapper = mountItem(item, true)

    await flushPromises()

    // Tasks section should render for folder items — 1 task row.
    const taskRows = wrapper.findAll('[data-task-id]')
    expect(taskRows.length).toBeGreaterThan(0)

    // No design pages section for folder items.
    expect(wrapper.find('[data-testid="design-sidebar-add-page-button"]').exists()).toBe(false)

    wrapper.unmount()
  })

  it('collapsed DESIGN item with no pages: nothing rendered under the row', async () => {
    // Even with tasks populated, an un-expanded design item should not render anything below the
    // row (the tasks-section guard is `isExpanded && item.item_type !== 'design'` — when collapsed,
    // neither section renders).
    const store = useWorkspacesStore()
    store.expandedItemIds[ITEM_ID] = false

    const item = makeDesignItem()
    const wrapper = mountItem(item, false)

    await flushPromises()

    // Neither section renders when collapsed.
    expect(wrapper.findAll('[data-task-id]')).toHaveLength(0)
    expect(wrapper.find('[data-testid="design-sidebar-add-page-button"]').exists()).toBe(false)

    wrapper.unmount()
  })
})
