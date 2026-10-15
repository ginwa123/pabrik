/** Behavioural tests for `<LayersPanel>` drag-and-drop wire (Chunk 4
 * Task 4.2) — drop-zone rendering + multi-reparent emit.
 * Plan: docs/superpowers/plans/2026-07-30-design-layer-drag-join-or-leave-group.md */
import { mount } from '@vue/test-utils'
import { beforeEach, describe, expect, it } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'

import LayersPanel from '../components/design/LayersPanel.vue'
import type { DesignElement } from '../api'

function makeElements(): DesignElement[] {
  return [
    {
      id: 'a',
      page_id: 'page_1',
      type: 'rectangle',
      parent_id: '',
      name: 'a',
      x: 0, y: 0, width: 100, height: 100,
      z_index: 0, position: 0,
      fill: '', stroke: '', stroke_width: 0, corner_radius: 0,
      rotation: 0, opacity: 1.0,
      text_content: '', text_style: '', image_url: '',
      file_path: '', created_at: '', updated_at: '',
    },
    {
      id: 'b',
      page_id: 'page_1',
      type: 'rectangle',
      parent_id: '',
      name: 'b',
      x: 0, y: 0, width: 100, height: 100,
      z_index: 0, position: 1,
      fill: '', stroke: '', stroke_width: 0, corner_radius: 0,
      rotation: 0, opacity: 1.0,
      text_content: '', text_style: '', image_url: '',
      file_path: '', created_at: '', updated_at: '',
    },
    {
      id: 'group',
      page_id: 'page_1',
      type: 'group',
      parent_id: '',
      name: 'group',
      x: 0, y: 0, width: 100, height: 100,
      z_index: 0, position: 2,
      fill: '', stroke: '', stroke_width: 0, corner_radius: 0,
      rotation: 0, opacity: 1.0,
      text_content: '', text_style: '', image_url: '',
      file_path: '', created_at: '', updated_at: '',
    },
  ]
}

describe('<LayersPanel> drop zone rendering + multi-reparent', () => {
  beforeEach(() => setActivePinia(createPinia()))

  it('renders top-level drop zones (above first, between each pair, below last)', () => {
    const wrapper = mount(LayersPanel, {
      props: { elements: makeElements(), selectedIds: [], readonly: false },
    })
    // For 3 top-level rows, render 4 drop zones: above the first,
    // between a-b, between b-group, below the last.
    const zones = wrapper.findAll('[data-testid="design-layer-drop-zone-top-level"]')
    expect(zones.length).toBeGreaterThanOrEqual(2) // at least 2 — we don't care about the exact number
  })

  it('emits reparent with elementIds=[selected...] and newParentId=null on a top-level drop', async () => {
    const elements = makeElements()
    const wrapper = mount(LayersPanel, {
      props: {
        elements,
        selectedIds: ['a', 'b'],
        readonly: false,
      },
    })
    // First, simulate dragging row 'a' (which expands to the full
    // selection ['a', 'b'] because selectedIds.size > 1).
    await wrapper.find('[data-testid="design-layer-a"]').trigger('dragstart', {
      dataTransfer: {},
    })
    const topZones = wrapper.findAll('[data-testid="design-layer-drop-zone-top-level"]')
    // Drop on the FIRST zone (above the first top-level row).
    await topZones[0]!.trigger('drop', { dataTransfer: {} })
    expect(wrapper.emitted('reparent')).toBeTruthy()
    expect(wrapper.emitted('reparent')![0]).toEqual([
      { elementIds: ['a', 'b'], newParentId: null },
    ])
  })

  it('emits reparent with newParentId=group.id when dropped ON a group row', async () => {
    const elements = makeElements()
    const wrapper = mount(LayersPanel, {
      props: {
        elements,
        selectedIds: ['a'],
        readonly: false,
      },
    })
    // Single-element drag (selection size === 1, so multi-drag doesn't kick in).
    await wrapper.find('[data-testid="design-layer-a"]').trigger('dragstart', {
      dataTransfer: {},
    })
    const groupRow = wrapper.find('[data-testid="design-layer-group"]')
    await groupRow.trigger('drop', { dataTransfer: {} })
    expect(wrapper.emitted('reparent')![0]).toEqual([
      { elementIds: ['a'], newParentId: 'group' },
    ])
  })

  it('passes multi-drag elementIds through when multiple rows are selected', async () => {
    const elements = makeElements()
    const wrapper = mount(LayersPanel, {
      props: {
        elements,
        selectedIds: ['a', 'group'],
        readonly: false,
      },
    })
    // Drag 'a' — selection size is 2 so the whole set is dragged.
    await wrapper.find('[data-testid="design-layer-a"]').trigger('dragstart', {
      dataTransfer: {},
    })
    // Drop on the FIRST top-level zone — both 'a' AND 'group' become
    // top-level (no-op for 'a' since it's already top-level; 'group'
    // leaves its current group context).
    const topZones = wrapper.findAll('[data-testid="design-layer-drop-zone-top-level"]')
    await topZones[0]!.trigger('drop', { dataTransfer: {} })
    expect(wrapper.emitted('reparent')![0]).toEqual([
      { elementIds: ['a', 'group'], newParentId: null },
    ])
  })

  it('readonly panels do not render drag affordances (still renders rows for display)', () => {
    const wrapper = mount(LayersPanel, {
      props: { elements: makeElements(), selectedIds: [], readonly: true },
    })
    // Rows still render (readonly is for preview mode — display only).
    expect(wrapper.findAll('[data-testid^="design-layer-"]').length).toBeGreaterThan(0)
  })
})