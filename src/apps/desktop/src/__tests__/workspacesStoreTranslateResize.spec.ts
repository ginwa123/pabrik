/** Behavioural tests for `workspacesStore.translateDesignElement` and
 * `workspacesStore.resizeDesignElement`. These exercise the new single-element endpoints that
 * replace the conflated PATCH /geometry. */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'

import { useWorkspacesStore } from '../stores/workspaces'

const ELEM_BOX = {
  id: 'elem_1',
  page_id: 'page_1',
  parent_id: '',
  type: 'rectangle',
  name: 'Box',
  x: 100, y: 100, width: 200, height: 200,
  z_index: 0, position: 0,
  fill: '', stroke: '', stroke_width: 0,
  corner_radius: 0, rotation: 0,
  opacity: 1.0, text_content: '', text_style: '',
  image_url: '', file_path: '',
  created_at: '', updated_at: '',
}

const ELEM_BOX_MOVED = {
  ...ELEM_BOX,
  x: 150, y: 130,
}

const ELEM_BOX_RESIZED = {
  ...ELEM_BOX,
  x: 50, y: 60, width: 300, height: 400, rotation: 15,
}

function makeStore() {
  const store = useWorkspacesStore()
  store.workspaces = [
    {
      id: 'ws_1',
      name: 'ws',
      position: 0,
      items: [
        {
          id: 'item_1',
          workspace_id: 'ws_1',
          name: 'design item',
          item_type: 'design',
          path: '/tmp/foo',
          position: 0,
          created_at: '2026-08-06 12:00:00',
          updated_at: '2026-08-06 12:00:00',
          design_pages: [],
          design_elements: [ELEM_BOX],
        },
      ],
    },
   
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  ] as any
  return store
}

describe('workspacesStore.translateDesignElement', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
  })

  afterEach(() => {
    vi.restoreAllMocks()
  })

  it('POSTs to /translate with {dx, dy} body', async () => {
    const store = makeStore()
     
    const apiSpy = vi.spyOn(await import('../api'), 'translateDesignElement')
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      .mockResolvedValueOnce({ updated: [ELEM_BOX_MOVED] } as any)

    await store.translateDesignElement('ws_1', 'item_1', 'page_1', 'elem_1', 50, 30)

    expect(apiSpy).toHaveBeenCalledWith('ws_1', 'item_1', 'page_1', 'elem_1', 50, 30)
  })

  it('mirrors the response into item.design_elements[]', async () => {
     
    const store = makeStore()
    vi.spyOn(await import('../api'), 'translateDesignElement')
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      .mockResolvedValueOnce({ updated: [ELEM_BOX_MOVED] } as any)

 

    await store.translateDesignElement('ws_1', 'item_1', 'page_1', 'elem_1', 50, 30)

    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const elements = (store.workspaces[0] as any).items[0].design_elements
    expect(elements[0].x).toBe(150)
    expect(elements[0].y).toBe(130)
  })

 

  it('returns the updated elements array', async () => {
    const store = makeStore()
    vi.spyOn(await import('../api'), 'translateDesignElement')
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      .mockResolvedValueOnce({ updated: [ELEM_BOX_MOVED] } as any)

    const result = await store.translateDesignElement('ws_1', 'item_1', 'page_1', 'elem_1', 50, 30)
    expect(result).toHaveLength(1)
    expect(result[0]!.x).toBe(150)
  })

  it('mirrors cascade responses (group drag — root + child)', async () => {
    const store = makeStore()
    // Pre-seed a child so the cascade mirror can find it.
    store.workspaces = [
      {
        id: 'ws_1', name: 'ws', position: 0,
        items: [{
          id: 'item_1', workspace_id: 'ws_1', name: 'item', item_type: 'design',
          path: '/tmp', position: 0, created_at: '', updated_at: '',
          design_pages: [],
          design_elements: [
            { id: 'elem_root', page_id: 'page_1', parent_id: '',
              type: 'frame', name: 'r',
              x: 0, y: 100, width: 200, height: 200,
              z_index: 0, position: 0,
              fill: '', stroke: '', stroke_width: 0,
              corner_radius: 0, rotation: 0,
              opacity: 1.0, text_content: '', text_style: '',
              image_url: '', file_path: '',
              created_at: '', updated_at: '' },
            { id: 'elem_child1', page_id: 'page_1', parent_id: 'elem_root',
              type: 'rectangle', name: 'c1',
              x: 10, y: 110, width: 50, height: 50,
              z_index: 0, position: 0,
              fill: '', stroke: '', stroke_width: 0,
              corner_radius: 0, rotation: 0,
              opacity: 1.0, text_content: '', text_style: '',
               
              image_url: '', file_path: '',
              created_at: '', updated_at: '' },
          ],
        }],
      },
     
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    ] as any

     
    vi.spyOn(await import('../api'), 'translateDesignElement')
      .mockResolvedValueOnce({
        updated: [
          // eslint-disable-next-line @typescript-eslint/no-explicit-any
          { ...(store.workspaces[0] as any).items[0].design_elements[0], x: 200 },
           
          // eslint-disable-next-line @typescript-eslint/no-explicit-any
          { ...(store.workspaces[0] as any).items[0].design_elements[1], x: 210 },
        ],
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      } as any)

    await store.translateDesignElement('ws_1', 'item_1', 'page_1', 'elem_root', 200, 0)

    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const elements = (store.workspaces[0] as any).items[0].design_elements
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    expect(elements.find((e: any) => e.id === 'elem_root').x).toBe(200)
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    expect(elements.find((e: any) => e.id === 'elem_child1').x).toBe(210)
  })
})

 
describe('workspacesStore.resizeDesignElement', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
  })

  afterEach(() => {
    vi.restoreAllMocks()
  })

  it('POSTs to /resize with absolute geometry fields', async () => {
    const store = makeStore()
    const apiSpy = vi.spyOn(await import('../api'), 'resizeDesignElement')
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      .mockResolvedValueOnce(ELEM_BOX_RESIZED as any)

 

    await store.resizeDesignElement('ws_1', 'item_1', 'page_1', 'elem_1', {
      x: 50, y: 60, width: 300, height: 400, rotation: 15,
    })

    expect(apiSpy).toHaveBeenCalledWith('ws_1', 'item_1', 'page_1', 'elem_1', {
       
      x: 50, y: 60, width: 300, height: 400, rotation: 15,
    })
  })

  it('mirrors the response into item.design_elements[]', async () => {
    const store = makeStore()
    vi.spyOn(await import('../api'), 'resizeDesignElement')
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      .mockResolvedValueOnce(ELEM_BOX_RESIZED as any)

    await store.resizeDesignElement('ws_1', 'item_1', 'page_1', 'elem_1', {
      x: 50, y: 60, width: 300, height: 400, rotation: 15,
    })

    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const elem = (store.workspaces[0] as any).items[0].design_elements[0]
    expect(elem.x).toBe(50)
    expect(elem.y).toBe(60)
    expect(elem.width).toBe(300)
    expect(elem.height).toBe(400)
    expect(elem.rotation).toBe(15)
  })
})
