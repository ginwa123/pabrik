/**
 * KanbanDependsInput: never offers the task itself, emits the id array on pick and on chip remove, marks incomplete deps distinctly.
 */
import { describe, expect, it } from 'vitest'
import { mount, flushPromises } from '@vue/test-utils'
import KanbanDependsInput from '../components/kanban/KanbanDependsInput.vue'

const TASKS = [
  { id: 'task_a', name: 'Fix login' },
  { id: 'task_b', name: 'Add tests' },
  { id: 'task_self', name: 'My task' },
]

function mountInput(overrides: Record<string, unknown> = {}) {
  return mount(KanbanDependsInput, {
    props: {
      modelValue: [],
      tasks: TASKS,
      selfTaskId: 'task_self',
      ...overrides,
    },
  })
}

describe('KanbanDependsInput', () => {
  it('renders candidate tasks in the dropdown, but never the task itself', async () => {
    const wrapper = mountInput()
    await wrapper.find('[data-testid="kanban-depends-input-field"]').trigger('focus')
    await flushPromises()
    expect(
      wrapper.find('[data-testid="kanban-depends-input-suggestion-task_a"]').exists(),
    ).toBe(true)
    expect(
      wrapper.find('[data-testid="kanban-depends-input-suggestion-task_b"]').exists(),
    ).toBe(true)
    expect(
      wrapper.find('[data-testid="kanban-depends-input-suggestion-task_self"]').exists(),
    ).toBe(false)
  })

  it('emits the new id array when a candidate is picked', async () => {
    const wrapper = mountInput()
    await wrapper.find('[data-testid="kanban-depends-input-field"]').trigger('focus')
    await flushPromises()
    await wrapper
      .find('[data-testid="kanban-depends-input-suggestion-task_a"]')
      .trigger('mousedown')
    expect(wrapper.emitted('update:modelValue')?.[0]).toEqual([['task_a']])
  })

  it('emits the new id array when a chip is removed', async () => {
    const wrapper = mountInput({ modelValue: ['task_a', 'task_b'] })
    await wrapper.find('[data-testid="kanban-depends-input-remove-task_a"]').trigger('click')
    expect(wrapper.emitted('update:modelValue')?.[0]).toEqual([['task_b']])
  })

  it('renders the task NAME on chips and marks incomplete deps distinctly', () => {
    const wrapper = mountInput({ modelValue: ['task_a', 'task_b'], blockedIds: ['task_a'] })
    const chipA = wrapper.find('[data-testid="kanban-depends-input-chip-task_a"]')
    const chipB = wrapper.find('[data-testid="kanban-depends-input-chip-task_b"]')
    expect(chipA.text()).toContain('Fix login')
    expect(chipB.text()).toContain('Add tests')
    expect(
      wrapper.find('[data-testid="kanban-depends-input-chip-blocked-dot-task_a"]').exists(),
    ).toBe(true)
    expect(
      wrapper.find('[data-testid="kanban-depends-input-chip-blocked-dot-task_b"]').exists(),
    ).toBe(false)
  })

  it('filters candidates by the search text', async () => {
    const wrapper = mountInput()
    const field = wrapper.find('[data-testid="kanban-depends-input-field"]')
    await field.trigger('focus')
    await field.setValue('login')
    await flushPromises()
    expect(
      wrapper.find('[data-testid="kanban-depends-input-suggestion-task_a"]').exists(),
    ).toBe(true)
    expect(
      wrapper.find('[data-testid="kanban-depends-input-suggestion-task_b"]').exists(),
    ).toBe(false)
  })
})
