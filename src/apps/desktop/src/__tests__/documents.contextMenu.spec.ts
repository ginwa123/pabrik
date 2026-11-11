import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { nextTick } from 'vue'
import { flushPromises, mount } from '@vue/test-utils'
import { createMemoryHistory, createRouter } from 'vue-router'

import DocumentsList from '../components/workspace/DocumentsList.vue'
import { makeLocalStorageStub } from './helpers'

const listDocuments = vi.hoisted(() => vi.fn())
const getDocument = vi.hoisted(() => vi.fn())
const createDocument = vi.hoisted(() => vi.fn())
const updateDocument = vi.hoisted(() => vi.fn())
const deleteDocument = vi.hoisted(() => vi.fn())

vi.mock('../api', async () => {
  const actual = await vi.importActual<typeof import('../api')>('../api')
  return {
    ...actual,
    listDocuments,
    getDocument,
    createDocument,
    updateDocument,
    deleteDocument,
    reorderDocuments: vi.fn(),
    exportDocument: vi.fn(),
    exportDocuments: vi.fn(),
  }
})

const DOCS = [
  {
    id: 'doc_1',
    workspace_id: 'ws_1',
    title: 'Release plan',
    format: 'markdown',
    created_at: '2026-09-01 10:00:00',
    updated_at: '2026-09-02 10:00:00',
  },
  {
    id: 'doc_2',
    workspace_id: 'ws_1',
    title: 'Meeting notes',
    format: 'markdown',
    created_at: '2026-09-01 11:00:00',
    updated_at: '2026-09-01 11:00:00',
  },
]

async function makeRouter() {
  const router = createRouter({
    history: createMemoryHistory(),
    routes: [{ path: '/:pathMatch(.*)*', component: { template: '<div/>' } }],
  })
  await router.push('/app/ws_1')
  await router.isReady()
  return router
}

async function settle(): Promise<void> {
  await flushPromises()
  await nextTick()
}

async function clearDocumentsCache(workspaceId = 'ws_1'): Promise<void> {
  const { documentEngineDb } = await import('../sync/DocumentEngineDb')
  const { runSyncVoid } = await import('../sync/runtime')
  await runSyncVoid(documentEngineDb.clear(workspaceId), 'spec.clearDocumentsCache')
}

async function mountList() {
  const router = await makeRouter()
  const wrapper = mount(DocumentsList, {
    props: { workspaceId: 'ws_1' },
    global: { plugins: [router] },
    attachTo: document.body,
  })
  await settle()
  return { wrapper, router }
}

function menuRow(testId: string): HTMLElement | null {
  return document.querySelector<HTMLElement>(`[data-testid="${testId}"]`)
}

function dialogButton(re: RegExp): HTMLButtonElement | undefined {
  return Array.from(document.body.querySelectorAll('button')).find((b) =>
    re.test(b.textContent ?? ''),
  )
}

async function rightClick(wrapper: Awaited<ReturnType<typeof mountList>>['wrapper'], id: string) {
  await wrapper.get(`[data-testid="document-row-${id}"]`).trigger('contextmenu', {
    clientX: 40,
    clientY: 60,
  })
  await nextTick()
}

describe('DocumentsList — context menu actions', () => {
  beforeEach(async () => {
    await clearDocumentsCache()
    setActivePinia(createPinia())
    Object.defineProperty(globalThis, 'localStorage', {
      value: makeLocalStorageStub(),
      writable: true,
      configurable: true,
    })
    Object.defineProperty(navigator, 'clipboard', {
      value: { writeText: vi.fn().mockResolvedValue(undefined) },
      writable: true,
      configurable: true,
    })
    listDocuments.mockReset()
    getDocument.mockReset()
    createDocument.mockReset()
    updateDocument.mockReset()
    deleteDocument.mockReset()
    listDocuments.mockResolvedValue({ documents: DOCS, count: DOCS.length })
    getDocument.mockImplementation(async (_ws: string, id: string) => ({
      document: { ...DOCS.find((d) => d.id === id)!, content: '# body' },
    }))
    updateDocument.mockImplementation(
      async (_ws: string, id: string, patch: { title?: string }) => ({
        document: { ...DOCS.find((d) => d.id === id)!, ...patch },
      }),
    )
    deleteDocument.mockImplementation(async (_ws: string, id: string) => ({
      id,
      success: true,
    }))
  })

  afterEach(() => {
    document.body.innerHTML = ''
  })

  it('names the right-clicked document in the menu title', async () => {
    const { wrapper } = await mountList()
    await rightClick(wrapper, 'doc_1')

    expect(menuRow('documents-context-menu-title')?.textContent?.trim()).toBe('Release plan')
    wrapper.unmount()
  })

  it('offers open, rename, duplicate, copy link and delete for one document', async () => {
    const { wrapper } = await mountList()
    await rightClick(wrapper, 'doc_1')

    expect(menuRow('documents-context-menu-open')?.textContent).toContain('Open')
    expect(menuRow('documents-context-menu-rename')?.textContent).toContain('Rename')
    expect(menuRow('documents-context-menu-duplicate')?.textContent).toContain('Duplicate')
    expect(menuRow('documents-context-menu-copy-link')?.textContent).toContain('Copy link')
    expect(menuRow('documents-context-menu-delete')?.textContent).toContain('Delete')
    wrapper.unmount()
  })

  it('open navigates to the document page', async () => {
    const { wrapper, router } = await mountList()
    await rightClick(wrapper, 'doc_2')
    menuRow('documents-context-menu-open')?.click()
    await settle()

    expect(router.currentRoute.value.path).toBe('/app/ws_1/doc/doc_2')
    wrapper.unmount()
  })

  it('rename turns the row into a field and saving the new name retitles the row', async () => {
    const { wrapper } = await mountList()
    await rightClick(wrapper, 'doc_1')
    menuRow('documents-context-menu-rename')?.click()
    await settle()

    const input = wrapper.get('[data-testid="document-rename-input"]')
    await input.setValue('Release plan v2')
    await input.trigger('keydown.enter')
    await settle()

    expect(wrapper.get('[data-testid="document-row-doc_1"]').text()).toBe('Release plan v2')
    expect(wrapper.find('[data-testid="document-rename-input"]').exists()).toBe(false)
    wrapper.unmount()
  })

  it('an unchanged name is not written back', async () => {
    const { wrapper } = await mountList()
    await rightClick(wrapper, 'doc_1')
    menuRow('documents-context-menu-rename')?.click()
    await settle()

    await wrapper.get('[data-testid="document-rename-input"]').trigger('keydown.enter')
    await settle()

    expect(updateDocument).not.toHaveBeenCalled()
    wrapper.unmount()
  })

  it('duplicate copies the body into a new document titled "<title> copy"', async () => {
    createDocument.mockResolvedValue({
      document: { ...DOCS[0], id: 'doc_copy', title: 'Release plan copy' },
    })
    const { wrapper } = await mountList()
    await rightClick(wrapper, 'doc_1')
    menuRow('documents-context-menu-duplicate')?.click()
    await settle()

    expect(getDocument).toHaveBeenCalledWith('ws_1', 'doc_1')
    expect(createDocument).toHaveBeenCalledWith(
      'ws_1',
      'Release plan copy',
      '# body',
      null,
      'markdown',
    )
    expect(wrapper.get('[data-testid="document-row-doc_copy"]').text()).toBe('Release plan copy')
    wrapper.unmount()
  })

  it('copy link puts the document URL on the clipboard and says so', async () => {
    const { wrapper } = await mountList()
    await rightClick(wrapper, 'doc_1')
    menuRow('documents-context-menu-copy-link')?.click()
    await settle()

    expect(navigator.clipboard.writeText).toHaveBeenCalledWith(
      `${window.location.origin}/app/ws_1/doc/doc_1`,
    )
    expect(wrapper.get('[data-testid="documents-action-notice"]').text()).toBe('Link copied')
    wrapper.unmount()
  })

  it('delete asks first and removes nothing until the dialog is confirmed', async () => {
    const { wrapper } = await mountList()
    await rightClick(wrapper, 'doc_1')
    menuRow('documents-context-menu-delete')?.click()
    await settle()

    expect(deleteDocument).not.toHaveBeenCalled()
    expect(wrapper.find('[data-testid="document-row-doc_1"]').exists()).toBe(true)
    expect(document.body.textContent).toContain('Delete "Release plan"?')
    wrapper.unmount()
  })

  it('confirming the delete removes the document from the list', async () => {
    const { wrapper } = await mountList()
    await rightClick(wrapper, 'doc_1')
    menuRow('documents-context-menu-delete')?.click()
    await settle()

    dialogButton(/^Delete$/)?.click()
    await settle()

    expect(deleteDocument).toHaveBeenCalledWith('ws_1', 'doc_1')
    expect(wrapper.find('[data-testid="document-row-doc_1"]').exists()).toBe(false)
    expect(wrapper.get('[data-testid="documents-action-notice"]').text()).toBe('Deleted 1 document')
    wrapper.unmount()
  })

  it('cancelling the delete keeps the document', async () => {
    const { wrapper } = await mountList()
    await rightClick(wrapper, 'doc_1')
    menuRow('documents-context-menu-delete')?.click()
    await settle()

    dialogButton(/^Cancel$/)?.click()
    await settle()

    expect(deleteDocument).not.toHaveBeenCalled()
    expect(wrapper.find('[data-testid="document-row-doc_1"]').exists()).toBe(true)
    wrapper.unmount()
  })

  it('deleting a multi-selection removes every selected document', async () => {
    const { wrapper } = await mountList()
    await wrapper.get('[data-testid="document-row-doc_1"]').trigger('click', { ctrlKey: true })
    await wrapper.get('[data-testid="document-row-doc_2"]').trigger('click', { ctrlKey: true })
    await rightClick(wrapper, 'doc_2')

    expect(menuRow('documents-context-menu-delete')?.textContent).toContain('Delete 2 documents')
    menuRow('documents-context-menu-delete')?.click()
    await settle()
    expect(document.body.textContent).toContain('Delete 2 documents?')

    dialogButton(/^Delete$/)?.click()
    await settle()

    expect(deleteDocument).toHaveBeenCalledWith('ws_1', 'doc_1')
    expect(deleteDocument).toHaveBeenCalledWith('ws_1', 'doc_2')
    expect(wrapper.find('[data-testid="document-row-doc_1"]').exists()).toBe(false)
    expect(wrapper.find('[data-testid="document-row-doc_2"]').exists()).toBe(false)
    wrapper.unmount()
  })

  it('open, rename and copy link are unavailable for a multi-selection', async () => {
    const { wrapper } = await mountList()
    await wrapper.get('[data-testid="document-row-doc_1"]').trigger('click', { ctrlKey: true })
    await wrapper.get('[data-testid="document-row-doc_2"]').trigger('click', { ctrlKey: true })
    await rightClick(wrapper, 'doc_2')

    expect(menuRow('documents-context-menu-open')?.hasAttribute('disabled')).toBe(true)
    expect(menuRow('documents-context-menu-rename')?.hasAttribute('disabled')).toBe(true)
    expect(menuRow('documents-context-menu-copy-link')?.hasAttribute('disabled')).toBe(true)
    expect(menuRow('documents-context-menu-duplicate')?.hasAttribute('disabled')).toBe(false)
    expect(menuRow('documents-context-menu-delete')?.hasAttribute('disabled')).toBe(false)
    wrapper.unmount()
  })
})
