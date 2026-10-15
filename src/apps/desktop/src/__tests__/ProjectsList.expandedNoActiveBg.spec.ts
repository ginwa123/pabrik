/** Lock in the post-revamp contract: the expanded PROJECTS section renders with no background fill.
 * Only the active content item (URL-driven — see WorkspaceItem.activeFromUrl.spec.ts) gets the
 * `--semantic-active-bg` background + violet accent bar. */
/** The workspace ROW whose expanded state used to be conflated with active state is gone (the
 * header dropdown owns workspace selection now), so this pins the section header + body too. Plan:
 * docs/plans/2026-09-22-revamp-workspace-ui-dropdown-projects.md */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
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
      id: 'item_design',
      name: 'design',
      item_type: 'design',
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
  // Stub WorkspaceItem so the test focuses on the section header /
  // body styling — not the items' internal state.
  return mount(ProjectsList, {
    props: {
      workspace: baseWorkspace,
      activeWorkspaceItemId: null,
    },
    global: {
      provide: { processingState: ref<Record<string, boolean>>({}) },
      stubs: { WorkspaceItem: true },
    },
  })
}

describe('ProjectsList — expanded section has NO active background', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    Object.defineProperty(globalThis, 'localStorage', {
      value: makeLocalStorageStub(),
      writable: true,
      configurable: true,
    })
    useRouteMock.mockReturnValue({
      query: {} as Record<string, string>,
      path: '/app',
      fullPath: '/app',
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
    } as any)
  })
  afterEach(() => {
    vi.restoreAllMocks()
  })

  it('renders the section title', async () => {
    const wrapper = mountList()
    await nextTick()
    expect(wrapper.text()).toContain('Projects')
    wrapper.unmount()
  })

  it('expanded section does NOT paint --semantic-active-bg anywhere', async () => {
    const wrapper = mountList()
    await nextTick()
    // With no active item, nothing may carry the active background —
    // the section (header + body) is plain, only the active item row
    // would be highlighted.
    expect(wrapper.html()).not.toContain('--semantic-active-bg')
    wrapper.unmount()
  })

  it('section chevron is rotated while expanded (visual cue)', async () => {
    const wrapper = mountList()
    await nextTick()
    const chevrons = wrapper.findAll('span[style*="rotate(90deg)"]')
    expect(chevrons.length).toBeGreaterThan(0)
    wrapper.unmount()
  })
})
