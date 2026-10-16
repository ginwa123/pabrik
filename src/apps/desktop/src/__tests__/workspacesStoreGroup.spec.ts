/** Unit tests for `workspacesStore.groupDesignElements` (the store action backing Cmd+G). 5 tests:
 * 1. */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { createPinia, setActivePinia } from 'pinia'

import { useWorkspacesStore, type Workspace, type WorkspaceItem } from '../stores/workspaces'
import type { DesignElement } from '../api'

// Helper to build a DesignElement. Page + z_index + position are
// required for tree ordering (test asserts these).
function elem(overrides: Partial<DesignElement>): DesignElement {
  return {
    id: 'elem_default',
    page_id: 'page_1',
    name: 'Default',
    type: 'rectangle',
    x: 0,
    y: 0,
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
    parent_id: '',
    z_index: 0,
    position: 0,
    created_at: '',
    updated_at: '',
    ...overrides,
  }
}

function makeWorkspaceWithItem(item: WorkspaceItem): Workspace {
  return {
    id: 'ws_1',
    name: 'Test ws',
    icon: '',
    expanded: true,
    items: [item],
  }
}

describe('workspacesStore.groupDesignElements (Chunk 5)', () => {
  const originalFetch = global.fetch
  const fetchMock = vi.fn()

  beforeEach(() => {
    setActivePinia(createPinia())
  })

  afterEach(() => {
    fetchMock.mockReset()
    global.fetch = originalFetch
  })

  function mockFetchOnce(status: number, body: unknown): void {
    fetchMock.mockResolvedValueOnce({
      ok: status >= 200 && status < 300,
      status,
      json: () => Promise.resolve(body),
      text: () => Promise.resolve(JSON.stringify(body)),
    } as Response)
    global.fetch = fetchMock as unknown as typeof fetch
  }

  const PARENT: DesignElement = elem({
    id: 'elem_parent',
    name: 'My Group',
    type: 'group',
    z_index: 2,
    position: 5,
  })

  const CHILD_A_UPDATED: DesignElement = elem({
    id: 'elem_a',
    parent_id: 'elem_parent',
    z_index: 0,
    position: 0,
  })
  const CHILD_B_UPDATED: DesignElement = elem({
    id: 'elem_b',
    parent_id: 'elem_parent',
    z_index: 1,
    position: 1,
  })

  function makeItemWithChildren(): WorkspaceItem {
    const item: WorkspaceItem = {
      id: 'item_1',
      name: 'Design',
      item_type: 'design',
      path: '/tmp/test',
      design_elements: [
        elem({ id: 'elem_a', z_index: 0, position: 0 }),
        elem({ id: 'elem_b', z_index: 1, position: 1 }),
      ],
    }
    return item
  }

  it('calls api.groupDesignElements with the right URL + method + body', async () => {
    mockFetchOnce(201, {
      parent: PARENT,
      children: [CHILD_A_UPDATED, CHILD_B_UPDATED],
    })

    const store = useWorkspacesStore()
    store.workspaces = [
      makeWorkspaceWithItem({
        id: 'item_1',
        name: 'Design',
        item_type: 'design',
        path: '/tmp/test',
        design_elements: [elem({ id: 'elem_a' }), elem({ id: 'elem_b' })],
      }),
    ]
    await store.groupDesignElements('ws_1', 'item_1', 'page_1', {
      child_ids: ['elem_a', 'elem_b'],
      name: 'My Group',
      type: 'group',
    })

    const [url, init] = fetchMock.mock.calls[0] as [string, RequestInit]
    expect(url).toContain(
      '/api/workspaces/ws_1/items/item_1/design/pages/page_1/elements/group',
    )
    expect(init.method).toBe('POST')
    const body = JSON.parse(init.body as string)
    expect(body).toEqual({
      child_ids: ['elem_a', 'elem_b'],
      name: 'My Group',
      type: 'group',
    })
  })

  it('pushes the new parent to item.design_elements (LayersPanel tree picks it up)', async () => {
    mockFetchOnce(201, {
      parent: PARENT,
      children: [CHILD_A_UPDATED, CHILD_B_UPDATED],
    })

    const store = useWorkspacesStore()
    const initial = makeItemWithChildren()
    expect(initial.design_elements?.length).toBe(2)
    store.workspaces = [makeWorkspaceWithItem(initial)]

    await store.groupDesignElements('ws_1', 'item_1', 'page_1', {
      child_ids: ['elem_a', 'elem_b'],
    })

    const item = store.workspaces[0]!.items[0]!
    expect(item.design_elements?.length).toBe(3)
    // The parent is appended LAST (preserves backend ordering:
    // append-not-unshift matches addDesignElement's convention).
    expect(item.design_elements?.[2]?.id).toBe('elem_parent')
    expect(item.design_elements?.[2]?.type).toBe('group')
  })

  it('replaces each child in place with the updated version (parent_id set, z_index preserved)', async () => {
    mockFetchOnce(201, {
      parent: PARENT,
      children: [CHILD_A_UPDATED, CHILD_B_UPDATED],
    })

    const store = useWorkspacesStore()
    store.workspaces = [makeWorkspaceWithItem(makeItemWithChildren())]

    await store.groupDesignElements('ws_1', 'item_1', 'page_1', {
      child_ids: ['elem_a', 'elem_b'],
    })

    const item = store.workspaces[0]!.items[0]!
    // Array length grew by 1 (parent appended, no children added).
    expect(item.design_elements?.length).toBe(3)

    const childA = item.design_elements?.find((e) => e.id === 'elem_a')
    const childB = item.design_elements?.find((e) => e.id === 'elem_b')
    expect(childA?.parent_id).toBe('elem_parent')
    expect(childB?.parent_id).toBe('elem_parent')
    // z_index / position are preserved by the backend's response
    // (the SELECT in groupElements returns the existing values).
    expect(childA?.z_index).toBe(0)
    expect(childB?.z_index).toBe(1)
  })

  it('returns the API result unchanged on success', async () => {
    mockFetchOnce(201, {
      parent: PARENT,
      children: [CHILD_A_UPDATED, CHILD_B_UPDATED],
    })

    const store = useWorkspacesStore()
    store.workspaces = [makeWorkspaceWithItem(makeItemWithChildren())]

    const result = await store.groupDesignElements('ws_1', 'item_1', 'page_1', {
      child_ids: ['elem_a', 'elem_b'],
      name: 'My Group',
    })

    expect(result.parent).toBe(PARENT)
    expect(result.children).toEqual([CHILD_A_UPDATED, CHILD_B_UPDATED])
  })

  it('does NOT mutate item.design_elements on 5xx error', async () => {
    mockFetchOnce(500, { error: 'DB write failed' })

    const store = useWorkspacesStore()
    const initial = makeItemWithChildren()
    const beforeLength = initial.design_elements?.length ?? 0
    store.workspaces = [makeWorkspaceWithItem(initial)]

    await expect(
      store.groupDesignElements('ws_1', 'item_1', 'page_1', {
        child_ids: ['elem_a', 'elem_b'],
      }),
    ).rejects.toMatchObject({ status: 500 })

    const item = store.workspaces[0]!.items[0]!
    expect(item.design_elements?.length).toBe(beforeLength)
  })
})
