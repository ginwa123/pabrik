import { describe, expect, it, beforeEach, vi } from 'vitest'
import { mount } from '@vue/test-utils'
import { nextTick } from 'vue'
import AddRoutineItemDialog from './AddRoutineItemDialog.vue'

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

function query<T extends HTMLElement>(testId: string): T | null {
  return document.querySelector(`[data-testid="${testId}"]`) as T | null
}

async function fillName(value: string) {
  const input = query<HTMLInputElement>('add-routine-name')!
  input.value = value
  input.dispatchEvent(new Event('input'))
  await nextTick()
}

async function pickFolder(wrapper: ReturnType<typeof mountDialog>) {
  wrapper.findComponent({ name: 'FilePickerDialog' }).vm.$emit('select', '/tmp/routine')
  await nextTick()
}

describe('AddRoutineItemDialog', () => {
  beforeEach(() => vi.restoreAllMocks())

  it('shows the "Add Routine" title and a name input when show=true', async () => {
    mountDialog()
    await nextTick()
    expect(query('add-routine-dialog')?.textContent).toContain('Add Routine')
    expect(query('add-routine-name')).toBeTruthy()
  })

  it('disables the Add button when name or path is empty', async () => {
    mountDialog()
    await nextTick()
    expect(query<HTMLButtonElement>('add-routine-submit')!.hasAttribute('disabled')).toBe(true)
  })

  it('emits "create" with the name, the folder and the instruction/schedule the user typed', async () => {
    const wrapper = mountDialog()
    await nextTick()
    await fillName('Nightly')
    await pickFolder(wrapper)

    const instruction = query<HTMLTextAreaElement>('add-routine-instruction')!
    instruction.value = 'summarise new issues'
    instruction.dispatchEvent(new Event('input'))
    const schedule = query<HTMLInputElement>('add-routine-schedule')!
    schedule.value = '0 9 * * 1-5'
    schedule.dispatchEvent(new Event('input'))
    await nextTick()

    query<HTMLButtonElement>('add-routine-submit')!.click()
    await nextTick()

    expect(wrapper.emitted('create')![0]).toEqual([
      'Nightly',
      '/tmp/routine',
      { instruction: 'summarise new issues', schedule: '0 9 * * 1-5' },
    ])
  })

  it('fills the schedule from a preset', async () => {
    const wrapper = mountDialog()
    await nextTick()
    await fillName('Hourly')
    await pickFolder(wrapper)

    query<HTMLButtonElement>('add-routine-preset-0 * * * *')!.click()
    await nextTick()

    expect(query<HTMLInputElement>('add-routine-schedule')!.value).toBe('0 * * * *')

    query<HTMLButtonElement>('add-routine-submit')!.click()
    await nextTick()
    expect(wrapper.emitted('create')![0]).toEqual([
      'Hourly',
      '/tmp/routine',
      { instruction: '', schedule: '0 * * * *' },
    ])
  })

  it('blocks Add and explains a cron schedule with the wrong field count', async () => {
    mountDialog()
    await nextTick()
    await fillName('Broken')
    const schedule = query<HTMLInputElement>('add-routine-schedule')!
    schedule.value = '* * *'
    schedule.dispatchEvent(new Event('input'))
    await nextTick()

    expect(query('add-routine-dialog')!.textContent).toContain('5 fields')
    expect(query<HTMLButtonElement>('add-routine-submit')!.hasAttribute('disabled')).toBe(true)
  })

  it('emits "close" when Cancel is clicked', async () => {
    const wrapper = mountDialog()
    await nextTick()
    query<HTMLButtonElement>('add-routine-cancel')!.click()
    await nextTick()
    expect(wrapper.emitted('close')).toBeTruthy()
  })
})
