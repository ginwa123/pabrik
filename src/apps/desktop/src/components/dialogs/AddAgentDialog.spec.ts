// Behavioural tests for AddAgentDialog. Mirrors AddKanbanDialog.spec.ts.
import { describe, expect, it, beforeEach, vi } from 'vitest'
import { mount } from '@vue/test-utils'
import { nextTick } from 'vue'
import AddAgentDialog from './AddAgentDialog.vue'

// Stub the FilePickerDialog — same pattern as AddMemoryDialog.spec.ts.
// The real FilePickerDialog uses useRecentFoldersStore which requires
// an active Pinia; stubbing it isolates this test from that.
vi.mock('../FilePickerDialog.vue', () => ({
  default: {
    name: 'FilePickerDialog',
    props: ['modelValue', 'mode', 'loadItems', 'keyFor', 'pathFor', 'isExpandable', 'labelFor', 'title'],
    emits: ['update:modelValue', 'select'],
    template: `
      <div v-if="modelValue" data-testid="file-picker-dialog">
        <h2 data-testid="file-picker-title">{{ title }}</h2>
        <button data-testid="file-picker-select-tmp" @click="$emit('select', '/tmp/agent')">
          Pick /tmp/agent
        </button>
        <button data-testid="file-picker-cancel" @click="$emit('update:modelValue', false)">
          Cancel
        </button>
      </div>
    `,
  },
}))

function mountDialog() {
  // The dialog uses <Teleport to="body">, so we attach to document.body
  // and search via document.querySelector. Same pattern as
  // AddMemoryDialog.spec.ts.
  document.body.innerHTML = ''
  return mount(AddAgentDialog, {
    attachTo: document.body,
    props: { show: true },
  })
}

describe('AddAgentDialog', () => {
  beforeEach(() => vi.restoreAllMocks())

  it('shows the "Add Agent" title and a name input when show=true', async () => {
    mountDialog()
    await nextTick()
    const dialog = document.querySelector('[data-testid="add-agent-dialog"]') as HTMLElement | null
    expect(dialog?.textContent).toContain('Add Agent')
    expect(document.querySelector('[data-testid="add-agent-name"]')).toBeTruthy()
  })

  it('disables the Add button when name or path is empty', async () => {
    mountDialog()
    await nextTick()
    const submit = document.querySelector('[data-testid="add-agent-submit"]') as HTMLButtonElement
    expect(submit.hasAttribute('disabled')).toBe(true)
  })

  it('emits "create" with (name, path) when Add is clicked with valid input', async () => {
    const wrapper = mountDialog()
    await nextTick()
    const nameInput = document.querySelector('[data-testid="add-agent-name"]') as HTMLInputElement
    nameInput.value = 'My Agent'
    nameInput.dispatchEvent(new Event('input'))
    await nextTick()
    // Simulate the FilePickerDialog `select` event firing with a
    // folder path. The dialog calls handleFolderSelected on select,
    // which sets the internal `selectedPath` ref.
    const picker = wrapper.findComponent({ name: 'FilePickerDialog' })
    picker.vm.$emit('select', '/tmp/agent')
    await nextTick()
    const submit = document.querySelector('[data-testid="add-agent-submit"]') as HTMLButtonElement
    submit.click()
    await nextTick()
    const events = wrapper.emitted('create')
    expect(events).toBeTruthy()
    expect(events![0]).toEqual(['My Agent', '/tmp/agent'])
  })

  it('emits "close" when Cancel is clicked', async () => {
    const wrapper = mountDialog()
    await nextTick()
    const cancel = document.querySelector('[data-testid="add-agent-cancel"]') as HTMLButtonElement
    cancel.click()
    await nextTick()
    expect(wrapper.emitted('close')).toBeTruthy()
  })
})
