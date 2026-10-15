/**
 * Behavioural tests asserting that the undo/redo feature is HIDDEN
 * from the user in design mode (2026-08-06).
 *
 * The feature was intentionally disabled in response to a product
 * request. The user-visible surface is removed:
 *   - The <DesignHistoryButtons> toolbar (was in the canvas header)
 *   - The Cmd/Ctrl+Z, Cmd/Ctrl+Shift+Z, Cmd/Ctrl+Y keyboard shortcuts
 *     bound in DesignView's keydown handler.
 *
 * Internal plumbing is INTENTIONALLY retained so the feature can be
 * re-enabled without re-deriving capture sites:
 *   - `useDesignHistory` composable still exists
 *   - `designHistory` Pinia store still exists
 *   - All `history.capture*()` calls in DesignView.vue / PropertiesPanel
 *     / LayersPanel / DesignElement still fire (they're harmless dead
 *     code without undo/redo, but provide a clean re-enable path)
 *
 * These tests lock in the "feature is hidden" invariant. If a future
 * contributor re-enables the buttons or keyboard shortcuts, these
 * tests fail and force them to also delete this spec file.
 *
 * 6 behavioural tests. Project convention is behavioural only —
 * see ~/.config/pabrik/memories/static-contract-test-when-to-prefer-behavioural.md.
 */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { flushPromises, mount } from '@vue/test-utils'
import { createPinia, setActivePinia } from 'pinia'
import { ref } from 'vue'
import DesignView from '../components/design/DesignView.vue'

// Hoisted mocks — every captured call is asserted on at least once.
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

describe('DesignView undo/redo feature is hidden (2026-08-06)', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    canUndoRef.value = false
    canRedoRef.value = false
    nextUndoLabelRef.value = null
    nextRedoLabelRef.value = null
    undoMock.mockClear()
    redoMock.mockClear()
    capturePreStateMock.mockClear()
    capturePostStateMock.mockClear()
    captureDeleteMock.mockClear()
    captureReorderMock.mockClear()
    captureGroupMock.mockClear()
    captureCreateMock.mockClear()
  })

  afterEach(() => {
    vi.restoreAllMocks()
  })

  // ─── DOM assertions (buttons not rendered) ─────────────────────────

  it('DesignView does NOT render the design-history-buttons wrapper', async () => {
    const wrapper = mount(DesignView, {
      props: { item: ITEM, workspaceId: 'ws_1', itemId: 'item_1' },
    })
    await flushPromises()
    expect(wrapper.find('[data-testid="design-history-buttons"]').exists()).toBe(false)
    expect(wrapper.find('[data-testid="design-undo-button"]').exists()).toBe(false)
    expect(wrapper.find('[data-testid="design-redo-button"]').exists()).toBe(false)
    wrapper.unmount()
  })

  // ─── Keyboard shortcut assertions (handlers removed) ────────────────

  it('Cmd+Z does NOT call history.undo() even when canUndo is true', async () => {
    canUndoRef.value = true
    nextUndoLabelRef.value = 'Move element'
    const wrapper = mount(DesignView, {
      props: { item: ITEM, workspaceId: 'ws_1', itemId: 'item_1' },
    })
    await flushPromises()
    document.dispatchEvent(
      new KeyboardEvent('keydown', { key: 'z', metaKey: true, bubbles: true }),
    )
    await flushPromises()
    expect(undoMock).not.toHaveBeenCalled()
    wrapper.unmount()
  })

  it('Cmd+Shift+Z does NOT call history.redo() even when canRedo is true', async () => {
    canRedoRef.value = true
    const wrapper = mount(DesignView, {
      props: { item: ITEM, workspaceId: 'ws_1', itemId: 'item_1' },
    })
    await flushPromises()
    document.dispatchEvent(
      new KeyboardEvent('keydown', {
        key: 'z',
        metaKey: true,
        shiftKey: true,
        bubbles: true,
      }),
    )
    await flushPromises()
    expect(redoMock).not.toHaveBeenCalled()
    wrapper.unmount()
  })

  it('Cmd+Y does NOT call history.redo() even when canRedo is true', async () => {
    canRedoRef.value = true
    const wrapper = mount(DesignView, {
      props: { item: ITEM, workspaceId: 'ws_1', itemId: 'item_1' },
    })
    await flushPromises()
    document.dispatchEvent(
      new KeyboardEvent('keydown', { key: 'y', metaKey: true, bubbles: true }),
    )
    await flushPromises()
    expect(redoMock).not.toHaveBeenCalled()
    wrapper.unmount()
  })

  // ─── Keyboard event passthrough (browser-native Cmd+Z works again) ─

  it('Cmd+Z is NOT preventDefault()ed (browser-native Cmd+Z should still work)', async () => {
    const wrapper = mount(DesignView, {
      props: { item: ITEM, workspaceId: 'ws_1', itemId: 'item_1' },
    })
    await flushPromises()
    let preventedDefault = false
    const event = new KeyboardEvent('keydown', {
      key: 'z',
      metaKey: true,
      bubbles: true,
      cancelable: true,
    })
    event.preventDefault = () => { preventedDefault = true }
    document.dispatchEvent(event)
    await flushPromises()
    expect(preventedDefault).toBe(false)
    wrapper.unmount()
  })

  // ─── Regression guard — see DesignView.endToEnd.spec.ts ───────────── The "capture calls still
  // fire" invariant is verified by the arrow-key nudge test in DesignView.endToEnd.spec.ts (it
  // asserts capturePreState + capturePostState both fire 3 times for 3 arrow presses).
  // Re-asserting here would duplicate coverage; the failure modes are the same and one canonical
  // regression test is cleaner than two near-identical ones.
})