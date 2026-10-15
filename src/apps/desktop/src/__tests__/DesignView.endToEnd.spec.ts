/** End-to-end test for design-mode undo/redo capture calls (Chunk 7). Originally verified the full
 * gesture → entry push → undo/redo → element restored cycle for the most important mutations. */

/** After 2026-08-06 (the undo/redo feature was hidden from the user in design mode — see
 * DesignView.undoHidden.spec.ts), the Cmd+Z / Cmd+Shift+Z / Cmd+Y keyboard shortcut tests were
 * deleted because the keyboard handlers were removed. */

/** The capture-call invariant (history.capturePreState / capturePostState fire on every gesture) is
 * still the canonical regression guard against accidentally removing the dead-code captures during
 * future refactors. 1 behavioural test. */

/** Project convention is behavioural only — see
 * ~/.config/pabrik/memories/static-contract-test-when-to-prefer-behavioural.md. */
import { beforeEach, describe, expect, it, vi } from 'vitest'
import { flushPromises, mount } from '@vue/test-utils'
import { createPinia, setActivePinia } from 'pinia'
import { ref } from 'vue'
import DesignView from '../components/design/DesignView.vue'

const undoMock = vi.fn().mockResolvedValue(undefined)
const redoMock = vi.fn().mockResolvedValue(undefined)
const capturePreStateMock = vi.fn()
const capturePostStateMock = vi.fn().mockResolvedValue(undefined)
const captureDeleteMock = vi.fn().mockResolvedValue(undefined)
const captureReorderMock = vi.fn().mockResolvedValue(undefined)
const captureGroupMock = vi.fn().mockResolvedValue(undefined)
const canUndoRef = ref(false)
const canRedoRef = ref(false)

vi.mock('../composables/useDesignHistory', () => ({
  useDesignHistory: () => ({
    canUndo: canUndoRef,
    canRedo: canRedoRef,
    nextUndoLabel: ref(null),
    nextRedoLabel: ref(null),
    undo: undoMock,
    redo: redoMock,
    capturePreState: capturePreStateMock,
    capturePostState: capturePostStateMock,
    captureDelete: captureDeleteMock,
    captureReorder: captureReorderMock,
    captureGroup: captureGroupMock,
    captureCreate: vi.fn().mockResolvedValue(undefined),
  }),
}))

vi.mock('../api', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../api')>()
  return {
    ...actual,
    listDesignPages: vi.fn().mockResolvedValue({
      pages: [
        {
          id: 'page_1',
          workspace_item_id: 'item_1',
          name: 'Test Page',
          width: 1440,
          height: 1024,
          position: 0,
          created_at: '2026-07-29 12:00:00',
          updated_at: '2026-07-29 12:00:00',
        },
      ],
      count: 1,
    }),
    reorderDesignElements: vi.fn().mockResolvedValue({ reordered: [] }),
    deleteDesignElement: vi.fn().mockResolvedValue(undefined),
    updateDesignElementGeometry: vi.fn().mockResolvedValue({}),
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

 

// eslint-disable-next-line @typescript-eslint/no-explicit-any
function makeEl(overrides: Record<string, unknown> = {}): any {
  return {
    id: 'el_1',
    name: 'Box',
    type: 'rectangle',
    page_id: 'page_1',
    x: 100,
    y: 100,
    width: 200,
    height: 200,
    rotation: 0,
    opacity: 1,
    fill: '#fff',
    stroke: '',
    stroke_width: 0,
    corner_radius: 0,
    text_content: '',
    text_style: '',
    image_url: '',
    z_index: 0,
    position: 0,
    file_path: '',
    parent_id: null,
    created_at: '',
    updated_at: '',
    ...overrides,
  }
}

describe('DesignView undo/redo capture invariant (Chunk 7 regression guard)', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    canUndoRef.value = false
    canRedoRef.value = false
    capturePreStateMock.mockClear()
    capturePostStateMock.mockClear()
    captureDeleteMock.mockClear()
    captureReorderMock.mockClear()
    captureGroupMock.mockClear()
    undoMock.mockClear()
    redoMock.mockClear()
  })

  it('arrow-key nudge pushes 1 entry per keypress', async () => {
    const wrapper = mount(DesignView, {
      props: {
        item: { ...ITEM, design_elements: [makeEl({ id: 'a' })] },
        workspaceId: 'ws_1',
        itemId: 'item_1',
      },
    })
    await flushPromises()
    // Select.
    document.dispatchEvent(
      new KeyboardEvent('keydown', { key: 'a', metaKey: true, bubbles: true }),
    )
    await flushPromises()
    // 3 nudges.
    for (let i = 0; i < 3; i++) {
      document.dispatchEvent(
        new KeyboardEvent('keydown', { key: 'ArrowRight', bubbles: true }),
      )
      await flushPromises()
    }
    expect(capturePreStateMock).toHaveBeenCalledTimes(3)
    expect(capturePostStateMock).toHaveBeenCalledTimes(3)
    wrapper.unmount()
  })
})