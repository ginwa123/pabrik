/**
 * Unit tests for the reparent API surface:
 *   - updateDesignElement accepts an optional `reposition: 'last_in_parent'` field
 *     (added in Chunk 1 Task 1.3 backend handler).
 *   - reparentDesignElementsBatch POSTs to
 *     /elements/reparent-batch with the parsed body.
 *
 * 5 mock-based tests. Same pattern as `apiDesign.spec.ts`:
 *   - `setActivePinia(createPinia())` in `beforeEach`.
 *   - Mock fetch via vi.fn() returning `{ ok, status, json, text }`.
 *   - Assert URL, HTTP method, body shape.
 *
 * Plan: docs/superpowers/plans/2026-07-30-design-layer-drag-join-or-leave-group.md
 * (Chunk 2 Task 2.1)
 */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'

import {
  updateDesignElement,
  reparentDesignElementsBatch,
} from '../api'

describe('api.updateDesignElement — reposition field', () => {
  const originalFetch = global.fetch
  const fetchMock = vi.fn()

  beforeEach(() => {
    setActivePinia(createPinia())
  })

  afterEach(() => {
    fetchMock.mockReset()
    global.fetch = originalFetch
  })

  function mockFetchOnce(status: number, body: unknown) {
    fetchMock.mockResolvedValueOnce({
      ok: status >= 200 && status < 300,
      status,
      json: () => Promise.resolve(body),
      text: () => Promise.resolve(JSON.stringify(body)),
    } as Response)
    global.fetch = fetchMock as unknown as typeof fetch
  }

  it('forwards the optional reposition field to the wire body', async () => {
    mockFetchOnce(200, {
      id: 'elem_a',
      page_id: 'page_1',
      parent_id: 'group_1',
      type: 'rectangle',
      x: 0, y: 0, width: 100, height: 100,
      z_index: 0, position: 0,
      fill: '', stroke: '', stroke_width: 0, corner_radius: 0,
      opacity: 1.0, text_content: '', text_style: '', image_url: '',
      name: 'a', file_path: '', created_at: '', updated_at: '',
    })

    await updateDesignElement('ws_1', 'item_1', 'page_1', 'elem_a', {
      // The wire type allows reposition?; we cast via the call site to
      // assert it lands in the body.
      parent_id: 'group_1',
      reposition: 'last_in_parent',
     
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    } as any)

    const [, init] = fetchMock.mock.calls[0] as [string, RequestInit]
    const body = JSON.parse(init.body as string)
    expect(body).toEqual({
      parent_id: 'group_1',
      reposition: 'last_in_parent',
    })
  })
})

describe('api.reparentDesignElementsBatch', () => {
  const originalFetch = global.fetch
  const fetchMock = vi.fn()

  beforeEach(() => {
    setActivePinia(createPinia())
  })

  afterEach(() => {
    fetchMock.mockReset()
    global.fetch = originalFetch
  })

  function mockFetchOnce(status: number, body: unknown) {
    fetchMock.mockResolvedValueOnce({
      ok: status >= 200 && status < 300,
      status,
      json: () => Promise.resolve(body),
      text: () => Promise.resolve(JSON.stringify(body)),
    } as Response)
    global.fetch = fetchMock as unknown as typeof fetch
  }

  it('POSTs to /elements/reparent-batch with the parsed body', async () => {
    mockFetchOnce(200, {
      updated: [
        {
          id: 'elem_a', page_id: 'page_1', parent_id: 'group_1',
          type: 'rectangle', x: 0, y: 0, width: 100, height: 100,
          z_index: 0, position: 0, fill: '', stroke: '', stroke_width: 0,
          corner_radius: 0, opacity: 1.0, text_content: '',
          text_style: '', image_url: '', name: 'a', file_path: '',
          created_at: '', updated_at: '',
        },
      ],
    })

    const result = await reparentDesignElementsBatch('ws_1', 'item_1', 'page_1', {
      element_ids: ['elem_a', 'elem_b', 'elem_c'],
      new_parent_id: 'group_1',
      reposition: 'last_in_parent',
    })

    const [url, init] = fetchMock.mock.calls[0] as [string, RequestInit]
    expect(url).toContain(
      '/api/workspaces/ws_1/items/item_1/design/pages/page_1/elements/reparent-batch',
    )
    expect(init.method).toBe('POST')
    const body = JSON.parse(init.body as string)
    expect(body).toEqual({
      element_ids: ['elem_a', 'elem_b', 'elem_c'],
      new_parent_id: 'group_1',
      reposition: 'last_in_parent',
    })
    expect(result.updated).toHaveLength(1)
    expect(result.updated[0]!.id).toBe('elem_a')
  })

  it('sends new_parent_id as null when leaving a group (top-level)', async () => {
    mockFetchOnce(200, { updated: [] })

    await reparentDesignElementsBatch('ws_1', 'item_1', 'page_1', {
      element_ids: ['elem_a'],
      new_parent_id: null,
      reposition: 'last_in_parent',
    })

    const [, init] = fetchMock.mock.calls[0] as [string, RequestInit]
    const body = JSON.parse(init.body as string)
    expect(body.new_parent_id).toBe(null)
  })

  it('throws ApiError on 400 BadReparent (cycle)', async () => {
    mockFetchOnce(400, { error: 'Reparenting would create a cycle' })

    await expect(
      reparentDesignElementsBatch('ws_1', 'item_1', 'page_1', {
        element_ids: ['elem_a', 'elem_b'],
        new_parent_id: 'group_x',
        reposition: 'last_in_parent',
      }),
    ).rejects.toMatchObject({
      status: 400,
      body: expect.stringContaining('cycle'),
    })
  })

  it('throws ApiError on 409 CrossPageIds', async () => {
    mockFetchOnce(409, { error: 'All element_ids must be on the same page' })

    await expect(
      reparentDesignElementsBatch('ws_1', 'item_1', 'page_1', {
        element_ids: ['elem_a', 'elem_b'],
        new_parent_id: 'group_x',
        reposition: 'last_in_parent',
      }),
    ).rejects.toMatchObject({ status: 409 })
  })
})