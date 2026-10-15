/** Tests for KanbanView.handleRunAgentFromMenu — the card / row context-menu "Run agent" host
 * handler. Same store action as the detail dialog's caret menu (`startAgentOnTask` → POST
 * .../tasks/:task_id/start_agent), reached without opening the dialog. */
/** The behavioural difference worth pinning is the ERROR SURFACE: there is no dialog to hold an
 * inline banner, so failures go to the notification store instead. */
/** Distinct from KanbanView.startAgent.spec.ts (dialog path, inline banner) and
 * KanbanView.runAllAgents.spec.ts (column bulk path). */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { flushPromises, mount, type VueWrapper } from '@vue/test-utils'
import { setActivePinia, createPinia } from 'pinia'

import KanbanView from '@/components/kanban/KanbanView.vue'
import { useWorkspacesStore } from '@/stores/workspaces'
import { useNotificationStore } from '@/stores/notifications'

// Stub the heavy children — we only test the host's handler.
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
  kanban_columns: [{ id: 'col_todo', name: 'todo', position: 0, workspace_item_id: 'item_1' }],
}

describe('KanbanView.handleRunAgentFromMenu', () => {
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
    return wrapper!
  }

  it('calls startAgentOnTask with the right args and raises no toast on success', async () => {
    const store = useWorkspacesStore()
    const notifications = useNotificationStore()
    const startAgentSpy = vi.spyOn(store, 'startAgentOnTask').mockResolvedValue({
      success: true,
      session_id: 'task_existing',
      status: 'triggered',
    })

    const view = await mountView()
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const vm: any = view.vm
    await vm.handleRunAgentFromMenu({ taskId: 'task_existing' })
    await flushPromises()

    expect(startAgentSpy).toHaveBeenCalledTimes(1)
    expect(startAgentSpy).toHaveBeenCalledWith('ws_1', 'item_1', 'task_existing')
    // Success is silent — the SSE worker events drive the card's
    // spinner from here, so a toast would be noise.
    expect(notifications.notifications).toHaveLength(0)
  })

  it('falls back to item.id when the itemId prop is absent', async () => {
    const store = useWorkspacesStore()
    const startAgentSpy = vi.spyOn(store, 'startAgentOnTask').mockResolvedValue({
      success: true,
      status: 'triggered',
    })

    const view = mount(KanbanView, {
      props: { item: structuredClone(ITEM_WITH_TASK), workspaceId: 'ws_1' },
    })
    wrapper = view
    await flushPromises()
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const vm: any = view.vm
    await vm.handleRunAgentFromMenu({ taskId: 'task_existing' })
    await flushPromises()

    expect(startAgentSpy).toHaveBeenCalledWith('ws_1', 'item_1', 'task_existing')
  })

  it('notifies when the store returns undefined (network error)', async () => {
    const store = useWorkspacesStore()
    const notifications = useNotificationStore()
    vi.spyOn(store, 'startAgentOnTask').mockResolvedValue(undefined)

    const view = await mountView()
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const vm: any = view.vm
    await vm.handleRunAgentFromMenu({ taskId: 'task_existing' })
    await flushPromises()

    expect(notifications.notifications).toHaveLength(1)
    expect(notifications.notifications[0]?.message).toBe("Agent didn't start — network error.")
  })

  it('notifies when the backend reports { success: false }', async () => {
    const store = useWorkspacesStore()
    const notifications = useNotificationStore()
    vi.spyOn(store, 'startAgentOnTask').mockResolvedValue({ success: false })

    const view = await mountView()
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const vm: any = view.vm
    await vm.handleRunAgentFromMenu({ taskId: 'task_existing' })
    await flushPromises()

    expect(notifications.notifications).toHaveLength(1)
    expect(notifications.notifications[0]?.message).toBe(
      "Agent didn't start — server reported failure.",
    )
  })

  it('notifies with the error message when the store throws', async () => {
    const store = useWorkspacesStore()
    const notifications = useNotificationStore()
    vi.spyOn(store, 'startAgentOnTask').mockRejectedValue(new Error('boom'))

    const view = await mountView()
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const vm: any = view.vm
    await vm.handleRunAgentFromMenu({ taskId: 'task_existing' })
    await flushPromises()

    expect(notifications.notifications).toHaveLength(1)
    expect(notifications.notifications[0]?.message).toBe('boom')
  })

  it('ignores a payload with no taskId', async () => {
    const store = useWorkspacesStore()
    const startAgentSpy = vi.spyOn(store, 'startAgentOnTask')

    const view = await mountView()
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const vm: any = view.vm
    await vm.handleRunAgentFromMenu({ taskId: '' })
    await flushPromises()

    expect(startAgentSpy).not.toHaveBeenCalled()
  })

  it('does not double-fire when called twice in quick succession', async () => {
    // Per-task re-entrancy guard: the menu row is hidden while a worker
    // runs, but the SSE state lands a beat after the click, so the
    // second click has to bail on the in-flight POST.
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
      .mockResolvedValueOnce({ success: true, status: 'triggered' })

    const view = await mountView()
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const vm: any = view.vm

    const firstClick = vm.handleRunAgentFromMenu({ taskId: 'task_existing' })
    await vm.handleRunAgentFromMenu({ taskId: 'task_existing' })

    resolveFirst({ success: true, session_id: 'task_existing', status: 'triggered' })
    await firstClick
    await flushPromises()

    expect(startAgentSpy).toHaveBeenCalledTimes(1)
  })

  it('releases the busy guard after a failure so the user can retry', async () => {
    const store = useWorkspacesStore()
    const startAgentSpy = vi
      .spyOn(store, 'startAgentOnTask')
      .mockResolvedValueOnce({ success: false })
      .mockResolvedValueOnce({ success: true, status: 'triggered' })

    const view = await mountView()
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const vm: any = view.vm
    await vm.handleRunAgentFromMenu({ taskId: 'task_existing' })
    await flushPromises()
    await vm.handleRunAgentFromMenu({ taskId: 'task_existing' })
    await flushPromises()

    expect(startAgentSpy).toHaveBeenCalledTimes(2)
  })
})
