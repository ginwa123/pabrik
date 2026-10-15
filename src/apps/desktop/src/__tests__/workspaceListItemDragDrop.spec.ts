/** Unit tests for the drag-and-drop handlers on workspace ITEMS in ProjectsList.vue. */
/** The handlers convert the HTML5 drag events (dragstart, dragover, drop, dragend) on a
 * per-workspace `<ul>` (event delegation) into a `reorder-workspace-items` emit with the new
 * top-to-bottom ID order, scoped to the workspace the drop target belongs to. */
/** Scoped to a single workspace's items — the 2026-09-22 revamp plan removed workspace-level
 * reorder from the UI. Plan: docs/superpowers/plans/2026-06-16-workspace-item-position-reorder.md */
import { beforeEach, describe, expect, it } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { defineComponent, h, nextTick } from 'vue'
import { mount } from '@vue/test-utils'

import ProjectsList from '../components/workspace/ProjectsList.vue'
import {
  type Workspace,
  type WorkspaceItem,
} from '../stores/workspaces'
import { makeLocalStorageStub } from './helpers'

/** Minimal stub for WorkspaceItemComponent that renders just the `<li>` with the data-* attributes
 * the parent uses for event delegation. */
/** The real component has a lot of children (button, spinner, task list, etc.) that we don't need
 * for the drag-and-drop test — the events bubble up to the parent `<ul>` and the handler uses
 * `closest('[data-item-id]')` to find the source. */
/** Keeping the stub minimal avoids the real component's deep dep tree (WorkspaceItemTask, etc.)
 * which would slow the test down and require its own setup. */
const WorkspaceItemStub = defineComponent({
  name: 'WorkspaceItem',
  props: {
    item: { type: Object, required: true },
    isActive: { type: Boolean, default: false },
    workspaceId: { type: String, required: true },
    isItemDragging: { type: Boolean, default: false },
    isItemDragOver: { type: Boolean, default: false },
    isItemDragOverInsertAfter: { type: Boolean, default: false },
  },
  emits: ['click', 'delete', 'addTask', 'selectTask'],
  setup(props, { emit }) {
    return () =>
      h(
        'li',
        {
          draggable: 'true',
          'data-item-id': props.item.id,
          'data-workspace-id': props.workspaceId,
          class: { 'opacity-50': props.isItemDragging },
          style: {
            // Mirror the real WorkspaceItem's drop indicator: top-line on top-half hover,
            // bottom-line on bottom- half hover. The test asserts on the rendered boxShadow so any
            // future regression that desyncs the visual from the drop logic fails here.
            boxShadow:
              props.isItemDragOver && !props.isItemDragging
                ? props.isItemDragOverInsertAfter
                  ? '0 2px 0 0 var(--color-violet)'
                  : '0 -2px 0 0 var(--color-violet)'
                : 'none',
          },
          onClick: () => emit('click', props.item),
        },
        props.item.name,
      )
  },
})

function makeItem(id: string, name: string): WorkspaceItem {
  return { id, name, item_type: 'folder' }
}

function makeWorkspace(
  id: string,
  name: string,
  items: WorkspaceItem[] = [],
): Workspace {
  return { id, name, icon: '📁', expanded: true, items }
}

describe('ProjectsList item drag-and-drop', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    Object.defineProperty(globalThis, 'localStorage', {
      value: makeLocalStorageStub(),
      writable: true,
    })
  })

  /**    * Build a fake DragEvent with a writable dataTransfer. JSDOM does not provide the browser's
   * `DataTransfer` class, so we use a minimal in-memory stub that implements just the surface our
   * component touches (`setData` / `getData`). */
  function makeDragStore() {
    const store = new Map<string, string>()
    return {
      effectAllowed: 'none' as 'none' | 'copy' | 'move' | 'link' | 'copyMove' | 'copyLink' | 'linkMove' | 'all',
      dropEffect: 'none' as 'none' | 'copy' | 'move' | 'link',
      setData(type: string, value: string) {
        store.set(type, value)
      },
      getData(type: string): string {
        return store.get(type) ?? ''
      },
    }
  }

  function makeDragEvent(
    type: string,
    dt: ReturnType<typeof makeDragStore>,
    clientY: number = 0,
  ): DragEvent {
     
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const event = new Event(type, { bubbles: true, cancelable: true }) as any
    event.dataTransfer = dt
    // JSDOM's `getBoundingClientRect()` returns a zeroed DOMRect, so the midpoint of any element is
    // (0 + 0/2) = 0.

    // That makes the cursor-Y half-test collapse to "clientY > 0 = bottom half, clientY <= 0 = top
    // half" — which lets us drive the behavior from tests without mocking layout.
    event.clientY = clientY
    return event as DragEvent
  }

  /** Find the draggable item <li>s (the data-item-id elements). */
  function findDraggableItems(wrapper: ReturnType<typeof mount>) {
    return wrapper.findAll('[data-item-id]')
  }

  it('emits reorderWorkspaceItems with the new order when item2 is dropped on item0', async () => {
    const workspaces = [
      makeWorkspace('ws_a', 'A', [
        makeItem('item1', '1'),
        makeItem('item2', '2'),
        makeItem('item3', '3'),
      ]),
    ]
    const wrapper = mount(ProjectsList, {
      props: { workspace: workspaces[0]!, activeWorkspaceItemId: null },
      attachTo: document.body,
      global: { stubs: { WorkspaceItem: WorkspaceItemStub } },
    })
    // The workspace is already expanded (makeWorkspace sets
    // expanded: true), so the inner <ul> renders without needing
    // to click the section header.
    await nextTick()

    const items = findDraggableItems(wrapper)
    expect(items.length).toBe(3)

    // Drag the second item (item2) onto the first item (item1).
    // After drop, item2 should be at the top: [item2, item1, item3].
    const sourceItem = items[1]!
    const targetItem = items[0]!

    const dt = makeDragStore()

    // dragstart on source: sets dataTransfer to 'item2'
    const startEvent = makeDragEvent('dragstart', dt)
    sourceItem.element.dispatchEvent(startEvent)
    expect(dt.getData('application/x-item-id')).toBe('item2')

    // dragover on target: enables the drop
    const overEvent = makeDragEvent('dragover', dt)
    targetItem.element.dispatchEvent(overEvent)

    // drop on target: fires the emit
    const dropEvent = makeDragEvent('drop', dt)
    targetItem.element.dispatchEvent(dropEvent)

    const emitted = wrapper.emitted('reorderWorkspaceItems')
    expect(emitted).toBeDefined()
    expect(emitted).toHaveLength(1)
    // Emit payload is `(workspaceId, orderedItemIds)` — 2 args.
    expect(emitted![0]![0]).toBe('ws_a')
    expect(emitted![0]![1]).toEqual(['item2', 'item1', 'item3'])

    wrapper.unmount()
  })

  it('does not emit when an item is dropped on the same slot', async () => {
    // The item handler short-circuits on self-drop — mirrors the workspace-level handler (which has
    // the same check).

    // This is a deliberate design choice: the same-order no-op is a UX-level concern (the user
    // explicitly dropped on the same row, so the UI shouldn't flicker) and it's cheaper to skip the
    // event entirely than to round-trip through the store's same-order check.

    // The store's same-order check still exists as defense-in-depth (see
    // workspacesStoreItemReorder.spec.ts).
    const workspaces = [
      makeWorkspace('ws_a', 'A', [makeItem('item1', '1'), makeItem('item2', '2')]),
    ]
    const wrapper = mount(ProjectsList, {
      props: { workspace: workspaces[0]!, activeWorkspaceItemId: null },
      attachTo: document.body,
      global: { stubs: { WorkspaceItem: WorkspaceItemStub } },
    })
    await nextTick()

    const items = findDraggableItems(wrapper)
    const dt = makeDragStore()

    // Drag item1 onto item1 (same slot).
    items[0]!.element.dispatchEvent(makeDragEvent('dragstart', dt))
    items[0]!.element.dispatchEvent(makeDragEvent('drop', dt))

    expect(wrapper.emitted('reorderWorkspaceItems')).toBeUndefined()

    wrapper.unmount()
  })

  it('is a no-op (no emit) when an item is dropped on an item from a different workspace', async () => {
    // Cross-workspace drop is out of scope for this plan; the handler must silently no-op (no event
    // emitted) so the source workspace's order stays intact and no API call is made for a drop the
    // backend would reject.
    const workspaces = [
      makeWorkspace('ws_a', 'A', [makeItem('item1', '1'), makeItem('item2', '2')]),
      makeWorkspace('ws_b', 'B', [makeItem('item3', '3'), makeItem('item4', '4')]),
    ]
    const wrapper = mount(ProjectsList, {
      props: { workspace: workspaces[0]!, activeWorkspaceItemId: null },
      attachTo: document.body,
      global: { stubs: { WorkspaceItem: WorkspaceItemStub } },
    })
    await nextTick()

    const items = findDraggableItems(wrapper)
    // ProjectsList renders only the SELECTED workspace now, so only
    // ws_a's items are in the DOM.
    expect(items.length).toBe(2)

    // Drag item1 (workspace A) onto item2 with a FORGED foreign workspace id — ProjectsList can't
    // render ws_b, but the guard only reads `data-workspace-id` off the target <li>, so this still
    // exercises the cross-workspace no-op.
    const dt = makeDragStore()
    items[1]!.element.setAttribute('data-workspace-id', 'ws_b')
    items[0]!.element.dispatchEvent(makeDragEvent('dragstart', dt))
    items[1]!.element.dispatchEvent(makeDragEvent('drop', dt))

    expect(wrapper.emitted('reorderWorkspaceItems')).toBeUndefined()

    wrapper.unmount()
  })

  it('inserts the source BEFORE the target when dropped in the TOP half of the target row (top-to-bottom)', async () => {
    // Regression test for the top-to-bottom off-by-one bug.
    //
    // Before the fix, `handleItemDrop` did:
    //   splice(fromIdx, 1)
    //   splice(toIdx, 0, moved)
    // where `toIdx` came from the ORIGINAL array. When the source
    // was at a LOWER index than the target (toIdx > fromIdx), the
    // target row's index in the modified array had shifted left by
    // 1 — so inserting at the original `toIdx` placed the source 1
    // position AFTER the target, not at it.
    //
    // Example: [A, B, C, D, E], drag A onto D.
    //   Buggy:  splice(0, 1) + splice(3, 0, A) → [B, C, D, A, E]
    //                                          (A lands AFTER D)
    //   Fixed:  splice(0, 1) + splice(2, 0, A) → [B, C, A, D, E]
    //                                          (A lands BEFORE D)
    //
    // The fix uses the cursor's Y position to decide "before" vs
    // "after" the target row, which is the standard Trello/Jira UX.
    // clientY=0 maps to the top half in JSDOM (see makeDragEvent).
    const workspaces = [
      makeWorkspace('ws_a', 'A', [
        makeItem('item1', '1'),
        makeItem('item2', '2'),
        makeItem('item3', '3'),
        makeItem('item4', '4'),
        makeItem('item5', '5'),
      ]),
    ]
    const wrapper = mount(ProjectsList, {
      props: { workspace: workspaces[0]!, activeWorkspaceItemId: null },
      attachTo: document.body,
      global: { stubs: { WorkspaceItem: WorkspaceItemStub } },
    })
    await nextTick()

    const items = findDraggableItems(wrapper)
    expect(items.length).toBe(5)

    // Drag item1 (idx 0) onto item4 (idx 3), drop in top half of
    // item4 (clientY=0). Expected: item1 ends up BEFORE item4.
    const sourceItem = items[0]!
    const targetItem = items[3]!

    const dt = makeDragStore()
    sourceItem.element.dispatchEvent(makeDragEvent('dragstart', dt, 0))
    targetItem.element.dispatchEvent(makeDragEvent('dragover', dt, 0))
    targetItem.element.dispatchEvent(makeDragEvent('drop', dt, 0))

    const emitted = wrapper.emitted('reorderWorkspaceItems')
    expect(emitted).toBeDefined()
    expect(emitted).toHaveLength(1)
    expect(emitted![0]![0]).toBe('ws_a')
    expect(emitted![0]![1]).toEqual(['item2', 'item3', 'item1', 'item4', 'item5'])

    wrapper.unmount()
  })

  it('inserts the source AFTER the target when dropped in the BOTTOM half of the target row (top-to-bottom)', async () => {
    // Counterpart of the previous test — confirms the cursor-Y
    // toggle works. clientY=1 maps to the bottom half in JSDOM.
    const workspaces = [
      makeWorkspace('ws_a', 'A', [
        makeItem('item1', '1'),
        makeItem('item2', '2'),
        makeItem('item3', '3'),
        makeItem('item4', '4'),
        makeItem('item5', '5'),
      ]),
    ]
    const wrapper = mount(ProjectsList, {
      props: { workspace: workspaces[0]!, activeWorkspaceItemId: null },
      attachTo: document.body,
      global: { stubs: { WorkspaceItem: WorkspaceItemStub } },
    })
    await nextTick()

    const items = findDraggableItems(wrapper)

    // Drag item1 (idx 0) onto item4 (idx 3), drop in bottom half of
    // item4 (clientY=1). Expected: item1 ends up AFTER item4.
    const sourceItem = items[0]!
    const targetItem = items[3]!

    const dt = makeDragStore()
    sourceItem.element.dispatchEvent(makeDragEvent('dragstart', dt, 1))
    targetItem.element.dispatchEvent(makeDragEvent('dragover', dt, 1))
    targetItem.element.dispatchEvent(makeDragEvent('drop', dt, 1))

    const emitted = wrapper.emitted('reorderWorkspaceItems')
    expect(emitted).toBeDefined()
    expect(emitted![0]![1]).toEqual(['item2', 'item3', 'item4', 'item1', 'item5'])

    wrapper.unmount()
  })

  it('inserts the source BEFORE the target when dropped in the TOP half of the target row (bottom-to-top)', async () => {
    // Mirrors the first regression test but in the opposite drag direction.

    // Existing tests already covered this case (the bottom-to-top direction happened to give the
    // right result even with the buggy algorithm), but the test is included here to lock in the new
    // explicit semantics so a future refactor can't silently regress either direction.
    const workspaces = [
      makeWorkspace('ws_a', 'A', [
        makeItem('item1', '1'),
        makeItem('item2', '2'),
        makeItem('item3', '3'),
        makeItem('item4', '4'),
        makeItem('item5', '5'),
      ]),
    ]
    const wrapper = mount(ProjectsList, {
      props: { workspace: workspaces[0]!, activeWorkspaceItemId: null },
      attachTo: document.body,
      global: { stubs: { WorkspaceItem: WorkspaceItemStub } },
    })
    await nextTick()

    const items = findDraggableItems(wrapper)

    // Drag item5 (idx 4) onto item2 (idx 1), drop in top half of
    // item2 (clientY=0). Expected: item5 ends up BEFORE item2.
    const sourceItem = items[4]!
    const targetItem = items[1]!

    const dt = makeDragStore()
    sourceItem.element.dispatchEvent(makeDragEvent('dragstart', dt, 0))
    targetItem.element.dispatchEvent(makeDragEvent('dragover', dt, 0))
    targetItem.element.dispatchEvent(makeDragEvent('drop', dt, 0))

    const emitted = wrapper.emitted('reorderWorkspaceItems')
    expect(emitted).toBeDefined()
    expect(emitted![0]![1]).toEqual(['item1', 'item5', 'item2', 'item3', 'item4'])

    wrapper.unmount()
  })

  it('inserts the source AFTER the target when dropped in the BOTTOM half of the target row (bottom-to-top)', async () => {
    // Counterpart of the bottom-to-top top-half test.
    const workspaces = [
      makeWorkspace('ws_a', 'A', [
        makeItem('item1', '1'),
        makeItem('item2', '2'),
        makeItem('item3', '3'),
        makeItem('item4', '4'),
        makeItem('item5', '5'),
      ]),
    ]
    const wrapper = mount(ProjectsList, {
      props: { workspace: workspaces[0]!, activeWorkspaceItemId: null },
      attachTo: document.body,
      global: { stubs: { WorkspaceItem: WorkspaceItemStub } },
    })
    await nextTick()

    const items = findDraggableItems(wrapper)

    // Drag item5 (idx 4) onto item2 (idx 1), drop in bottom half of
    // item2 (clientY=1). Expected: item5 ends up AFTER item2.
    const sourceItem = items[4]!
    const targetItem = items[1]!

    const dt = makeDragStore()
    sourceItem.element.dispatchEvent(makeDragEvent('dragstart', dt, 1))
    targetItem.element.dispatchEvent(makeDragEvent('dragover', dt, 1))
    targetItem.element.dispatchEvent(makeDragEvent('drop', dt, 1))

    const emitted = wrapper.emitted('reorderWorkspaceItems')
    expect(emitted).toBeDefined()
    expect(emitted![0]![1]).toEqual(['item1', 'item2', 'item5', 'item3', 'item4'])

    wrapper.unmount()
  })

  it('swaps adjacent items when the source is dropped in the BOTTOM half of the target row', async () => {
    // Adjacent edge case. With [A, B, C], drag B onto C and drop in the bottom half — expected
    // result is [A, C, B] (swap).

    // The OLD buggy algorithm also produced [A, C, B] for this case, but the new algorithm gets
    // there for a different reason (explicit "insert after target" semantics). This test pins the
    // new behavior so a future change can't quietly break it.
    const workspaces = [
      makeWorkspace('ws_a', 'A', [
        makeItem('item1', 'A'),
        makeItem('item2', 'B'),
        makeItem('item3', 'C'),
      ]),
    ]
    const wrapper = mount(ProjectsList, {
      props: { workspace: workspaces[0]!, activeWorkspaceItemId: null },
      attachTo: document.body,
      global: { stubs: { WorkspaceItem: WorkspaceItemStub } },
    })
    await nextTick()

    const items = findDraggableItems(wrapper)

    const dt = makeDragStore()
    items[1]!.element.dispatchEvent(makeDragEvent('dragstart', dt, 1))
    items[2]!.element.dispatchEvent(makeDragEvent('dragover', dt, 1))
    items[2]!.element.dispatchEvent(makeDragEvent('drop', dt, 1))

    const emitted = wrapper.emitted('reorderWorkspaceItems')
    expect(emitted).toBeDefined()
    expect(emitted![0]![1]).toEqual(['item1', 'item3', 'item2'])

    wrapper.unmount()
  })

  it('shows a TOP-line drop indicator when the cursor is in the TOP half of the target row', async () => {
    // Visual-feedback contract test. After the fix, the drop indicator must show WHERE the drop
    // will land — a top-line means "insert before", a bottom-line means "insert after".

    // Without this, the user can't see that a top-to-bottom drop in the top half will land BEFORE
    // the target row (vs the pre-fix behavior of landing one slot too far down).

    // The test pins the boxShadow string so a future regression that removes the
    // top-line/bottom-line distinction fails here.
    const workspaces = [
      makeWorkspace('ws_a', 'A', [makeItem('item1', '1'), makeItem('item2', '2')]),
    ]
    const wrapper = mount(ProjectsList, {
      props: { workspace: workspaces[0]!, activeWorkspaceItemId: null },
      attachTo: document.body,
      global: { stubs: { WorkspaceItem: WorkspaceItemStub } },
    })
    await nextTick()

    const items = findDraggableItems(wrapper)
    const dt = makeDragStore()

    // Drag item1 over item2, cursor in top half (clientY=0).
    items[0]!.element.dispatchEvent(makeDragEvent('dragstart', dt, 0))
    items[1]!.element.dispatchEvent(makeDragEvent('dragover', dt, 0))
    await nextTick()

    const target = items[1]!.element as HTMLElement
    expect(target.style.boxShadow).toBe('0 -2px 0 0 var(--color-violet)')

    wrapper.unmount()
  })

  it('shows a BOTTOM-line drop indicator when the cursor is in the BOTTOM half of the target row', async () => {
    // Counterpart of the top-line test.
    const workspaces = [
      makeWorkspace('ws_a', 'A', [makeItem('item1', '1'), makeItem('item2', '2')]),
    ]
    const wrapper = mount(ProjectsList, {
      props: { workspace: workspaces[0]!, activeWorkspaceItemId: null },
      attachTo: document.body,
      global: { stubs: { WorkspaceItem: WorkspaceItemStub } },
    })
    await nextTick()

    const items = findDraggableItems(wrapper)
    const dt = makeDragStore()

    // Drag item1 over item2, cursor in bottom half (clientY=1).
    items[0]!.element.dispatchEvent(makeDragEvent('dragstart', dt, 1))
    items[1]!.element.dispatchEvent(makeDragEvent('dragover', dt, 1))
    await nextTick()

    const target = items[1]!.element as HTMLElement
    expect(target.style.boxShadow).toBe('0 2px 0 0 var(--color-violet)')

    wrapper.unmount()
  })

  it('clears the dragging state on dragend (no opacity-50 after dragend)', async () => {
    // The dragend handler must clear `draggingItemId` so the
    // dimmed source <li> goes back to normal. Without this, the
    // row would stay dimmed forever after every drag.
    const workspaces = [
      makeWorkspace('ws_a', 'A', [makeItem('item1', '1'), makeItem('item2', '2')]),
    ]
    const wrapper = mount(ProjectsList, {
      props: { workspace: workspaces[0]!, activeWorkspaceItemId: null },
      attachTo: document.body,
      global: { stubs: { WorkspaceItem: WorkspaceItemStub } },
    })
    await nextTick()

    const items = findDraggableItems(wrapper)
    const source = items[0]!.element as HTMLElement
    const dt = makeDragStore()

    // Pre-drag: no opacity-50.
    expect(source.className.includes('opacity-50')).toBe(false)

    // During drag: source is dimmed.
    source.dispatchEvent(makeDragEvent('dragstart', dt))
    await nextTick()
    const sourceDuring = findDraggableItems(wrapper)[0]!.element as HTMLElement
    expect(sourceDuring.className.includes('opacity-50')).toBe(true)

    // After dragend: opacity-50 is removed.
    const endEvent = new Event('dragend', { bubbles: true })
    findDraggableItems(wrapper)[0]!.element.dispatchEvent(endEvent)
    await nextTick()
    const sourceAfter = findDraggableItems(wrapper)[0]!.element as HTMLElement
    expect(sourceAfter.className.includes('opacity-50')).toBe(false)

    wrapper.unmount()
  })
})
