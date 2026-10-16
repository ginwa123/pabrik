/** Tests for KanbanCard — the draggable card wrapper around WorkspaceItemTask. Plan:
 * docs/superpowers/plans/2026-06-21-workspace-item-kanban.md Chunk 6 / Task 6.3 */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { mount, type VueWrapper } from '@vue/test-utils'
import { ref, type Ref } from 'vue'

import KanbanCard from '../components/kanban/KanbanCard.vue'
import type { Task } from '../stores/workspaces'

function mountCard(task: Task) {
  // WorkspaceItemTask injects `processingState`; provide a default so
  // the mount succeeds (matches the pattern in workspaceItemTaskLoadMore
  // .spec.ts and workspaceItemTaskRoutine.spec.ts).
  const processingState: Ref<Record<string, boolean>> = ref({})
  return mount(KanbanCard, {
    props: {
      task,
      workspaceId: 'ws_1',
      itemId: 'item_1',
    },
    global: {
      provide: { processingState },
    },
  })
}

const sampleTask: Task = {
  id: 'task_1',
  name: 'My Task',
}

describe('KanbanCard', () => {
  let wrapper: VueWrapper | null = null

  beforeEach(() => {
    setActivePinia(createPinia())
  })

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    vi.restoreAllMocks()
  })

  it('renders the task name via the wrapped WorkspaceItemTask', () => {
    wrapper = mountCard(sampleTask)
    expect(wrapper.text()).toContain('My Task')
  })

  it('is draggable and carries the task id on the wrapper element', () => {
    wrapper = mountCard(sampleTask)
    const card = wrapper.find('[data-kanban-card="task_1"]')
    expect(card.exists()).toBe(true)
    expect(card.attributes('draggable')).toBe('true')
  })

  it('emits dragstart with the task id and sets the kanban MIME type on dragstart', async () => {
    wrapper = mountCard(sampleTask)
    const card = wrapper.find('[data-kanban-card="task_1"]')

    // jsdom's DragEvent doesn't expose a real dataTransfer, so we
    // synthesize one and assert on the calls we made.
    const setData = vi.fn()
    const dataTransfer = {
      effectAllowed: '',
      setData,
      getData: vi.fn(),
    } as unknown as DataTransfer
    await card.trigger('dragstart', { dataTransfer })

    expect(wrapper.emitted('dragstart')).toBeTruthy()
    expect(wrapper.emitted('dragstart')?.[0]).toEqual(['task_1'])
    expect(setData).toHaveBeenCalledWith('application/x-kanban-task-id', 'task_1')
    expect((dataTransfer as { effectAllowed: string }).effectAllowed).toBe('move')
  })

  it('emits dragend (no payload) on drag end', async () => {
    wrapper = mountCard(sampleTask)
    const card = wrapper.find('[data-kanban-card="task_1"]')
    await card.trigger('dragend')
    expect(wrapper.emitted('dragend')).toBeTruthy()
    expect(wrapper.emitted('dragend')?.length).toBe(1)
    // dragend emits no payload — the args array is empty.
    expect(wrapper.emitted('dragend')?.[0]).toEqual([])
  })

  // NEW (change-task-to-card-kanban plan): KanbanCard passes the `variant="card"` prop to its
  // wrapped <WorkspaceItemTask> so the kanban-card UX (bordered card layout, optional description
  // preview) is used inside kanban columns.
  it('renders the wrapped WorkspaceItemTask in card variant (data-task-card present, data-task-row absent)', () => {
    wrapper = mountCard(sampleTask)
    expect(wrapper.find('[data-task-card]').exists()).toBe(true)
    expect(wrapper.find('[data-task-row]').exists()).toBe(false)
  })

  it('renders the card description when the task has one', () => {
    wrapper = mountCard({ ...sampleTask, description: 'Card body text' })
    const desc = wrapper.find('[data-testid="task-description"]')
    expect(desc.exists()).toBe(true)
    expect(desc.text()).toBe('Card body text')
  })
})