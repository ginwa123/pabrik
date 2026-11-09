/** The office branch of the document page: an `office` document opens the Univer
 *  editor instead of a textarea, and Save stores the envelope it hands back. */
import { beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { defineComponent, h, nextTick } from 'vue'
import { flushPromises, mount } from '@vue/test-utils'
import { createMemoryHistory, createRouter } from 'vue-router'

import DocumentsView from '../components/workspace/DocumentsView.vue'
import { serializeOfficeBody } from '../helpers/officeDocument'

const getDocument = vi.hoisted(() => vi.fn())
const updateDocument = vi.hoisted(() => vi.fn())
const deleteDocument = vi.hoisted(() => vi.fn())

vi.mock('../api', async () => {
  const actual = await vi.importActual<typeof import('../api')>('../api')
  return { ...actual, getDocument, updateDocument, deleteDocument, listDocuments: vi.fn() }
})

const { useWorkspacesStore } = await import('../stores/workspaces')
const { useDocumentsStore } = await import('../stores/documents')

const SNAPSHOT = { sheets: { s1: { cellData: { '0': { '0': { v: 'saved' } } } } } }

/** Stands in for the Univer editor: jsdom cannot evaluate the SDK, and the
 *  contract under test is the one the view relies on — `snapshot()` plus a
 *  `change` event. */
const OfficeEditorStub = defineComponent({
  name: 'OfficeDocumentEditor',
  props: { body: { type: String, default: '' } },
  emits: ['change'],
  setup(props, { expose }) {
    expose({
      snapshot: () => SNAPSHOT,
      // The view stores the snapshot under the kind the editor mounted, so the
      // stub reports the kind its body names — exactly like the real one.
      kind: () => (JSON.parse(props.body || '{}').kind === 'doc' ? 'doc' : 'sheet'),
    })
    return () => h('div', { 'data-testid': 'office-editor-stub' })
  },
})

const OFFICE_DOC = {
  id: 'doc_1',
  workspace_id: 'ws_1',
  title: 'Budget',
  content: serializeOfficeBody('sheet', {}),
  format: 'office',
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
    global: { plugins: [router], stubs: { OfficeDocumentEditor: OfficeEditorStub } },
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
  useDocumentsStore().documents = [OFFICE_DOC]
  useDocumentsStore().loaded = true
})

describe('DocumentsView — office documents', () => {
  it('opens the Univer editor instead of the markdown textarea', async () => {
    const wrapper = await mountView()
    await flushPromises()

    expect(wrapper.find('[data-testid="office-editor-stub"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="documents-content-input"]').exists()).toBe(false)
    expect(wrapper.find('[data-testid="documents-rendered"]').exists()).toBe(false)
    wrapper.unmount()
  })

  it('Save is disabled until the editor reports a change, then stores the envelope', async () => {
    updateDocument.mockResolvedValue({
      document: { ...OFFICE_DOC, content: serializeOfficeBody('sheet', SNAPSHOT) },
    })
    const wrapper = await mountView()
    await flushPromises()

    expect(wrapper.get('[data-testid="documents-save"]').attributes('disabled')).toBeDefined()

    wrapper.findComponent(OfficeEditorStub).vm.$emit('change')
    await nextTick()
    expect(wrapper.get('[data-testid="documents-save"]').attributes('disabled')).toBeUndefined()

    await wrapper.get('[data-testid="documents-save"]').trigger('click')
    await flushPromises()

    const call = updateDocument.mock.calls[0] as [string, string, Record<string, unknown>]
    expect(call[0]).toBe('ws_1')
    expect(call[1]).toBe('doc_1')
    // The body is the envelope, not the bare snapshot: the kind has to survive
    // the round trip or the next open mounts the wrong editor.
    expect(JSON.parse(String(call[2].content))).toEqual({ kind: 'sheet', snapshot: SNAPSHOT })
    expect('title' in call[2]).toBe(false)
    wrapper.unmount()
  })

  it('renaming an office document sends only the title', async () => {
    updateDocument.mockResolvedValue({ document: { ...OFFICE_DOC, title: 'Budget v2' } })
    const wrapper = await mountView()
    await flushPromises()

    await wrapper.get('[data-testid="documents-edit"]').trigger('click')
    await nextTick()
    await wrapper.get('[data-testid="documents-title-input"]').setValue('Budget v2')
    await wrapper.get('[data-testid="documents-save"]').trigger('click')
    await flushPromises()

    const patch = (updateDocument.mock.calls[0] as [string, string, Record<string, unknown>])[2]
    // A rename must not rewrite the body: the editor's snapshot is not the
    // user's intent here, and a whole-body PATCH would revert an agent edit.
    expect(Object.keys(patch)).toEqual(['title'])
    wrapper.unmount()
  })

  it('does not mount the editor until the body has loaded', async () => {
    // The bug this guards: mounting the editor while the body is still empty
    // opened a blank spreadsheet for every office document, and Save then wrote
    // that workbook under the document's real kind.
    let release: (value: unknown) => void = () => {}
    const gate = new Promise((resolve) => {
      release = resolve
    })
    getDocument.mockReturnValue(gate)

    // A list row: metadata only, no body. This is what the sidebar holds
    // before the single-document read lands.
    const { content: _omit, ...listRow } = OFFICE_DOC
    useDocumentsStore().documents = [listRow]

    const wrapper = await mountView()
    await flushPromises()

    expect(wrapper.find('[data-testid="office-editor-stub"]').exists()).toBe(false)
    expect(wrapper.find('[data-testid="documents-office-loading"]').exists()).toBe(true)

    release({ document: OFFICE_DOC })
    await flushPromises()

    const stub = wrapper.findComponent(OfficeEditorStub)
    expect(stub.exists()).toBe(true)
    // And it mounts with the REAL body, not an empty one.
    expect(stub.props('body')).toBe(OFFICE_DOC.content)
    wrapper.unmount()
  })

  it('stores the snapshot under the kind the editor mounted', async () => {
    updateDocument.mockResolvedValue({
      document: { ...OFFICE_DOC, content: serializeOfficeBody('doc', SNAPSHOT) },
    })
    useDocumentsStore().documents = [
      { ...OFFICE_DOC, content: serializeOfficeBody('doc', {}) },
    ]
    const wrapper = await mountView()
    await flushPromises()

    wrapper.findComponent(OfficeEditorStub).vm.$emit('change')
    await nextTick()
    await wrapper.get('[data-testid="documents-save"]').trigger('click')
    await flushPromises()

    const patch = (updateDocument.mock.calls[0] as [string, string, Record<string, unknown>])[2]
    // A docx must stay a docx: the envelope's kind and the snapshot inside it
    // come from the same editor.
    expect(JSON.parse(String(patch.content)).kind).toBe('doc')
    wrapper.unmount()
  })

  it('a document body that is not an envelope is reported by the editor, not the view', async () => {
    useDocumentsStore().documents = [{ ...OFFICE_DOC, content: 'not json' }]
    const wrapper = await mountView()
    await flushPromises()

    // The view still renders the editor; the editor owns the "unreadable body"
    // message, so there is exactly one place that decides what a bad body means.
    const stub = wrapper.findComponent(OfficeEditorStub)
    expect(stub.exists()).toBe(true)
    expect(stub.props('body')).toBe('not json')
    wrapper.unmount()
  })
})
