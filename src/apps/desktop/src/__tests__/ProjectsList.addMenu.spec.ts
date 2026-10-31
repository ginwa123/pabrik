import { beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { nextTick, ref } from 'vue'
import { mount } from '@vue/test-utils'

import ProjectsList from '../components/workspace/ProjectsList.vue'
import { useSidebarStore } from '../stores/sidebar'
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
  items: [],
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

async function openAddMenu(wrapper: ReturnType<typeof mountList>) {
  useSidebarStore().projectsExpanded = true
  await nextTick()
  await wrapper.find('[data-testid="projects-add-item-button"]').trigger('click')
  await nextTick()
}

describe('ProjectsList add-item menu', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    Object.defineProperty(globalThis, 'localStorage', {
      value: makeLocalStorageStub(),
      writable: true,
      configurable: true,
    })
    useRouteMock.mockReturnValue({ query: {}, path: '/app', fullPath: '/app' } as never)
  })

  it('lists the routine option enabled so the user can create a routine', async () => {
    const wrapper = mountList()
    await openAddMenu(wrapper)
    const option = wrapper.find('[data-testid="workspace-add-routine-option"]')
    expect(option.exists()).toBe(true)
    expect(option.text()).toBe('Add Routine')
    expect(option.attributes('disabled')).toBeUndefined()
    expect(option.attributes('aria-disabled')).toBeUndefined()
    expect(option.classes()).not.toContain('cursor-not-allowed')
    wrapper.unmount()
  })

  it('clicking the routine option requests a routine item and closes the menu', async () => {
    const wrapper = mountList()
    await openAddMenu(wrapper)
    await wrapper.find('[data-testid="workspace-add-routine-option"]').trigger('click')
    await nextTick()
    expect(wrapper.emitted('requestAddItem')).toEqual([['ws_1', 'routine']])
    expect(wrapper.find('[data-testid="workspace-add-routine-option"]').exists()).toBe(false)
    wrapper.unmount()
  })

  it('still lists the paused design option as disabled', async () => {
    const wrapper = mountList()
    await openAddMenu(wrapper)
    const option = wrapper.find('[data-testid="workspace-add-design-option"]')
    expect(option.exists()).toBe(true)
    expect(option.text()).toBe('Add Design (alpha)')
    expect(option.attributes('disabled')).toBeDefined()
    expect(option.attributes('aria-disabled')).toBe('true')
    expect(option.classes()).toContain('cursor-not-allowed')
    wrapper.unmount()
  })

  it('clicking the disabled design option never emits requestAddItem', async () => {
    const wrapper = mountList()
    await openAddMenu(wrapper)
    await wrapper.find('[data-testid="workspace-add-design-option"]').trigger('click')
    await nextTick()
    expect(wrapper.emitted('requestAddItem')).toBeUndefined()
    expect(wrapper.find('[data-testid="workspace-add-design-option"]').exists()).toBe(true)
    wrapper.unmount()
  })

  it('keeps the enabled options (kanban, agent) working', async () => {
    const wrapper = mountList()
    await openAddMenu(wrapper)
    await wrapper.find('[data-testid="workspace-add-agent-option"]').trigger('click')
    await nextTick()
    expect(wrapper.emitted('requestAddItem')).toEqual([['ws_1', 'agent']])

    await openAddMenu(wrapper)
    const kanban = wrapper.findAll('button').find((b) => b.text() === 'Add Kanban')
    expect(kanban).toBeDefined()
    expect(kanban!.attributes('disabled')).toBeUndefined()
    await kanban!.trigger('click')
    await nextTick()
    expect(wrapper.emitted('requestAddItem')).toEqual([
      ['ws_1', 'agent'],
      ['ws_1', 'kanban'],
    ])
    wrapper.unmount()
  })
})
