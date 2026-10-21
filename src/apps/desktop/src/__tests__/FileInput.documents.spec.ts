/** The paperclip flow takes documents as well as images and video: a PDF rides along as a file
 * attachment, a text document as text. */
import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest'
import { mount, flushPromises } from '@vue/test-utils'
import { setActivePinia, createPinia } from 'pinia'
import FileInput from '@/components/file/FileInput.vue'
import * as api from '@/api'

vi.mock('@/api', async (importOriginal) => {
  const actual = await importOriginal<typeof import('@/api')>()
  return { ...actual, searchFiles: vi.fn() }
})

const originalFetch = global.fetch

async function mountInput() {
  document.body.innerHTML = ''
  const wrapper = mount(FileInput, {
    attachTo: document.body,
    props: { cwd: '/home/user' },
  })
  await flushPromises()
  return wrapper
}

/** Drive the hidden native file input the paperclip button opens. jsdom's `files` setter
 * demands a real FileList, so the property is defined instead of assigned. */
function selectFiles(wrapper: ReturnType<typeof mount>, files: File[]) {
  const input = wrapper.find('input[type="file"]')
  Object.defineProperty(input.element, 'files', { value: files, configurable: true })
  input.trigger('change')
}

describe('FileInput — the paperclip takes documents', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    vi.mocked(api.searchFiles).mockResolvedValue({ entries: [] })
    global.fetch = vi.fn() as unknown as typeof fetch
  })

  afterEach(() => {
    global.fetch = originalFetch
    vi.restoreAllMocks()
  })

  it('stages a picked PDF as an attachment', async () => {
    const wrapper = await mountInput()
    selectFiles(wrapper, [
      new File([new Uint8Array([0x25, 0x50, 0x44, 0x46])], 'doc.pdf', {
        type: 'application/pdf',
      }),
    ])
    await flushPromises()
    expect(wrapper.findAll('.preview-item').length).toBe(1)
  })

  it('stages a picked markdown file as an attachment', async () => {
    const wrapper = await mountInput()
    selectFiles(wrapper, [new File(['# hello'], 'notes.md', { type: 'text/markdown' })])
    await flushPromises()
    expect(wrapper.findAll('.preview-item').length).toBe(1)
  })

  it('ignores a file the model has no way to read', async () => {
    const wrapper = await mountInput()
    selectFiles(wrapper, [
      new File([new Uint8Array([0, 1, 2])], 'tool.exe', { type: 'application/octet-stream' }),
    ])
    await flushPromises()
    expect(wrapper.findAll('.preview-item').length).toBe(0)
  })

  it('stages at most the number of documents the backend accepts', async () => {
    const wrapper = await mountInput()
    selectFiles(
      wrapper,
      Array.from({ length: 9 }, (_, i) =>
        new File([`doc ${i}`], `doc-${i}.md`, { type: 'text/markdown' }),
      ),
    )
    await flushPromises()
    expect(wrapper.findAll('.preview-item').length).toBe(8)
  })

  it('sends the staged document to the parent on submit', async () => {
    const wrapper = await mountInput()
    selectFiles(wrapper, [
      new File([new Uint8Array([0x25, 0x50, 0x44, 0x46])], 'doc.pdf', {
        type: 'application/pdf',
      }),
    ])
    await flushPromises()

    const textarea = wrapper.find('textarea')
    await textarea.setValue('read this')
    await wrapper.find('button[type="submit"]').trigger('click')
    await flushPromises()

    const submitted = wrapper.emitted('submit')
    expect(submitted).toBeTruthy()
    const files = submitted?.[0]?.[1] as File[] | undefined
    expect(files?.map((f) => f.name)).toEqual(['doc.pdf'])
  })
})
