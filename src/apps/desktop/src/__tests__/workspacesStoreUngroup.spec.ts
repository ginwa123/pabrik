/** Unit tests for `workspacesStore.ungroupDesignElements` (the store action backing Cmd+Shift+G /
 * right-click Ungroup). 5 tests: 1. */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { createPinia, setActivePinia } from 'pinia'

import { useWorkspacesStore, type Workspace, type WorkspaceItem } from '../stores/workspaces'
import type { DesignElement } from '../api'

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

describe('workspacesStore.ungroupDesignElements (Chunk 9)', () => {
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

  // A typical "after ungroup" response — the children were reparented
  // to empty parent_id (top-level).
  const CHILD_A_REPARENTED: DesignElement = elem({
    id: 'elem_a',
    name: 'Child A',
    parent_id: '',
    z_index: 0,
    position: 0,
  })
  const CHILD_B_REPARENTED: DesignElement = elem({
    id: 'elem_b',
    name: 'Child B',
    parent_id: '',
    z_index: 1,
    position: 1,
  })

  function makeItemWithGroup(): WorkspaceItem {
    return {
      id: 'item_1',
      name: 'Design',
      item_type: 'design',
      path: '/tmp/test',
      design_elements: [
        elem({ id: 'elem_a', parent_id: 'elem_g', z_index: 0, position: 0 }),
        elem({ id: 'elem_b', parent_id: 'elem_g', z_index: 1, position: 1 }),
        elem({ id: 'elem_g', name: 'My Group', type: 'group', parent_id: '', z_index: 2, position: 2 }),
      ],
    }
  }

  it('calls api.ungroupDesignElements with the right URL + method', async () => {
    mockFetchOnce(200, { orphaned: [CHILD_A_REPARENTED, CHILD_B_REPARENTED] })

    const store = useWorkspacesStore()
    store.workspaces = [makeWorkspaceWithItem(makeItemWithGroup())]
    await store.ungroupDesignElements('ws_1', 'item_1', 'page_1', 'elem_g')

    const [url, init] = fetchMock.mock.calls[0] as [string, RequestInit]
    expect(url).toContain(
      '/api/workspaces/ws_1/items/item_1/design/pages/page_1/elements/ungroup',
    )
    expect(init.method).toBe('POST')
    const body = JSON.parse(init.body as string)
    expect(body).toEqual({ element_id: 'elem_g' })
  })

  it('removes the dissolved group row from item.design_elements', async () => {
    mockFetchOnce(200, { orphaned: [CHILD_A_REPARENTED, CHILD_B_REPARENTED] })

    const store = useWorkspacesStore()
    store.workspaces = [makeWorkspaceWithItem(makeItemWithGroup())]

    const before = store.workspaces[0]!.items[0]!.design_elements!
    expect(before.find((e) => e.id === 'elem_g')).toBeDefined()

    await store.ungroupDesignElements('ws_1', 'item_1', 'page_1', 'elem_g')

    const after = store.workspaces[0]!.items[0]!.design_elements!
    expect(after.find((e) => e.id === 'elem_g')).toBeUndefined()
    // Children are still there (reparented).
    expect(after.find((e) => e.id === 'elem_a')).toBeDefined()
    expect(after.find((e) => e.id === 'elem_b')).toBeDefined()
  })

  it('replaces each orphaned child in place (parent_id reset to empty)', async () => {
    mockFetchOnce(200, { orphaned: [CHILD_A_REPARENTED, CHILD_B_REPARENTED] })

    const store = useWorkspacesStore()
    store.workspaces = [makeWorkspaceWithItem(makeItemWithGroup())]

    await store.ungroupDesignElements('ws_1', 'item_1', 'page_1', 'elem_g')

    const after = store.workspaces[0]!.items[0]!.design_elements!
    const childA = after.find((e) => e.id === 'elem_a')
    const childB = after.find((e) => e.id === 'elem_b')
    // parent_id was the group id, now empty (top-level).
    expect(childA?.parent_id).toBe('')
    expect(childB?.parent_id).toBe('')
  })

  it('returns the API result unchanged on success', async () => {
    mockFetchOnce(200, { orphaned: [CHILD_A_REPARENTED, CHILD_B_REPARENTED] })

    const store = useWorkspacesStore()
    store.workspaces = [makeWorkspaceWithItem(makeItemWithGroup())]

    const result = await store.ungroupDesignElements('ws_1', 'item_1', 'page_1', 'elem_g')

    expect(result.orphaned).toEqual([CHILD_A_REPARENTED, CHILD_B_REPARENTED])
  })

  it('does NOT mutate item.design_elements on 4xx error (EmptyGroup)', async () => {
    mockFetchOnce(400, { error: 'group has no children — nothing to ungroup' })

    const store = useWorkspacesStore()
    const initial = makeItemWithGroup()
    const beforeIds = initial.design_elements!.map((e) => e.id)
    store.workspaces = [makeWorkspaceWithItem(initial)]

    await expect(
      store.ungroupDesignElements('ws_1', 'item_1', 'page_1', 'elem_g'),
    ).rejects.toMatchObject({ status: 400 })

    const after = store.workspaces[0]!.items[0]!.design_elements!
    expect(after.map((e) => e.id)).toEqual(beforeIds)
    // The group row is still there.
    expect(after.find((e) => e.id === 'elem_g')).toBeDefined()
  })
})