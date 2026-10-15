import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest'
import { mount, type VueWrapper } from '@vue/test-utils'
import { setActivePinia, createPinia } from 'pinia'
import { nextTick } from 'vue'
import LayersPanel from '../components/design/LayersPanel.vue'
import type { DesignElement } from '../api'

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
    created_at: '2026-07-29 12:00:00',
    updated_at: '2026-07-29 12:00:00',
    ...overrides,
  }
}

describe('LayersPanel context menu', () => {
  let wrapper: VueWrapper | null = null

  beforeEach(() => {
    setActivePinia(createPinia())
  })

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    vi.restoreAllMocks()
    document.body.innerHTML = ''
  })

  it('opens the menu positioned at the contextmenu event coordinates', async () => {
    const elements = [
      makeElement({ id: 'elem_a', z_index: 1, position: 0 }),
      makeElement({ id: 'elem_b', z_index: 0, position: 1 }),
    ]
    wrapper = mount(LayersPanel, {
      props: { elements, selectedIds: [], readonly: false },
      attachTo: document.body,
    })
    await nextTick()

    const row = wrapper.find('[data-testid="design-layer-elem_a"]')
    await row.trigger('contextmenu', { clientX: 100, clientY: 200 })
    await nextTick()

    const menu = document.querySelector<HTMLElement>('[data-testid="design-context-menu"]')
    expect(menu).not.toBeNull()
    expect(menu!.style.left).toBe('100px')
    expect(menu!.style.top).toBe('200px')
  })

  it('opens the menu with the full selection as targetIds when shiftKey + row already selected', async () => {
    const elements = [
      makeElement({ id: 'elem_a', z_index: 2, position: 0 }),
      makeElement({ id: 'elem_b', z_index: 1, position: 1 }),
      makeElement({ id: 'elem_c', z_index: 0, position: 2 }),
    ]
    wrapper = mount(LayersPanel, {
      props: { elements, selectedIds: ['elem_a', 'elem_b'], readonly: false },
      attachTo: document.body,
    })
    await nextTick()

    const row = wrapper.find('[data-testid="design-layer-elem_b"]')
    await row.trigger('contextmenu', { clientX: 150, clientY: 250, shiftKey: true })
    await nextTick()

    const vm = wrapper.findComponent({ name: 'DesignContextMenu' })
    expect(vm.props('targetIds')).toEqual(['elem_a', 'elem_b'])
  })

  it('replaces the selection with the right-clicked id when that row is NOT in the selection', async () => {
    const elements = [
      makeElement({ id: 'elem_a', z_index: 2, position: 0 }),
      makeElement({ id: 'elem_b', z_index: 1, position: 1 }),
    ]
    wrapper = mount(LayersPanel, {
      props: { elements, selectedIds: ['elem_a'], readonly: false },
      attachTo: document.body,
    })
    await nextTick()

    const row = wrapper.find('[data-testid="design-layer-elem_b"]')
    await row.trigger('contextmenu', { clientX: 50, clientY: 80 })
    await nextTick()

    const selectEmits = wrapper.emitted('select')
    expect(selectEmits).toBeTruthy()
    expect(selectEmits?.[0]?.[0]).toEqual({ elementId: 'elem_b', additive: false })

    const vm = wrapper.findComponent({ name: 'DesignContextMenu' })
    expect(vm.props('targetIds')).toEqual(['elem_b'])
  })

  it('does not render the menu when readonly is true (Preview mode)', async () => {
    const elements = [
      makeElement({ id: 'elem_a', z_index: 1 }),
      makeElement({ id: 'elem_b', z_index: 0 }),
    ]
    wrapper = mount(LayersPanel, {
      props: { elements, selectedIds: [], readonly: true },
      attachTo: document.body,
    })
    await nextTick()

    // No @contextmenu listener is bound in readonly mode; dispatching
    // a contextmenu event should have no effect.
    const row = wrapper.find('[data-testid="design-layer-elem_a"]')
    await row.trigger('contextmenu', { clientX: 100, clientY: 100 })
    await nextTick()

    const menu = document.querySelector('[data-testid="design-context-menu"]')
    expect(menu).toBeNull()
  })

  // ─── Ctrl/Cmd+click toggles multi-select (Plan: design-multiselect-ctrl-fix) ──

  it('Ctrl+click on a row toggles additive selection (Figma parity for Linux/Windows users)', async () => {
    const elements = [
      makeElement({ id: 'elem_a', z_index: 2 }),
      makeElement({ id: 'elem_b', z_index: 1 }),
    ]
    wrapper = mount(LayersPanel, {
      props: { elements, selectedIds: ['elem_a'], readonly: false },
      attachTo: document.body,
    })
    await nextTick()

    const row = wrapper.find('[data-testid="design-layer-elem_b"]')
    await row.trigger('click', { ctrlKey: true })
    await nextTick()

    const emits = wrapper.emitted('select')
    expect(emits).toBeTruthy()
    // LayerRow fires select with additive: true when ctrlKey is held.
    expect(emits?.[0]?.[0]).toEqual({ elementId: 'elem_b', additive: true })
  })

  it('Cmd+click on a row toggles additive selection (Figma parity for macOS users)', async () => {
    const elements = [
      makeElement({ id: 'elem_a', z_index: 2 }),
      makeElement({ id: 'elem_b', z_index: 1 }),
    ]
    wrapper = mount(LayersPanel, {
      props: { elements, selectedIds: ['elem_a'], readonly: false },
      attachTo: document.body,
    })
    await nextTick()

    const row = wrapper.find('[data-testid="design-layer-elem_b"]')
    await row.trigger('click', { metaKey: true })
    await nextTick()

    const emits = wrapper.emitted('select')
    expect(emits).toBeTruthy()
    expect(emits?.[0]?.[0]).toEqual({ elementId: 'elem_b', additive: true })
  })

  it('plain click on a row emits additive: false (replaces selection)', async () => {
    const elements = [
      makeElement({ id: 'elem_a', z_index: 2 }),
      makeElement({ id: 'elem_b', z_index: 1 }),
    ]
    wrapper = mount(LayersPanel, {
      props: { elements, selectedIds: ['elem_a'], readonly: false },
      attachTo: document.body,
    })
    await nextTick()

    const row = wrapper.find('[data-testid="design-layer-elem_b"]')
    await row.trigger('click')
    await nextTick()

    const emits = wrapper.emitted('select')
    expect(emits).toBeTruthy()
    // No modifier key → additive: false (replace selection).
    expect(emits?.[0]?.[0]).toEqual({ elementId: 'elem_b', additive: false })
  })

  it('opens the menu with the full selection as targetIds when right-clicking an already-selected row (no shift required)', async () => {
    // Figma parity: right-click on a row that's already in the
    // multi-selection — regardless of shift — opens the menu against
    // the FULL selection. The earlier implementation incorrectly
    // collapsed the targetIds to a single id when shiftKey was false,
    // which broke the "Select all then right-click" workflow
    // (Group selection was disabled because targetIds.length became 1).
    const elements = [
      makeElement({ id: 'elem_a', z_index: 2, position: 0 }),
      makeElement({ id: 'elem_b', z_index: 1, position: 1 }),
      makeElement({ id: 'elem_c', z_index: 0, position: 2 }),
    ]
    wrapper = mount(LayersPanel, {
      props: { elements, selectedIds: ['elem_a', 'elem_b', 'elem_c'], readonly: false },
      attachTo: document.body,
    })
    await nextTick()

    const row = wrapper.find('[data-testid="design-layer-elem_b"]')
    await row.trigger('contextmenu', { clientX: 150, clientY: 250 })
    await nextTick()

    const vm = wrapper.findComponent({ name: 'DesignContextMenu' })
    expect(vm.props('targetIds')).toEqual(['elem_a', 'elem_b', 'elem_c'])
  })

  // ─── Leave group (2026-08-06, design-leave-group plan) ────────────────

  // The LayersPanel forwards the menu's @leave-group emit upward as
  // the @leaveGroup emit. The test confirms the forward works — the
  // actual reparent is in DesignView (out of scope here).

  it('forwards the menu leaveGroup click as a top-level @leaveGroup emit with the single id', async () => {
    // `elem_b` is a child of `elem_a` (parent_id set). Right-click,
    // then click the menu's Leave-group button. LayersPanel must
    // emit `leaveGroup` with ['elem_b'].
    const elements = [
      makeElement({ id: 'elem_a', z_index: 1 }),
      makeElement({ id: 'elem_b', z_index: 0, parent_id: 'elem_a' }),
    ]
    wrapper = mount(LayersPanel, {
      props: { elements, selectedIds: ['elem_b'], readonly: false },
      attachTo: document.body,
    })
    await nextTick()

    // Open the menu on elem_b's row.
    const row = wrapper.find('[data-testid="design-layer-elem_b"]')
    await row.trigger('contextmenu', { clientX: 100, clientY: 200 })
    await nextTick()

    // Click Leave group.
    const btn = document.querySelector<HTMLButtonElement>(
      '[data-testid="design-context-menu-leave-group"]',
    )!
    expect(btn).not.toBeNull()
    expect(btn.disabled).toBe(false)
    btn.click()
    await nextTick()

    // The forward reaches LayersPanel's emit.
    const emits = wrapper.emitted('leaveGroup')
    expect(emits).toBeTruthy()
    expect(emits?.[0]).toEqual(['elem_b'])
  })
})