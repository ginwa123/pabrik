/** Tests for the column description subtitle rendered between the header row (name + count + ⋮
 * menu) and the cards drop zone in KanbanColumn.vue. */
import { beforeEach, describe, expect, it } from 'vitest'
import { mount } from '@vue/test-utils'
import { setActivePinia, createPinia } from 'pinia'
import KanbanColumn from '@/components/kanban/KanbanColumn.vue'
import type { KanbanColumn as KanbanColumnT, Task } from '@/api'

const baseColumn: KanbanColumnT = {
  id: 'col_test',
  workspace_item_id: 'wi_test',
  name: 'in_review',
  description: 'Awaiting code review',
  position: 0,
  created_at: '2026-06-26T10:00:00Z',
}

const baseTask: Task = {
  id: 'task_test',
  name: 'test task',
  kanban_column_id: null,
  kanban_position: 0,
}

describe('KanbanColumn description display', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
  })

  it('renders the description under the column name when present', () => {
    const wrapper = mount(KanbanColumn, {
      props: {
        column: baseColumn,
        tasks: [baseTask],
        workspaceId: 'ws_test',
        itemId: 'wi_test',
      },
      attachTo: document.body,
    })
    const desc = wrapper.find(
      '[data-testid="kanban-column-col_test-description"]',
    )
    expect(desc.exists()).toBe(true)
    expect(desc.text()).toBe('Awaiting code review')
    expect((desc.element as HTMLParagraphElement).title).toBe('Awaiting code review')
    wrapper.unmount()
  })

  it('does not render the description element when description is empty', () => {
    const wrapper = mount(KanbanColumn, {
      props: {
        column: { ...baseColumn, description: '' },
        tasks: [baseTask],
        workspaceId: 'ws_test',
        itemId: 'wi_test',
      },
      attachTo: document.body,
    })
    const desc = wrapper.find(
      '[data-testid="kanban-column-col_test-description"]',
    )
    expect(desc.exists()).toBe(false)
    wrapper.unmount()
  })

  it('does not render the description element when description is null', () => {
    const wrapper = mount(KanbanColumn, {
      props: {
        column: { ...baseColumn, description: null },
        tasks: [baseTask],
        workspaceId: 'ws_test',
        itemId: 'wi_test',
      },
      attachTo: document.body,
    })
    const desc = wrapper.find(
      '[data-testid="kanban-column-col_test-description"]',
    )
    expect(desc.exists()).toBe(false)
    wrapper.unmount()
  })

  it('does not render the description element when description is undefined', () => {
    const columnWithoutDescription: KanbanColumnT = { ...baseColumn }
    delete columnWithoutDescription.description
    const wrapper = mount(KanbanColumn, {
      props: {
        column: columnWithoutDescription,
        tasks: [baseTask],
        workspaceId: 'ws_test',
        itemId: 'wi_test',
      },
      attachTo: document.body,
    })
    const desc = wrapper.find(
      '[data-testid="kanban-column-col_test-description"]',
    )
    expect(desc.exists()).toBe(false)
    wrapper.unmount()
  })
})