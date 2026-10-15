/**
 * Behavioural tests for `workspacesStore.updateDesignElementGeometry`
 * (single-element drag/resize path).
 *
 * The single-element action is the "easy" drag path: user drags a
 * non-group/non-frame rectangle, ellipse, text, or image element.
 * Every pointermove emits an `update` patch which routes through
 * `useDesignHandlers.updateElement` → this action → PATCH
 * `/geometry` → emit `design_element_updated` SSE.
 *
 * Two invariants this spec locks in:
 *
 *   1. The action must mirror the API response into
 *      `item.design_elements[].x/y/width/height/rotation` so the
 *      DesignElement wrapper's `elementStyle.left/top` (bound to
 *      `props.element.x/y`) updates reactively during drag. Without
 *      the mirror, the element visually freezes at its
 *      pointerdown-time position until the next SSE event triggers a
 *      full `fetchDesignElements` reconcile — which never happens
 *      during a continuous drag because the SSE dedupe (1500 ms TTL)
 *      skips every locally-issued event. Symptom: the user sees the
 *      element "can't move" while 60+/sec of `/geometry` PATCHes
 *      flood the network (visible in DevTools Network tab).
 *
 *   2. The action must register the mutated element_id in the SSE
 *      dedupe Map (mirrors the existing batch-endpoint contract from
 *      workspacesStoreBatchGeometry.spec.ts:87).
 *
 * The mirror is local-only — the SSE event from the backend will
 * overwrite the entry with the server-confirmed value on arrival
 * (or skip the GET entirely when the SSE dedupe wins). Either way,
 * the element's visual position stays consistent.
 *
 * Plan: docs/superpowers/plans/2026-08-06-design-single-element-drag-mirror.md
 */
import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'

import {
  useWorkspacesStore,
  _clearRecentLocalMutationsForTests,
  isRecentLocalMutation,
} from '../stores/workspaces'

describe('workspacesStore.updateDesignElementGeometry (single)', () => {
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

  function mockFetchOnce(status: number, body: unknown): void {
    fetchMock.mockResolvedValueOnce({
      ok: status >= 200 && status < 300,
      status,
      json: () => Promise.resolve(body),
      text: () => Promise.resolve(JSON.stringify(body)),
    } as Response)
  }

   
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

 

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  function seedItem(itemId = 'item_1', elems: any[] = [makeElement('el_1', 0, 0)]): void {
    const ws = useWorkspacesStore()
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
          design_elements: elems,
        // eslint-disable-next-line @typescript-eslint/no-explicit-any
        } as any,
      ],
      expanded: false,
    })
  }

  // ── Invariant 1: local mirror (the bug fix) ─────────────────────────
  it('mirrors the API response into item.design_elements[].x/y (the visual-drag freeze fix)', async () => {
    seedItem('item_1', [makeElement('el_1', 0, 0)])

    mockFetchOnce(200, makeElement('el_1', 250, 350))
    await useWorkspacesStore().updateDesignElementGeometry(
      'ws_1', 'item_1', 'p1', 'el_1',
      { x: 250, y: 350 },
     
    )

    const store = useWorkspacesStore()
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const items = store.workspaces[0]!.items as any[]
    const el = items[0].design_elements[0]
    expect(el.x).toBe(250)
    expect(el.y).toBe(350)
  })

  it('mirrors the API response for width/height (resize path uses the same action)', async () => {
    seedItem('item_1', [makeElement('el_1', 100, 100)])

    mockFetchOnce(200, { ...makeElement('el_1', 100, 100), width: 300, height: 400 })
    await useWorkspacesStore().updateDesignElementGeometry(
       
      'ws_1', 'item_1', 'p1', 'el_1',
      { width: 300, height: 400 },
    )

    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const items = useWorkspacesStore().workspaces[0]!.items as any[]
    const el = items[0].design_elements[0]
    expect(el.width).toBe(300)
    expect(el.height).toBe(400)
    // x/y untouched (the patch only set width/height)
    expect(el.x).toBe(100)
    expect(el.y).toBe(100)
  })

  it('mirrors the API response for rotation', async () => {
    seedItem('item_1', [makeElement('el_1', 100, 100)])

    mockFetchOnce(200, { ...makeElement('el_1', 100, 100), rotation: 45 })
     
    await useWorkspacesStore().updateDesignElementGeometry(
      'ws_1', 'item_1', 'p1', 'el_1',
      { rotation: 45 },
    )

    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const items = useWorkspacesStore().workspaces[0]!.items as any[]
    const el = items[0].design_elements[0]
    expect(el.rotation).toBe(45)
  })

  it('mirror preserves the array order (no splice) when other elements exist', async () => {
    seedItem('item_1', [
      makeElement('el_1', 0, 0),
      makeElement('el_2', 100, 100),
      makeElement('el_3', 200, 200),
    ])

     
    mockFetchOnce(200, makeElement('el_2', 999, 999))
     
    await useWorkspacesStore().updateDesignElementGeometry(
      'ws_1', 'item_1', 'p1', 'el_2',
      { x: 999, y: 999 },
    )

    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const elements = (useWorkspacesStore().workspaces[0]!.items as any[])[0].design_elements as any[]
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    expect(elements.map((e: any) => e.id)).toEqual(['el_1', 'el_2', 'el_3'])
    expect(elements[1].x).toBe(999)
    expect(elements[1].y).toBe(999)
    expect(elements[0].x).toBe(0)
    expect(elements[2].x).toBe(200)
  })

  it('mirror no-ops when the item is not in the local store (defensive — stale SSE callers)', async () => {
    // No seedItem() — store has no item with this id.
    mockFetchOnce(200, makeElement('el_1', 250, 350))
    // Should not throw; the action simply skips the mirror step.
    await expect(
      useWorkspacesStore().updateDesignElementGeometry(
        'ws_1', 'no_such_item', 'p1', 'el_1',
        { x: 250, y: 350 },
      ),
    ).resolves.toMatchObject({ id: 'el_1', x: 250, y: 350 })
  })

  // ── Invariant 2: SSE dedupe registration (existing behaviour) ───────
  it('registers the mutated element_id in the SSE dedupe Map', async () => {
    seedItem('item_1', [makeElement('el_1', 0, 0)])

    mockFetchOnce(200, makeElement('el_1', 99, 99))
    await useWorkspacesStore().updateDesignElementGeometry(
      'ws_1', 'item_1', 'p1', 'el_1',
      { x: 99, y: 99 },
    )

    expect(isRecentLocalMutation('el_1')).toBe(true)
  })

  // ── Wire shape ───────────────────────────────────────────────────────
  it('calls PATCH /geometry (not the batch endpoint)', async () => {
    seedItem('item_1', [makeElement('el_1', 0, 0)])

    mockFetchOnce(200, makeElement('el_1', 100, 100))
    await useWorkspacesStore().updateDesignElementGeometry(
      'ws_1', 'item_1', 'p1', 'el_1',
      { x: 100, y: 100 },
    )

    expect(fetchMock).toHaveBeenCalledTimes(1)
    const [url, init] = fetchMock.mock.calls[0] as [string, RequestInit]
    expect(url).toMatch(/\/elements\/el_1\/geometry(?:\?|$)/)
    expect(init.method).toBe('PATCH')
  })

  it('returns the full DesignElement from the API response', async () => {
    seedItem('item_1', [makeElement('el_1', 0, 0)])

    const serverResponse = {
      ...makeElement('el_1', 42, 84),
      width: 222,
      updated_at: '2026-08-06T00:00:00Z',
    }
    mockFetchOnce(200, serverResponse)
    const result = await useWorkspacesStore().updateDesignElementGeometry(
      'ws_1', 'item_1', 'p1', 'el_1',
      { x: 42, y: 84, width: 222 },
    )

    expect(result).toEqual(serverResponse)
  })
})