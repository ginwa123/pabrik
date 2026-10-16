/**  * WorkspaceItemTaskCard — tags row (Migration 067). Covers: empty/undefined tags → no row,
 * non-empty tags → chips, max 3 visible + "+N more" affordance, deterministic color. Plan:
 * docs/superpowers/plans/2026-07-28-kanban-task-tags.md (Task 12) */
import { describe, it, expect, beforeEach } from 'vitest'
import { mount } from '@vue/test-utils'
import { nextTick } from 'vue'
import { createPinia, setActivePinia } from 'pinia'
import WorkspaceItemTaskCard from '../components/workspace/WorkspaceItemTaskCard.vue'

function makeTask(overrides: Record<string, unknown> = {}) {
  return {
    id: 'task_1',
    name: 'Test task',
    description: '',
    task_type: 'standard' as const,
    is_pinned: false,
    kanban_column_id: 'col_1',
    kanban_position: 0,
    completed: false,
    needs_human_review: false,
    last_finish_reason: '',
    tags: [] as string[],
    ...overrides,
  }
}

describe('WorkspaceItemTaskCard — tags row', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
  })

  it('does not render the tags row when task.tags is undefined', async () => {
    const wrapper = mount(WorkspaceItemTaskCard, {
      props: { task: makeTask({ tags: undefined }), workspaceId: 'ws_1', itemId: 'item_1' },
    })
    await nextTick()
    expect(wrapper.find('[data-testid="task-tags-row"]').exists()).toBe(false)
  })

  it('does not render the tags row when task.tags is empty', async () => {
    const wrapper = mount(WorkspaceItemTaskCard, {
      props: { task: makeTask({ tags: [] }), workspaceId: 'ws_1', itemId: 'item_1' },
    })
    await nextTick()
    expect(wrapper.find('[data-testid="task-tags-row"]').exists()).toBe(false)
  })

  it('renders chip per tag when task.tags has 1 or 2 entries', async () => {
    const wrapper = mount(WorkspaceItemTaskCard, {
      props: { task: makeTask({ tags: ['bug', 'urgent'] }), workspaceId: 'ws_1', itemId: 'item_1' },
    })
    await nextTick()
    expect(wrapper.find('[data-testid="task-tags-row"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="task-tag-chip-bug"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="task-tag-chip-urgent"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="task-tags-more"]').exists()).toBe(false)
  })

  it('renders at most 3 chips and shows +N more when task.tags has more', async () => {
    const wrapper = mount(WorkspaceItemTaskCard, {
      props: { task: makeTask({ tags: ['a', 'b', 'c', 'd', 'e'] }), workspaceId: 'ws_1', itemId: 'item_1' },
    })
    await nextTick()
    expect(wrapper.find('[data-testid="task-tag-chip-a"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="task-tag-chip-b"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="task-tag-chip-c"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="task-tag-chip-d"]').exists()).toBe(false)
    expect(wrapper.find('[data-testid="task-tag-chip-e"]').exists()).toBe(false)
    const more = wrapper.find('[data-testid="task-tags-more"]')
    expect(more.exists()).toBe(true)
    expect(more.text()).toContain('+2 more')
  })

  it('renders exactly 3 chips with no +N more when there are exactly 3 tags', async () => {
    const wrapper = mount(WorkspaceItemTaskCard, {
      props: { task: makeTask({ tags: ['a', 'b', 'c'] }), workspaceId: 'ws_1', itemId: 'item_1' },
    })
    await nextTick()
    expect(wrapper.find('[data-testid="task-tag-chip-a"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="task-tag-chip-b"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="task-tag-chip-c"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="task-tags-more"]').exists()).toBe(false)
  })

  it('"+N more" click emits viewTaskDetail', async () => {
    const wrapper = mount(WorkspaceItemTaskCard, {
      props: { task: makeTask({ tags: ['a', 'b', 'c', 'd'] }), workspaceId: 'ws_1', itemId: 'item_1' },
    })
    await nextTick()
    await wrapper.find('[data-testid="task-tags-more"]').trigger('click')
    expect(wrapper.emitted('viewTaskDetail')).toBeTruthy()
    expect(wrapper.emitted('viewTaskDetail')![0]).toEqual(['task_1'])
  })

  it('chip color is deterministic for the same tag', async () => {
    const a = mount(WorkspaceItemTaskCard, {
      props: { task: makeTask({ tags: ['frontend'] }), workspaceId: 'ws_1', itemId: 'item_1' },
    })
    await nextTick()
    const aStyle = a.find('[data-testid="task-tag-chip-frontend"]').attributes('style') ?? ''
    const b = mount(WorkspaceItemTaskCard, {
      props: { task: makeTask({ tags: ['frontend'] }), workspaceId: 'ws_1', itemId: 'item_1' },
    })
    await nextTick()
    const bStyle = b.find('[data-testid="task-tag-chip-frontend"]').attributes('style') ?? ''
    // Same tag string → same djb2 hash → same palette index → same style.
    expect(aStyle).toBe(bStyle)
    expect(aStyle.length).toBeGreaterThan(0)
  })

  it('different tags usually get different colors (probabilistic check)', async () => {
    // 'frontend' and 'backend' hash to different indices in the
    // 6-color palette with overwhelming probability. Verify via
    // direct property comparison.
    const wrapper = mount(WorkspaceItemTaskCard, {
      props: { task: makeTask({ tags: ['frontend', 'backend'] }), workspaceId: 'ws_1', itemId: 'item_1' },
    })
    await nextTick()
    const aStyle = wrapper.find('[data-testid="task-tag-chip-frontend"]').attributes('style') ?? ''
    const bStyle = wrapper.find('[data-testid="task-tag-chip-backend"]').attributes('style') ?? ''
    expect(aStyle).not.toEqual(bStyle)
  })
})
