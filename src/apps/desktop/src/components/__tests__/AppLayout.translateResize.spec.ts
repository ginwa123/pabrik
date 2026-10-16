/** Behavioural tests for AppLayout's translate-element + resize-element handlers (Step 4 of the
 * drag/resize wire). */
import { beforeEach, describe, expect, it, vi } from 'vitest'
import { createPinia, setActivePinia } from 'pinia'

const {
  translateDesignElementApiMock,
  resizeDesignElementApiMock,
  fetchWorkspacesApiMock,
} = vi.hoisted(() => ({
  translateDesignElementApiMock: vi.fn().mockResolvedValue({
    updated: [
      {
        id: 'el_1', page_id: 'page_1', parent_id: '',
        type: 'rectangle', name: 'Box',
        x: 150, y: 130, width: 200, height: 200,
        z_index: 0, position: 0,
        fill: '', stroke: '', stroke_width: 0, corner_radius: 0, rotation: 0,
        opacity: 1.0, text_content: '', text_style: '',
        image_url: '', file_path: '', created_at: '', updated_at: '',
      },
    ],
  }),
  resizeDesignElementApiMock: vi.fn().mockResolvedValue({
    id: 'el_1', page_id: 'page_1', parent_id: '',
    type: 'rectangle', name: 'Box',
    x: 50, y: 60, width: 300, height: 400, rotation: 15,
    z_index: 0, position: 0,
    fill: '', stroke: '', stroke_width: 0, corner_radius: 0,
    opacity: 1.0, text_content: '', text_style: '',
    image_url: '', file_path: '', created_at: '', updated_at: '',
  }),
  fetchWorkspacesApiMock: vi.fn().mockResolvedValue({
    workspaces: [
      {
        id: 'ws_1', name: 'ws', position: 0,
        items: [
          {
            id: 'item_1', name: 'design', path: '/tmp',
            item_type: 'design', position: 0,
            workspace_id: 'ws_1',
            design_pages: [
              { id: 'page_1', workspace_item_id: 'item_1', name: 'P',
                width: 1440, height: 1024, position: 0,
                created_at: '', updated_at: '' },
            ],
            design_elements: [
              { id: 'el_1', page_id: 'page_1', parent_id: '',
                type: 'rectangle', name: 'Box',
                x: 100, y: 100, width: 200, height: 200,
                z_index: 0, position: 0,
                fill: '', stroke: '', stroke_width: 0, corner_radius: 0, rotation: 0,
                opacity: 1.0, text_content: '', text_style: '',
                image_url: '', file_path: '', created_at: '', updated_at: '' },
            ],
          },
        ],
      },
    ],
  }),
}))

vi.mock('../../api', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../../api')>()
  return {
    ...actual,
    translateDesignElement: translateDesignElementApiMock,
    resizeDesignElement: resizeDesignElementApiMock,
    fetchWorkspaces: fetchWorkspacesApiMock,
  }
})

import { useWorkspacesStore } from '../../stores/workspaces'
import { useDesignHandlers } from '../../composables/useDesignHandlers'
import { setDesignLoggerEnabled } from '../../helpers/designLogger'

describe('useDesignHandlers.translateElement → store → POST /translate', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    vi.clearAllMocks()
  })

  it('calls workspacesStore.translateDesignElement with (ws, item, page, id, dx, dy)', async () => {
    const store = useWorkspacesStore()
    store.activeDesignPageId = 'page_1'
    const spy = vi.spyOn(store, 'translateDesignElement')
      .mockResolvedValue([])

    const handlers = useDesignHandlers()
    await handlers.translateElement('ws_1', 'item_1', 'el_1', 50, 30)

    expect(spy).toHaveBeenCalledWith('ws_1', 'item_1', 'page_1', 'el_1', 50, 30)
  })

  it('hits POST /translate on the api with the same args', async () => {
    const store = useWorkspacesStore()
    store.activeDesignPageId = 'page_1'

    const handlers = useDesignHandlers()
    await handlers.translateElement('ws_1', 'item_1', 'el_1', 50, 30)

    expect(translateDesignElementApiMock).toHaveBeenCalledWith('ws_1', 'item_1', 'page_1', 'el_1', 50, 30)
  })

  it('is a no-op when activeDesignPageId is empty (warns)', async () => {
    setDesignLoggerEnabled(true)
    const store = useWorkspacesStore()
    store.activeDesignPageId = ''
    const warnSpy = vi.spyOn(console, 'warn').mockImplementation(() => {})

    const handlers = useDesignHandlers()
    await handlers.translateElement('ws_1', 'item_1', 'el_1', 50, 30)

    expect(translateDesignElementApiMock).not.toHaveBeenCalled()
    expect(warnSpy).toHaveBeenCalled()
    warnSpy.mockRestore()
  })
})

describe('useDesignHandlers.resizeElement → store → POST /resize', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    vi.clearAllMocks()
  })

  it('calls workspacesStore.resizeDesignElement with (ws, item, page, id, patch)', async () => {
    const store = useWorkspacesStore()
    store.activeDesignPageId = 'page_1'
    const spy = vi.spyOn(store, 'resizeDesignElement')
       
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      .mockResolvedValue({} as any)

    const handlers = useDesignHandlers()
    await handlers.resizeElement('ws_1', 'item_1', 'el_1', {
      x: 50, y: 60, width: 300, height: 400, rotation: 15,
    })

    expect(spy).toHaveBeenCalledWith('ws_1', 'item_1', 'page_1', 'el_1', {
      x: 50, y: 60, width: 300, height: 400, rotation: 15,
    })
  })

  it('hits POST /resize on the api with the same args', async () => {
    const store = useWorkspacesStore()
    store.activeDesignPageId = 'page_1'

    const handlers = useDesignHandlers()
    await handlers.resizeElement('ws_1', 'item_1', 'el_1', {
      x: 50, y: 60, width: 300, height: 400, rotation: 15,
    })

    expect(resizeDesignElementApiMock).toHaveBeenCalledWith('ws_1', 'item_1', 'page_1', 'el_1', {
      x: 50, y: 60, width: 300, height: 400, rotation: 15,
    })
  })
})

