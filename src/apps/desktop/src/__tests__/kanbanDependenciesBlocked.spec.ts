/**
 * Blocked badge on both twins (WorkspaceItemTaskCard, KanbanTaskRow): hidden when `is_blocked` is falsy, else count + names.
 */
import { describe, expect, it, beforeEach } from 'vitest'
import { mount } from '@vue/test-utils'
import { setActivePinia, createPinia } from 'pinia'
import WorkspaceItemTaskCard from '@/components/workspace/WorkspaceItemTaskCard.vue'
import KanbanTaskRow from '@/components/kanban/KanbanTaskRow.vue'
import type { Task } from '@/stores/workspaces'

function makeTask(overrides: Partial<Task> = {}): Task {
  return { id: 'task_1', name: 'Test', task_type: 'standard', ...overrides }
}

const BLOCKERS = [
  { task_id: 'task_a', name: 'Fix login', column_id: 'col_x', column_name: 'in progress' },
  { task_id: 'task_b', name: 'Add tests', column_id: 'col_x', column_name: 'in progress' },
]

describe('blocked badge', () => {
  beforeEach(() => setActivePinia(createPinia()))

  it('card: hidden when is_blocked is falsy', () => {
    const wrapper = mount(WorkspaceItemTaskCard, {
      props: { task: makeTask(), workspaceId: 'ws_1', itemId: 'item_1' },
    })
    expect(wrapper.find('[data-testid="task-blocked-badge"]').exists()).toBe(false)
  })

  it('card: shows the count and names the blockers in the tooltip', () => {
    const wrapper = mount(WorkspaceItemTaskCard, {
      props: {
        task: makeTask({ is_blocked: true, blocked_by: BLOCKERS }),
        workspaceId: 'ws_1',
        itemId: 'item_1',
      },
    })
    const badge = wrapper.find('[data-testid="task-blocked-badge"]')
    expect(badge.exists()).toBe(true)
    expect(badge.text()).toContain('blocked by 2')
    expect(badge.attributes('title')).toBe('Blocked by 2 tasks: Fix login, Add tests')
  })

  it('row: hidden when is_blocked is falsy', () => {
    const wrapper = mount(KanbanTaskRow, {
      props: {
        task: makeTask(),
        workspaceId: 'ws_1',
        itemId: 'item_1',
        density: 'comfortable' as const,
      },
    })
    expect(wrapper.find('[data-testid="kanban-row-blocked"]').exists()).toBe(false)
  })

  it('row: shows the count and names the blockers in the tooltip', () => {
    const wrapper = mount(KanbanTaskRow, {
      props: {
        task: makeTask({ is_blocked: true, blocked_by: BLOCKERS }),
        workspaceId: 'ws_1',
        itemId: 'item_1',
        density: 'comfortable' as const,
      },
    })
    const badge = wrapper.find('[data-testid="kanban-row-blocked"]')
    expect(badge.exists()).toBe(true)
    expect(badge.text()).toContain('blocked by 2')
    expect(badge.attributes('title')).toBe('Blocked by 2 tasks: Fix login, Add tests')
  })
})
