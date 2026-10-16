/** Behavioural tests for `workspacesStore.fetchDesignElements` in-place mutation contract. Bug
 * history (2026-08-06): the FIRST drag of a group/frame moved only the group, not the descendants. */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'

import { useWorkspacesStore } from '../stores/workspaces'
import * as api from '../api'

function makeWorkspacesStore() {
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
          design_pages: [
            {
              id: 'page_1',
              workspace_item_id: 'item_1',
              name: 'Login',
              width: 1440,
              height: 1024,
              position: 0,
              created_at: '2026-08-06 12:00:00',
              updated_at: '2026-08-06 12:00:00',
            },
          ],
          design_elements: [
            {
              id: 'elem_root',
              page_id: 'page_1',
              parent_id: '',
              type: 'frame',
              name: 'root',
              x: 0, y: 0, width: 200, height: 200,
              z_index: 0, position: 0,
              fill: '', stroke: '', stroke_width: 0, corner_radius: 0, rotation: 0,
              opacity: 1.0, text_content: '', text_style: '',
              image_url: '', file_path: '', created_at: '', updated_at: '',
            },
            {
              id: 'elem_child1',
              page_id: 'page_1',
              parent_id: 'elem_root',
              type: 'rectangle',
              name: 'c1',
              x: 10, y: 10, width: 50, height: 50,
              z_index: 0, position: 0,
              fill: '', stroke: '', stroke_width: 0, corner_radius: 0, rotation: 0,
              opacity: 1.0, text_content: '', text_style: '',
              image_url: '', file_path: '', created_at: '', updated_at: '',
            },
          ],
        },
      ],
    },
  ] as never
  return store
}

describe('workspacesStore.fetchDesignElements (in-place mutation)', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
  })

  afterEach(() => {
    vi.restoreAllMocks()
  })

  it('preserves the design_elements array reference (mutates in place)', async () => {
    const store = makeWorkspacesStore()
     
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const beforeRef = (store.workspaces[0] as any).items[0].design_elements

    // Simulate a remote edit that arrives via SSE: same ids, new x/y.
    vi.spyOn(api, 'getDesignPage').mockResolvedValueOnce({
      page: {
        id: 'page_1',
        workspace_item_id: 'item_1',
        workspace_item_task_id: "",
        name: 'Login',
        width: 1440,
        height: 1024,
        position: 0,
        created_at: '2026-08-06 12:00:00',
        updated_at: '2026-08-06 12:00:00',
      },
      elements: [
        {
          id: 'elem_root',
          page_id: 'page_1',
          parent_id: '',
          type: 'frame',
          name: 'root',
          x: 50, y: 60, width: 200, height: 200,
          z_index: 0, position: 0,
          fill: '', stroke: '', stroke_width: 0, corner_radius: 0, rotation: 0,
          opacity: 1.0, text_content: '', text_style: '',
          image_url: '', file_path: '', created_at: '', updated_at: '',
        },
        {
          id: 'elem_child1',
          page_id: 'page_1',
          parent_id: 'elem_root',
          type: 'rectangle',
          name: 'c1',
          x: 70, y: 80, width: 50, height: 50,
          z_index: 0, position: 0,
          fill: '', stroke: '', stroke_width: 0, corner_radius: 0, rotation: 0,
          opacity: 1.0, text_content: '', text_style: '',
          image_url: '', file_path: '', created_at: '', updated_at: '',
        },
      ] as never,
    })

    await store.fetchDesignElements('ws_1', 'item_1', 'page_1')

    // CRITICAL: the array reference must be the same — Vue 3 reactivity depends on per-index writes to
    // the same reactive array, and a new reference would orphan in-flight mirror writes.
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const afterRef = (store.workspaces[0] as any).items[0].design_elements
    expect(afterRef).toBe(beforeRef)
    // Per-element values were updated in place.
    expect(afterRef[0].x).toBe(50)
    expect(afterRef[0].y).toBe(60)
    expect(afterRef[1].x).toBe(70)
    expect(afterRef[1].y).toBe(80)
  })

   
  it('removes rows whose id is no longer in the incoming set (deleted remotely)', async () => {
    const store = makeWorkspacesStore()
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const initialLen = (store.workspaces[0] as any).items[0].design_elements.length
    expect(initialLen).toBe(2)

    // Remote: only elem_root remains; elem_child1 was deleted elsewhere.
    vi.spyOn(api, 'getDesignPage').mockResolvedValueOnce({
      page: {
        id: 'page_1',
        workspace_item_id: 'item_1',
        workspace_item_task_id: "",
        name: 'Login',
        width: 1440,
        height: 1024,
        position: 0,
        created_at: '2026-08-06 12:00:00',
        updated_at: '2026-08-06 12:00:00',
      },
      elements: [
        {
          id: 'elem_root',
          page_id: 'page_1',
          parent_id: '',
          type: 'frame',
          name: 'root',
          x: 0, y: 0, width: 200, height: 200,
          z_index: 0, position: 0,
          fill: '', stroke: '', stroke_width: 0, corner_radius: 0, rotation: 0,
          opacity: 1.0, text_content: '', text_style: '',
          image_url: '', file_path: '', created_at: '', updated_at: '',
        },
      ] as never,
    })

 

    await store.fetchDesignElements('ws_1', 'item_1', 'page_1')

    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const after = (store.workspaces[0] as any).items[0].design_elements
    expect(after.length).toBe(1)
    expect(after[0].id).toBe('elem_root')
   
  })

  it('appends rows whose id is new in the incoming set (created remotely)', async () => {
    const store = makeWorkspacesStore()
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    expect((store.workspaces[0] as any).items[0].design_elements.length).toBe(2)

    // Remote: elem_root + elem_child1 + a brand-new elem_child2.
    vi.spyOn(api, 'getDesignPage').mockResolvedValueOnce({
      page: {
        id: 'page_1',
        workspace_item_id: 'item_1',
        workspace_item_task_id: "",
        name: 'Login',
        width: 1440,
        height: 1024,
        position: 0,
        created_at: '2026-08-06 12:00:00',
        updated_at: '2026-08-06 12:00:00',
      },
      elements: [
        {
          id: 'elem_root',
          page_id: 'page_1',
          parent_id: '',
          type: 'frame',
          name: 'root',
          x: 0, y: 0, width: 200, height: 200,
          z_index: 0, position: 0,
          fill: '', stroke: '', stroke_width: 0, corner_radius: 0, rotation: 0,
          opacity: 1.0, text_content: '', text_style: '',
          image_url: '', file_path: '', created_at: '', updated_at: '',
        },
        {
          id: 'elem_child1',
          page_id: 'page_1',
          parent_id: 'elem_root',
          type: 'rectangle',
          name: 'c1',
          x: 10, y: 10, width: 50, height: 50,
          z_index: 0, position: 0,
          fill: '', stroke: '', stroke_width: 0, corner_radius: 0, rotation: 0,
          opacity: 1.0, text_content: '', text_style: '',
          image_url: '', file_path: '', created_at: '', updated_at: '',
        },
        {
          id: 'elem_child2',
          page_id: 'page_1',
          parent_id: 'elem_root',
          type: 'rectangle',
          name: 'c2',
          x: 80, y: 80, width: 50, height: 50,
          z_index: 0, position: 1,
          fill: '', stroke: '', stroke_width: 0, corner_radius: 0, rotation: 0,
          opacity: 1.0, text_content: '', text_style: '',
          image_url: '', file_path: '', created_at: '', updated_at: '',
        },
       
      ] as never,
    })

    await store.fetchDesignElements('ws_1', 'item_1', 'page_1')

    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const after = (store.workspaces[0] as any).items[0].design_elements
    expect(after.length).toBe(3)
    expect(after[2].id).toBe('elem_child2')
  })
})