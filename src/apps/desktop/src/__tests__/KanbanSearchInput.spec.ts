/** Behavioural tests for <KanbanSearchInput>.The component is a compact input
 * + clear button + Esc-to-clear. */
import { describe, it, expect } from 'vitest'
import { mount } from '@vue/test-utils'

import KanbanSearchInput from '../components/kanban/KanbanSearchInput.vue'

describe('KanbanSearchInput', () => {
  it('renders with empty value when modelValue is empty', () => {
    const wrapper = mount(KanbanSearchInput, { props: { modelValue: '' } })
    const input = wrapper.find('input[type="text"]')
    expect(input.exists()).toBe(true)
    expect((input.element as HTMLInputElement).value).toBe('')
  })

  it('emits update:modelValue with each typed character', async () => {
    const wrapper = mount(KanbanSearchInput, { props: { modelValue: '' } })
    const input = wrapper.find('input[type="text"]')
    await input.setValue('d')
    expect(wrapper.emitted('update:modelValue')).toBeTruthy()
    expect(wrapper.emitted('update:modelValue')![0]).toEqual(['d'])

    await input.setValue('de')
    expect(wrapper.emitted('update:modelValue')![1]).toEqual(['de'])
  })

  it('does not render the clear ✕ button when value is empty', () => {
    const wrapper = mount(KanbanSearchInput, { props: { modelValue: '' } })
    expect(wrapper.find('[data-testid="kanban-search-input-clear"]').exists()).toBe(false)
  })

  it('renders the clear ✕ button when value is non-empty', () => {
    const wrapper = mount(KanbanSearchInput, { props: { modelValue: 'design' } })
    expect(wrapper.find('[data-testid="kanban-search-input-clear"]').exists()).toBe(true)
  })

  it('clicking the clear ✕ button emits update:modelValue with empty string', async () => {
    const wrapper = mount(KanbanSearchInput, { props: { modelValue: 'design' } })
    await wrapper.find('[data-testid="kanban-search-input-clear"]').trigger('click')
    expect(wrapper.emitted('update:modelValue')).toBeTruthy()
    expect(wrapper.emitted('update:modelValue')![0]).toEqual([''])
  })

  it('pressing Esc clears the input (emits empty string)', async () => {
    const wrapper = mount(KanbanSearchInput, { props: { modelValue: 'design' } })
    const input = wrapper.find('input[type="text"]')
    await input.trigger('keydown', { key: 'Escape' })
    expect(wrapper.emitted('update:modelValue')![0]).toEqual([''])
  })

  it('renders the search icon in the placeholder', () => {
    const wrapper = mount(KanbanSearchInput, { props: { modelValue: '' } })
    const input = wrapper.find('input[type="text"]')
    const placeholder = (input.element as HTMLInputElement).placeholder
    expect(placeholder).toContain('Search')
  })
})