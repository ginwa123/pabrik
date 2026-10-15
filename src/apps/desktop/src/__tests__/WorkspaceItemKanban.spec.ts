/**
 * Tests for the kanban branch of WorkspaceItem.vue after the
 * inline-board → main-content migration (2026-06-21). The kanban
 * board NO LONGER renders inside WorkspaceItem (it lives in
 * AppLayout's main content area). These tests verify:
 *   - item_type='kanban' does NOT render <KanbanView> inline
 *   - item_type='kanban' does NOT render <KanbanColumnEditor>
 *   - item_type='kanban' does NOT emit the kanban-* events
 *     (those now fire from <AppLayout>'s <KanbanView>)
 *   - item_type='folder' (or other) renders the existing task list
 *   - clicking a kanban item emits 'click' but does NOT toggle
 *     expansion (folder items still toggle)
 *
 * The actual <KanbanView> rendering in the main content area is
 * tested in AppLayout.kanban.spec.ts.
 *
 * Plan: docs/superpowers/plans/2026-06-21-workspace-item-kanban.md
 *   Migration chunk / step "Move kanban board to AppLayout"
 */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { mount, type VueWrapper } from '@vue/test-utils'
import { nextTick, ref, type Ref } from 'vue'

import WorkspaceItem from '../components/workspace/WorkspaceItem.vue'
import { useWorkspacesStore } from '../stores/workspaces'
import type { WorkspaceItem as WorkspaceItemType, KanbanColumn, Task } from '../stores/workspaces'
import { makeLocalStorageStub } from './helpers'

const WS_ID = 'ws_1'
const ITEM_ID = 'item_1'

const makeColumn = (overrides: Partial<KanbanColumn> = {}): KanbanColumn => ({
  id: 'col_a',
  workspace_item_id: ITEM_ID,
  name: 'todo',
  position: 0,
  created_at: '2026-06-21 12:00:00',
  ...overrides,
})

const makeTask = (overrides: Partial<Task> = {}): Task => ({
  id: 'task_1',
  name: 'My Task',
  ...overrides,
})

const makeKanbanItem = (overrides: Partial<WorkspaceItemType> = {}): WorkspaceItemType => ({
  id: ITEM_ID,
  name: 'My Sprint',
  item_type: 'kanban',
  kanban_columns: [makeColumn()],
  tasks: [],
  ...overrides,
})

const makeFolderItem = (overrides: Partial<WorkspaceItemType> = {}): WorkspaceItemType => ({
  id: ITEM_ID,
  name: 'My Project',
  item_type: 'folder',
  path: '/abs/path',
  tasks: [],
  ...overrides,
})

function mountItem(item: WorkspaceItemType, isActive = false) {
  const processingState: Ref<Record<string, boolean>> = ref({})
  return mount(WorkspaceItem, {
    props: {
      item,
      isActive,
      workspaceId: WS_ID,
    },
    global: {
      provide: { processingState },
    },
  })
}

function expandItem(): void {
  // Tasks are only rendered when the parent item is expanded.
  // Mutate `expandedItemIds` and reassign to trigger reactivity,
  // matching the production toggle.
  const ws = useWorkspacesStore()
  ws.expandedItemIds[ITEM_ID] = true
  ws.expandedItemIds = { ...ws.expandedItemIds }
}

describe('WorkspaceItem — item_type branching (post-kanban-migration)', () => {
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

  it("does NOT render KanbanView inline when item_type='kanban' (board lives in AppLayout)", async () => {
    // Pre-migration, this test verified that KanbanView rendered
    // inline in the sidebar. Post-migration, the kanban board lives
    // in <AppLayout> (rendered in the main content area when
    // activeWorkspaceItem.item_type === 'kanban'). WorkspaceItem
    // should NOT render any board-related DOM — just the item row
    // and the task list (for folder items).
    wrapper = mountItem(makeKanbanItem())
    expandItem()
    await nextTick()
    // data-kanban-view="<id>" was the KanbanView root marker.
    // After the migration, WorkspaceItem should not emit it.
    const kanban = wrapper.find(`[data-kanban-view="${ITEM_ID}"]`)
    expect(kanban.exists()).toBe(false)
    // No columns / cards should be visible.
    expect(wrapper.findAll('[data-kanban-column]')).toHaveLength(0)
    expect(wrapper.findAll('[data-kanban-card]')).toHaveLength(0)
  })

  it("does NOT render KanbanColumnEditor for kanban items (modal moved to AppLayout)", async () => {
    // The KanbanColumnEditor used to live inside WorkspaceItem (gated by `v-if="item.item_type ===
    // 'kanban'"`). After the migration it lives in AppLayout's template. WorkspaceItem should not
    // render it.
    wrapper = mountItem(makeKanbanItem())
    expandItem()
    await nextTick()
    // The editor uses a Teleport to body, so even if it tried to mount, we'd find the modal root by
    // class. Easier check: there is no "Add Column" / "+Column" button in the sidebar (those live
    // in <KanbanView>'s header in the main content).
    expect(wrapper.findAll(`[data-testid="kanban-view-${ITEM_ID}-add-column"]`)).toHaveLength(0)
  })

  it("renders the existing task list when item_type='folder'", async () => {
    wrapper = mountItem(makeFolderItem({ tasks: [makeTask()] }))
    expandItem()
    await nextTick()
    // No kanban DOM should appear.
    const kanban = wrapper.find(`[data-kanban-view="${ITEM_ID}"]`)
    expect(kanban.exists()).toBe(false)
    // The folder-item task row IS rendered.
    expect(wrapper.find('[data-task-id="task_1"]').exists()).toBe(true)
  })

  it("renders the existing task list when item_type='memory' (any non-kanban type)", async () => {
    const item = makeFolderItem({ item_type: 'memory', tasks: [makeTask()] })
    wrapper = mountItem(item)
    expandItem()
    await nextTick()
    const kanban = wrapper.find(`[data-kanban-view="${ITEM_ID}"]`)
    expect(kanban.exists()).toBe(false)
    expect(wrapper.find('[data-task-id="task_1"]').exists()).toBe(true)
  })
})

describe('WorkspaceItem — kanban click behavior', () => {
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

  it("clicking a kanban item does NOT toggle expansion (2026-09-10: no expand on kanban mode)", async () => {
    // Kanban items navigate to the board only — no sidebar expand.
    // The selectItem event still fires — Sidebar uses it to set
    // activeWorkspaceItemId. Agent/folder items still toggle.
    wrapper = mountItem(makeKanbanItem())
    // Find the main item row button (the one with @click="handleClick").
    const button = wrapper.find('button.flex-1')
    expect(button.exists()).toBe(true)
    await button.trigger('click')
    const ws = useWorkspacesStore()
    expect(ws.expandedItemIds[ITEM_ID]).toBeUndefined()
    // The selectItem event MUST still fire (AppLayout relies on it
    // to set activeWorkspaceItemId and route to the kanban view).
    expect(wrapper.emitted('click')).toBeTruthy()
    expect(wrapper.emitted('click')?.length).toBe(1)
  })

  it("clicking a folder item DOES toggle expansion (existing behavior preserved)", async () => {
    wrapper = mountItem(makeFolderItem())
    const button = wrapper.find('button.flex-1')
    expect(button.exists()).toBe(true)
    await button.trigger('click')
    const ws = useWorkspacesStore()
    expect(ws.expandedItemIds[ITEM_ID]).toBe(true)
    expect(wrapper.emitted('click')).toBeTruthy()
  })

  it("does NOT emit kanban-* events for any item type (the events come from KanbanView in AppLayout now)", async () => {
    // Pre-migration, WorkspaceItem re-emitted kanban-* events
    // bubbled up from its inline <KanbanView>. Post-migration,
    // WorkspaceItem has no <KanbanView>, so it cannot bubble any
    // kanban events. The new flow: <KanbanView> in AppLayout
    // emits directly to AppLayout's handlers.
    wrapper = mountItem(
      makeKanbanItem({
        kanban_columns: [makeColumn({ id: 'col_x', position: 0 })],
      }),
    )
    expandItem()
    await nextTick()
    // Even after the click + expand (no-op for kanban), no kanban events should appear. (Folder
    // items never emitted them either, so this guard ensures the migration didn't leave any
    // stragglers.)
    expect(wrapper.emitted('addKanbanTask')).toBeUndefined()
    expect(wrapper.emitted('moveKanbanTask')).toBeUndefined()
    expect(wrapper.emitted('addKanbanColumn')).toBeUndefined()
    expect(wrapper.emitted('renameKanbanColumn')).toBeUndefined()
    expect(wrapper.emitted('deleteKanbanColumn')).toBeUndefined()
  })
})

describe('WorkspaceItem — show-all-arrows (kanban chevron)', () => {
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

  it('renders chevron for kanban items (visual-only, no expand — 2026-09-10)', async () => {
    wrapper = mountItem(makeKanbanItem())
    await nextTick()
    expect(wrapper.find('[data-testid="item-row-chevron"]').exists()).toBe(true)
  })

  it('renders chevron for folder items (regression)', async () => {
    wrapper = mountItem(makeFolderItem())
    await nextTick()
    expect(wrapper.find('[data-testid="item-row-chevron"]').exists()).toBe(true)
  })

  it('expanded kanban does NOT show its tasks inline (2026-09-10: no expand on kanban mode)', async () => {
    wrapper = mountItem(makeKanbanItem({ tasks: [makeTask()] }))
    expandItem()
    await nextTick()
    expect(wrapper.find('[data-task-id="task_1"]').exists()).toBe(false)
  })
})
