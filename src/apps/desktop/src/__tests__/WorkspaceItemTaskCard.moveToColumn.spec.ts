/**
 * "Move to column" — the new context-menu submenu.
 *
 * Two halves are covered:
 *   1. <WorkspaceItemTaskCard> emits the DESTINATION only (it cannot see
 *      the board, so it cannot know the append position).
 *   2. <KanbanColumn> resolves that into the existing `moveTask` shape
 *      its host already handles for drag-and-drop — which is the whole
 *      reason <KanbanView> and AppLayout needed no changes.
 *
 * Plan: docs/superpowers/plans/2026-09-25-kanban-card-context-menu-move-to-column.md
 */
import { beforeEach, describe, expect, it } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { nextTick, ref } from 'vue'
import { mount } from '@vue/test-utils'
import WorkspaceItemTaskCard from '../components/workspace/WorkspaceItemTaskCard.vue'
import KanbanColumn from '../components/kanban/KanbanColumn.vue'
import type { KanbanColumn as KanbanColumnType, Task } from '../stores/workspaces'
import { makeLocalStorageStub } from './helpers'

const ITEM_ID = 'item_1'

// Typed factory rather than a bare literal: KanbanColumn carries workspace_item_id + created_at,
// and a plain object literal silently drifts from the interface the component actually receives.

// The type is aliased because this file also imports the <KanbanColumn> component — same setup as
// KanbanColumn.spec.ts.
const makeColumn = (overrides: Partial<KanbanColumnType> = {}): KanbanColumnType => ({
  id: 'col_todo',
  workspace_item_id: ITEM_ID,
  name: 'todo',
  position: 0,
  created_at: '2026-06-21 12:00:00',
  ...overrides,
})

// DOING is a named handle rather than COLUMNS[1]: the repo enables
// noUncheckedIndexedAccess, so an index reads as `KanbanColumn | undefined`
// and forces a non-null assertion at every use site.
const DOING = makeColumn({ id: 'col_doing', name: 'in progress', position: 1 })

const COLUMNS: KanbanColumnType[] = [
  makeColumn(),
  DOING,
  makeColumn({ id: 'col_done', name: 'merged', position: 2 }),
]

const q = (testid: string) =>
  document.body.querySelector(`[data-testid="${testid}"]`) as HTMLElement | null

function mountCard(
  task: Task,
  columns: KanbanColumnType[] = COLUMNS,
  currentColumnId: string | null = 'col_doing',
) {
  return mount(WorkspaceItemTaskCard, {
    attachTo: document.body,
    props: {
      task,
      workspaceId: 'ws_1',
      itemId: ITEM_ID,
      columns,
      currentColumnId,
    },
    global: { provide: { processingState: ref<Record<string, boolean>>({}) } },
  })
}

async function openMenuToSub(wrapper: ReturnType<typeof mountCard>) {
  await wrapper.find('[data-task-card]').trigger('contextmenu', {
    clientX: 100,
    clientY: 150,
  })
  await nextTick()
  const moveRow = q('kanban-task-context-menu-move')
  if (!moveRow) throw new Error('"Move to column" row not rendered')
  expect(moveRow).toBeTruthy()
  moveRow!.dispatchEvent(new MouseEvent('mouseenter', { bubbles: false }))
  await nextTick()
  await nextTick()
}

describe('Move to column — submenu visibility', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    Object.defineProperty(globalThis, 'localStorage', {
      value: makeLocalStorageStub(),
      writable: true,
      configurable: true,
    })
    document.body.innerHTML = ''
  })

  it('hides the row entirely when the board has no columns loaded', async () => {
    // Sidebar-row host / legacy board. A submenu that can only be a dead
    // end is worse than no submenu.
    const wrapper = mountCard({ id: 't1', name: 'Alpha' }, [], null)
    await wrapper.find('[data-task-card]').trigger('contextmenu', { clientX: 10, clientY: 10 })
    await nextTick()

    expect(q('kanban-task-context-menu-move')).toBeNull()
    wrapper.unmount()
  })

  it('hides the row when the board has only ONE column (nowhere to move)', async () => {
    const wrapper = mountCard({ id: 't1', name: 'Alpha' }, [DOING], 'col_doing')
    await wrapper.find('[data-task-card]').trigger('contextmenu', { clientX: 10, clientY: 10 })
    await nextTick()

    expect(q('kanban-task-context-menu-move')).toBeNull()
    wrapper.unmount()
  })

  it('lists every column and marks the current one with ●', async () => {
    const wrapper = mountCard({ id: 't1', name: 'Alpha' })
    await openMenuToSub(wrapper)

    expect(q('kanban-task-context-menu-sub')).toBeTruthy()
    const current = q('kanban-task-context-menu-sub-col_doing')
    const other = q('kanban-task-context-menu-sub-col_done')
    expect(current?.getAttribute('data-current')).toBe('true')
    expect(current?.getAttribute('aria-disabled')).toBe('true')
    expect(current?.textContent).toContain('●')
    expect(other?.getAttribute('data-current')).toBeNull()
    expect(other?.textContent).not.toContain('●')

    wrapper.unmount()
  })
})

describe('Move to column — picking a destination', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    Object.defineProperty(globalThis, 'localStorage', {
      value: makeLocalStorageStub(),
      writable: true,
      configurable: true,
    })
    document.body.innerHTML = ''
  })

  it('emits moveTaskToColumn with the destination column id', async () => {
    const wrapper = mountCard({ id: 't1', name: 'Alpha' })
    await openMenuToSub(wrapper)

    q('kanban-task-context-menu-sub-col_done')!.click()
    await nextTick()

    expect(wrapper.emitted('moveTaskToColumn')?.[0]).toEqual([
      { taskId: 't1', columnId: 'col_done' },
    ])

    wrapper.unmount()
  })

  it('picking the CURRENT column is a no-op (no wasted POST)', async () => {
    const wrapper = mountCard({ id: 't1', name: 'Alpha' })
    await openMenuToSub(wrapper)

    q('kanban-task-context-menu-sub-col_doing')!.click()
    await nextTick()

    expect(wrapper.emitted('moveTaskToColumn')).toBeUndefined()

    wrapper.unmount()
  })
})

describe('Move to column — <KanbanColumn> resolves the append position', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    Object.defineProperty(globalThis, 'localStorage', {
      value: makeLocalStorageStub(),
      writable: true,
      configurable: true,
    })
    document.body.innerHTML = ''
  })

  // "merged" holds two tasks, so an append there must be position 2.
  const BOARD_TASKS: Task[] = [
    { id: 'a', name: 'A', kanban_column_id: 'col_doing' },
    { id: 'b', name: 'B', kanban_column_id: 'col_done' },
    { id: 'c', name: 'C', kanban_column_id: 'col_done' },
  ] as Task[]

  function mountColumn(tasks: Task[]) {
    return mount(KanbanColumn, {
      attachTo: document.body,
      props: {
        column: DOING,
        tasks,
        workspaceId: 'ws_1',
        itemId: ITEM_ID,
        columns: COLUMNS,
      },
      global: {
        stubs: {
          VirtualScroller: {
            props: ['items'],
            template: '<div><slot v-for="i in items" :item="i" :key="i.id" /></div>',
          },
        },
        provide: { processingState: ref<Record<string, boolean>>({}) },
      },
    })
  }

  it('re-emits as moveTask with position = the target column card count', async () => {
    const wrapper = mountColumn(BOARD_TASKS)
    const card = wrapper.findAllComponents(WorkspaceItemTaskCard)[0]!
    expect(card.exists()).toBe(true)

    card.vm.$emit('moveTaskToColumn', { taskId: 'a', columnId: 'col_done' })
    await nextTick()

    // Two tasks already in col_done → append lands at position 2.
    expect(wrapper.emitted('moveTask')?.[0]).toEqual([
      { taskId: 'a', columnId: 'col_done', position: 2 },
    ])

    wrapper.unmount()
  })

  it('does not emit when the destination is the column the card is already in', async () => {
    const wrapper = mountColumn(BOARD_TASKS)
    const card = wrapper.findAllComponents(WorkspaceItemTaskCard)[0]!
    expect(card.exists()).toBe(true)

    card.vm.$emit('moveTaskToColumn', { taskId: 'a', columnId: 'col_doing' })
    await nextTick()

    expect(wrapper.emitted('moveTask')).toBeUndefined()

    wrapper.unmount()
  })
})
