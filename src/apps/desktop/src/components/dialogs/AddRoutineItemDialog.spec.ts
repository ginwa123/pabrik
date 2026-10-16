// Behavioural tests for AddRoutineItemDialog. Mirrors AddAgentDialog.spec.ts.
import { describe, expect, it, beforeEach, vi } from 'vitest'
import { mount } from '@vue/test-utils'
import { nextTick } from 'vue'
import AddRoutineItemDialog from './AddRoutineItemDialog.vue'

// Stub the FilePickerDialog — same pattern as AddAgentDialog.spec.ts.
vi.mock('../FilePickerDialog.vue', () => ({
  default: {
    name: 'FilePickerDialog',
    props: ['modelValue', 'mode', 'loadItems', 'keyFor', 'pathFor', 'isExpandable', 'labelFor', 'title'],
    emits: ['update:modelValue', 'select'],
    template: `
      <div v-if="modelValue" data-testid="file-picker-dialog">
        <h2 data-testid="file-picker-title">{{ title }}</h2>
        <button data-testid="file-picker-select-tmp" @click="$emit('select', '/tmp/routine')">
          Pick /tmp/routine
        </button>
        <button data-testid="file-picker-cancel" @click="$emit('update:modelValue', false)">
          Cancel
        </button>
      </div>
    `,
  },
}))

function mountDialog() {
  document.body.innerHTML = ''
  return mount(AddRoutineItemDialog, {
    attachTo: document.body,
    props: { show: true },
  })
}

describe('AddRoutineItemDialog', () => {
  beforeEach(() => vi.restoreAllMocks())

  it('shows the "Add Routine" title and a name input when show=true', async () => {
    mountDialog()
    await nextTick()
    const dialog = document.querySelector('[data-testid="add-routine-dialog"]') as HTMLElement | null
    expect(dialog?.textContent).toContain('Add Routine')
    expect(document.querySelector('[data-testid="add-routine-name"]')).toBeTruthy()
  })

  it('disables the Add button when name or path is empty', async () => {
    mountDialog()
    await nextTick()
    const submit = document.querySelector('[data-testid="add-routine-submit"]') as HTMLButtonElement
    expect(submit.hasAttribute('disabled')).toBe(true)
  })

  it('emits "create" with (name, path) when Add is clicked with valid input', async () => {
    const wrapper = mountDialog()
    await nextTick()
    const nameInput = document.querySelector('[data-testid="add-routine-name"]') as HTMLInputElement
    nameInput.value = 'Nightly'
    nameInput.dispatchEvent(new Event('input'))
    await nextTick()
    const picker = wrapper.findComponent({ name: 'FilePickerDialog' })
    picker.vm.$emit('select', '/tmp/routine')
    await nextTick()
    const submit = document.querySelector('[data-testid="add-routine-submit"]') as HTMLButtonElement
    submit.click()
    await nextTick()
    const events = wrapper.emitted('create')
    expect(events).toBeTruthy()
    expect(events![0]).toEqual(['Nightly', '/tmp/routine'])
  })

  it('emits "close" when Cancel is clicked', async () => {
    const wrapper = mountDialog()
    await nextTick()
    const cancel = document.querySelector('[data-testid="add-routine-cancel"]') as HTMLButtonElement
    cancel.click()
    await nextTick()
    expect(wrapper.emitted('close')).toBeTruthy()
  })
})
