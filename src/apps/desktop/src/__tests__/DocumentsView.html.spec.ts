/** The HTML branch of the document page: an `html` document renders in a
 *  sandboxed iframe, and Save stores the page source the user typed. */
import { beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { nextTick } from 'vue'
import { flushPromises, mount } from '@vue/test-utils'
import { createMemoryHistory, createRouter } from 'vue-router'

import DocumentsView from '../components/workspace/DocumentsView.vue'

const getDocument = vi.hoisted(() => vi.fn())
const updateDocument = vi.hoisted(() => vi.fn())
const deleteDocument = vi.hoisted(() => vi.fn())

vi.mock('../api', async () => {
  const actual = await vi.importActual<typeof import('../api')>('../api')
  return { ...actual, getDocument, updateDocument, deleteDocument, listDocuments: vi.fn() }
})

const { useWorkspacesStore } = await import('../stores/workspaces')
const { useDocumentsStore } = await import('../stores/documents')

const PAGE = '<!doctype html><html><body><h1>Hello</h1></body></html>'

const HTML_DOC = {
  id: 'doc_1',
  workspace_id: 'ws_1',
  title: 'Landing draft',
  content: PAGE,
  format: 'html',
  created_at: '2026-09-01 10:00:00',
  updated_at: '2026-09-01 10:00:00',
  position: 0,
}

async function mountView() {
  const router = createRouter({
    history: createMemoryHistory(),
    routes: [{ path: '/:pathMatch(.*)*', component: { template: '<div/>' } }],
  })
  await router.push({ path: '/app/ws_1/doc/doc_1' })
  await router.isReady()
  return mount(DocumentsView, {
    props: { documentId: 'doc_1' },
    global: { plugins: [router] },
  })
}

beforeEach(() => {
  setActivePinia(createPinia())
  getDocument.mockReset()
  updateDocument.mockReset()
  deleteDocument.mockReset()
  useWorkspacesStore().workspaces = [
    { id: 'ws_1', name: 'agentic coding', icon: '📁', expanded: true, items: [] },
  ]
  useDocumentsStore().documents = [HTML_DOC]
  useDocumentsStore().loaded = true
})

describe('DocumentsView — html documents', () => {
  it('renders the page in an iframe instead of the markdown renderer', async () => {
    const wrapper = await mountView()
    await flushPromises()

    const frame = wrapper.get('[data-testid="documents-html-preview"]')
    expect(frame.attributes('srcdoc')).toBe(PAGE)
    expect(wrapper.find('[data-testid="documents-rendered"]').exists()).toBe(false)
    expect(wrapper.find('[data-testid="documents-content-input"]').exists()).toBe(false)
    wrapper.unmount()
  })

  it('runs the page on a null origin so it cannot reach the app', async () => {
    const wrapper = await mountView()
    await flushPromises()

    const sandbox = wrapper.get('[data-testid="documents-html-preview"]').attributes('sandbox') ?? ''
    expect(sandbox).toContain('allow-scripts')
    expect(sandbox).not.toContain('allow-same-origin')
    wrapper.unmount()
  })

  it('editing shows the source and Save stores the new page', async () => {
    const next = '<!doctype html><html><body><h1>Changed</h1></body></html>'
    updateDocument.mockResolvedValue({ document: { ...HTML_DOC, content: next } })
    const wrapper = await mountView()
    await flushPromises()

    await wrapper.get('[data-testid="documents-edit"]').trigger('click')
    await nextTick()

    const source = wrapper.get('[data-testid="documents-content-input"]')
    expect((source.element as HTMLTextAreaElement).value).toBe(PAGE)
    await source.setValue(next)
    await wrapper.get('[data-testid="documents-save"]').trigger('click')
    await flushPromises()

    const call = updateDocument.mock.calls[0] as [string, string, Record<string, unknown>]
    expect(call[0]).toBe('ws_1')
    expect(call[1]).toBe('doc_1')
    expect(call[2]).toEqual({ content: next })
    wrapper.unmount()
  })

  it('the preview follows the draft while editing', async () => {
    const wrapper = await mountView()
    await flushPromises()

    await wrapper.get('[data-testid="documents-edit"]').trigger('click')
    await nextTick()
    await wrapper.get('[data-testid="documents-content-input"]').setValue('<p>live</p>')
    await nextTick()

    expect(wrapper.get('[data-testid="documents-html-preview"]').attributes('srcdoc')).toBe(
      '<p>live</p>',
    )
    wrapper.unmount()
  })
})
