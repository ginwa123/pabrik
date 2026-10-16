/** V2 sidebar: header shows a quiet count, no search filter.
 * Every project is listed; actions are always visible; indent is compact. */
import { beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { nextTick, ref } from 'vue'
import { mount } from '@vue/test-utils'

import ProjectsList from '../components/workspace/ProjectsList.vue'
import { makeLocalStorageStub } from './helpers'

const { useRouteMock } = vi.hoisted(() => ({
  useRouteMock: vi.fn(),
}))

vi.mock('vue-router', async () => {
  const actual = await vi.importActual<typeof import('vue-router')>('vue-router')
  return { ...actual, useRoute: useRouteMock }
})

const baseWorkspace = {
  id: 'ws_1',
  name: 'agentic coding',
  icon: 'folder',
  expanded: true,
  items: [
    {
      id: 'item_a',
      name: 'AGENTIC_KANBAN',
      item_type: 'agent',
      path: '/tmp',
      tasks: [{ id: 't1', name: 'parse-stream-chunk', is_pinned: false }],
      design_elements: [],
      kanban_columns: [],
      isLoaded: true,
      isLoading: false,
    },
    {
      id: 'item_b',
      name: 'kabelweb',
      item_type: 'agent',
      path: '/tmp',
      tasks: [],
      design_elements: [],
      kanban_columns: [],
      isLoaded: true,
      isLoading: false,
    },
  ],
}

function mountList() {
  return mount(ProjectsList, {
    props: { workspace: baseWorkspace, activeWorkspaceItemId: null },
    global: {
      provide: { processingState: ref<Record<string, boolean>>({}) },
      stubs: { WorkspaceItem: true },
    },
  })
}

describe('ProjectsList v2 — count, no search, compact indent', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    Object.defineProperty(globalThis, 'localStorage', {
      value: makeLocalStorageStub(),
      writable: true,
      configurable: true,
    })
    useRouteMock.mockReturnValue({ query: {}, path: '/app', fullPath: '/app' } as never)
  })

  it('shows quiet project count', async () => {
    const wrapper = mountList()
    await nextTick()
    const count = wrapper.find('[data-testid="projects-count"]')
    expect(count.exists()).toBe(true)
    expect(count.text()).toBe('2')
    wrapper.unmount()
  })

  it('has no search input — every project is listed', async () => {
    const wrapper = mountList()
    await nextTick()
    expect(wrapper.find('[data-testid="projects-search"]').exists()).toBe(false)
    expect(wrapper.find('[data-testid="projects-no-results"]').exists()).toBe(false)
    // Both items render without filtering (stubbed rows carry item id).
    expect(wrapper.html()).toContain('item_a')
    expect(wrapper.html()).toContain('item_b')
    wrapper.unmount()
  })

  // The list used to carry a 12px left margin and a 1px rail, which inset every project row by 13px
  // against a flush RECENT row: the strip the sidebar review found. jsdom resolves no Tailwind, so the
  // witness here is the class list; the measured box lives in the functional UI suite.
  it('renders the project list flush, with no indent and no rail', async () => {
    const wrapper = mountList()
    await nextTick()
    const ul = wrapper.find('ul')
    expect(ul.exists()).toBe(true)
    expect(ul.classes().filter((c) => /(^|:)ml-|(^|:)pl-|border-l/.test(c))).toEqual([])
    // Not vacuous: the rows are still there and still selectable.
    expect(wrapper.html()).toContain('item_a')
    expect(wrapper.html()).toContain('item_b')
    expect(wrapper.find('ul').classes()).toContain('space-y-0')
    wrapper.unmount()
  })
})
