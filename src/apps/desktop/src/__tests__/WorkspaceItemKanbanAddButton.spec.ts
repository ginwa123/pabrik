/** Sidebar `+` (Add Task) visibility per item_type (2026-09-09).
 * - kanban items: NO `+` button. Kanban tasks are created from inside
 *   the kanban view (column "+ Add" → KanbanTaskDetailDialog) — the
 *   sidebar picker would bypass the board context. The `×` (Delete
 *   Item) stays visible.
 * - agent / folder items: `+` stays visible (agent skips the picker
 *   and opens a chat directly; folder opens the picker). */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { mount, type VueWrapper } from '@vue/test-utils'
import { ref, type Ref } from 'vue'

import WorkspaceItem from '../components/workspace/WorkspaceItem.vue'
import type { WorkspaceItem as WorkspaceItemType } from '../stores/workspaces'
import { makeLocalStorageStub } from './helpers'

const WS_ID = 'ws_1'
const ITEM_ID = 'item_1'

const makeItem = (itemType: string): WorkspaceItemType =>
  ({
    id: ITEM_ID,
    name: itemType,
    item_type: itemType,
    path: '/abs/path',
    kanban_columns: [],
    tasks: [],
    isLoaded: true,
    isLoading: false,
  }) as unknown as WorkspaceItemType

function mountItem(item: WorkspaceItemType) {
  const processingState: Ref<Record<string, boolean>> = ref({})
  return mount(WorkspaceItem, {
    props: {
      item,
      isActive: false,
      workspaceId: WS_ID,
    },
    global: {
      provide: { processingState },
    },
  })
}

describe('WorkspaceItem — Add Task (+) visibility per item_type (2026-09-09)', () => {
  let wrapper: VueWrapper | null = null

  beforeEach(() => {
    setActivePinia(createPinia())
    Object.defineProperty(globalThis, 'localStorage', {
      value: makeLocalStorageStub(),
      writable: true,
      configurable: true,
    })
  })

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    vi.restoreAllMocks()
  })

  it("kanban item: NO + button (create tasks from the kanban view), × still visible", () => {
    wrapper = mountItem(makeItem('kanban'))
    expect(wrapper.find('[aria-label="Add Task"]').exists()).toBe(false)
    expect(wrapper.find('[aria-label="Delete Item"]').exists()).toBe(true)
  })

  it("agent item: + button visible (direct-to-chat)", () => {
    wrapper = mountItem(makeItem('agent'))
    expect(wrapper.find('[aria-label="Add Task"]').exists()).toBe(true)
  })

  it("folder item (regression): + button visible (picker flow)", () => {
    wrapper = mountItem(makeItem('folder'))
    expect(wrapper.find('[aria-label="Add Task"]').exists()).toBe(true)
  })
})
