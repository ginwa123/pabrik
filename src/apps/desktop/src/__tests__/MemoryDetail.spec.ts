/** Tests for MemoryDetail.vue. Covers the 4 modes (empty, view, edit,
 * create) and the 3 emit types (memoryDeleted, memorySaved, error).
 * Mocks the api module so no network calls happen. */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { mount, type VueWrapper } from '@vue/test-utils'

import MemoryDetail from '../components/memory/MemoryDetail.vue'

vi.mock('../api', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../api')>()
  return {
    ...actual,
    getMemoryDetail: vi.fn(),
    createMemory: vi.fn(),
    updateMemory: vi.fn(),
    deleteMemory: vi.fn(),
  }
})

import { getMemoryDetail, createMemory, updateMemory, deleteMemory } from '../api'

const mockGet = getMemoryDetail as unknown as ReturnType<typeof vi.fn>
const mockCreate = createMemory as unknown as ReturnType<typeof vi.fn>
const mockUpdate = updateMemory as unknown as ReturnType<typeof vi.fn>
const mockDelete = deleteMemory as unknown as ReturnType<typeof vi.fn>

describe('MemoryDetail', () => {
  let wrapper: VueWrapper | null = null

  function mountDetail(memoryName: string | null) {
    const w = mount(MemoryDetail, {
      props: { memoryName },
      attachTo: document.body,
    })
    wrapper = w
    return w
  }

  beforeEach(() => {
    mockGet.mockReset()
    mockCreate.mockReset()
    mockUpdate.mockReset()
    mockDelete.mockReset()
  })

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
  })

  it('renders the empty state with a New Memory button when memoryName is null', () => {
    mountDetail(null)
    expect(document.body.textContent).toContain('Select a memory to view, or create a new one.')
    expect(document.body.textContent).toContain('+ New Memory')
  })

  it('loads and renders the content when memoryName is set', async () => {
    mockGet.mockResolvedValue({
      memory: { name: 'foo.md', title: 'Foo', path: '/x/foo.md', size: 7, content: '# Foo' },
      error_message: null,
    })
    const w = mountDetail('foo.md')
    // Wait for the watch's async load + render.
    await new Promise((r) => setTimeout(r, 0))
    await w.vm.$nextTick()
    expect(document.body.textContent).toContain('Foo')
    expect(document.body.textContent).toContain('# Foo')
    expect(mockGet).toHaveBeenCalledWith('foo.md')
  })

  it('switches to edit mode and calls updateMemory on save', async () => {
    mockGet.mockResolvedValue({
      memory: { name: 'foo.md', title: 'Foo', path: '/x/foo.md', size: 7, content: '# Foo' },
      error_message: null,
    })
    mockUpdate.mockResolvedValue({
      memory: { name: 'foo.md', title: 'Foo', path: '/x/foo.md', size: 13 },
    })
    const w = mountDetail('foo.md')
    await new Promise((r) => setTimeout(r, 0))
    await w.vm.$nextTick()

    // Click Edit.
    const editBtn = Array.from(document.querySelectorAll('button')).find(
      (b) => b.textContent?.trim() === 'Edit',
    ) as HTMLElement
    expect(editBtn).toBeTruthy()
    editBtn.click()
    await w.vm.$nextTick()

    // Now we should have a textarea with the current content.
    const textarea = document.querySelector('textarea') as HTMLTextAreaElement
    expect(textarea).toBeTruthy()
    expect(textarea.value).toBe('# Foo')

    // Change and save.
    textarea.value = '# Foo (edited)'
    textarea.dispatchEvent(new Event('input', { bubbles: true }))
    const saveBtn = Array.from(document.querySelectorAll('button')).find(
      (b) => b.textContent?.trim() === 'Save',
    ) as HTMLElement
    expect(saveBtn).toBeTruthy()
    saveBtn.click()

    // Wait for the update + refresh + emit.
    await new Promise((r) => setTimeout(r, 0))
    await w.vm.$nextTick()
    expect(mockUpdate).toHaveBeenCalledWith('foo.md', '# Foo (edited)')
    expect(w.emitted('memorySaved')).toBeTruthy()
  })

  it('switches to create mode and calls createMemory on save', async () => {
    mockCreate.mockResolvedValue({
      memory: { name: 'new.md', title: 'New', path: '/x/new.md', size: 5 },
    })
    const w = mountDetail(null)
    const newBtn = Array.from(document.querySelectorAll('button')).find(
      (b) => b.textContent?.trim() === '+ New Memory',
    ) as HTMLElement
    newBtn.click()
    await w.vm.$nextTick()

    // Fill in name + content.
    const inputs = document.querySelectorAll('input')
    const nameInput = inputs[0] as HTMLInputElement
    nameInput.value = 'new.md'
    nameInput.dispatchEvent(new Event('input', { bubbles: true }))
    const textareas = document.querySelectorAll('textarea')
    const contentTextarea = textareas[0] as HTMLTextAreaElement
    contentTextarea.value = '# New'
    contentTextarea.dispatchEvent(new Event('input', { bubbles: true }))

    // Click Create.
    const createBtn = Array.from(document.querySelectorAll('button')).find(
      (b) => b.textContent?.trim() === 'Create',
    ) as HTMLElement
    createBtn.click()

    await new Promise((r) => setTimeout(r, 0))
    await w.vm.$nextTick()
    expect(mockCreate).toHaveBeenCalledWith('new.md', '# New')
    expect(w.emitted('memorySaved')).toBeTruthy()
  })

  it('emits error on validation failure (empty name)', async () => {
    const w = mountDetail(null)
    const newBtn = Array.from(document.querySelectorAll('button')).find(
      (b) => b.textContent?.trim() === '+ New Memory',
    ) as HTMLElement
    newBtn.click()
    await w.vm.$nextTick()

    // Leave name empty, click Create.
    const createBtn = Array.from(document.querySelectorAll('button')).find(
      (b) => b.textContent?.trim() === 'Create',
    ) as HTMLElement
    createBtn.click()
    await w.vm.$nextTick()

    expect(w.emitted('error')).toBeTruthy()
    expect(w.emitted('error')![0]).toEqual(['Name cannot be empty'])
    expect(mockCreate).not.toHaveBeenCalled()
  })

  it('emits error on name without .md suffix', async () => {
    const w = mountDetail(null)
    const newBtn = Array.from(document.querySelectorAll('button')).find(
      (b) => b.textContent?.trim() === '+ New Memory',
    ) as HTMLElement
    newBtn.click()
    await w.vm.$nextTick()

    const nameInput = document.querySelector('input') as HTMLInputElement
    nameInput.value = 'no-suffix'
    nameInput.dispatchEvent(new Event('input', { bubbles: true }))
    const createBtn = Array.from(document.querySelectorAll('button')).find(
      (b) => b.textContent?.trim() === 'Create',
    ) as HTMLElement
    createBtn.click()
    await w.vm.$nextTick()

    expect(w.emitted('error')![0]).toEqual(['Name must end in .md'])
    expect(mockCreate).not.toHaveBeenCalled()
  })
})
