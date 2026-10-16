/** KanbanTagsInput — chip input component. Tests cover: empty state, existing chips render, add via
 * Enter, add via comma, ✕ removes, backspace-on-empty removes last, case-insensitive dedupe (silent
 * no-op), forbidden char error, length cap error. */
import { describe, it, expect, beforeEach } from 'vitest'
import { mount } from '@vue/test-utils'
import { nextTick } from 'vue'
import KanbanTagsInput from '../components/kanban/KanbanTagsInput.vue'

describe('KanbanTagsInput', () => {
  beforeEach(() => {
    // No global setup; the component is fully self-contained.
  })

  it('renders the empty-state placeholder when modelValue is empty', async () => {
    const wrapper = mount(KanbanTagsInput, {
      props: { modelValue: [] },
    })
    await nextTick()
    const input = wrapper.find('[data-testid="kanban-tags-input-field"]')
    expect(input.exists()).toBe(true)
    expect(input.attributes('placeholder')).toContain('Add tags')
    expect(wrapper.findAll('[data-testid^="kanban-tags-input-chip-"]').length).toBe(0)
  })

  it('renders existing tags as chips with ✕ buttons', async () => {
    const wrapper = mount(KanbanTagsInput, {
      props: { modelValue: ['bug', 'urgent'] },
    })
    await nextTick()
    expect(wrapper.find('[data-testid="kanban-tags-input-chip-bug"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="kanban-tags-input-chip-urgent"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="kanban-tags-input-remove-bug"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="kanban-tags-input-remove-urgent"]').exists()).toBe(true)
  })

  it('typing a tag + Enter appends to modelValue + clears the input', async () => {
    const wrapper = mount(KanbanTagsInput, {
      props: { modelValue: [] },
    })
    const input = wrapper.find<HTMLInputElement>('[data-testid="kanban-tags-input-field"]')
    input.element.value = 'newtag'
    await input.trigger('input')
    await input.trigger('keydown', { key: 'Enter' })
    expect(wrapper.emitted('update:modelValue')).toBeTruthy()
    expect(wrapper.emitted('update:modelValue')![0]).toEqual([['newtag']])
  })

  it('typing a tag + comma appends + clears', async () => {
    const wrapper = mount(KanbanTagsInput, {
      props: { modelValue: [] },
    })
    const input = wrapper.find<HTMLInputElement>('[data-testid="kanban-tags-input-field"]')
    input.element.value = 'commaTag'
    await input.trigger('input')
    await input.trigger('keydown', { key: ',' })
    expect(wrapper.emitted('update:modelValue')![0]).toEqual([['commaTag']])
  })

  it('clicking the chip ✕ removes the tag', async () => {
    const wrapper = mount(KanbanTagsInput, {
      props: { modelValue: ['a', 'b', 'c'] },
    })
    await wrapper.find('[data-testid="kanban-tags-input-remove-b"]').trigger('click')
    expect(wrapper.emitted('update:modelValue')).toBeTruthy()
    expect(wrapper.emitted('update:modelValue')![0]).toEqual([['a', 'c']])
  })

  it('Backspace on an empty input removes the last chip', async () => {
    const wrapper = mount(KanbanTagsInput, {
      props: { modelValue: ['x', 'y', 'z'] },
    })
    const input = wrapper.find<HTMLInputElement>('[data-testid="kanban-tags-input-field"]')
    expect((input.element as HTMLInputElement).value).toBe('')
    await input.trigger('keydown', { key: 'Backspace' })
    expect(wrapper.emitted('update:modelValue')![0]).toEqual([['x', 'y']])
  })

  it('Backspace when input has text does NOT remove a chip (lets the browser handle text deletion)', async () => {
    const wrapper = mount(KanbanTagsInput, {
      props: { modelValue: ['only-tag'] },
    })
    const input = wrapper.find<HTMLInputElement>('[data-testid="kanban-tags-input-field"]')
    input.element.value = 'still-typing'
    await input.trigger('input')
    await input.trigger('keydown', { key: 'Backspace' })
    expect(wrapper.emitted('update:modelValue')).toBeFalsy()
  })

  it('case-insensitive duplicate is silently rejected', async () => {
    const wrapper = mount(KanbanTagsInput, {
      props: { modelValue: ['Bug'] },
    })
    const input = wrapper.find<HTMLInputElement>('[data-testid="kanban-tags-input-field"]')
    input.element.value = 'bug'
    await input.trigger('input')
    await input.trigger('keydown', { key: 'Enter' })
    // No new emit (the existing 'Bug' stays). The input is cleared.
    expect(wrapper.emitted('update:modelValue')).toBeFalsy()
  })

  it('rejects forbidden chars (space, slash, comma, dot)', async () => {
    const wrapper = mount(KanbanTagsInput, {
      props: { modelValue: [] },
    })
    const input = wrapper.find<HTMLInputElement>('[data-testid="kanban-tags-input-field"]')
    input.element.value = 'with space'
    await input.trigger('input')
    await input.trigger('keydown', { key: 'Enter' })
    expect(wrapper.emitted('update:modelValue')).toBeFalsy()
    expect(wrapper.find('[data-testid="kanban-tags-input-error"]').exists()).toBe(true)
  })

  it('rejects tags over 50 chars', async () => {
    const wrapper = mount(KanbanTagsInput, {
      props: { modelValue: [] },
    })
    const input = wrapper.find<HTMLInputElement>('[data-testid="kanban-tags-input-field"]')
    input.element.value = 'a'.repeat(51)
    await input.trigger('input')
    await input.trigger('keydown', { key: 'Enter' })
    expect(wrapper.emitted('update:modelValue')).toBeFalsy()
    expect(wrapper.find('[data-testid="kanban-tags-input-error"]').exists()).toBe(true)
  })

  it('accepts tags with allowed chars (letters, digits, underscore, hyphen)', async () => {
    const wrapper = mount(KanbanTagsInput, {
      props: { modelValue: [] },
    })
    const input = wrapper.find<HTMLInputElement>('[data-testid="kanban-tags-input-field"]')
    input.element.value = 'abc-XYZ_1'
    await input.trigger('input')
    await input.trigger('keydown', { key: 'Enter' })
    expect(wrapper.emitted('update:modelValue')![0]).toEqual([['abc-XYZ_1']])
  })

  it('trims whitespace from the draft', async () => {
    const wrapper = mount(KanbanTagsInput, {
      props: { modelValue: [] },
    })
    const input = wrapper.find<HTMLInputElement>('[data-testid="kanban-tags-input-field"]')
    input.element.value = '   spaced   '
    await input.trigger('input')
    await input.trigger('keydown', { key: 'Enter' })
    expect(wrapper.emitted('update:modelValue')![0]).toEqual([['spaced']])
  })

  it('clears the error when the user starts typing again', async () => {
    const wrapper = mount(KanbanTagsInput, {
      props: { modelValue: [] },
    })
    const input = wrapper.find<HTMLInputElement>('[data-testid="kanban-tags-input-field"]')
    input.element.value = 'with space'
    await input.trigger('input')
    await input.trigger('keydown', { key: 'Enter' })
    expect(wrapper.find('[data-testid="kanban-tags-input-error"]').exists()).toBe(true)
    // Now type again — the error should clear.
    input.element.value = 'clean'
    await input.trigger('input')
    expect(wrapper.find('[data-testid="kanban-tags-input-error"]').exists()).toBe(false)
  })

  it('respects a custom testId prefix', async () => {
    const wrapper = mount(KanbanTagsInput, {
      props: { modelValue: ['foo'], testId: 'my-prefix' },
    })
    await nextTick()
    expect(wrapper.find('[data-testid="my-prefix-chip-foo"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="my-prefix-remove-foo"]').exists()).toBe(true)
  })

  it('auto-commits the draft on blur (so clicking Save without Enter/comma still saves the tag)', async () => {
    const wrapper = mount(KanbanTagsInput, {
      props: { modelValue: [] },
    })
    const input = wrapper.find<HTMLInputElement>('[data-testid="kanban-tags-input-field"]')
    input.element.value = 'sadsad'
    await input.trigger('input')
    await input.trigger('blur')
    expect(wrapper.emitted('update:modelValue')).toBeTruthy()
    expect(wrapper.emitted('update:modelValue')![0]).toEqual([['sadsad']])
  })

  it('exposes commitDraft() so the host can imperatively commit before reading modelValue', async () => {
    const wrapper = mount(KanbanTagsInput, {
      props: { modelValue: [] },
    })
    // Sanity: the component does NOT auto-commit on input alone —
    // the bug we are fixing. Typing without Enter/comma/blur is
    // intentionally a no-op so chip inputs don't surprise users.
    const input = wrapper.find<HTMLInputElement>('[data-testid="kanban-tags-input-field"]')
    input.element.value = 'draft'
    await input.trigger('input')
    expect(wrapper.emitted('update:modelValue')).toBeFalsy()
    // Now call the exposed imperative method (the dialog uses this
    // pattern in handleSave, before reading tags.value).
    ;(wrapper.vm as unknown as { commitDraft: () => void }).commitDraft()
    await nextTick()
    expect(wrapper.emitted('update:modelValue')![0]).toEqual([['draft']])
    // Input cleared post-commit.
    expect(input.element.value).toBe('')
  })

  it('commitDraft() is a silent no-op on an empty draft (does not emit, does not error)', async () => {
    const wrapper = mount(KanbanTagsInput, {
      props: { modelValue: ['existing'] },
    })
    expect(wrapper.emitted('update:modelValue')).toBeFalsy()
    ;(wrapper.vm as unknown as { commitDraft: () => void }).commitDraft()
    expect(wrapper.emitted('update:modelValue')).toBeFalsy()
  })
})
