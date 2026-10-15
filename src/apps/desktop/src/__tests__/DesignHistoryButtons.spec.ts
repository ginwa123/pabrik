/** Behavioural tests for `DesignHistoryButtons.vue`. Renders two toolbar buttons with disabled
 * states + tooltips that show the next undo/redo entry's label. */
/** Click handlers delegate to the `useDesignHistory` composable. 4 behavioural tests (the project
 * convention is behavioural only — see
 * ~/.config/pabrik/memories/static-contract-test-when-to-prefer-behavioural.md). */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { mount, type VueWrapper } from '@vue/test-utils'
import { createPinia, setActivePinia } from 'pinia'
import { ref, type ComputedRef } from 'vue'
import DesignHistoryButtons from '../components/design/DesignHistoryButtons.vue'

// Mock the composable so we control canUndo/canRedo/nextUndoLabel/etc.
// and can assert on undo()/redo() call counts.
const undoMock = vi.fn().mockResolvedValue(undefined)
const redoMock = vi.fn().mockResolvedValue(undefined)
const canUndoRef = ref(false)
const canRedoRef = ref(false)
const nextUndoLabelRef = ref<string | null>(null)
const nextRedoLabelRef = ref<string | null>(null)

vi.mock('../composables/useDesignHistory', () => ({
  useDesignHistory: (_pageId: ComputedRef<string>) => ({
    canUndo: canUndoRef,
    canRedo: canRedoRef,
    nextUndoLabel: nextUndoLabelRef,
    nextRedoLabel: nextRedoLabelRef,
    undo: undoMock,
    redo: redoMock,
    capturePreState: vi.fn(),
    capturePostState: vi.fn(),
    captureDelete: vi.fn(),
    captureCreate: vi.fn(),
    captureReorder: vi.fn(),
    captureGroup: vi.fn(),
  }),
}))

describe('DesignHistoryButtons', () => {
  let wrapper: VueWrapper | null = null

  beforeEach(() => {
    setActivePinia(createPinia())
    // Reset mock state.
    canUndoRef.value = false
    canRedoRef.value = false
    nextUndoLabelRef.value = null
    nextRedoLabelRef.value = null
    undoMock.mockClear()
    redoMock.mockClear()
  })

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    vi.restoreAllMocks()
  })

  it('renders two buttons with design-undo-button and design-redo-button testids', () => {
    wrapper = mount(DesignHistoryButtons, {
      props: { workspaceId: 'ws_1', itemId: 'item_1', pageId: 'page_1' },
    })
    expect(wrapper.find('[data-testid="design-undo-button"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="design-redo-button"]').exists()).toBe(true)
  })

  it('disables buttons when canUndo/canRedo are false', async () => {
    wrapper = mount(DesignHistoryButtons, {
      props: { workspaceId: 'ws_1', itemId: 'item_1', pageId: 'page_1' },
    })
    const undoBtn = wrapper.find('[data-testid="design-undo-button"]')
    const redoBtn = wrapper.find('[data-testid="design-redo-button"]')
    expect((undoBtn.element as HTMLButtonElement).disabled).toBe(true)
    expect((redoBtn.element as HTMLButtonElement).disabled).toBe(true)

    canUndoRef.value = true
    await wrapper.vm.$nextTick()
    expect((undoBtn.element as HTMLButtonElement).disabled).toBe(false)
    // Redo is still disabled because canRedo is still false.
    expect((redoBtn.element as HTMLButtonElement).disabled).toBe(true)

    canRedoRef.value = true
    await wrapper.vm.$nextTick()
    expect((redoBtn.element as HTMLButtonElement).disabled).toBe(false)
  })

  it('tooltips show nextUndoLabel / nextRedoLabel text', async () => {
    nextUndoLabelRef.value = 'Move element'
    nextRedoLabelRef.value = 'Delete 3 elements'
    wrapper = mount(DesignHistoryButtons, {
      props: { workspaceId: 'ws_1', itemId: 'item_1', pageId: 'page_1' },
    })
    await wrapper.vm.$nextTick()
    const undoBtn = wrapper.find('[data-testid="design-undo-button"]')
    const redoBtn = wrapper.find('[data-testid="design-redo-button"]')
    expect(undoBtn.attributes('title')).toBe('Undo: Move element')
    expect(redoBtn.attributes('title')).toBe('Redo: Delete 3 elements')
  })

  it('clicking the undo button calls useDesignHistory.undo() once', async () => {
    canUndoRef.value = true
    wrapper = mount(DesignHistoryButtons, {
      props: { workspaceId: 'ws_1', itemId: 'item_1', pageId: 'page_1' },
    })
    await wrapper.find('[data-testid="design-undo-button"]').trigger('click')
    expect(undoMock).toHaveBeenCalledOnce()
  })
})
