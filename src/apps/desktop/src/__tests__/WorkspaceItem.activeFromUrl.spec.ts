import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { nextTick, reactive, ref } from 'vue'
import { mount } from '@vue/test-utils'

import WorkspaceItem from '../components/workspace/WorkspaceItem.vue'
import { makeLocalStorageStub } from './helpers'

const { useRouteMock } = vi.hoisted(() => ({
  useRouteMock: vi.fn(),
}))

vi.mock('vue-router', async () => {
  const actual = await vi.importActual<typeof import('vue-router')>('vue-router')
  return { ...actual, useRoute: useRouteMock }
})

// The active row is painted from the theme's semantic tokens (`--semantic-active-bg` +
// `--semantic-active-text` + a violet inset rule), not a hard-coded rgb, so the row reads as active
// in every theme. The token itself is the marker.
const ACTIVE_MARKER = '--semantic-active-bg'

const baseItem = {
  id: 'item_design',
  name: 'Design',
  item_type: 'design',
  path: '/tmp',
  tasks: [],
  design_elements: [],
  kanban_columns: [],
  isLoaded: true,
  isLoading: false,
}

function mountItem(overrides: { isActive?: boolean } = {}) {
  const wrapper = mount(WorkspaceItem, {
    props: {
      item: baseItem,
      workspaceId: 'ws_1',
      isActive: overrides.isActive ?? false,
    },
    global: {
      provide: { processingState: ref<Record<string, boolean>>({}) },
    },
  })
  return { wrapper }
}

describe('WorkspaceItem — item row active state from URL', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    Object.defineProperty(globalThis, 'localStorage', {
      value: makeLocalStorageStub(),
      writable: true,
      configurable: true,
    })
  })
  afterEach(() => { vi.restoreAllMocks() })

  it('item row is active when URL is ?view=workspace&itemId=Y (this item)', async () => {
    useRouteMock.mockReturnValue({
      query: { view: 'workspace', itemId: 'item_design' },
      path: '/app',
      fullPath: '/app?view=workspace&itemId=item_design',
     
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    } as any)
    const { wrapper } = mountItem()
    await nextTick()
    // Find the main row button (the one with the chevron + name)
    const buttons = wrapper.findAll('button')
    const itemButton = buttons.find((b) => b.text().includes('Design'))
    expect(itemButton).toBeDefined()
    expect(itemButton!.attributes('style')).toContain(ACTIVE_MARKER)
  })

  it('item row is NOT active when URL is ?view=chat&session=X', async () => {
    useRouteMock.mockReturnValue({
      query: { view: 'chat', session: 'chat_xyz' },
      path: '/app',
       
      fullPath: '/app?view=chat&session=chat_xyz',
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    } as any)
    const { wrapper } = mountItem()
    await nextTick()
    const buttons = wrapper.findAll('button')
    const itemButton = buttons.find((b) => b.text().includes('Design'))
    expect(itemButton).toBeDefined()
    expect(itemButton!.attributes('style') ?? '').not.toContain(ACTIVE_MARKER)
  })

  it('item row is NOT active when URL is ?view=workspace&itemId=OTHER', async () => {
    useRouteMock.mockReturnValue({
      query: { view: 'workspace', itemId: 'item_other' },
       
      path: '/app',
      fullPath: '/app?view=workspace&itemId=item_other',
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    } as any)
    const { wrapper } = mountItem()
    await nextTick()
    const buttons = wrapper.findAll('button')
    const itemButton = buttons.find((b) => b.text().includes('Design'))
    expect(itemButton).toBeDefined()
    expect(itemButton!.attributes('style') ?? '').not.toContain(ACTIVE_MARKER)
  })

  it('item row active state reacts to URL changes mid-mount', async () => {
    const route = reactive({
      query: {} as Record<string, string>,
       
      path: '/app',
      fullPath: '/app',
    })
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    useRouteMock.mockReturnValue(route as any)
    const { wrapper } = mountItem()
    await nextTick()
    let buttons = wrapper.findAll('button')
    let itemButton = buttons.find((b) => b.text().includes('Design'))
    expect(itemButton!.attributes('style') ?? '').not.toContain(ACTIVE_MARKER)

    route.query = { view: 'workspace', itemId: 'item_design' }
    await nextTick()
    buttons = wrapper.findAll('button')
    itemButton = buttons.find((b) => b.text().includes('Design'))
    expect(itemButton!.attributes('style')).toContain(ACTIVE_MARKER)
  })
})
