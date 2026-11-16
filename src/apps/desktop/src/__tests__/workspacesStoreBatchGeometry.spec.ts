import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'

import {
  useWorkspacesStore,
  _clearRecentLocalMutationsForTests,
  isRecentLocalMutation,
} from '../stores/workspaces'

describe('workspacesStore.updateDesignElementsGeometryBatch', () => {
  const originalFetch = global.fetch
  const fetchMock = vi.fn()

  beforeEach(() => {
    setActivePinia(createPinia())
    fetchMock.mockReset()
    global.fetch = fetchMock as unknown as typeof global.fetch
    _clearRecentLocalMutationsForTests()
  })

  afterEach(() => {
    global.fetch = originalFetch
    _clearRecentLocalMutationsForTests()
  })

  // Minimal mock — apiFetch calls .text() on non-OK responses and useNotificationStore() for toast on non-2xx (we don't exercise error paths here; this is the …
  function mockFetchOnce(status: number, body: unknown): void {
    fetchMock.mockResolvedValueOnce({
      ok: status >= 200 && status < 300,
      status,
      json: () => Promise.resolve(body),
      text: () => Promise.resolve(JSON.stringify(body)),
    } as Response)
  }

  it('calls the batch API ONCE with all updates (not N per-element PATCHes)', async () => {
    const ws = useWorkspacesStore()
    // Seed a workspace + item with 3 elements in the local cache so the store action can mirror the response.
    const itemId = 'item_1'
    ws.workspaces.push({
      id: 'ws_1',
      name: 'Test',
      icon: '',
      items: [
        {
          id: itemId,
          workspace_id: 'ws_1',
          item_type: 'design',
          name: 'Item',
          path: '/tmp',
          position: 0,
          design_elements: [
            makeElement('e1', 0, 0),
            makeElement('e2', 0, 0),
            makeElement('e3', 0, 0),
          ],
         
        // eslint-disable-next-line @typescript-eslint/no-explicit-any
        } as any,
      ],
      expanded: false,
    })

    mockFetchOnce(200, {
      updated: [
        makeElement('e1', 100, 100),
        makeElement('e2', 200, 200),
        makeElement('e3', 300, 300),
      ],
    })

    await ws.updateDesignElementsGeometryBatch('ws_1', itemId, 'p1', [
      { element_id: 'e1', x: 100, y: 100 },
      { element_id: 'e2', x: 200, y: 200 },
      { element_id: 'e3', x: 300, y: 300 },
    ])

    // Exactly ONE fetch call — no N per-element PATCHes.
    expect(fetchMock).toHaveBeenCalledTimes(1)
    const [url, init] = fetchMock.mock.calls[0] as [string, RequestInit]
    expect(url).toContain('/elements/geometry-batch')
    expect(init.method).toBe('POST')
  })

  it('registers each element_id in the SSE dedupe Map (so the fan-out GET is skipped)', async () => {
    const ws = useWorkspacesStore()
    const itemId = 'item_1'
    ws.workspaces.push({
      id: 'ws_1',
      name: 'Test',
      icon: '',
      items: [
        {
          id: itemId,
          workspace_id: 'ws_1',
          item_type: 'design',
          name: 'Item',
          path: '/tmp',
          position: 0,
          design_elements: [
            makeElement('e1', 0, 0),
            makeElement('e2', 0, 0),
           
          ],
        // eslint-disable-next-line @typescript-eslint/no-explicit-any
        } as any,
      ],
      expanded: false,
    })

    mockFetchOnce(200, {
      updated: [makeElement('e1', 50, 50), makeElement('e2', 60, 60)],
    })

    await ws.updateDesignElementsGeometryBatch('ws_1', itemId, 'p1', [
      { element_id: 'e1', x: 50 },
      { element_id: 'e2', x: 60 },
    ])

    // Both ids are now in the SSE dedupe Map.
    expect(isRecentLocalMutation('e1')).toBe(true)
    expect(isRecentLocalMutation('e2')).toBe(true)
    // An unrelated id is NOT.
    expect(isRecentLocalMutation('e_unknown')).toBe(false)
  })

  it('is a no-op (no API call) for an empty updates array', async () => {
    const ws = useWorkspacesStore()
    const itemId = 'item_1'
    ws.workspaces.push({
      id: 'ws_1',
      name: 'Test',
      icon: '',
      items: [
        {
          id: itemId,
          workspace_id: 'ws_1',
          item_type: 'design',
          name: 'Item',
          path: '/tmp',
           
          position: 0,
          design_elements: [],
        // eslint-disable-next-line @typescript-eslint/no-explicit-any
        } as any,
      ],
      expanded: false,
    })

    const result = await ws.updateDesignElementsGeometryBatch(
      'ws_1',
      itemId,
      'p1',
      [],
    )

    expect(result).toEqual([])
    expect(fetchMock).not.toHaveBeenCalled()
  })

  it('single-element action ALSO registers the id in the dedupe Map (consistency)', async () => {
    const ws = useWorkspacesStore()
    const itemId = 'item_1'
    ws.workspaces.push({
      id: 'ws_1',
      name: 'Test',
      icon: '',
      items: [
        {
          id: itemId,
          workspace_id: 'ws_1',
          item_type: 'design',
          name: 'Item',
           
          path: '/tmp',
          position: 0,
          design_elements: [makeElement('e_single', 0, 0)],
        // eslint-disable-next-line @typescript-eslint/no-explicit-any
        } as any,
      ],
      expanded: false,
    })

    mockFetchOnce(200, makeElement('e_single', 99, 99))
    await ws.updateDesignElementGeometry('ws_1', itemId, 'p1', 'e_single', {
      x: 99,
    })

     
    expect(isRecentLocalMutation('e_single')).toBe(true)
  })
})

// eslint-disable-next-line @typescript-eslint/no-explicit-any
function makeElement(id: string, x: number, y: number): any {
  return {
    id,
    page_id: 'p1',
    name: id,
    type: 'rectangle',
    x,
    y,
    width: 100,
    height: 100,
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
    created_at: '',
    updated_at: '',
    parent_id: '',
  }
}