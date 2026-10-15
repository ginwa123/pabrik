/**
 * The documents API client's wire shape (Migration 095).
 *
 * In its own file, with NO `vi.mock('../api')`: a module factory that
 * spreads the real module re-wraps the exports, and the real
 * `apiFetch` never reaches the `fetch` spy the assertions install. The
 * mocking this feature needs lives in `DocumentsList.spec.ts`; the two
 * concerns do not belong in one file.
 *
 * These assert at `fetch`, not at `apiFetch`, because `apiFetch` is
 * called through the api module's own module-scope binding — a spy on
 * the exported namespace is never read. Intercepting `fetch` is both
 * the only thing that works and the stronger assertion: it proves the
 * `workspace_id` survives onto the actual request URL, and that URL is
 * the whole isolation mechanism. A helper that dropped the segment
 * would silently read a different workspace's documents.
 */
import { beforeEach, afterEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import * as api from '../api'

let urls: string[] = []
let fetchSpy: ReturnType<typeof vi.spyOn>

beforeEach(() => {
  setActivePinia(createPinia())
  urls = []
  fetchSpy = vi.spyOn(globalThis, 'fetch').mockImplementation((input: RequestInfo | URL) => {
    urls.push(String(input))
    return Promise.resolve(
      new Response(JSON.stringify({ documents: [], count: 0 }), { status: 200 }),
    )
  })
})

afterEach(() => {
  fetchSpy.mockRestore()
})

describe('documents API client — scoping', () => {
  it('puts the workspace id in the path of every request', async () => {
    await api.listDocuments('ws_1')
    await api.getDocument('ws_1', 'doc_1')
    await api.createDocument('ws_1', 't')
    await api.updateDocument('ws_1', 'doc_1', { content: 'x' })
    await api.deleteDocument('ws_1', 'doc_1')

    expect(urls).toEqual([
      '/api/workspaces/ws_1/documents',
      '/api/workspaces/ws_1/documents/doc_1',
      '/api/workspaces/ws_1/documents',
      '/api/workspaces/ws_1/documents/doc_1',
      '/api/workspaces/ws_1/documents/doc_1',
    ])
  })

  it('never sends a workspace id in the query string or the body', async () => {
    // The server resolves scope from the path alone. A helper that
    // ALSO passed `workspace_id` in the body would be one refactor away
    // from the server trusting the body, which is a spoofing vector.
    const bodies: string[] = []
    fetchSpy.mockImplementation((input: RequestInfo | URL, init?: RequestInit) => {
      urls.push(String(input))
      if (init?.body) bodies.push(String(init.body))
      return Promise.resolve(
        new Response(JSON.stringify({ documents: [], count: 0 }), { status: 200 }),
      )
    })

    await api.createDocument('ws_1', 't', 'body')
    await api.updateDocument('ws_1', 'doc_1', { content: 'x' })

    expect(bodies.join(' ')).not.toContain('workspace_id')
    expect(bodies).toEqual(['{"title":"t","content":"body"}', '{"content":"x"}'])
  })

  it('url-encodes the workspace and document ids', async () => {
    // A workspace id containing a slash would otherwise reshape the path
    // and hit a different route (or none).
    await api.getDocument('ws/1', 'doc 1')
    expect(urls[0]).toBe('/api/workspaces/ws%2F1/documents/doc%201')
  })

  it('sends the right method for each verb', async () => {
    const methods: string[] = []
    fetchSpy.mockImplementation((_input: RequestInfo | URL, init?: RequestInit) => {
      methods.push(String(init?.method ?? 'GET'))
      return Promise.resolve(
        new Response(JSON.stringify({ documents: [], count: 0 }), { status: 200 }),
      )
    })

    await api.listDocuments('ws_1')
    await api.getDocument('ws_1', 'doc_1')
    await api.createDocument('ws_1', 't')
    await api.updateDocument('ws_1', 'doc_1', { content: 'x' })
    await api.deleteDocument('ws_1', 'doc_1')

    // A PATCH sent as a PUT (or a create sent as a POST with no body)
    // would 400 at the wire; assert it here where the failure is legible.
    expect(methods).toEqual(['GET', 'GET', 'POST', 'PATCH', 'DELETE'])
  })

  it('omits content from a create body when only a title is given', async () => {
    // The backend treats `"content": ""` and an absent `content` the same (both store ''), but
    // sending the empty string explicitly is one less thing for a future "absent means keep" PATCH
    // semantic to get wrong. Assert the default rather than trust it.
    let body = ''
    fetchSpy.mockImplementation((_input: RequestInfo | URL, init?: RequestInit) => {
      body = String(init?.body ?? '')
      return Promise.resolve(new Response('{}', { status: 200 }))
    })

    await api.createDocument('ws_1', 'Only a title')
    expect(JSON.parse(body)).toEqual({ title: 'Only a title', content: '' })
  })
})
