import { beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { nextTick, ref } from 'vue'
import { mount } from '@vue/test-utils'
import WorkspaceItemTaskRow from '../components/workspace/WorkspaceItemTaskRow.vue'
import { makeLocalStorageStub } from './helpers'

vi.mock('vue-router', async () => {
  const actual = await vi.importActual<typeof import('vue-router')>('vue-router')
  return {
    ...actual,
    useRouter: () => ({ replace: vi.fn(), push: vi.fn() }),
    useRoute: () => ({ query: {}, path: '/', fullPath: '/' }),
  }
})

describe('WorkspaceItemTaskRow — right-click context menu', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    Object.defineProperty(globalThis, 'localStorage', {
      value: makeLocalStorageStub(),
      writable: true,
      configurable: true,
    })
    document.body.innerHTML = ''
  })

  it('emits openTaskInBackground with row ids when the menu item clicks', async () => {
    const wrapper = mount(WorkspaceItemTaskRow, {
      attachTo: document.body,
      props: {
        task: { id: 'task_9', name: 'Fix login' },
        workspaceId: 'ws_1',
        itemId: 'item_7',
      },
      global: { provide: { processingState: ref<Record<string, boolean>>({}) } },
    })
    await nextTick()
    const row = wrapper.find('[data-task-row]')
    expect(row.exists()).toBe(true)
    await row.trigger('contextmenu', { clientX: 50, clientY: 60 })
    await nextTick()
    const item = document.body.querySelector(
      '[data-testid="open-new-tab-item"]',
    ) as HTMLButtonElement
    expect(item).toBeTruthy()
    item.click()
    await nextTick()
    expect(wrapper.emitted('openTaskInBackground')).toHaveLength(1)
    expect(wrapper.emitted('openTaskInBackground')?.[0]).toEqual([
      { workspaceId: 'ws_1', itemId: 'item_7', taskId: 'task_9' },
    ])
    expect(wrapper.emitted('selectTask')).toBeUndefined()
    wrapper.unmount()
  })

  // "Run agent" on the sidebar row calls the store directly rather than emitting — the sidebar
  // chain is four components deep and three of them add no context. These tests pin that the call
  // happens with the row's own ids and that the row is hidden while a worker runs.
  it('Run agent calls startAgentOnTask with the row ids', async () => {
    const { useWorkspacesStore } = await import('../stores/workspaces')
    const store = useWorkspacesStore()
    const spy = vi
      .spyOn(store, 'startAgentOnTask')
      .mockResolvedValue({ success: true, status: 'triggered' })

    const wrapper = mount(WorkspaceItemTaskRow, {
      attachTo: document.body,
      props: {
        task: { id: 'task_9', name: 'Fix login' },
        workspaceId: 'ws_1',
        itemId: 'item_7',
      },
      global: { provide: { processingState: ref<Record<string, boolean>>({}) } },
    })
    await nextTick()
    await wrapper.find('[data-task-row]').trigger('contextmenu', { clientX: 50, clientY: 60 })
    await nextTick()

    const item = document.body.querySelector('[data-testid="run-agent-item"]') as HTMLButtonElement
    expect(item).toBeTruthy()
    item.click()
    await nextTick()
    await new Promise((r) => setTimeout(r, 0))

    expect(spy).toHaveBeenCalledWith('ws_1', 'item_7', 'task_9')
    wrapper.unmount()
  })

  it('Run agent is hidden while a worker runs on the task', async () => {
    const wrapper = mount(WorkspaceItemTaskRow, {
      attachTo: document.body,
      props: {
        task: { id: 'task_9', name: 'Fix login' },
        workspaceId: 'ws_1',
        itemId: 'item_7',
      },
      // The backend answers 409 to a second start, so the row must not
      // offer the action while a worker is in flight.
      global: { provide: { processingState: ref<Record<string, boolean>>({ task_9: true }) } },
    })
    await nextTick()
    await wrapper.find('[data-task-row]').trigger('contextmenu', { clientX: 50, clientY: 60 })
    await nextTick()

    expect(document.body.querySelector('[data-testid="run-agent-item"]')).toBeNull()
    wrapper.unmount()
  })
})
