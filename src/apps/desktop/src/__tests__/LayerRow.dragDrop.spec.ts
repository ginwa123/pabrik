/** Behavioural tests for `<LayerRow>` drag-and-drop wire (Chunk 4
 * Task 4.1).
 * Plan: docs/superpowers/plans/2026-07-30-design-layer-drag-join-or-leave-group.md */
import { mount } from '@vue/test-utils'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'

import LayerRow from '../components/design/LayerRow.vue'

function makeNode(id: string, type: 'rectangle' | 'group' | 'frame' = 'rectangle') {
  return {
    element: {
      id,
      page_id: 'page_1',
      type,
      parent_id: '',
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
    },
    children: [],
  }
}

describe('<LayerRow> drag-and-drop', () => {
  beforeEach(() => setActivePinia(createPinia()))

  it('the row DOM has draggable=true when not readonly', () => {
    const wrapper = mount(LayerRow, {
      props: {
        node: makeNode('a'),
        depth: 0,
        selectedIds: ['a'],
        readonly: false,
        collapsedIds: new Set<string>(),
      },
    })
    // mount(LayerRow) wraps the component in an app root; the
    // LayerRow's own root is its first child div.
    const root = wrapper.find('div').element as HTMLElement
    expect(root.draggable).toBe(true)
  })

  it('readonly rows are not draggable', () => {
    const wrapper = mount(LayerRow, {
      props: {
        node: makeNode('a'),
        depth: 0,
        selectedIds: [],
        readonly: true,
        collapsedIds: new Set<string>(),
      },
    })
    const root = wrapper.find('div').element as HTMLElement
    expect(root.draggable).toBe(false)
  })

  it('action buttons (▲▼×) are NOT draggable (prevent dragstart from clicks)', () => {
    const wrapper = mount(LayerRow, {
      props: {
        node: makeNode('a'),
        depth: 0,
        selectedIds: [],
        readonly: false,
        collapsedIds: new Set<string>(),
      },
    })
    // Buttons render as <button>, so attributes('draggable') is fine
    // for them — but only on the <button>, not the wrapper.
    expect(
      (wrapper.find('[data-testid="design-layer-reorder-up-a"]').element as HTMLElement)
        .draggable,
    ).toBe(false)
    expect(
      (wrapper.find('[data-testid="design-layer-delete-a"]').element as HTMLElement)
        .draggable,
    ).toBe(false)
  })

  it('calls the onLayerDragStart prop with the row element id when dragstart fires', async () => {
    const onLayerDragStart = vi.fn()
    const wrapper = mount(LayerRow, {
      props: {
        node: makeNode('a'),
        depth: 0,
        selectedIds: [],
        readonly: false,
        collapsedIds: new Set<string>(),
        onLayerDragStart,
      },
    })
    const root = wrapper.find('div')
    await root.trigger('dragstart', { dataTransfer: {} })
    expect(onLayerDragStart).toHaveBeenCalledWith('a', expect.anything())
  })

  it('calls the onLayerDragEnd prop on dragend', async () => {
    const onLayerDragEnd = vi.fn()
    const wrapper = mount(LayerRow, {
      props: {
        node: makeNode('a'),
        depth: 0,
        selectedIds: [],
        readonly: false,
        collapsedIds: new Set<string>(),
        onLayerDragEnd,
      },
    })
    await wrapper.find('div').trigger('dragend')
    expect(onLayerDragEnd).toHaveBeenCalled()
  })

  it('calls the onLayerDrop prop on drop with the row element id', async () => {
    const onLayerDrop = vi.fn()
    const wrapper = mount(LayerRow, {
      props: {
        node: makeNode('a'),
        depth: 0,
        selectedIds: [],
        readonly: false,
        collapsedIds: new Set<string>(),
        onLayerDrop,
      },
    })
    await wrapper.find('div').trigger('drop', { dataTransfer: {} })
    expect(onLayerDrop).toHaveBeenCalledWith('a', expect.anything())
  })

  it('applies the drop-target visual class when isDropTarget prop is true', () => {
    const wrapper = mount(LayerRow, {
      props: {
        node: makeNode('group_x', 'group'),
        depth: 0,
        selectedIds: [],
        readonly: false,
        collapsedIds: new Set<string>(),
        isDropTarget: true,
      },
    })
    expect(wrapper.find('div').classes()).toContain('layer-row-drop-target')
  })

  it('applies the drop-target-blocked visual class when isDropTargetBlocked is true', () => {
    const wrapper = mount(LayerRow, {
      props: {
        node: makeNode('group_x', 'group'),
        depth: 0,
        selectedIds: [],
        readonly: false,
        collapsedIds: new Set<string>(),
        isDropTarget: false,
        isDropTargetBlocked: true,
      },
    })
    expect(wrapper.find('div').classes()).toContain('layer-row-drop-target-blocked')
  })

  it('applies the dragging class when isBeingDragged prop is true', () => {
    const wrapper = mount(LayerRow, {
      props: {
        node: makeNode('a'),
        depth: 0,
        selectedIds: [],
        readonly: false,
        collapsedIds: new Set<string>(),
        isBeingDragged: true,
      },
    })
    expect(wrapper.find('div').classes()).toContain('layer-row-dragging')
  })

  it('kind="drop-zone" rows are NOT draggable (top-level drop targets)', () => {
    const wrapper = mount(LayerRow, {
      props: {
        kind: 'drop-zone',
        node: makeNode('drop_zone_sentinel'),
        depth: 0,
        selectedIds: [],
        readonly: false,
        collapsedIds: new Set<string>(),
      },
    })
    const root = wrapper.find('div').element as HTMLElement
    expect(root.draggable).toBe(false)
  })
})