/** Behavioural mount tests for LayersPanel.vue. The component renders the vertical list of elements
 * on the active page (ordered top-to-bottom by z-index) with per-row select / up / down / delete
 * buttons. */
import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest'
import { mount, type VueWrapper } from '@vue/test-utils'
import { setActivePinia, createPinia } from 'pinia'
import { nextTick } from 'vue'

import LayersPanel from '../components/design/LayersPanel.vue'
import type { DesignElement } from '../api'

// ─── Behavioral mount tests (Chunk 7 — tree render) ────────────────────────
function makeElement(overrides: Partial<DesignElement> = {}): DesignElement {
  return {
    id: 'elem_1',
    page_id: 'page_1',
    name: 'Element 1',
    type: 'rectangle',
    x: 0,
    y: 0,
    width: 100,
    height: 50,
    rotation: 0,
    fill: '#ffffff',
    stroke: '',
    stroke_width: 1,
    corner_radius: 0,
    opacity: 1,
    text_content: '',
    text_style: '',
    image_url: '',
    file_path: '',
    parent_id: null,
    z_index: 0,
    position: 0,
    created_at: '2026-07-28 12:00:00',
    updated_at: '2026-07-28 12:00:00',
    ...overrides,
  }
}

function mountPanel(props: { elements: DesignElement[]; selectedIds?: string[]; readonly?: boolean }): VueWrapper {
  return mount(LayersPanel, {
    props: {
      elements: props.elements,
      selectedIds: props.selectedIds ?? [],
      readonly: props.readonly ?? false,
    },
  })
}

describe('LayersPanel.vue — flat list (no parent_id set)', () => {
  let wrapper: VueWrapper | null = null

  beforeEach(() => {
    setActivePinia(createPinia())
  })

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    vi.restoreAllMocks()
  })

  it('renders one row per element when no element has parent_id', () => {
    const elements = [
      makeElement({ id: 'elem_a', z_index: 2, position: 0 }),
      makeElement({ id: 'elem_b', z_index: 1, position: 0 }),
      makeElement({ id: 'elem_c', z_index: 0, position: 0 }),
    ]
    wrapper = mountPanel({ elements })
    const rows = wrapper.findAll('[data-testid^="design-layer-elem_"]')
    // Three rows, all top-level.
    expect(rows).toHaveLength(3)
  })

  it('renders top-level rows when parent_id is the empty string (the wire form of SQL NULL from the backend)', () => {
    // The backend's design_model.listElements uses COALESCE(de.parent_id, '') AS parent_id so
    // top-level elements (parent_id IS NULL) arrive at the frontend with parent_id === "" — NOT
    // null, NOT undefined.
    const elements = [
      makeElement({ id: 'elem_backdrop', name: 'backdrop', type: 'rectangle', z_index: 0, position: 0, parent_id: '' }),
      makeElement({ id: 'elem_card', name: 'dialog-card', type: 'frame', z_index: 0, position: 1, parent_id: '' }),
    ]
    wrapper = mountPanel({ elements })
    const rows = wrapper.findAll('[data-testid^="design-layer-elem_"]')
    expect(rows).toHaveLength(2)
  })
})

describe('LayersPanel.vue — tree render (parent_id set)', () => {
  let wrapper: VueWrapper | null = null

  beforeEach(() => {
    setActivePinia(createPinia())
  })

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    vi.restoreAllMocks()
  })

  it('renders parent and its children in the tree (parent before children)', async () => {
    // Tree: group (elem_g) contains two children (elem_a, elem_b).
    const elements = [
      makeElement({ id: 'elem_g', type: 'group', z_index: 3, position: 0 }),
      makeElement({ id: 'elem_a', z_index: 2, position: 0, parent_id: 'elem_g' }),
      makeElement({ id: 'elem_b', z_index: 1, position: 0, parent_id: 'elem_g' }),
    ]
    wrapper = mountPanel({ elements })
    await nextTick()

    const rows = wrapper.findAll('[data-testid^="design-layer-elem_"]')
    expect(rows).toHaveLength(3)

    // The group appears first (highest z_index). Its children appear
    // below it (nested under the group).
    const testIds = rows.map((r) => r.attributes('data-testid'))
    // Group testid is at index 0 (top of the panel).
    expect(testIds[0]).toBe('design-layer-elem_g')
    // The two children are below the group in the walk.
    expect(testIds).toContain('design-layer-elem_a')
    expect(testIds).toContain('design-layer-elem_b')
  })

  it('indents children by depth * 16px', async () => {
    const elements = [
      makeElement({ id: 'elem_g', type: 'group', z_index: 3 }),
      makeElement({ id: 'elem_a', z_index: 2, parent_id: 'elem_g' }),
      makeElement({ id: 'elem_b', z_index: 1, parent_id: 'elem_g' }),
    ]
    wrapper = mountPanel({ elements })
    await nextTick()

    const groupRow = wrapper.find('[data-testid="design-layer-elem_g"]')
    const childRowA = wrapper.find('[data-testid="design-layer-elem_a"]')

    const groupStyle = groupRow.attributes('style') ?? ''
    const childStyle = childRowA.attributes('style') ?? ''

    // Top-level row: paddingLeft = 0px
    expect(groupStyle).toMatch(/padding-left:\s*0(?:px)?/)
    // Nested row: paddingLeft = 16px (depth=1 × 16)
    expect(childStyle).toMatch(/padding-left:\s*16(?:px)?/)
  })

  it('indents grandchildren by 32px (depth=2)', async () => {
    // 3-level tree: group → subgroup → leaf
    const elements = [
      makeElement({ id: 'elem_g', type: 'group', z_index: 3 }),
      makeElement({ id: 'elem_sg', type: 'group', z_index: 2, parent_id: 'elem_g' }),
      makeElement({ id: 'elem_leaf', z_index: 1, parent_id: 'elem_sg' }),
    ]
    wrapper = mountPanel({ elements })
    await nextTick()

    const leaf = wrapper.find('[data-testid="design-layer-elem_leaf"]')
    const style = leaf.attributes('style') ?? ''
    expect(style).toMatch(/padding-left:\s*32(?:px)?/)
  })

  it('clicking the chevron on a parent toggles children visibility', async () => {
    const elements = [
      makeElement({ id: 'elem_g', type: 'group', z_index: 2 }),
      makeElement({ id: 'elem_a', z_index: 1, parent_id: 'elem_g' }),
      makeElement({ id: 'elem_b', z_index: 0, parent_id: 'elem_g' }),
    ]
    wrapper = mountPanel({ elements })
    await nextTick()

    // Initially: all 3 rows visible (parent + 2 children).
    expect(wrapper.findAll('[data-testid^="design-layer-elem_"]')).toHaveLength(3)

    // Find the chevron button. The button is identified by the
    // design-layer-toggle-${element.id} data-testid selector.
    const toggleBtn = wrapper.find('[data-testid="design-layer-toggle-elem_g"]')
    expect(toggleBtn.exists()).toBe(true)

    await toggleBtn.trigger('click')
    await nextTick()

    // After toggle: only the parent row visible (children hidden).
    const rowsAfter = wrapper.findAll('[data-testid^="design-layer-elem_"]')
    expect(rowsAfter).toHaveLength(1)
    expect(rowsAfter[0]?.attributes('data-testid')).toBe('design-layer-elem_g')

    // Click again: children re-appear.
    await toggleBtn.trigger('click')
    await nextTick()
    expect(wrapper.findAll('[data-testid^="design-layer-elem_"]')).toHaveLength(3)
  })

  it('selectedIds highlights rows across the tree regardless of nesting', async () => {
    const elements = [
      makeElement({ id: 'elem_g', type: 'group', z_index: 2 }),
      makeElement({ id: 'elem_a', z_index: 1, parent_id: 'elem_g' }),
    ]
    wrapper = mountPanel({ elements, selectedIds: ['elem_a'] })
    await nextTick()

    const groupRow = wrapper.find('[data-testid="design-layer-elem_g"]')
    const childRow = wrapper.find('[data-testid="design-layer-elem_a"]')

    // Child row (selected) has the active background color.
    const childStyle = childRow.attributes('style') ?? ''
    expect(childStyle).toContain('background-color')

    // Group row (not selected) does NOT have the active background.
    const groupStyle = groupRow.attributes('style') ?? ''
    // The dim color is applied; the violet "active" bg is not.
    expect(groupStyle).not.toContain('--semantic-active-bg')
  })

  it('delete emit bubbles up from a nested LayerRow', async () => {
    const elements = [
      makeElement({ id: 'elem_g', type: 'group', z_index: 2 }),
      makeElement({ id: 'elem_a', z_index: 1, parent_id: 'elem_g' }),
    ]
    wrapper = mountPanel({ elements })
    await nextTick()

    const deleteBtn = wrapper.find('[data-testid="design-layer-delete-elem_a"]')
    expect(deleteBtn.exists()).toBe(true)

    await deleteBtn.trigger('click')

    const emitted = wrapper.emitted('delete')
    expect(emitted).toBeTruthy()
    expect(emitted?.[0]).toEqual(['elem_a'])
  })

  it('does not render a chevron on leaf elements (no children)', async () => {
    const elements = [
      makeElement({ id: 'elem_g', type: 'group', z_index: 2 }),
      makeElement({ id: 'elem_a', z_index: 1, parent_id: 'elem_g' }),
      // elem_b is a leaf — no parent_id, no children.
      makeElement({ id: 'elem_b', z_index: 0 }),
    ]
    wrapper = mountPanel({ elements })
    await nextTick()

    // elem_g has children → chevron.
    expect(wrapper.find('[data-testid="design-layer-toggle-elem_g"]').exists()).toBe(true)
    // elem_a is a child of elem_g → no chevron of its own (unless
    // it had nested children, which it doesn't).
    expect(wrapper.find('[data-testid="design-layer-toggle-elem_a"]').exists()).toBe(false)
    // elem_b is top-level leaf → no chevron.
    expect(wrapper.find('[data-testid="design-layer-toggle-elem_b"]').exists()).toBe(false)
  })
})

// ─── Drop-zone rows (Chunk 4 Task 4.2 of drag-to-reparent plan) ────────── LayersPanel renders N+1
// top-level drop-zone rows between real elements (one BEFORE the first row + one AFTER every
// top-level row).
describe('LayersPanel.vue — top-level drop-zone rows (must not look like element rows)', () => {
  let wrapper: VueWrapper | null = null

  beforeEach(() => {
    setActivePinia(createPinia())
  })

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    vi.restoreAllMocks()
  })

  it('renders one drop-zone before the first element AND one after every element (N+1 total)', async () => {
    const elements = [
      makeElement({ id: 'elem_a', name: 'A', z_index: 0, position: 0 }),
      makeElement({ id: 'elem_b', name: 'B', z_index: 0, position: 1 }),
      makeElement({ id: 'elem_c', name: 'C', z_index: 0, position: 2 }),
    ]
    wrapper = mountPanel({ elements })
    await nextTick()

    const dropZones = wrapper.findAll('[data-testid="design-layer-drop-zone-top-level"]')
    // 3 elements → 1 before + 3 after = 4 drop zones.
    expect(dropZones).toHaveLength(4)
  })

  it('does NOT render "(unnamed)" text in any drop-zone row', async () => {
    // The bug: LayerRow.vue rendered `node.element.name || '(unnamed)'`
    // for ALL rows including drop zones (which have name: ''). The
    // result: every drop-zone row showed "(unnamed)" in the panel.
    const elements = [
      makeElement({ id: 'elem_a', name: 'A', z_index: 0, position: 0 }),
      makeElement({ id: 'elem_b', name: 'B', z_index: 0, position: 1 }),
    ]
    wrapper = mountPanel({ elements })
    await nextTick()

    const dropZones = wrapper.findAll('[data-testid="design-layer-drop-zone-top-level"]')
    for (const dz of dropZones) {
      expect(dz.text()).not.toContain('(unnamed)')
    }
  })

  it('does NOT render a type icon in any drop-zone row', async () => {
    // Same root cause as above — LayerRow rendered typeIcon(node.element.type)
    // for ALL rows. The drop zone's synthetic element has type: 'rectangle'
    // so it rendered '▭', making the row look like a real rectangle element.
    const elements = [
      makeElement({ id: 'elem_a', name: 'A', z_index: 0, position: 0 }),
    ]
    wrapper = mountPanel({ elements })
    await nextTick()

    // Positive control: the real element row DOES draw an icon, so the
    // absence below is about the drop zone and not about a dead selector.
    const realRows = wrapper.findAll('[data-testid="design-layer-elem_a"]')
    expect(realRows.length).toBeGreaterThan(0)
    expect(realRows.some((row) => row.find('[data-icon]').exists())).toBe(true)

    const dropZones = wrapper.findAll('[data-testid="design-layer-drop-zone-top-level"]')
    expect(dropZones.length).toBeGreaterThan(0)
    for (const dz of dropZones) {
      // LayerRow now draws its type through `UiIcon`, which stamps
      // data-icon on every glyph — one selector covers all 7 types.
      expect(dz.find('[data-icon]').exists()).toBe(false)
    }
  })

  it('does NOT render action buttons (▲ ▼ ×) in any drop-zone row', async () => {
    // Drop zones are inert drop targets — no reorder, no delete.
    const elements = [
      makeElement({ id: 'elem_a', name: 'A', z_index: 0, position: 0 }),
    ]
    wrapper = mountPanel({ elements })
    await nextTick()

    const dropZones = wrapper.findAll('[data-testid="design-layer-drop-zone-top-level"]')
    for (const dz of dropZones) {
      expect(dz.findAll('[data-testid^="design-layer-reorder-up-"]')).toHaveLength(0)
      expect(dz.findAll('[data-testid^="design-layer-reorder-down-"]')).toHaveLength(0)
      expect(dz.findAll('[data-testid^="design-layer-delete-"]')).toHaveLength(0)
    }
  })

  it('does NOT render drop-zone rows when readonly is true (preview mode)', async () => {
    const elements = [
      makeElement({ id: 'elem_a', name: 'A', z_index: 0, position: 0 }),
      makeElement({ id: 'elem_b', name: 'B', z_index: 0, position: 1 }),
    ]
    wrapper = mountPanel({ elements, readonly: true })
    await nextTick()

    // Only the 2 real rows — no drop zones in readonly/preview mode.
    expect(wrapper.findAll('[data-testid="design-layer-drop-zone-top-level"]')).toHaveLength(0)
  })
})
