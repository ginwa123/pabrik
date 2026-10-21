/** Tests for KanbanSortMenu — the menu used inside the kanban's per-column "⋮" menu (Sort tasks…)
 * and (in future) the kanban header. */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { mount, type VueWrapper } from '@vue/test-utils'

import KanbanSortMenu from '../components/kanban/KanbanSortMenu.vue'

function mountSortMenu(
  sortBy: 'position' | 'created_at' | 'updated_at' | 'name' = 'position',
  direction: 'asc' | 'desc' = 'asc',
  showTrigger = true,
) {
  return mount(KanbanSortMenu, {
    props: { sortBy, direction, showTrigger },
    attachTo: document.body,
  })
}

describe('KanbanSortMenu — trigger + label (showTrigger=true, default)', () => {
  let wrapper: VueWrapper | null = null

  beforeEach(() => {
    document.body.innerHTML = ''
  })

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    vi.restoreAllMocks()
  })

  it('renders the trigger button with the current sort label', () => {
    wrapper = mountSortMenu('updated_at', 'desc')
    const trigger = wrapper.find('[data-testid="kanban-sort-menu-trigger"]')
    expect(trigger.exists()).toBe(true)
    expect(trigger.text()).toContain('Sort:')
    expect(trigger.text()).toContain('Updated (newest)')
  })

  it('shows "Manual" as the trigger label for sortBy=position', () => {
    wrapper = mountSortMenu('position', 'asc')
    const trigger = wrapper.find('[data-testid="kanban-sort-menu-trigger"]')
    expect(trigger.text()).toContain('Manual')
  })

  it('shows "Created (newest)" / "(oldest)" labels', () => {
    wrapper = mountSortMenu('created_at', 'asc')
    const trigger = wrapper.find('[data-testid="kanban-sort-menu-trigger"]')
    expect(trigger.text()).toContain('Created (oldest)')
  })

  it('shows "Name (A→Z)" / "(Z→A)" labels', () => {
    const asc = mountSortMenu('name', 'asc')
    expect(asc.find('[data-testid="kanban-sort-menu-trigger"]').text()).toContain('Name (A')
    asc.unmount()

    const desc = mountSortMenu('name', 'desc')
    expect(desc.find('[data-testid="kanban-sort-menu-trigger"]').text()).toContain('Name (Z')
    desc.unmount()
  })
})

describe('KanbanSortMenu — menu open/close (showTrigger=true, default)', () => {
  let wrapper: VueWrapper | null = null

  beforeEach(() => {
    document.body.innerHTML = ''
  })

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    vi.restoreAllMocks()
  })

  it('is closed by default (no menu items rendered)', () => {
    wrapper = mountSortMenu()
    expect(wrapper.find('[data-testid="kanban-sort-menu-position"]').exists()).toBe(false)
  })

  it('opens on trigger click', async () => {
    wrapper = mountSortMenu()
    await wrapper.find('[data-testid="kanban-sort-menu-trigger"]').trigger('click')
    expect(wrapper.find('[data-testid="kanban-sort-menu-position"]').exists()).toBe(true)
  })

  it('renders all 7 menu items when open', async () => {
    wrapper = mountSortMenu()
    await wrapper.find('[data-testid="kanban-sort-menu-trigger"]').trigger('click')
    const itemIds = [
      'kanban-sort-menu-position',
      'kanban-sort-menu-created-desc',
      'kanban-sort-menu-created-asc',
      'kanban-sort-menu-updated-desc',
      'kanban-sort-menu-updated-asc',
      'kanban-sort-menu-name-asc',
      'kanban-sort-menu-name-desc',
    ]
    for (const id of itemIds) {
      expect(wrapper.find(`[data-testid="${id}"]`).exists()).toBe(true)
    }
  })

  it('closes on click outside the menu', async () => {
    wrapper = mountSortMenu()
    await wrapper.find('[data-testid="kanban-sort-menu-trigger"]').trigger('click')
    expect(wrapper.find('[data-testid="kanban-sort-menu-position"]').exists()).toBe(true)
    document.body.click()
    await wrapper.vm.$nextTick()
    expect(wrapper.find('[data-testid="kanban-sort-menu-position"]').exists()).toBe(false)
  })

  it('closes on Escape keydown', async () => {
    wrapper = mountSortMenu()
    await wrapper.find('[data-testid="kanban-sort-menu-trigger"]').trigger('click')
    expect(wrapper.find('[data-testid="kanban-sort-menu-position"]').exists()).toBe(true)
    const event = new KeyboardEvent('keydown', { key: 'Escape' })
    document.dispatchEvent(event)
    await wrapper.vm.$nextTick()
    expect(wrapper.find('[data-testid="kanban-sort-menu-position"]').exists()).toBe(false)
  })
})

describe('KanbanSortMenu — emits (showTrigger=true, default)', () => {
  let wrapper: VueWrapper | null = null

  beforeEach(() => {
    document.body.innerHTML = ''
  })

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    vi.restoreAllMocks()
  })

  it('clicking Manual emits update:sortBy=position + update:direction=asc', async () => {
    wrapper = mountSortMenu('updated_at', 'desc')
    await wrapper.find('[data-testid="kanban-sort-menu-trigger"]').trigger('click')
    await wrapper.find('[data-testid="kanban-sort-menu-position"]').trigger('click')
    expect(wrapper.emitted('update:sortBy')).toEqual([['position']])
    expect(wrapper.emitted('update:direction')).toEqual([['asc']])
  })

  it('clicking Created (newest) emits created_at desc', async () => {
    wrapper = mountSortMenu()
    await wrapper.find('[data-testid="kanban-sort-menu-trigger"]').trigger('click')
    await wrapper.find('[data-testid="kanban-sort-menu-created-desc"]').trigger('click')
    expect(wrapper.emitted('update:sortBy')).toEqual([['created_at']])
    expect(wrapper.emitted('update:direction')).toEqual([['desc']])
  })

  it('clicking Updated (oldest) emits updated_at asc', async () => {
    wrapper = mountSortMenu()
    await wrapper.find('[data-testid="kanban-sort-menu-trigger"]').trigger('click')
    await wrapper.find('[data-testid="kanban-sort-menu-updated-asc"]').trigger('click')
    expect(wrapper.emitted('update:sortBy')).toEqual([['updated_at']])
    expect(wrapper.emitted('update:direction')).toEqual([['asc']])
  })

  it('clicking Name (A→Z) emits name asc', async () => {
    wrapper = mountSortMenu()
    await wrapper.find('[data-testid="kanban-sort-menu-trigger"]').trigger('click')
    await wrapper.find('[data-testid="kanban-sort-menu-name-asc"]').trigger('click')
    expect(wrapper.emitted('update:sortBy')).toEqual([['name']])
    expect(wrapper.emitted('update:direction')).toEqual([['asc']])
  })

  it('clicking Name (Z→A) emits name desc', async () => {
    wrapper = mountSortMenu()
    await wrapper.find('[data-testid="kanban-sort-menu-trigger"]').trigger('click')
    await wrapper.find('[data-testid="kanban-sort-menu-name-desc"]').trigger('click')
    expect(wrapper.emitted('update:sortBy')).toEqual([['name']])
    expect(wrapper.emitted('update:direction')).toEqual([['desc']])
  })

  it('clicking a menu item closes the menu', async () => {
    wrapper = mountSortMenu()
    await wrapper.find('[data-testid="kanban-sort-menu-trigger"]').trigger('click')
    expect(wrapper.find('[data-testid="kanban-sort-menu-position"]').exists()).toBe(true)
    await wrapper.find('[data-testid="kanban-sort-menu-name-asc"]').trigger('click')
    await wrapper.vm.$nextTick()
    expect(wrapper.find('[data-testid="kanban-sort-menu-name-asc"]').exists()).toBe(false)
  })
})

describe('KanbanSortMenu — active item marker (showTrigger=true, default)', () => {
  let wrapper: VueWrapper | null = null

  beforeEach(() => {
    document.body.innerHTML = ''
  })

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    vi.restoreAllMocks()
  })

  it('marks the active sortBy + direction item with aria-current=true', async () => {
    wrapper = mountSortMenu('name', 'desc')
    await wrapper.find('[data-testid="kanban-sort-menu-trigger"]').trigger('click')
    const activeItem = wrapper.find('[data-testid="kanban-sort-menu-name-desc"]')
    expect(activeItem.attributes('aria-current')).toBe('true')

    const inactiveItem = wrapper.find('[data-testid="kanban-sort-menu-name-asc"]')
    expect(inactiveItem.attributes('aria-current')).toBeUndefined()
  })

  it('Manual item is marked active when sortBy=position', async () => {
    wrapper = mountSortMenu('position', 'asc')
    await wrapper.find('[data-testid="kanban-sort-menu-trigger"]').trigger('click')
    const manualItem = wrapper.find('[data-testid="kanban-sort-menu-position"]')
    expect(manualItem.attributes('aria-current')).toBe('true')
  })
})

describe('KanbanSortMenu — showTrigger=false (modal mode)', () => {
  let wrapper: VueWrapper | null = null

  beforeEach(() => {
    document.body.innerHTML = ''
  })

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    vi.restoreAllMocks()
  })

  it('does NOT render the trigger button', () => {
    wrapper = mountSortMenu('position', 'asc', false)
    expect(wrapper.find('[data-testid="kanban-sort-menu-trigger"]').exists()).toBe(false)
  })

  it('renders the menu items immediately (no click needed)', () => {
    wrapper = mountSortMenu('position', 'asc', false)
    expect(wrapper.find('[data-testid="kanban-sort-menu-position"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="kanban-sort-menu-name-asc"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="kanban-sort-menu-name-desc"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="kanban-sort-menu-created-desc"]').exists()).toBe(true)
  })

  it('does NOT install a document click-outside handler (items stay rendered)', async () => {
    wrapper = mountSortMenu('position', 'asc', false)
    expect(wrapper.find('[data-testid="kanban-sort-menu-position"]').exists()).toBe(true)
    // Dispatch a click on document body — must NOT remove the items.
    document.body.click()
    await wrapper.vm.$nextTick()
    expect(wrapper.find('[data-testid="kanban-sort-menu-position"]').exists()).toBe(true)
  })

  it('does NOT install a document Esc handler', async () => {
    wrapper = mountSortMenu('position', 'asc', false)
    expect(wrapper.find('[data-testid="kanban-sort-menu-position"]').exists()).toBe(true)
    const event = new KeyboardEvent('keydown', { key: 'Escape' })
    document.dispatchEvent(event)
    await wrapper.vm.$nextTick()
    // Items are still rendered — the modal wrapper handles Esc close.
    expect(wrapper.find('[data-testid="kanban-sort-menu-position"]').exists()).toBe(true)
  })

  it('clicking a menu item still emits update:sortBy + update:direction', async () => {
    wrapper = mountSortMenu('position', 'asc', false)
    await wrapper.find('[data-testid="kanban-sort-menu-name-asc"]').trigger('click')
    expect(wrapper.emitted('update:sortBy')).toEqual([['name']])
    expect(wrapper.emitted('update:direction')).toEqual([['asc']])
  })

  it('active item marker still works', () => {
    wrapper = mountSortMenu('name', 'desc', false)
    const activeItem = wrapper.find('[data-testid="kanban-sort-menu-name-desc"]')
    expect(activeItem.attributes('aria-current')).toBe('true')
  })
})