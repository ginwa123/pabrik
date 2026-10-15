/** Behavioural tests for `useLayerDragDrop` composable — the pure state machine that backs the
 * LayersPanel drag affordance. Multi-drag semantics: when the dragged row is in `selectedIds`, the
 * WHOLE selection is dragged together (per D4 of the plan). */
/** Per-element cycle preflight rejects target rows that are themselves OR a descendant of any
 * dragged element. Plan: docs/superpowers/plans/2026-07-30-design-layer-drag-join-or-leave-group.md
 * (Chunk 3 Task 3.1) */
import { describe, expect, it } from 'vitest'

import { useLayerDragDrop, TOP_LEVEL_SENTINEL } from '../composables/useLayerDragDrop'
import type { DesignElement } from '../api'

// ─── Fixtures ──────────────────────────────────────────────────────────────
function makeElement(
  id: string,
  type: 'rectangle' | 'frame' | 'group' | 'text' | 'image' | 'ellipse',
  parent_id: string | null = null,
): DesignElement {
  return {
    id,
    page_id: 'page_1',
    type,
    parent_id,
    name: id,
    x: 0,
    y: 0,
    width: 100,
    height: 100,
    z_index: 0,
    position: 0,
    fill: '',
    stroke: '',
    stroke_width: 0,
    corner_radius: 0,
    rotation: 0,
    opacity: 1.0,
    text_content: '',
    text_style: '',
    image_url: '',
    file_path: '',
    created_at: '',
    updated_at: '',
  }
}

const STANDARD_ELEMENTS = () => [
  makeElement('leaf_top_1', 'rectangle'),
  makeElement('leaf_top_2', 'rectangle'),
  makeElement('group_a', 'group'),
  makeElement('leaf_in_a', 'rectangle', 'group_a'),
  makeElement('group_b', 'group', 'group_a'), // grandchild of group_a
]

// ─── Tests ────────────────────────────────────────────────────────────────
describe('useLayerDragDrop — single-element drag', () => {
  it('onDragStart with empty selection records the dragged element id', () => {
    const { handlers, state } = useLayerDragDrop({
      elements: STANDARD_ELEMENTS(),
      selectedIds: () => new Set<string>(),
    })
    handlers.onDragStart('leaf_top_1', new Event('dragstart'))
    expect(state.draggedIds.value).toEqual(new Set(['leaf_top_1']))
  })

  it('isBeingDragged reports true ONLY for the dragged row', () => {
    const { handlers, state } = useLayerDragDrop({
      elements: STANDARD_ELEMENTS(),
      selectedIds: () => new Set<string>(),
    })
    handlers.onDragStart('leaf_top_1', new Event('dragstart'))
    expect(state.isBeingDragged('leaf_top_1')).toBe(true)
    expect(state.isBeingDragged('leaf_top_2')).toBe(false)
    expect(state.isBeingDragged('group_a')).toBe(false)
  })
})

describe('useLayerDragDrop — multi-element drag', () => {
  it('onDragStart on a selected row records ALL selected ids (not just the dragged one)', () => {
    const { handlers, state } = useLayerDragDrop({
      elements: STANDARD_ELEMENTS(),
      selectedIds: () => new Set(['leaf_top_1', 'leaf_top_2', 'group_a']),
    })
    handlers.onDragStart('leaf_top_1', new Event('dragstart'))
    expect(state.draggedIds.value).toEqual(
      new Set(['leaf_top_1', 'leaf_top_2', 'group_a']),
    )
  })

  it('onDragStart on an unselected row records ONLY that row (single-element shortcut)', () => {
    const { handlers, state } = useLayerDragDrop({
      elements: STANDARD_ELEMENTS(),
      selectedIds: () => new Set(['leaf_top_1']),
    })
    handlers.onDragStart('leaf_top_2', new Event('dragstart'))
    expect(state.draggedIds.value).toEqual(new Set(['leaf_top_2']))
  })

  it('every selected row gets the dragging class during a multi-drag', () => {
    const { handlers, state } = useLayerDragDrop({
      elements: STANDARD_ELEMENTS(),
      selectedIds: () => new Set(['leaf_top_1', 'leaf_top_2', 'group_a']),
    })
    handlers.onDragStart('leaf_top_1', new Event('dragstart'))
    expect(state.isBeingDragged('leaf_top_1')).toBe(true)
    expect(state.isBeingDragged('leaf_top_2')).toBe(true)
    expect(state.isBeingDragged('group_a')).toBe(true)
    expect(state.isBeingDragged('leaf_in_a')).toBe(false)
    expect(state.isBeingDragged('group_b')).toBe(false)
  })
})

describe('useLayerDragDrop — drop resolution', () => {
  it('onDrop on a group resolves to { elementIds: [...], newParentId: group.id }', () => {
    const { handlers } = useLayerDragDrop({
      elements: STANDARD_ELEMENTS(),
      selectedIds: () => new Set(['leaf_top_1', 'leaf_top_2']),
    })
    handlers.onDragStart('leaf_top_1', new Event('dragstart'))
    const result = handlers.onDrop('group_a', new Event('drop'))
    expect(result).toEqual({
      elementIds: ['leaf_top_1', 'leaf_top_2'],
      newParentId: 'group_a',
    })
  })

  it('onDrop on a top-level zone resolves to newParentId: null (leave any group)', () => {
    const { handlers } = useLayerDragDrop({
      elements: STANDARD_ELEMENTS(),
      selectedIds: () => new Set(['group_a', 'leaf_in_a']),
    })
    handlers.onDragStart('group_a', new Event('dragstart'))
    const result = handlers.onDrop(TOP_LEVEL_SENTINEL, new Event('drop'))
    expect(result).toEqual({
      elementIds: ['group_a', 'leaf_in_a'],
      newParentId: null,
    })
  })

  it('drop result is null when no drag is in flight', () => {
    const { handlers } = useLayerDragDrop({
      elements: STANDARD_ELEMENTS(),
      selectedIds: () => new Set<string>(),
    })
    expect(handlers.onDrop('group_a', new Event('drop'))).toBe(null)
  })

  it('onDragEnd clears the drag state', () => {
    const { handlers, state } = useLayerDragDrop({
      elements: STANDARD_ELEMENTS(),
      selectedIds: () => new Set(['leaf_top_1', 'leaf_top_2']),
    })
    handlers.onDragStart('leaf_top_1', new Event('dragstart'))
    handlers.onDragEnd(new Event('dragend'))
    expect(state.draggedIds.value).toEqual(new Set())
    expect(state.hoveredDropId.value).toBe(null)
  })

  it('drop result preserves input order from draggedIds', () => {
    const { handlers } = useLayerDragDrop({
      elements: STANDARD_ELEMENTS(),
      selectedIds: () => new Set(['leaf_top_1', 'leaf_top_2']),
    })
    handlers.onDragStart('leaf_top_1', new Event('dragstart'))
    const result = handlers.onDrop('group_a', new Event('drop'))!
    // The result.elementIds array order matches the order they were
    // added to the Set (insertion order).
    expect(result.elementIds).toEqual(['leaf_top_1', 'leaf_top_2'])
  })
})

describe('useLayerDragDrop — cycle prevention', () => {
  it('marks target invalid when target is in the descendant chain of ANY dragged element', () => {
    // Drag group_a (which contains group_b) — group_b is its descendant
    const { handlers, state } = useLayerDragDrop({
      elements: STANDARD_ELEMENTS(),
      selectedIds: () => new Set(['group_a']),
    })
    handlers.onDragStart('group_a', new Event('dragstart'))
    handlers.onDragOver('group_b', new Event('dragover'))
    expect(state.isDropTarget('group_b')).toBe(false)
  })

  it('blocks dropping a group onto itself', () => {
    const { handlers, state } = useLayerDragDrop({
      elements: STANDARD_ELEMENTS(),
      selectedIds: () => new Set(['group_a']),
    })
    handlers.onDragStart('group_a', new Event('dragstart'))
    handlers.onDragOver('group_a', new Event('dragover'))
    expect(state.isDropTarget('group_a')).toBe(false)
  })

  it('blocks dropping a mixed selection onto one of its own members (cycle)', () => {
    // Selecting [group_a, leaf_in_a] — group_a is an ancestor of
    // leaf_in_a, so dropping on leaf_in_a would create a cycle.
    const { handlers, state } = useLayerDragDrop({
      elements: STANDARD_ELEMENTS(),
      selectedIds: () => new Set(['group_a', 'leaf_in_a']),
    })
    handlers.onDragStart('group_a', new Event('dragstart'))
    handlers.onDragOver('leaf_in_a', new Event('dragover'))
    expect(state.isDropTarget('leaf_in_a')).toBe(false)
  })

  it('allows dropping a nested element onto its own parent (no cycle)', () => {
    const { handlers, state } = useLayerDragDrop({
      elements: STANDARD_ELEMENTS(),
      selectedIds: () => new Set(['leaf_in_a']),
    })
    handlers.onDragStart('leaf_in_a', new Event('dragstart'))
    handlers.onDragOver('group_a', new Event('dragover'))
    expect(state.isDropTarget('group_a')).toBe(true)
  })

  it('rejects leaf-type rows as drop targets (only group/frame accept children)', () => {
    const { handlers, state } = useLayerDragDrop({
      elements: STANDARD_ELEMENTS(),
      selectedIds: () => new Set(['leaf_top_1']),
    })
    handlers.onDragStart('leaf_top_1', new Event('dragstart'))
    handlers.onDragOver('leaf_top_2', new Event('dragover'))
    expect(state.isDropTarget('leaf_top_2')).toBe(false)
  })

  it('always allows dropping on the top-level sentinel (no cycle possible)', () => {
    const { handlers, state } = useLayerDragDrop({
      elements: STANDARD_ELEMENTS(),
      selectedIds: () => new Set(['group_a']),
    })
    handlers.onDragStart('group_a', new Event('dragstart'))
    handlers.onDragOver(TOP_LEVEL_SENTINEL, new Event('dragover'))
    expect(state.isDropTarget(TOP_LEVEL_SENTINEL)).toBe(true)
  })
})