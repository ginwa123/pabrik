import { beforeEach, describe, expect, it, vi } from 'vitest'
import { createPinia, setActivePinia } from 'pinia'
import { ref } from 'vue'
import { useDesignHandlers } from '../useDesignHandlers'

const updateDesignElementGeometrySpy = vi.fn().mockResolvedValue({ id: 'el_1' })
const updateDesignElementSpy = vi.fn().mockResolvedValue({ id: 'el_1' })
const deleteDesignElementSpy = vi.fn().mockResolvedValue({ success: true })
const ungroupDesignElementsSpy = vi.fn().mockResolvedValue({
  orphaned: [{ id: 'el_orphan_1' }, { id: 'el_orphan_2' }],
})

vi.mock('../../stores/workspaces', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../../stores/workspaces')>()
  return {
    ...actual,
    useWorkspacesStore: () => ({
      activeDesignPageId: 'page_test',
      updateDesignElementGeometry: updateDesignElementGeometrySpy,
      updateDesignElement: updateDesignElementSpy,
      deleteDesignElement: deleteDesignElementSpy,
      ungroupDesignElements: ungroupDesignElementsSpy,
    }),
  }
})

describe('useDesignHandlers', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    vi.clearAllMocks()
    vi.stubGlobal('confirm', vi.fn(() => true))
  })

  it('routes a geometry-only patch to updateDesignElementGeometry', async () => {
    const { updateElement } = useDesignHandlers()
    await updateElement('ws_1', 'item_1', 'el_1', { x: 100, y: 200 })
    expect(updateDesignElementGeometrySpy).toHaveBeenCalledWith('ws_1', 'item_1', 'page_test', 'el_1', { x: 100, y: 200 })
    expect(updateDesignElementSpy).not.toHaveBeenCalled()
  })

  it('routes a non-geometry patch to updateDesignElement', async () => {
    const { updateElement } = useDesignHandlers()
    await updateElement('ws_1', 'item_1', 'el_1', { fill: '#ff0000' })
    expect(updateDesignElementSpy).toHaveBeenCalledWith('ws_1', 'item_1', 'page_test', 'el_1', { fill: '#ff0000' })
    expect(updateDesignElementGeometrySpy).not.toHaveBeenCalled()
  })

  it('routes a mixed patch to updateDesignElement (full PUT, not geometry-only)', async () => {
    const { updateElement } = useDesignHandlers()
    await updateElement('ws_1', 'item_1', 'el_1', { x: 50, fill: 'red' })
    expect(updateDesignElementSpy).toHaveBeenCalled()
    expect(updateDesignElementGeometrySpy).not.toHaveBeenCalled()
  })

  it('deleteElement routes to deleteDesignElement', async () => {
    const { deleteElement } = useDesignHandlers()
    await deleteElement('ws_1', 'item_1', 'el_1')
    expect(deleteDesignElementSpy).toHaveBeenCalledWith('ws_1', 'item_1', 'page_test', 'el_1')
  })

  // ─── Chunk 9 — ungroupSelection ──────────────────────────────────────
  it('ungroupSelection routes to workspacesStore.ungroupDesignElements', async () => {
    const selectedIds = ref(new Set<string>(['el_g']))
    const { ungroupSelection } = useDesignHandlers({
      workspaceId: 'ws_1',
      itemId: 'item_1',
      pageId: 'page_test',
      selectedIds,
    })
    await ungroupSelection('el_g')
    expect(ungroupDesignElementsSpy).toHaveBeenCalledWith('ws_1', 'item_1', 'page_test', 'el_g')
  })

  it('ungroupSelection clears the selection Set after success', async () => {
    const selectedIds = ref(new Set<string>(['el_g']))
    const { ungroupSelection } = useDesignHandlers({
      workspaceId: 'ws_1',
      itemId: 'item_1',
      pageId: 'page_test',
      selectedIds,
    })
    await ungroupSelection('el_g')
    expect(selectedIds.value.size).toBe(0)
  })

  it('ungroupSelection is a no-op when elementId is empty (matches Figma greyed-out)', async () => {
    const selectedIds = ref(new Set<string>())
    const { ungroupSelection } = useDesignHandlers({
      workspaceId: 'ws_1',
      itemId: 'item_1',
      pageId: 'page_test',
      selectedIds,
    })
    await ungroupSelection('')
    expect(ungroupDesignElementsSpy).not.toHaveBeenCalled()
  })

  it('ungroupSelection is a no-op when args are missing', async () => {
    const { ungroupSelection } = useDesignHandlers()
    await ungroupSelection('el_g')
    expect(ungroupDesignElementsSpy).not.toHaveBeenCalled()
  })

  it('ungroupSelection is a no-op when pageId is empty (no active page)', async () => {
    const selectedIds = ref(new Set<string>(['el_g']))
    const { ungroupSelection } = useDesignHandlers({
      workspaceId: 'ws_1',
      itemId: 'item_1',
      pageId: '',
      selectedIds,
    })
    await ungroupSelection('el_g')
    expect(ungroupDesignElementsSpy).not.toHaveBeenCalled()
  })
})
