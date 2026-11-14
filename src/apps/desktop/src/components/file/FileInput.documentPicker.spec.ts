/** FileInput `/document-` picker — trigger, list, title filter, insert, gates. */
import { describe, expect, it, vi, beforeEach, afterEach } from 'vitest'
import { mount, flushPromises, type VueWrapper } from '@vue/test-utils'
import { setActivePinia, createPinia } from 'pinia'
import FileInput from './FileInput.vue'
import * as api from '../../api'
import { useWorkspacesStore, type Workspace } from '../../stores/workspaces'
import { useDocumentsStore } from '../../stores/documents'

vi.mock('../../api', () => ({
  API_BASE: '/api',
  searchFiles: vi.fn(),
  getSkills: vi.fn(),
  getAgentToolsRegistry: vi.fn(),
}))

const WS_ID = 'ws_1'
const PICKER = '[data-testid="document-picker-list"]'

function seedWorkspace(id = WS_ID): void {
  const store = useWorkspacesStore()
  store.workspaces = [
    { id, name: 'First', icon: 'folder', items: [], expanded: true } satisfies Workspace,
  ]
}

function seedDocuments(rows: Array<{ id: string; title: string; preview?: string }>): void {
  const store = useDocumentsStore()
  store.documents = rows.map((row, index) => ({
    id: row.id,
    workspace_id: WS_ID,
    title: row.title,
    preview: row.preview ?? '',
    format: 'markdown',
    created_at: '2026-11-14T00:00:00Z',
    updated_at: '2026-11-14T00:00:00Z',
    position: index,
  })) as api.Document[]
  store.loaded = true
}

async function mountInput() {
  document.body.innerHTML = ''
  const wrapper = mount(FileInput, {
    attachTo: document.body,
    props: { cwd: '/home/user' },
  })
  await flushPromises()
  return wrapper
}

async function typeInTextarea(
  textareaWrapper: ReturnType<VueWrapper['find']>,
  value: string,
  waitMs = 450,
) {
  const element = textareaWrapper.element as HTMLTextAreaElement
  await textareaWrapper.setValue(value)
  element.setSelectionRange(value.length, value.length)
  element.dispatchEvent(new Event('input', { bubbles: true }))
  await new Promise((resolve) => setTimeout(resolve, waitMs))
  await flushPromises()
}

function pickerTitles(wrapper: VueWrapper): string[] {
  return wrapper
    .find(PICKER)
    .findAll('button')
    .map((row) => row.find('span span').text())
}

describe('FileInput — /document picker', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
  })

  afterEach(() => {
    vi.restoreAllMocks()
  })

  it("typing '/document-' lists the workspace's documents by title", async () => {
    seedWorkspace()
    seedDocuments([
      { id: 'doc_1', title: 'Release plan' },
      { id: 'doc_2', title: 'Meeting notes' },
    ])
    const wrapper = await mountInput()
    await typeInTextarea(wrapper.find('textarea'), '/document-')

    expect(wrapper.find(PICKER).exists()).toBe(true)
    expect(pickerTitles(wrapper)).toEqual(['Release plan', 'Meeting notes'])
  })

  it('a query after the dash narrows the list to matching titles', async () => {
    seedWorkspace()
    seedDocuments([
      { id: 'doc_1', title: 'Release plan' },
      { id: 'doc_2', title: 'Meeting notes' },
    ])
    const wrapper = await mountInput()
    const textarea = wrapper.find('textarea')
    await typeInTextarea(textarea, '/document-plan')

    expect(pickerTitles(wrapper)).toEqual(['Release plan'])
  })

  it('a query matching no title renders the empty state instead of vanishing', async () => {
    seedWorkspace()
    seedDocuments([{ id: 'doc_1', title: 'Release plan' }])
    const wrapper = await mountInput()
    await typeInTextarea(wrapper.find('textarea'), '/document-zzz')

    expect(wrapper.find(PICKER).exists()).toBe(true)
    expect(wrapper.find(PICKER).text()).toContain('No documents found')
  })

  it('a workspace with no documents renders the empty state', async () => {
    seedWorkspace()
    seedDocuments([])
    const wrapper = await mountInput()
    await typeInTextarea(wrapper.find('textarea'), '/document-')

    expect(wrapper.find(PICKER).text()).toContain('No documents found')
  })

  it("Enter inserts '/document-<id>' and closes the picker", async () => {
    seedWorkspace()
    seedDocuments([{ id: 'doc_42', title: 'Release plan' }])
    const wrapper = await mountInput()
    const textarea = wrapper.find('textarea')
    await typeInTextarea(textarea, 'summarize /document-rel')
    await textarea.trigger('keydown', { key: 'Enter' })
    await flushPromises()

    const element = textarea.element as HTMLTextAreaElement
    expect(element.value).toBe('summarize /document-doc_42')
    expect(wrapper.find(PICKER).exists()).toBe(false)
  })

  it('ArrowDown then Enter picks the second row', async () => {
    seedWorkspace()
    seedDocuments([
      { id: 'doc_1', title: 'Alpha' },
      { id: 'doc_2', title: 'Beta' },
    ])
    const wrapper = await mountInput()
    const textarea = wrapper.find('textarea')
    await typeInTextarea(textarea, '/document-')
    await textarea.trigger('keydown', { key: 'ArrowDown' })
    await textarea.trigger('keydown', { key: 'Enter' })
    await flushPromises()

    expect((textarea.element as HTMLTextAreaElement).value).toBe('/document-doc_2')
  })

  it('Esc closes the picker and leaves the text as typed', async () => {
    seedWorkspace()
    seedDocuments([{ id: 'doc_1', title: 'Release plan' }])
    const wrapper = await mountInput()
    const textarea = wrapper.find('textarea')
    await typeInTextarea(textarea, '/document-')
    await textarea.trigger('keydown', { key: 'Escape' })
    await flushPromises()

    expect(wrapper.find(PICKER).exists()).toBe(false)
    expect((textarea.element as HTMLTextAreaElement).value).toBe('/document-')
  })

  it('a workspace-less composer never opens the picker', async () => {
    seedDocuments([{ id: 'doc_1', title: 'Release plan' }])
    const wrapper = await mountInput()
    await typeInTextarea(wrapper.find('textarea'), '/document-')

    expect(wrapper.find(PICKER).exists()).toBe(false)
  })

  it('opening the document picker closes the other composer surfaces', async () => {
    seedWorkspace()
    seedDocuments([{ id: 'doc_1', title: 'Release plan' }])
    const wrapper = await mountInput()
    const textarea = wrapper.find('textarea')
    await typeInTextarea(textarea, '/')

    expect(wrapper.find('[data-testid="slash-command-menu"]').exists()).toBe(true)

    await typeInTextarea(textarea, '/document-')
    expect(wrapper.find('[data-testid="slash-command-menu"]').exists()).toBe(false)
    expect(wrapper.find('[data-testid="skill-picker-list"]').exists()).toBe(false)
    expect(wrapper.find('[data-testid="tool-picker-list"]').exists()).toBe(false)
    expect(wrapper.find('.file-picker-list').exists()).toBe(false)
    expect(wrapper.find(PICKER).exists()).toBe(true)
  })

  it('a bare / offers the document command next to the other three', async () => {
    seedWorkspace()
    seedDocuments([])
    const wrapper = await mountInput()
    await typeInTextarea(wrapper.find('textarea'), '/')

    const rows = wrapper.find('[data-testid="slash-command-menu"]').findAll('button')
    expect(rows.map((row) => row.text())).toEqual([
      expect.stringContaining('/skill-'),
      expect.stringContaining('/tool-'),
      expect.stringContaining('/files-'),
      expect.stringContaining('/document-'),
    ])
  })

  it("typing '/d' narrows the command menu to the document command", async () => {
    seedWorkspace()
    seedDocuments([])
    const wrapper = await mountInput()
    await typeInTextarea(wrapper.find('textarea'), '/d')

    const rows = wrapper.find('[data-testid="slash-command-menu"]').findAll('button')
    expect(rows).toHaveLength(1)
    expect(rows[0]!.text()).toContain('/document-')
  })
})
