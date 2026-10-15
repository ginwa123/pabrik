/** Tests for KanbanView.handleStartAgent — the edit-mode "Start agent" button host handler. */
/** Calls workspacesStore.startAgentOnTask (which POSTs to the new
 * /api/.../tasks/:task_id/start_agent endpoint); closes the dialog + clears the active task on
 * success; keeps the dialog open with the errorMessage banner on failure. */
/** Distinct from KanbanView.createAndRun.spec.ts (which covers the create-mode create_and_run
 * flow). Plan: docs/superpowers/specs/2026-08-18-kanban-task-detail-start-agent.md */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { flushPromises, mount, type VueWrapper } from '@vue/test-utils'
import { setActivePinia, createPinia } from 'pinia'

import KanbanView from '@/components/kanban/KanbanView.vue'
import { useWorkspacesStore } from '@/stores/workspaces'

// Stub the heavy children — we only test the host's handleStartAgent.
vi.mock('@/components/kanban/KanbanColumn.vue', () => ({
  default: { name: 'KanbanColumn', template: '<div />' },
}))
vi.mock('@/components/kanban/KanbanSearchInput.vue', () => ({
  default: { name: 'KanbanSearchInput', template: '<div />' },
}))
vi.mock('@/components/kanban/KanbanTaskDetailDialog.vue', () => ({
  default: {
    name: 'KanbanTaskDetailDialog',
    template: '<div data-testid="stub-dialog" />',
  },
}))
vi.mock('@/composables/useKanbanScrollRestore', () => ({
  useKanbanScrollRestore: () => ({}),
}))
vi.mock('@/components/preview/InlineEditableText.vue', () => ({
  default: { name: 'InlineEditableText', template: '<div />' },
}))

// eslint-disable-next-line @typescript-eslint/no-explicit-any
const ITEM_WITH_TASK: any = {
  id: 'item_1',
  name: 'Kanban',
  path: '/home/u/proj',
  tasks: [
    {
      id: 'task_existing',
      name: 'Refactor modal',
      description: 'Move AddItemDialog to a generic base',
      task_type: 'standard',
      kanban_column_id: 'col_todo',
      is_auto_retry_until_stop: '0',
    },
  ],
  kanban_columns: [
    { id: 'col_todo', name: 'todo', position: 0, workspace_item_id: 'item_1' },
  ],
}

describe('KanbanView.handleStartAgent', () => {
  let wrapper: VueWrapper | null = null

  beforeEach(() => {
    setActivePinia(createPinia())
    vi.restoreAllMocks()
  })

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
  })

  async function mountView() {
    wrapper = mount(KanbanView, {
      props: {
        item: structuredClone(ITEM_WITH_TASK),
        workspaceId: 'ws_1',
        itemId: 'item_1',
      },
    })
    await flushPromises()
    // Set the active task id + open the dialog so handleStartAgent's guard passes and the "dialog
    // stays open on error" assertions are meaningful. In production, handleViewTaskDetail sets both
    // together; we replicate that here. eslint-disable-next-line @typescript-eslint/no-explicit-any
    const vmInit: any = wrapper!.vm
    vmInit.activeTaskDetailId = 'task_existing'
    vmInit.showTaskDetail = true
    return wrapper!
  }

  it('calls workspacesStore.startAgentOnTask with the right args and closes the dialog on success', async () => {
    const store = useWorkspacesStore()
    const startAgentSpy = vi
      .spyOn(store, 'startAgentOnTask')
      .mockResolvedValue({
        success: true,
        session_id: 'task_existing',
        status: 'triggered',
      })

    const view = await mountView()
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const vm: any = view.vm
    await vm.handleStartAgent({ taskId: 'task_existing' })
    await flushPromises()

    expect(startAgentSpy).toHaveBeenCalledTimes(1)
    expect(startAgentSpy).toHaveBeenCalledWith('ws_1', 'item_1', 'task_existing')

    // Dialog closed + activeTaskDetailId cleared.
    expect(vm.showTaskDetail).toBe(false)
    expect(vm.activeTaskDetailId).toBeNull()
    // No error banner.
    expect(vm.startAgentError).toBeNull()
  })

  it('sets startAgentError and keeps the dialog open when the store returns undefined (network error)', async () => {
    const store = useWorkspacesStore()
    vi.spyOn(store, 'startAgentOnTask').mockResolvedValue(undefined)

    const view = await mountView()
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const vm: any = view.vm
    await vm.handleStartAgent({ taskId: 'task_existing' })
    await flushPromises()

    expect(vm.startAgentError).toBe("Agent didn't start — network error.")
    expect(vm.showTaskDetail).toBe(true)
    expect(vm.activeTaskDetailId).toBe('task_existing')
  })

  it('sets startAgentError when the store throws', async () => {
    const store = useWorkspacesStore()
    vi.spyOn(store, 'startAgentOnTask').mockRejectedValue(new Error('boom'))

    const view = await mountView()
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const vm: any = view.vm
    await vm.handleStartAgent({ taskId: 'task_existing' })
    await flushPromises()

    expect(vm.startAgentError).toBe('boom')
    expect(vm.showTaskDetail).toBe(true)
  })

  it('sets startAgentError when the backend returns { success: false }', async () => {
    const store = useWorkspacesStore()
    vi.spyOn(store, 'startAgentOnTask').mockResolvedValue({ success: false })

    const view = await mountView()
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const vm: any = view.vm
    await vm.handleStartAgent({ taskId: 'task_existing' })
    await flushPromises()

    expect(vm.startAgentError).toBe(
      "Agent didn't start — server reported failure.",
    )
    expect(vm.showTaskDetail).toBe(true)
  })

  it('ignores a click for a different task than the one currently open', async () => {
    const store = useWorkspacesStore()
    const startAgentSpy = vi.spyOn(store, 'startAgentOnTask')

    const view = await mountView()
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const vm: any = view.vm
    // The guard: activeTaskDetailId is 'task_existing' but the payload
    // says 'task_other'. The handler should bail without calling the
    // store action.
    await vm.handleStartAgent({ taskId: 'task_other' })
    await flushPromises()

    expect(startAgentSpy).not.toHaveBeenCalled()
    expect(vm.showTaskDetail).toBe(true)
  })

  it('does not double-fire when handleStartAgent is called twice in quick succession', async () => {
    // 1-shot re-entrancy guard: the second click during the in-flight
    // POST should bail on startAgentBusy.
    const store = useWorkspacesStore()
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    let resolveFirst: (v: any) => void = () => {}
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const firstCallPromise = new Promise<any>((resolve) => {
      resolveFirst = resolve
    })
    const startAgentSpy = vi
      .spyOn(store, 'startAgentOnTask')
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      .mockReturnValueOnce(firstCallPromise as any)
      .mockResolvedValueOnce({
        success: true,
        session_id: 'task_existing',
        status: 'triggered',
      })

    const view = await mountView()
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const vm: any = view.vm

    // Fire two clicks without awaiting the first.
    const firstClick = vm.handleStartAgent({ taskId: 'task_existing' })
    // Immediately fire a second click — should bail on startAgentBusy.
    await vm.handleStartAgent({ taskId: 'task_existing' })

    // Resolve the first call.
    resolveFirst({ success: true, session_id: 'task_existing', status: 'triggered' })
    await firstClick
    await flushPromises()

    // Only the first call hits the store action.
    expect(startAgentSpy).toHaveBeenCalledTimes(1)
  })
})
