/** Regression specs for the right-click "Go to settings" work (task_1789493500744_2, PR #521
 * follow-ups). */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { mount, type VueWrapper } from '@vue/test-utils'
import { nextTick, ref, type Ref } from 'vue'

import WorkspaceItem from '../components/workspace/WorkspaceItem.vue'
import { useWorkspacesStore } from '../stores/workspaces'
import type { WorkspaceItem as WorkspaceItemType } from '../stores/workspaces'
import { makeLocalStorageStub } from './helpers'

const WS_ID = 'ws_1'
const ITEM_ID = 'item_1'

const makeItem = (
  itemType: string,
  overrides: Partial<WorkspaceItemType> = {},
): WorkspaceItemType => ({
  id: ITEM_ID,
  name: 'Test Item',
  item_type: itemType,
  tasks: [],
  ...overrides,
})

function mountItem(item: WorkspaceItemType) {
  const processingState: Ref<Record<string, boolean>> = ref({})
  return mount(WorkspaceItem, {
    attachTo: document.body,
    props: {
      item,
      isActive: false,
      workspaceId: WS_ID,
    },
    global: {
      provide: { processingState },
    },
  })
}

describe('WorkspaceItem — agent click is expand-only (no settings redirect)', () => {
  let wrapper: VueWrapper | null = null

  beforeEach(() => {
    setActivePinia(createPinia())
    Object.defineProperty(globalThis, 'localStorage', {
      value: makeLocalStorageStub(),
      writable: true,
      configurable: true,
    })
  })

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    vi.restoreAllMocks()
  })

  it('agent left-click toggles expansion but does NOT emit click', async () => {
    wrapper = mountItem(makeItem('agent'))
    const button = wrapper.find('button.flex-1')
    expect(button.exists()).toBe(true)
    await button.trigger('click')
    const ws = useWorkspacesStore()
    expect(ws.expandedItemIds[ITEM_ID]).toBe(true)
    expect(wrapper.emitted('click')).toBeUndefined()
  })

  it('routine left-click toggles expansion but does NOT emit click', async () => {
    wrapper = mountItem(makeItem('routine'))
    const button = wrapper.find('button.flex-1')
    expect(button.exists()).toBe(true)
    await button.trigger('click')
    const ws = useWorkspacesStore()
    expect(ws.expandedItemIds[ITEM_ID]).toBe(true)
    expect(wrapper.emitted('click')).toBeUndefined()
  })

  it('kanban left-click still emits click exactly once (board opens)', async () => {
    wrapper = mountItem(makeItem('kanban'))
    const button = wrapper.find('button.flex-1')
    expect(button.exists()).toBe(true)
    await button.trigger('click')
    expect(wrapper.emitted('click')).toBeTruthy()
    expect(wrapper.emitted('click')?.length).toBe(1)
  })

  it('folder left-click still toggles expansion and emits click', async () => {
    wrapper = mountItem(makeItem('folder', { path: '/abs/path' }))
    const button = wrapper.find('button.flex-1')
    expect(button.exists()).toBe(true)
    await button.trigger('click')
    const ws = useWorkspacesStore()
    expect(ws.expandedItemIds[ITEM_ID]).toBe(true)
    expect(wrapper.emitted('click')).toBeTruthy()
  })

  it('context menu shows Go to settings for kanban rows', async () => {
    wrapper = mountItem(makeItem('kanban'))
    const button = wrapper.find('button.flex-1')
    await button.trigger('contextmenu', { clientX: 100, clientY: 200 })
    await nextTick()
    const entry = document.body.querySelector('[data-testid="go-to-settings-item"]')
    expect(entry?.textContent).toContain('Go to settings')
  })

  it('context menu shows Go to settings for agent rows', async () => {
    wrapper = mountItem(makeItem('agent'))
    const button = wrapper.find('button.flex-1')
    await button.trigger('contextmenu', { clientX: 100, clientY: 200 })
    await nextTick()
    const entry = document.body.querySelector('[data-testid="go-to-settings-item"]')
    expect(entry?.textContent).toContain('Go to settings')
  })

  it('context menu shows Go to settings for routine rows', async () => {
    wrapper = mountItem(makeItem('routine'))
    const button = wrapper.find('button.flex-1')
    await button.trigger('contextmenu', { clientX: 100, clientY: 200 })
    await nextTick()
    const entry = document.body.querySelector('[data-testid="go-to-settings-item"]')
    expect(entry?.textContent).toContain('Go to settings')
  })

  it('context menu hides Go to settings for folder rows', async () => {
    wrapper = mountItem(makeItem('folder', { path: '/abs/path' }))
    const button = wrapper.find('button.flex-1')
    await button.trigger('contextmenu', { clientX: 100, clientY: 200 })
    await nextTick()
    // The shared "Open chat in new tab" entry still shows...
    expect(document.body.querySelector('[data-testid="open-new-tab-item"]')).toBeTruthy()
    // ...but there is no settings entry for types without a
    // dedicated settings surface.
    expect(document.body.querySelector('[data-testid="go-to-settings-item"]')).toBeNull()
  })

  it('activating Go to settings emits goToSettings with the item payload', async () => {
    wrapper = mountItem(makeItem('kanban'))
    const button = wrapper.find('button.flex-1')
    await button.trigger('contextmenu', { clientX: 100, clientY: 200 })
    await nextTick()
    const entry = document.body.querySelector(
      '[data-testid="go-to-settings-item"]',
    ) as HTMLButtonElement
    expect(entry).toBeTruthy()
    entry.click()
    await nextTick()
    expect(wrapper.emitted('goToSettings')).toEqual([
      [{ workspaceId: WS_ID, itemId: ITEM_ID, name: 'Test Item', itemType: 'kanban' }],
    ])
  })

  it('routine items hide Add Task in the context menu', async () => {
    // The row has no inline buttons; the menu is the only door.
    wrapper = mountItem(makeItem('routine'))
    const button = wrapper.find('button.flex-1')
    await button.trigger('contextmenu', { clientX: 100, clientY: 200 })
    await nextTick()
    expect(document.body.querySelector('[data-testid="add-task-menu-item"]')).toBeNull()
  })

  it('kanban items hide Add Task in the context menu', async () => {
    wrapper = mountItem(makeItem('kanban'))
    const button = wrapper.find('button.flex-1')
    await button.trigger('contextmenu', { clientX: 100, clientY: 200 })
    await nextTick()
    expect(document.body.querySelector('[data-testid="add-task-menu-item"]')).toBeNull()
  })

  it('agent/folder items keep Add Task in the context menu', async () => {
    wrapper = mountItem(makeItem('agent'))
    let button = wrapper.find('button.flex-1')
    await button.trigger('contextmenu', { clientX: 100, clientY: 200 })
    await nextTick()
    expect(document.body.querySelector('[data-testid="add-task-menu-item"]')).toBeTruthy()
    wrapper?.unmount()
    wrapper = mountItem(makeItem('folder', { path: '/abs/path' }))
    button = wrapper.find('button.flex-1')
    await button.trigger('contextmenu', { clientX: 100, clientY: 200 })
    await nextTick()
    expect(document.body.querySelector('[data-testid="add-task-menu-item"]')).toBeTruthy()
  })
})
