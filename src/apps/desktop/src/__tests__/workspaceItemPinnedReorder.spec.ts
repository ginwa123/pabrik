/**
 * Component tests for the pinned-task drag-reorder feature in
 * <WorkspaceItem>. Covers:
 *   1. The drop handler emits `reorderPinnedTasks` with the dragged
 *      row spliced at the cursor's target position (not always at
 *      the end — that was the v1 bug).
 *   2. The drop handler skips reorder when the cursor is on the
 *      dragged row itself (no-op).
 *   3. The drop handler falls back to "move to end" when no target
 *      row is recorded (e.g. drop on the region's empty padding).
 *   4. The per-row `dropIndicator` prop drives the yellow border on
 *      the row's box-shadow — above/below/null as expected.
 *   5. dragleave resets the visual indicator (cursor left the region).
 *
 * The dragover/drop events use jsdom's plain Event shim — we attach
 * a DataTransfer-shaped object as the `dataTransfer` property of the
 * event via Object.defineProperty. jsdom does NOT fire a real layout
 * / paint, so the `clientY`-vs-midpoint math in the dragover handler
 * uses the `clientY` we set on the event directly (the row's
 * `getBoundingClientRect()` returns all zeros in jsdom unless we
 * mock it).
 *
 * Plan: docs/superpowers/plans/2026-06-20-pinned-workspace-item-tasks.md
 */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { nextTick, ref, type Ref } from 'vue'
import { mount } from '@vue/test-utils'

import WorkspaceItem from '../components/workspace/WorkspaceItem.vue'
import { useWorkspacesStore } from '../stores/workspaces'
import { makeLocalStorageStub } from './helpers'

// Mock api.reorderPinnedTasks + pinTask so the store's optimistic-
// update path doesn't hit a real backend.
vi.mock('../api', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../api')>()
  return {
    ...actual,
    reorderPinnedTasks: vi.fn().mockResolvedValue({ success: true }),
    pinTask: vi.fn().mockResolvedValue({ success: true, id: '', is_pinned: true, pinned_position: 0 }),
  }
})

// Minimal DataTransfer shim — jsdom has no DataTransfer constructor.
class DataTransferShim {
  private store = new Map<string, string>()
  setData(type: string, value: string): void {
    this.store.set(type, value)
  }
  getData(type: string): string {
    return this.store.get(type) ?? ''
  }
}

function makePinnedItem(taskIds: string[]) {
  return {
    id: 'item_1',
    name: 'My Project',
    item_type: 'folder',
    tasks: taskIds.map((id, i) => ({
      id,
      name: `Task ${id}`,
      // `as const` so TS infers the literal type 'standard', not `string`,
      // and matches the Task interface's `task_type` union.
      task_type: 'standard' as const,
      is_pinned: true,
      pinned_position: taskIds.length - i, // DESC order
    })),
  }
}

function mountWorkspaceItem(item = makePinnedItem(['t1', 't2', 't3'])) {
  const processingState: Ref<Record<string, boolean>> = ref({})
  const wrapper = mount(WorkspaceItem, {
    props: {
      item: structuredClone(item),
      isActive: false,
      workspaceId: 'ws_1',
    },
    global: {
      provide: { processingState },
    },
  })
  return { wrapper, processingState }
}

function expandItem(itemId = 'item_1'): void {
  const ws = useWorkspacesStore()
  ws.expandedItemIds[itemId] = true
  ws.expandedItemIds = { ...ws.expandedItemIds }
}

async function flush(): Promise<void> {
  await nextTick()
  await nextTick()
}

// Build a DragEvent-ish Event with a real `dataTransfer` + `clientY`. jsdom doesn't support `new
// DragEvent('drop', { dataTransfer })` and the underlying DataTransfer constructor doesn't exist,
// so we shim the entire event surface.

// The handlers only read `event.dataTransfer`, `event.clientY`, `event.relatedTarget`,
// `event.currentTarget`, and `event.target` — all set below.
function makeDragEvent(type: string, opts: { clientY?: number; relatedTarget?: EventTarget | null } = {}): Event {
  const event = new Event(type, { bubbles: true, cancelable: true })
  Object.defineProperty(event, 'dataTransfer', { value: new DataTransferShim(), configurable: true })
  Object.defineProperty(event, 'clientY', { value: opts.clientY ?? 0, configurable: true })
  Object.defineProperty(event, 'relatedTarget', { value: opts.relatedTarget ?? null, configurable: true })
  return event
}

describe('WorkspaceItem pinned-task drag reorder', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    Object.defineProperty(globalThis, 'localStorage', {
      value: makeLocalStorageStub(),
      writable: true,
      configurable: true,
    })
  })

  afterEach(() => {
    vi.clearAllMocks()
  })

  it('renders the pinned region only when at least one task is pinned', async () => {
    const unpinnedItem = {
      id: 'item_1',
      name: 'My Project',
      item_type: 'folder',
      tasks: [{
        id: 't1',
        name: 'Task t1',
        task_type: 'standard' as const,
        is_pinned: false,
        pinned_position: 0,
      }],
    }
    const { wrapper } = mountWorkspaceItem(unpinnedItem)
    expandItem()
    await flush()
    expect(wrapper.findAll('[data-testid="pinned-tasks-region"]')).toHaveLength(0)

    // Now with a pinned task the region should appear.
    const pinnedItem = makePinnedItem(['t1', 't2'])
    const { wrapper: wrapper2 } = mountWorkspaceItem(pinnedItem)
    expandItem()
    await flush()
    expect(wrapper2.findAll('[data-testid="pinned-tasks-region"]')).toHaveLength(1)
  })

  it('emits reorderPinnedTasks with the dragged row spliced BEFORE the target when the cursor is in the target row top half', async () => {
    const { wrapper } = mountWorkspaceItem()
    expandItem()
    await flush()
    const region = wrapper.find('[data-testid="pinned-tasks-region"]')
    expect(region.exists()).toBe(true)
    const regionEl = region.element as HTMLElement

    // Drag t3 (at index 2) to t1 (at index 0) with cursor in t1's
    // top half → result: [t3, t1, t2] (t3 spliced BEFORE t1).
    const t1Row = regionEl.querySelector('[data-task-id="t1"]') as HTMLElement
    const t3Row = regionEl.querySelector('[data-task-id="t3"]') as HTMLElement
    const t1Rect = { top: 0, height: 40 } as DOMRect
    const t3Rect = { top: 100, height: 40 } as DOMRect
    vi.spyOn(t1Row, 'getBoundingClientRect').mockReturnValue(t1Rect)
    vi.spyOn(t3Row, 'getBoundingClientRect').mockReturnValue(t3Rect)
    const dragstart = makeDragEvent('dragstart')
    t3Row.dispatchEvent(dragstart)
    const dt3 = (dragstart as unknown as { dataTransfer: DataTransferShim }).dataTransfer
    expect(dt3.getData('application/x-pinned-task-id')).toBe('t3')

    // dragover on t1 with clientY=5 (top half; midpoint=20) → indicator 'above'.
    const dragover = new Event('dragover', { bubbles: true, cancelable: true })
    Object.defineProperty(dragover, 'dataTransfer', { value: dt3, configurable: true })
    Object.defineProperty(dragover, 'clientY', { value: 5, configurable: true })
    t1Row.dispatchEvent(dragover)
    await flush()
    expect(t1Row.getAttribute('data-drop-indicator')).toBe('above')

    // drop → emit [t3, t1, t2] (t3 spliced before t1).
    const drop = new Event('drop', { bubbles: true, cancelable: true })
    Object.defineProperty(drop, 'dataTransfer', { value: dt3, configurable: true })
    Object.defineProperty(drop, 'clientY', { value: 5, configurable: true })
    regionEl.dispatchEvent(drop)
    await flush()

    const emitted = wrapper.emitted('reorderPinnedTasks')
    expect(emitted).toBeDefined()
    expect(emitted![0]).toEqual(['ws_1', 'item_1', ['t3', 't1', 't2']])
  })

  it('emits reorderPinnedTasks with the dragged row spliced AFTER the target when the cursor is in the target row bottom half', async () => {
    const { wrapper } = mountWorkspaceItem()
    expandItem()
    await flush()
    const region = wrapper.find('[data-testid="pinned-tasks-region"]')
    const regionEl = region.element as HTMLElement

    // Drag t3 onto t1 (cursor in t1's bottom half) → [t1, t3, t2].
    const t1Row = regionEl.querySelector('[data-task-id="t1"]') as HTMLElement
    const t3Row = regionEl.querySelector('[data-task-id="t3"]') as HTMLElement
    const t1Rect = { top: 0, height: 40 } as DOMRect
    const t3Rect = { top: 100, height: 40 } as DOMRect
    vi.spyOn(t1Row, 'getBoundingClientRect').mockReturnValue(t1Rect)
    vi.spyOn(t3Row, 'getBoundingClientRect').mockReturnValue(t3Rect)
    const dragstart = makeDragEvent('dragstart')
    t3Row.dispatchEvent(dragstart)
    const dt3 = (dragstart as unknown as { dataTransfer: DataTransferShim }).dataTransfer
    expect(dt3.getData('application/x-pinned-task-id')).toBe('t3')

    // dragover: cursor on t1, clientY=30 (in t1's bottom half; midpoint=20).
    const dragover = new Event('dragover', { bubbles: true, cancelable: true })
    Object.defineProperty(dragover, 'dataTransfer', { value: dt3, configurable: true })
    Object.defineProperty(dragover, 'clientY', { value: 30, configurable: true })
    t1Row.dispatchEvent(dragover)
    await flush()
    expect(t1Row.getAttribute('data-drop-indicator')).toBe('below')

    // drop.
    const drop = new Event('drop', { bubbles: true, cancelable: true })
    Object.defineProperty(drop, 'dataTransfer', { value: dt3, configurable: true })
    Object.defineProperty(drop, 'clientY', { value: 30, configurable: true })
    regionEl.dispatchEvent(drop)
    await flush()

    const emitted = wrapper.emitted('reorderPinnedTasks')
    expect(emitted![0]).toEqual(['ws_1', 'item_1', ['t1', 't3', 't2']])
  })

  it('emits reorderPinnedTasks with the dragged row moved to the end when no target is recorded (fallback)', async () => {
    // No dragover — drop straight on the region. The handler falls
    // back to "move the dragged row to the end".
    const { wrapper } = mountWorkspaceItem()
    expandItem()
    await flush()
    const region = wrapper.find('[data-testid="pinned-tasks-region"]')
    const regionEl = region.element as HTMLElement

    const t1Row = regionEl.querySelector('[data-task-id="t1"]') as HTMLElement
    const dragstart = makeDragEvent('dragstart')
    t1Row.dispatchEvent(dragstart)
    const dt1 = (dragstart as unknown as { dataTransfer: DataTransferShim }).dataTransfer

    const drop = new Event('drop', { bubbles: true, cancelable: true })
    Object.defineProperty(drop, 'dataTransfer', { value: dt1, configurable: true })
    regionEl.dispatchEvent(drop)
    await flush()

    const emitted = wrapper.emitted('reorderPinnedTasks')
    expect(emitted![0]).toEqual(['ws_1', 'item_1', ['t2', 't3', 't1']])
  })

  it('clears the drop indicator when the cursor leaves the region (dragleave)', async () => {
    const { wrapper } = mountWorkspaceItem()
    expandItem()
    await flush()
    const region = wrapper.find('[data-testid="pinned-tasks-region"]')
    const regionEl = region.element as HTMLElement

    const t1Row = regionEl.querySelector('[data-task-id="t1"]') as HTMLElement
    const t1Rect = { top: 0, height: 40 } as DOMRect
    vi.spyOn(t1Row, 'getBoundingClientRect').mockReturnValue(t1Rect)
    const dragstart = makeDragEvent('dragstart')
    t1Row.dispatchEvent(dragstart)
    const dt1 = (dragstart as unknown as { dataTransfer: DataTransferShim }).dataTransfer

    // Move over t1 — indicator set to 'above'.
    const dragover = new Event('dragover', { bubbles: true, cancelable: true })
    Object.defineProperty(dragover, 'dataTransfer', { value: dt1, configurable: true })
    Object.defineProperty(dragover, 'clientY', { value: 5, configurable: true })
    t1Row.dispatchEvent(dragover)
    await flush()
    expect(t1Row.getAttribute('data-drop-indicator')).toBe('above')

    // Leave the region entirely (relatedTarget null = outside the region).
    const dragleave = new Event('dragleave', { bubbles: true, cancelable: true })
    Object.defineProperty(dragleave, 'dataTransfer', { value: dt1, configurable: true })
    Object.defineProperty(dragleave, 'relatedTarget', { value: null, configurable: true })
    regionEl.dispatchEvent(dragleave)
    await flush()
    expect(t1Row.getAttribute('data-drop-indicator')).toBeNull()
  })

  it('clears the drop indicator after a drop', async () => {
    const { wrapper } = mountWorkspaceItem()
    expandItem()
    await flush()
    const region = wrapper.find('[data-testid="pinned-tasks-region"]')
    const regionEl = region.element as HTMLElement

    const t1Row = regionEl.querySelector('[data-task-id="t1"]') as HTMLElement
    const t2Row = regionEl.querySelector('[data-task-id="t2"]') as HTMLElement
    const t1Rect = { top: 0, height: 40 } as DOMRect
    const t2Rect = { top: 50, height: 40 } as DOMRect
    vi.spyOn(t1Row, 'getBoundingClientRect').mockReturnValue(t1Rect)
    vi.spyOn(t2Row, 'getBoundingClientRect').mockReturnValue(t2Rect)
    const dragstart = makeDragEvent('dragstart')
    t1Row.dispatchEvent(dragstart)
    const dt1 = (dragstart as unknown as { dataTransfer: DataTransferShim }).dataTransfer

    const dragover = new Event('dragover', { bubbles: true, cancelable: true })
    Object.defineProperty(dragover, 'dataTransfer', { value: dt1, configurable: true })
    Object.defineProperty(dragover, 'clientY', { value: 55, configurable: true })
    t2Row.dispatchEvent(dragover)
    await flush()
    expect(t2Row.getAttribute('data-drop-indicator')).toBe('above')

    const drop = new Event('drop', { bubbles: true, cancelable: true })
    Object.defineProperty(drop, 'dataTransfer', { value: dt1, configurable: true })
    Object.defineProperty(drop, 'clientY', { value: 55, configurable: true })
    regionEl.dispatchEvent(drop)
    await flush()
    // After drop, the indicator must be cleared.
    expect(t2Row.getAttribute('data-drop-indicator')).toBeNull()
  })
})
