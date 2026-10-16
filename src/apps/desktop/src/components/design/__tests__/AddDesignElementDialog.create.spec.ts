/** Regression test for the bug "design mode, add element manual not working". Bug: clicking "+
 * Element" → filling the dialog → clicking "Add" had no effect because <DesignView> in
 * AppLayout.vue did not subscribe to `@create-element`. */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { flushPromises, mount } from '@vue/test-utils'
import { createPinia, setActivePinia } from 'pinia'
import DesignView from '../DesignView.vue'
import AddDesignElementDialog from '../AddDesignElementDialog.vue'
import { useDesignHandlers } from '../../../composables/useDesignHandlers'
import { useNotificationStore } from '../../../stores/notifications'
import { useWorkspacesStore } from '../../../stores/workspaces'

const {
  addDesignElementMock,
  listDesignPagesMock,
} = vi.hoisted(() => ({
  addDesignElementMock: vi.fn().mockResolvedValue({
    id: 'el_new_1',
    page_id: 'page_1',
    parent_id: '',
    name: 'My rectangle',
    type: 'rectangle',
    x: 0, y: 0, width: 100, height: 100,
    rotation: 0, opacity: 1, fill: '', stroke: '', stroke_width: 0,
    corner_radius: 0, text_content: '', text_style: '',
    image_url: '', file_path: '',
    z_index: 0, position: 0,
    created_at: '', updated_at: '',
  }),
  listDesignPagesMock: vi.fn().mockResolvedValue({
    pages: [
      {
        id: 'page_1',
        workspace_item_id: 'item_1',
        name: 'Test Page',
        width: 1440,
        height: 1024,
        position: 0,
        created_at: '',
        updated_at: '',
      },
    ],
    count: 1,
  }),
}))

vi.mock('../../../api', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../../../api')>()
  return {
    ...actual,
    listDesignPages: listDesignPagesMock,
    addDesignElement: addDesignElementMock,
  }
})

const ITEM = {
  id: 'item_1',
  name: 'Test',
  item_type: 'design',
  path: '',
  design_elements: [],
  workspace_id: 'ws_1',
 
// eslint-disable-next-line @typescript-eslint/no-explicit-any
} as any

function findInDom<T extends Element = Element>(selector: string): T | null {
  return document.querySelector<T>(selector)
}

// ─── (1) AddDesignElementDialog emits `create` ────────────────────────
describe('AddDesignElementDialog: `create` emit shape (link 1)', () => {
  let wrapper: ReturnType<typeof mount> | null = null

  beforeEach(() => {
    setActivePinia(createPinia())
    document.body.innerHTML = ''
    vi.clearAllMocks()
  })

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
  })

  it('emits `create` with { name, type, html } when the user submits', async () => {
    wrapper = mount(AddDesignElementDialog, {
      attachTo: document.body,
      props: { show: true, pageId: 'page_1' },
    })
    await flushPromises()

    // Type a name
    const nameInput = findInDom<HTMLInputElement>(
      '[data-testid="add-design-element-name"]',
    )!
    nameInput.value = 'My button'
    nameInput.dispatchEvent(new Event('input', { bubbles: true }))
    await flushPromises()

    // Click Add. The dialog only auto-fills the HTML textarea when the type field CHANGES (the
    // watch in AddDesignElementDialog.vue fires on `elementType` change, not on initial show).
    findInDom<HTMLButtonElement>(
      '[data-testid="add-design-element-submit"]',
    )?.click()
    await flushPromises()

    const creates = wrapper.emitted('create') ?? []
    expect(creates.length).toBe(1)
    expect(creates[0]).toEqual([
      {
        name: 'My button',
        type: 'rectangle',
        html: expect.stringContaining('background'),
      },
    ])
  })
})

// ─── (2) DesignView re-emits createElement upward ────────────────────
describe('DesignView: `@create` → `createElement` re-emit (link 2)', () => {
  let wrapper: ReturnType<typeof mount> | null = null

  beforeEach(() => {
    setActivePinia(createPinia())
    document.body.innerHTML = ''
    vi.clearAllMocks()
  })

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
  })

  it('re-emits `createElement` with the dialog body when the user submits the dialog', async () => {
    const store = useWorkspacesStore()
    store.setActiveDesignPage('page_1')

    wrapper = mount(DesignView, {
      attachTo: document.body,
      props: {
        item: { ...ITEM, design_elements: [] },
        workspaceId: 'ws_1',
        itemId: 'item_1',
      },
    })
    await flushPromises()

    // Open the dialog
    findInDom<HTMLButtonElement>(
      '[data-testid="design-add-element-button"]',
    )?.click()
    await flushPromises()

    expect(
      findInDom<HTMLElement>('[data-testid="add-design-element-dialog"]'),
    ).not.toBeNull()

    // Fill + submit
    const nameInput = findInDom<HTMLInputElement>(
      '[data-testid="add-design-element-name"]',
    )!
    nameInput.value = 'New thing'
    nameInput.dispatchEvent(new Event('input', { bubbles: true }))
    await flushPromises()
    findInDom<HTMLButtonElement>(
      '[data-testid="add-design-element-submit"]',
    )?.click()
    await flushPromises()

    // The pre-fix bug was that this emit went nowhere on AppLayout. We prove here that DesignView
    // itself DOES re-emit upward with the right shape; the AppLayout binding is verified by grep in
    // the verifier step of the bug-fix plan.
    const creates = wrapper.emitted('createElement') ?? []
    expect(creates.length).toBe(1)
    expect(creates[0]).toEqual([
      {
        name: 'New thing',
        type: 'rectangle',
        html: expect.any(String),
      },
    ])
  })
})

// ─── (3) useDesignHandlers.createElement routes to the api ────────────
describe('useDesignHandlers.createElement → api.addDesignElement (link 3)', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    vi.clearAllMocks()
  })

  it('calls api.addDesignElement with (workspaceId, itemId, pageId, body)', async () => {
    const store = useWorkspacesStore()
    store.setActiveDesignPage('page_1')

    const handlers = useDesignHandlers()
    await handlers.createElement('ws_1', 'item_1', {
      name: 'Hello',
      type: 'rectangle',
      html: '<div>x</div>',
    })

    expect(addDesignElementMock).toHaveBeenCalledTimes(1)
    expect(addDesignElementMock).toHaveBeenCalledWith(
      'ws_1',
      'item_1',
      'page_1',
      {
        name: 'Hello',
        type: 'rectangle',
        html: '<div>x</div>',
      },
    )
  })

  it('is a no-op when activeDesignPageId is empty (returns null, warns)', async () => {
    const store = useWorkspacesStore()
    store.activeDesignPageId = ''
    const warnSpy = vi.spyOn(console, 'warn').mockImplementation(() => {})
    const notificationSpy = vi.spyOn(
      useNotificationStore(),
      'notifyError',
    ).mockImplementation(() => {})

    const handlers = useDesignHandlers()
    const result = await handlers.createElement('ws_1', 'item_1', {
      name: 'X',
      type: 'rectangle',
      html: '<div></div>',
    })

    expect(addDesignElementMock).not.toHaveBeenCalled()
    expect(result).toBeNull()
    expect(warnSpy).toHaveBeenCalled()
    expect(notificationSpy).not.toHaveBeenCalled()
    warnSpy.mockRestore()
    notificationSpy.mockRestore()
  })

  it('surfaces an Error notification and returns null when the api rejects', async () => {
    const store = useWorkspacesStore()
    store.setActiveDesignPage('page_1')
    addDesignElementMock.mockRejectedValueOnce(new Error('boom'))
    const notificationSpy = vi.spyOn(
      useNotificationStore(),
      'notifyError',
    ).mockImplementation(() => {})

    const handlers = useDesignHandlers()
    const result = await handlers.createElement('ws_1', 'item_1', {
      name: 'X',
      type: 'rectangle',
      html: '<div></div>',
    })

    expect(result).toBeNull()
    expect(notificationSpy).toHaveBeenCalledWith(
      'Failed to add element',
      'boom',
    )
    notificationSpy.mockRestore()
  })
})
