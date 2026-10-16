/** FileInput autofocus — clicking a chat session should land the cursor in the message box with no
 * second mouse click. */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { mount, flushPromises } from '@vue/test-utils'
import { setActivePinia, createPinia } from 'pinia'
import FileInput from '@/components/file/FileInput.vue'
import * as api from '@/api'

vi.mock('@/api', async (importOriginal) => {
  const actual = await importOriginal<typeof import('@/api')>()
  return {
    ...actual,
    searchFiles: vi.fn(),
  }
})

const searchFilesMock = api.searchFiles as unknown as ReturnType<typeof vi.fn>

describe('FileInput — autofocus on mount', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    document.body.innerHTML = ''
    searchFilesMock.mockReset()
    searchFilesMock.mockResolvedValue({ entries: [] })
  })

  afterEach(() => {
    document.body.innerHTML = ''
    vi.restoreAllMocks()
  })

  it('auto-focuses the textarea on mount', async () => {
    const wrapper = mount(FileInput, {
      attachTo: document.body,
      props: { cwd: '/home/user' },
    })
    await flushPromises()
    // onMounted -> nextTick -> focus, so one more frame may be needed
    await new Promise((resolve) => setTimeout(resolve, 0))
    await flushPromises()

    const textarea = wrapper.find('textarea').element as HTMLTextAreaElement
    expect(document.activeElement).toBe(textarea)
    wrapper.unmount()
  })

  it('exposes focusInput() for parent-driven refocus', async () => {
    const wrapper = mount(FileInput, {
      attachTo: document.body,
      props: { cwd: '/home/user' },
    })
    await flushPromises()
    const vm = wrapper.vm as unknown as { focusInput?: () => void }
    expect(typeof vm.focusInput).toBe('function')
    // Blur then refocus via the exposed method
    ;(document.activeElement as HTMLElement | null)?.blur?.()
    vm.focusInput?.()
    const textarea = wrapper.find('textarea').element as HTMLTextAreaElement
    expect(document.activeElement).toBe(textarea)
    wrapper.unmount()
  })

  it('does not steal focus when a modal dialog is open', async () => {
    const dialog = document.createElement('div')
    dialog.setAttribute('role', 'dialog')
    document.body.appendChild(dialog)

    const wrapper = mount(FileInput, {
      attachTo: document.body,
      props: { cwd: '/home/user' },
    })
    await flushPromises()
    await new Promise((resolve) => setTimeout(resolve, 0))
    await flushPromises()

    const textarea = wrapper.find('textarea').element as HTMLTextAreaElement
    expect(document.activeElement).not.toBe(textarea)
    wrapper.unmount()
    dialog.remove()
  })
})
