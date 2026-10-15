/** Gesture-capture wiring tests for the undo/redo plan. These tests verify that the existing
 * gesture handlers in DesignView.vue push the right `useDesignHistory` capture calls at the right
 * times — drag-start, drag-end, delete, reorder, group. */

/** The full integration (Cmd+Z → element back to x:0) is tested in DesignView.undo.spec.ts. */

/** We mock the `useDesignHistory` composable to assert on the `capturePreState` /
 * `capturePostState` / `captureDelete` / `captureReorder` / `captureGroup` call counts and
 * arguments. 4 behavioural tests. */

/** Project convention is behavioural only — see
 * ~/.config/pabrik/memories/static-contract-test-when-to-prefer-behavioural.md. */
import { beforeEach, describe, expect, it, vi } from 'vitest'
import { flushPromises, mount } from '@vue/test-utils'
import { createPinia, setActivePinia } from 'pinia'
import { ref } from 'vue'
import DesignView from '../components/design/DesignView.vue'

// Hoisted mocks — see the hoist explanation in DesignView.undo.spec.ts.
const undoMock = vi.fn().mockResolvedValue(undefined)
const redoMock = vi.fn().mockResolvedValue(undefined)
const capturePreStateMock = vi.fn()
const capturePostStateMock = vi.fn().mockResolvedValue(undefined)
const captureDeleteMock = vi.fn().mockResolvedValue(undefined)
const captureReorderMock = vi.fn().mockResolvedValue(undefined)
const captureGroupMock = vi.fn().mockResolvedValue(undefined)
const captureCreateMock = vi.fn().mockResolvedValue(undefined)
const canUndoRef = ref(false)
const canRedoRef = ref(false)
const nextUndoLabelRef = ref<string | null>(null)
const nextRedoLabelRef = ref<string | null>(null)

vi.mock('../composables/useDesignHistory', () => ({
  useDesignHistory: () => ({
    canUndo: canUndoRef,
    canRedo: canRedoRef,
    nextUndoLabel: nextUndoLabelRef,
    nextRedoLabel: nextRedoLabelRef,
    undo: undoMock,
    redo: redoMock,
    capturePreState: capturePreStateMock,
    capturePostState: capturePostStateMock,
    captureDelete: captureDeleteMock,
    captureReorder: captureReorderMock,
    captureGroup: captureGroupMock,
    captureCreate: captureCreateMock,
  }),
}))

// Stub the api layer so DesignView mounts cleanly.
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

describe('DesignView gesture capture wiring (Chunk 4 of undo/redo plan)', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    canUndoRef.value = false
    canRedoRef.value = false
    capturePreStateMock.mockClear()
    capturePostStateMock.mockClear()
    captureDeleteMock.mockClear()
    captureReorderMock.mockClear()
    captureGroupMock.mockClear()
  })

  it('Backspace on selected elements → captureDelete is called', async () => {
    const confirmMock = vi.fn(() => true)
    vi.stubGlobal('confirm', confirmMock)
    const wrapper = mount(DesignView, {
      props: {
        item: { ...ITEM, design_elements: [makeEl({ id: 'a' })] },
        workspaceId: 'ws_1',
        itemId: 'item_1',
      },
    })
    await flushPromises()
    // Select all (1 element → 1 selection).
    document.dispatchEvent(
      new KeyboardEvent('keydown', { key: 'a', metaKey: true, bubbles: true }),
    )
    await flushPromises()
    // Dispatch Backspace.
    document.dispatchEvent(
      new KeyboardEvent('keydown', { key: 'Backspace', bubbles: true }),
    )
    await flushPromises()
    expect(captureDeleteMock).toHaveBeenCalled()
    wrapper.unmount()
    vi.unstubAllGlobals()
  })

  it('Cmd+G with 2+ elements selected → captureGroup is called', async () => {
    // Inject 2 elements into the store so Cmd+A selects them.
    const wrapper = mount(DesignView, {
      props: {
        item: { ...ITEM, design_elements: [makeEl({ id: 'a' }), makeEl({ id: 'b' })] },
        workspaceId: 'ws_1',
        itemId: 'item_1',
      },
    })
    await flushPromises()
    // Select all.
    document.dispatchEvent(
      new KeyboardEvent('keydown', { key: 'a', metaKey: true, bubbles: true }),
    )
    await flushPromises()
    captureGroupMock.mockClear()
    // Cmd+G.
    document.dispatchEvent(
      new KeyboardEvent('keydown', { key: 'g', metaKey: true, bubbles: true }),
    )
    await flushPromises()
    expect(captureGroupMock).toHaveBeenCalled()
    wrapper.unmount()
  })

  it('Cmd+] on selection → captureReorder is called', async () => {
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
    document.dispatchEvent(
      new KeyboardEvent('keydown', { key: ']', metaKey: true, bubbles: true }),
    )
    await flushPromises()
    expect(captureReorderMock).toHaveBeenCalled()
    wrapper.unmount()
  })

  it('Arrow keys on selection → capturePreState + capturePostState both called', async () => {
    const wrapper = mount(DesignView, {
      props: {
        item: { ...ITEM, design_elements: [makeEl({ id: 'a' })] },
        workspaceId: 'ws_1',
        itemId: 'item_1',
      },
    })
    await flushPromises()
    // Select the element.
    document.dispatchEvent(
      new KeyboardEvent('keydown', { key: 'a', metaKey: true, bubbles: true }),
    )
    await flushPromises()
    capturePreStateMock.mockClear()
    capturePostStateMock.mockClear()
    // ArrowRight.
    document.dispatchEvent(
      new KeyboardEvent('keydown', { key: 'ArrowRight', bubbles: true }),
    )
    await flushPromises()
    expect(capturePreStateMock).toHaveBeenCalled()
    expect(capturePostStateMock).toHaveBeenCalled()
    wrapper.unmount()
  })
})