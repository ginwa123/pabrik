/**
 * Unit tests for the design API client (listDesignPages, createDesignPage,
 * getDesignPage, addDesignElement, updateDesignElement, deleteDesignElement,
 * getDesignElementHtml, updateDesignElementHtml, updateDesignElementGeometry).
 *
 * 9 mock-based tests, one per public API function. Mirrors the
 * `kanbanApi.spec.ts` test style:
 *   - `setActivePinia(createPinia())` in `beforeEach` (apiFetch calls
 *     `useNotificationStore()` on every non-2xx response).
 *   - Mock helper includes `text: () => Promise.resolve(JSON.stringify(body))`
 *     (apiFetch calls `response.text().catch(() => '')` on every non-OK
 *     response to extract the body for the error toast).
 *   - Each test asserts URL, HTTP method, body shape (for write verbs),
 *     and the returned payload shape.
 *
 * Plan: docs/superpowers/plans/2026-07-08-design-mode-redesign.md
 *   (Chunk 5, Task 5.4)
 */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'

import {
  listDesignPages,
  createDesignPage,
  deleteDesignPage,
  getDesignPage,
  addDesignElement,
  updateDesignElement,
  deleteDesignElement,
  getDesignElementHtml,
  updateDesignElementHtml,
  updateDesignElementGeometry,
  updateDesignElementsGeometryBatch,
  type DesignElementType,
} from '../api'

describe('api.design', () => {
  const originalFetch = global.fetch
  const fetchMock = vi.fn()

  beforeEach(() => {
    // apiFetch calls useNotificationStore() on every non-2xx response to fire an error toast.
    // Without an active Pinia the call throws. setActivePinia(createPinia()) mounts a fresh store
    // for each test so the toast path can run without crashing.
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
      // text() is what apiFetch calls on every non-OK response to
      // extract the body for the error notification — see the
      // apiFetch-mock-must-include-text-and-pinia memory.
      text: () => Promise.resolve(JSON.stringify(body)),
    } as Response)
    global.fetch = fetchMock as unknown as typeof fetch
  }

  describe('listDesignPages', () => {
    it('GETs /api/workspaces/:wsId/items/:itemId/design/pages and returns {pages, count}', async () => {
      mockFetchOnce(200, {
        pages: [
          {
            id: 'p1',
            workspace_item_id: 'item_1',
            name: 'Home',
            width: 1280,
            height: 800,
            position: 0,
            created_at: '2026-07-08 12:00:00',
            updated_at: '2026-07-08 12:00:00',
          },
          {
            id: 'p2',
            workspace_item_id: 'item_1',
            name: 'Settings',
            width: 1280,
            height: 800,
            position: 1,
            created_at: '2026-07-08 12:00:00',
            updated_at: '2026-07-08 12:00:00',
          },
        ],
        count: 2,
      })

      const result = await listDesignPages('ws_1', 'item_1')

      const [url, init] = fetchMock.mock.calls[0] as [string, RequestInit]
      expect(url).toContain('/api/workspaces/ws_1/items/item_1/design/pages')
      // GET is the default for fetch when no method is supplied.
      expect(init.method).toBeUndefined()
      expect(result.count).toBe(2)
      expect(result.pages).toHaveLength(2)
      expect(result.pages[0]!.id).toBe('p1')
      expect(result.pages[0]!.name).toBe('Home')
      expect(result.pages[1]!.id).toBe('p2')
    })

    it('throws ApiError on 4xx/5xx', async () => {
      mockFetchOnce(404, { error: 'item not found' })

      await expect(listDesignPages('ws_1', 'item_missing')).rejects.toMatchObject({
        status: 404,
        body: expect.stringContaining('item not found'),
      })
    })
  })

  describe('createDesignPage', () => {
    it('POSTs {name} and returns the new page record', async () => {
      mockFetchOnce(201, {
        id: 'p_new',
        workspace_item_id: 'item_1',
        name: 'Dashboard',
        width: 1280,
        height: 800,
        position: 2,
        created_at: '2026-07-08 12:00:00',
        updated_at: '2026-07-08 12:00:00',
      })

      const result = await createDesignPage('ws_1', 'item_1', 'Dashboard')

      const [url, init] = fetchMock.mock.calls[0] as [string, RequestInit]
      expect(url).toContain('/api/workspaces/ws_1/items/item_1/design/pages')
      expect(init.method).toBe('POST')
      const body = JSON.parse(init.body as string)
      expect(body).toEqual({ name: 'Dashboard' })
      expect(result.id).toBe('p_new')
      expect(result.name).toBe('Dashboard')
      expect(result.position).toBe(2)
    })

    it('throws ApiError when the name is empty (400)', async () => {
      mockFetchOnce(400, { error: 'name cannot be empty' })

      await expect(createDesignPage('ws_1', 'item_1', '')).rejects.toMatchObject({
        status: 400,
        body: expect.stringContaining('name cannot be empty'),
      })
    })
  })

  describe('getDesignPage', () => {
    it('GETs the page+elements envelope for a single page', async () => {
      mockFetchOnce(200, {
        page: {
          id: 'p1',
          workspace_item_id: 'item_1',
          name: 'Home',
          width: 1280,
          height: 800,
          position: 0,
          created_at: '2026-07-08 12:00:00',
          updated_at: '2026-07-08 12:00:00',
        },
        elements: [
          {
            id: 'e1',
            page_id: 'p1',
            name: 'Header',
            type: 'rectangle',
            x: 0,
            y: 0,
            width: 1280,
            height: 64,
            rotation: 0,
            fill: '#22c55e',
            stroke: '',
            stroke_width: 0,
            corner_radius: 0,
            opacity: 1,
            text_content: '',
            text_style: '',
            image_url: '',
            file_path: '',
            z_index: 0,
            position: 0,
            created_at: '2026-07-08 12:00:00',
            updated_at: '2026-07-08 12:00:00',
          },
        ],
      })

      const result = await getDesignPage('ws_1', 'item_1', 'p1')

      const [url, init] = fetchMock.mock.calls[0] as [string, RequestInit]
      expect(url).toContain('/api/workspaces/ws_1/items/item_1/design/pages/p1')
      expect(init.method).toBeUndefined()
      expect(result.page.id).toBe('p1')
      expect(result.page.name).toBe('Home')
      expect(result.elements).toHaveLength(1)
      expect(result.elements[0]!.id).toBe('e1')
      expect(result.elements[0]!.type).toBe('rectangle')
    })

    it('throws ApiError when the page_id is unknown (404)', async () => {
      mockFetchOnce(404, { error: 'page not found' })

      await expect(getDesignPage('ws_1', 'item_1', 'p_missing')).rejects.toMatchObject({
        status: 404,
        body: expect.stringContaining('page not found'),
      })
    })
  })

  describe('addDesignElement', () => {
    it('POSTs {name, type, html} and returns the new element (201)', async () => {
      mockFetchOnce(201, {
        id: 'e_new',
        page_id: 'p1',
        name: 'Hero',
        type: 'frame',
        x: 0,
        y: 0,
        width: 1280,
        height: 480,
        rotation: 0,
        fill: '',
        stroke: '',
        stroke_width: 0,
        corner_radius: 0,
        opacity: 1,
        text_content: '',
        text_style: '',
        image_url: '',
        file_path: '.design/p1/e_new.html',
        z_index: 0,
        position: 0,
        created_at: '2026-07-08 12:00:00',
        updated_at: '2026-07-08 12:00:00',
      })

      const result = await addDesignElement('ws_1', 'item_1', 'p1', {
        name: 'Hero',
        type: 'frame' satisfies DesignElementType,
        html: '<div>Hello</div>',
      })

      const [url, init] = fetchMock.mock.calls[0] as [string, RequestInit]
      expect(url).toContain('/api/workspaces/ws_1/items/item_1/design/pages/p1/elements')
      expect(init.method).toBe('POST')
      const body = JSON.parse(init.body as string)
      expect(body).toEqual({ name: 'Hero', type: 'frame', html: '<div>Hello</div>' })
      expect(result.id).toBe('e_new')
      expect(result.name).toBe('Hero')
      expect(result.type).toBe('frame')
    })

    it('accepts optional geometry fields in the body', async () => {
      mockFetchOnce(201, {
        id: 'e_new',
        page_id: 'p1',
        name: 'Hero',
        type: 'rectangle',
        x: 100,
        y: 200,
        width: 320,
        height: 240,
        rotation: 0,
        fill: '#22c55e',
        stroke: '',
        stroke_width: 0,
        corner_radius: 0,
        opacity: 1,
        text_content: '',
        text_style: '',
        image_url: '',
        file_path: '',
        z_index: 0,
        position: 0,
        created_at: '2026-07-08 12:00:00',
        updated_at: '2026-07-08 12:00:00',
      })

      await addDesignElement('ws_1', 'item_1', 'p1', {
        name: 'Hero',
        type: 'rectangle',
        html: '<div>Hi</div>',
        x: 100,
        y: 200,
        width: 320,
        height: 240,
        fill: '#22c55e',
       
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      } as any)

      const [, init] = fetchMock.mock.calls[0] as [string, RequestInit]
      const body = JSON.parse(init.body as string)
      expect(body.x).toBe(100)
      expect(body.y).toBe(200)
      expect(body.fill).toBe('#22c55e')
    })

    it('throws ApiError on invalid type (400)', async () => {
      mockFetchOnce(400, { error: 'invalid element type' })

      await expect(
        addDesignElement('ws_1', 'item_1', 'p1', {
          name: 'X',
          type: 'bogus' as DesignElementType,
          html: '',
        }),
      ).rejects.toMatchObject({ status: 400 })
    })
  })

  describe('updateDesignElement', () => {
    it('PUTs the patch and returns the updated element', async () => {
      mockFetchOnce(200, {
        id: 'e1',
        page_id: 'p1',
        name: 'Renamed',
        type: 'rectangle',
        x: 0,
        y: 0,
        width: 1280,
        height: 64,
        rotation: 0,
        fill: '#22c55e',
        stroke: '',
        stroke_width: 0,
        corner_radius: 0,
        opacity: 1,
        text_content: '',
        text_style: '',
        image_url: '',
        file_path: '',
        z_index: 0,
        position: 0,
        created_at: '2026-07-08 12:00:00',
        updated_at: '2026-07-08 12:00:00',
      })

      const result = await updateDesignElement('ws_1', 'item_1', 'p1', 'e1', {
        name: 'Renamed',
      })

      const [url, init] = fetchMock.mock.calls[0] as [string, RequestInit]
      expect(url).toContain('/api/workspaces/ws_1/items/item_1/design/pages/p1/elements/e1')
      expect(init.method).toBe('PUT')
      const body = JSON.parse(init.body as string)
      expect(body).toEqual({ name: 'Renamed' })
      expect(result.id).toBe('e1')
      expect(result.name).toBe('Renamed')
    })

    it('forwards a multi-field patch (name + fill + rotation)', async () => {
      mockFetchOnce(200, {
        id: 'e1',
        page_id: 'p1',
        name: 'Renamed',
        type: 'rectangle',
        x: 0,
        y: 0,
        width: 1280,
        height: 64,
        rotation: 45,
        fill: '#ef4444',
        stroke: '',
        stroke_width: 0,
        corner_radius: 0,
        opacity: 1,
        text_content: '',
        text_style: '',
        image_url: '',
        file_path: '',
        z_index: 0,
        position: 0,
        created_at: '2026-07-08 12:00:00',
        updated_at: '2026-07-08 12:00:00',
      })

      await updateDesignElement('ws_1', 'item_1', 'p1', 'e1', {
        name: 'Renamed',
        fill: '#ef4444',
        rotation: 45,
      })

      const [, init] = fetchMock.mock.calls[0] as [string, RequestInit]
      const body = JSON.parse(init.body as string)
      expect(body).toEqual({ name: 'Renamed', fill: '#ef4444', rotation: 45 })
    })
  })

  describe('deleteDesignElement', () => {
    it('DELETEs the element and returns {success: true}', async () => {
      mockFetchOnce(200, { success: true })

      const result = await deleteDesignElement('ws_1', 'item_1', 'p1', 'e1')

      const [url, init] = fetchMock.mock.calls[0] as [string, RequestInit]
      expect(url).toContain('/api/workspaces/ws_1/items/item_1/design/pages/p1/elements/e1')
      expect(init.method).toBe('DELETE')
      expect(result.success).toBe(true)
    })

    it('throws ApiError on 5xx', async () => {
      mockFetchOnce(500, { error: 'DB write failed' })

      await expect(
        deleteDesignElement('ws_1', 'item_1', 'p1', 'e1'),
      ).rejects.toMatchObject({ status: 500 })
    })
  })

  describe('deleteDesignPage', () => {
    it('DELETEs the page and returns {success: true}', async () => {
      mockFetchOnce(200, { success: true })

      const result = await deleteDesignPage('ws_1', 'item_1', 'p1')

      const [url, init] = fetchMock.mock.calls[0] as [string, RequestInit]
      expect(url).toContain('/api/workspaces/ws_1/items/item_1/design/pages/p1')
      expect(init.method).toBe('DELETE')
      expect(result.success).toBe(true)
    })

    it('throws ApiError on 404 (page already gone)', async () => {
      mockFetchOnce(404, { error: 'Page not found' })

      await expect(
        deleteDesignPage('ws_1', 'item_1', 'p_missing'),
      ).rejects.toMatchObject({ status: 404 })
    })
  })

  describe('getDesignElementHtml', () => {
    it('GETs the html envelope for an element', async () => {
      mockFetchOnce(200, { html: '<div>hello world</div>' })

      const result = await getDesignElementHtml('ws_1', 'item_1', 'p1', 'e1')

      const [url, init] = fetchMock.mock.calls[0] as [string, RequestInit]
      expect(url).toContain('/api/workspaces/ws_1/items/item_1/design/pages/p1/elements/e1/html')
      expect(init.method).toBeUndefined()
      expect(result.html).toBe('<div>hello world</div>')
    })

    it('throws ApiError on missing element (404)', async () => {
      mockFetchOnce(404, { error: 'element not found' })

      await expect(
        getDesignElementHtml('ws_1', 'item_1', 'p1', 'e_missing'),
      ).rejects.toMatchObject({ status: 404 })
    })
  })

  describe('updateDesignElementHtml', () => {
    it('PATCHes {html} and returns the updated element', async () => {
      mockFetchOnce(200, {
        id: 'e1',
        page_id: 'p1',
        name: 'Hero',
        type: 'rectangle',
        x: 0,
        y: 0,
        width: 1280,
        height: 64,
        rotation: 0,
        fill: '',
        stroke: '',
        stroke_width: 0,
        corner_radius: 0,
        opacity: 1,
        text_content: 'new text',
        text_style: '',
        image_url: '',
        file_path: '.design/p1/e1.html',
        z_index: 0,
        position: 0,
        created_at: '2026-07-08 12:00:00',
        updated_at: '2026-07-08 12:00:00',
      })

      const result = await updateDesignElementHtml(
        'ws_1',
        'item_1',
        'p1',
        'e1',
        '<div>new html</div>',
      )

      const [url, init] = fetchMock.mock.calls[0] as [string, RequestInit]
      expect(url).toContain('/api/workspaces/ws_1/items/item_1/design/pages/p1/elements/e1/html')
      expect(init.method).toBe('PATCH')
      const body = JSON.parse(init.body as string)
      expect(body).toEqual({ html: '<div>new html</div>' })
      expect(result.id).toBe('e1')
    })
  })

  describe('updateDesignElementGeometry', () => {
    it('PATCHes the geometry subset and returns the updated element', async () => {
      mockFetchOnce(200, {
        id: 'e1',
        page_id: 'p1',
        name: 'Hero',
        type: 'rectangle',
        x: 100,
        y: 200,
        width: 320,
        height: 240,
        rotation: 0,
        fill: '',
        stroke: '',
        stroke_width: 0,
        corner_radius: 0,
        opacity: 1,
        text_content: '',
        text_style: '',
        image_url: '',
        file_path: '',
        z_index: 0,
        position: 0,
        created_at: '2026-07-08 12:00:00',
        updated_at: '2026-07-08 12:00:00',
      })

      const result = await updateDesignElementGeometry(
        'ws_1',
        'item_1',
        'p1',
        'e1',
        { x: 100, y: 200, width: 320, height: 240 },
      )

      const [url, init] = fetchMock.mock.calls[0] as [string, RequestInit]
      expect(url).toContain(
        '/api/workspaces/ws_1/items/item_1/design/pages/p1/elements/e1/geometry',
      )
      expect(init.method).toBe('PATCH')
      const body = JSON.parse(init.body as string)
      expect(body).toEqual({ x: 100, y: 200, width: 320, height: 240 })
      expect(result.x).toBe(100)
      expect(result.y).toBe(200)
    })

    it('forwards rotation-only patches without x/y/width/height', async () => {
      mockFetchOnce(200, {
        id: 'e1',
        page_id: 'p1',
        name: 'Hero',
        type: 'rectangle',
        x: 0,
        y: 0,
        width: 100,
        height: 100,
        rotation: 90,
        fill: '',
        stroke: '',
        stroke_width: 0,
        corner_radius: 0,
        opacity: 1,
        text_content: '',
        text_style: '',
        image_url: '',
        file_path: '',
        z_index: 0,
        position: 0,
        created_at: '2026-07-08 12:00:00',
        updated_at: '2026-07-08 12:00:00',
      })

      await updateDesignElementGeometry('ws_1', 'item_1', 'p1', 'e1', { rotation: 90 })

      const [, init] = fetchMock.mock.calls[0] as [string, RequestInit]
      const body = JSON.parse(init.body as string)
      expect(body).toEqual({ rotation: 90 })
    })
  })

  describe('updateDesignElementsGeometryBatch', () => {
    it('POSTs to /geometry-batch with the full updates array', async () => {
      mockFetchOnce(200, {
        updated: [
          { id: 'e1', x: 100 },
          { id: 'e2', x: 200 },
          { id: 'e3', x: 300 },
        ],
      })

      const result = await updateDesignElementsGeometryBatch(
        'ws_1',
        'item_1',
        'p1',
        [
          { element_id: 'e1', x: 100 },
          { element_id: 'e2', x: 200 },
          { element_id: 'e3', x: 300 },
        ],
      )

      const [url, init] = fetchMock.mock.calls[0] as [string, RequestInit]
      expect(url).toBe(
        '/api/workspaces/ws_1/items/item_1/design/pages/p1/elements/geometry-batch',
      )
      expect(init.method).toBe('POST')
      const body = JSON.parse(init.body as string)
      expect(body.updates).toHaveLength(3)
      expect(body.updates[0]).toEqual({ element_id: 'e1', x: 100 })
      expect(body.updates[1]).toEqual({ element_id: 'e2', x: 200 })
      expect(body.updates[2]).toEqual({ element_id: 'e3', x: 300 })
      expect(result.updated).toHaveLength(3)
      expect(result.updated[0]?.x).toBe(100)
    })

    it('accepts a single-element batch (N=1)', async () => {
      mockFetchOnce(200, {
        updated: [{ id: 'e1', x: 999 }],
      })

      await updateDesignElementsGeometryBatch('ws_1', 'item_1', 'p1', [
        { element_id: 'e1', x: 999 },
      ])

      const [, init] = fetchMock.mock.calls[0] as [string, RequestInit]
      const body = JSON.parse(init.body as string)
      expect(body.updates).toHaveLength(1)
    })
  })
})