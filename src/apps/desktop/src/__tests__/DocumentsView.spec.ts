/**
 * The documents viewer (Migration 095).
 *
 * The behaviours that are easy to break and invisible until a user hits
 * them:
 *
 *  1. `content` is a WHOLE-body replace, so "omitted" and "cleared" must
 *     stay distinguishable in the editor. Sending `content: ''` when the
 *     user only renamed the title would destroy the document.
 *  2. Markdown is rendered through `helpers/markdown.ts`, which escapes
 *     raw HTML before parsing. A document body is authored by an agent
 *     that may have quoted a file it read, so `v-html` on unescaped
 *     markdown is a real XSS sink, not a theoretical one.
 *  3. Switching documents while mounted reloads. `onMounted`-only would
 *     leave the previous body under the new title — the Back/Forward
 *     case.
 */
import { beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { nextTick } from 'vue'
import { flushPromises, mount } from '@vue/test-utils'
import { createMemoryHistory, createRouter, type Router } from 'vue-router'

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

const DOC = {
  id: 'doc_1',
  workspace_id: 'ws_1',
  title: 'Release plan',
  content: '# Heading\n\nSome **bold** text.',
  format: 'markdown',
  created_at: '2026-09-01 10:00:00',
  updated_at: '2026-09-01 10:00:00',
}

async function makeRouter() {
  const router = createRouter({
    history: createMemoryHistory(),
    routes: [{ path: '/:pathMatch(.*)*', component: { template: '<div/>' } }],
  })
  await router.push({ path: '/app/ws_1/doc/doc_1' })
  await router.isReady()
  return router
}

async function mountView(documentId = 'doc_1', router?: Router) {
  const r = router ?? (await makeRouter())
  return mount(DocumentsView, { props: { documentId }, global: { plugins: [r] } })
}

beforeEach(() => {
  setActivePinia(createPinia())
  getDocument.mockReset()
  updateDocument.mockReset()
  deleteDocument.mockReset()
  // Seed the workspace itself, not the raw `activeWorkspaceId` ref. The view resolves its workspace
  // through the `activeWorkspace` computed (precedence: explicit → persisted → item-owning → first
  // workspace), so seeding the ref alone no longer gives it anything to fetch against.

  // Seeding real store state is also what the app has: the ref is only set by the header dropdown
  // or a `?workspaceId=` URL restore.
  useWorkspacesStore().workspaces = [
    { id: 'ws_1', name: 'agentic coding', icon: '📁', expanded: true, items: [] },
  ]
  // Seed the list so `loadDocument` serves from cache, the way it does in
  // the real app (the sidebar has already listed the workspace).
  useDocumentsStore().documents = [DOC]
  useDocumentsStore().loaded = true
})

describe('DocumentsView — rendering', () => {
  it('shows the title and the rendered markdown', async () => {
    const wrapper = await mountView()
    await flushPromises()

    expect(wrapper.get('[data-testid="documents-title"]').text()).toBe('Release plan')
    const html = wrapper.get('[data-testid="documents-rendered"]').html()
    expect(html).toContain('<h1')
    expect(html).toContain('<strong>bold</strong>')
    wrapper.unmount()
  })

  it('escapes raw HTML in the body instead of executing it', async () => {
    // The XSS guard. An agent that read a file and quoted its contents
    // into a document is enough to make this reachable, so the escaping
    // in helpers/markdown.ts is load-bearing — not paranoia.
    useDocumentsStore().documents = [{ ...DOC, content: '<img src=x onerror="window.__pwned=1">' }]
    const wrapper = await mountView()
    await flushPromises()

    const html = wrapper.get('[data-testid="documents-rendered"]').html()
    expect(html).not.toContain('<img')
    expect(html).toContain('&lt;img')
    expect((globalThis as { __pwned?: number }).__pwned).toBeUndefined()
    wrapper.unmount()
  })

  it('a load failure is rendered, not a blank pane', async () => {
    useDocumentsStore().documents = []
    useDocumentsStore().loaded = true
    getDocument.mockRejectedValue(new Error('document not found'))
    const wrapper = await mountView()
    await flushPromises()

    // A silently empty view is indistinguishable from a deleted
    // document — the user cannot tell a 404 from a blank note.
    expect(wrapper.find('[data-testid="documents-view-error"]').exists()).toBe(true)
    wrapper.unmount()
  })
})

describe('DocumentsView — editing', () => {
  it('a title-only edit does NOT send content', async () => {
    const wrapper = await mountView()
    await flushPromises()

    await wrapper.get('[data-testid="documents-edit"]').trigger('click')
    await nextTick()
    const title = wrapper.get('[data-testid="documents-title-input"]')
    await title.setValue('Release plan v2')
    wrapper.unmount()

    updateDocument.mockResolvedValue({ document: { ...DOC, title: 'Release plan v2' } })
    await wrapper.get('[data-testid="documents-save"]').trigger('click')
    await flushPromises()

    // The regression this guards: a store that always sends
    // `{title, content}` would blank the body on every rename.
    const call = updateDocument.mock.calls[0]
    expect(call).toBeDefined()
    const [ws, id, patch] = call as [string, string, Record<string, unknown>]
    expect(ws).toBe('ws_1')
    expect(id).toBe('doc_1')
    expect(Object.keys(patch)).toEqual(['title'])
    expect('content' in patch).toBe(false)
  })

  it('an explicit empty body DOES clear the content', async () => {
    const wrapper = await mountView()
    await flushPromises()

    await wrapper.get('[data-testid="documents-edit"]').trigger('click')
    await nextTick()
    const body = wrapper.get('[data-testid="documents-content-input"]')
    await body.setValue('')
    wrapper.unmount()

    updateDocument.mockResolvedValue({ document: { ...DOC, content: '' } })
    await wrapper.get('[data-testid="documents-save"]').trigger('click')
    await flushPromises()

    const call = updateDocument.mock.calls[0]
    expect(call).toBeDefined()
    const patch = (call as [string, string, Record<string, unknown>])[2]
    // Distinct from the title-only case above: here "" must be SENT.
    expect(patch.content).toBe('')
  })

  it('Save is disabled until something actually changes', async () => {
    const wrapper = await mountView()
    await flushPromises()

    await wrapper.get('[data-testid="documents-edit"]').trigger('click')
    await nextTick()
    expect(wrapper.get('[data-testid="documents-save"]').attributes('disabled')).toBeDefined()

    await wrapper.get('[data-testid="documents-content-input"]').setValue('changed')
    await nextTick()
    expect(wrapper.get('[data-testid="documents-save"]').attributes('disabled')).toBeUndefined()
    wrapper.unmount()
  })

  it('cancel restores the stored body, discarding the edit', async () => {
    const wrapper = await mountView()
    await flushPromises()

    await wrapper.get('[data-testid="documents-edit"]').trigger('click')
    await nextTick()
    await wrapper.get('[data-testid="documents-content-input"]').setValue('throwaway')
    await wrapper.get('[data-testid="documents-cancel"]').trigger('click')
    await nextTick()

    // Re-opening the editor must show what is STORED, not the abandoned
    // draft — otherwise a second edit silently re-applies the first.
    await wrapper.get('[data-testid="documents-edit"]').trigger('click')
    await nextTick()
    const body = wrapper.get('[data-testid="documents-content-input"]')
    expect((body.element as HTMLTextAreaElement).value).toBe(DOC.content)
    expect(updateDocument).not.toHaveBeenCalled()
    wrapper.unmount()
  })

  it('editing shows the live preview and it can be hidden', async () => {
    const wrapper = await mountView()
    await flushPromises()

    await wrapper.get('[data-testid="documents-edit"]').trigger('click')
    await nextTick()
    expect(wrapper.find('[data-testid="documents-preview"]').exists()).toBe(true)

    await wrapper.get('[data-testid="documents-preview-toggle"]').trigger('click')
    await nextTick()
    expect(wrapper.find('[data-testid="documents-preview"]').exists()).toBe(false)
    // The textarea stays mounted: a v-if here drops the caret and the
    // scroll position on every preview toggle.
    expect(wrapper.find('[data-testid="documents-content-input"]').exists()).toBe(true)
    wrapper.unmount()
  })
})

describe('DocumentsView — delete and navigation', () => {
  it('delete leaves the document page so the view is not left blank', async () => {
    deleteDocument.mockResolvedValue({ id: 'doc_1', success: true })
    const router = await makeRouter()
    const wrapper = await mountView('doc_1', router)
    await flushPromises()

    await wrapper.get('[data-testid="documents-delete"]').trigger('click')
    await flushPromises()

    // A deleted document left selected renders a permanently empty view.
    // The document owns its path, so deleting leaves the page by going
    // back to the workspace root.
    expect(deleteDocument).toHaveBeenCalledWith('ws_1', 'doc_1')
    expect(router.currentRoute.value.path).toBe('/app/ws_1')
    wrapper.unmount()
  })

  it('a failed delete keeps the document open and the URL intact', async () => {
    deleteDocument.mockRejectedValue(new Error('document not found'))
    const router = await makeRouter()
    const wrapper = await mountView('doc_1', router)
    await flushPromises()

    await wrapper.get('[data-testid="documents-delete"]').trigger('click')
    await flushPromises()

    // Navigating away on a failed delete loses the user's place for a
    // request that did not happen.
    expect(router.currentRoute.value.path).toBe('/app/ws_1/doc/doc_1')
    expect(wrapper.find('[data-testid="documents-rendered"]').exists()).toBe(true)
    wrapper.unmount()
  })

  it('switching documentId reloads instead of showing the previous body', async () => {
    const wrapper = await mountView('doc_1')
    await flushPromises()
    expect(wrapper.get('[data-testid="documents-title"]').text()).toBe('Release plan')

    const second = { ...DOC, id: 'doc_2', title: 'Other doc', content: 'different body' }
    useDocumentsStore().documents = [DOC, second]
    await wrapper.setProps({ documentId: 'doc_2' })
    await flushPromises()

    // The Back/Forward case: the component stays mounted, so an
    // onMounted-only fetch would leave doc_1's body under doc_2's title.
    expect(wrapper.get('[data-testid="documents-title"]').text()).toBe('Other doc')
    expect(wrapper.get('[data-testid="documents-rendered"]').html()).toContain('different body')
    wrapper.unmount()
  })
})
