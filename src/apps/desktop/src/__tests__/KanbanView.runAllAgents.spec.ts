/** Tests for KanbanView.handleRunAllAgents — the column "Run all agents" host handler (plan:
 * docs/superpowers/plans/2026-09-09-run-all-agents-by-column.md, Tasks 3+4, Option C). */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { flushPromises, mount, type VueWrapper } from '@vue/test-utils'
import { setActivePinia, createPinia } from 'pinia'

import KanbanView from '@/components/kanban/KanbanView.vue'
import { useWorkspacesStore } from '@/stores/workspaces'

// Stub the heavy children — we only test the host's handleRunAllAgents.
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
const ITEM: any = {
  id: 'item_1',
  name: 'Kanban',
  path: '/home/u/proj',
  tasks: [],
  kanban_columns: [
    { id: 'col_todo', name: 'todo', position: 0, workspace_item_id: 'item_1' },
  ],
}

describe('KanbanView.handleRunAllAgents', () => {
  let wrapper: VueWrapper | null = null

  beforeEach(() => {
    setActivePinia(createPinia())
    vi.restoreAllMocks()
    vi.stubGlobal('confirm', vi.fn(() => true))
  })

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    vi.unstubAllGlobals()
  })

  async function mountView() {
    wrapper = mount(KanbanView, {
      props: {
        item: structuredClone(ITEM),
        workspaceId: 'ws_1',
        itemId: 'item_1',
      },
    })
    await flushPromises()
    return wrapper!
  }

  it('routes @request-run-all-agents to handleRunAllAgents and calls the store action', async () => {
    const store = useWorkspacesStore()
    const runAllSpy = vi.spyOn(store, 'runAllAgentsInColumn').mockResolvedValue({
      success: true,
      started: ['t1', 't2'],
      skipped: ['t3'],
      failed: [],
    })

    const view = await mountView()
    const columns = view.findAllComponents({ name: 'KanbanColumn' })
    expect(columns.length).toBeGreaterThan(0)
    await columns[0]!.vm.$emit('requestRunAllAgents', 'col_todo')
    await flushPromises()

    expect(runAllSpy).toHaveBeenCalledTimes(1)
    expect(runAllSpy).toHaveBeenCalledWith('ws_1', 'item_1', 'col_todo')
  })

  it('shows the confirm gate and aborts when the user cancels', async () => {
    const store = useWorkspacesStore()
    const runAllSpy = vi.spyOn(store, 'runAllAgentsInColumn')
    vi.stubGlobal('confirm', vi.fn(() => false))

    const view = await mountView()
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const vm: any = view.vm
    await vm.handleRunAllAgents('col_todo')
    await flushPromises()

    expect(vi.mocked(confirm)).toHaveBeenCalled()
    expect(runAllSpy).not.toHaveBeenCalled()
  })

  it('shows a summary banner with started/skipped/failed counts on success', async () => {
    const store = useWorkspacesStore()
    vi.spyOn(store, 'runAllAgentsInColumn').mockResolvedValue({
      success: true,
      started: ['t1', 't2'],
      skipped: ['t3'],
      failed: [],
    })

    const view = await mountView()
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const vm: any = view.vm
    await vm.handleRunAllAgents('col_todo')
    await flushPromises()

    expect(vm.runAllSummary).toContain('2')
    const banner = view.find('[data-testid="kanban-view-item_1-run-all-summary"]')
    expect(banner.exists()).toBe(true)
    expect(banner.text()).toContain('Started 2')
  })

  it('renders an error banner when the store returns success:false (swallowed throw)', async () => {
    const store = useWorkspacesStore()
    vi.spyOn(store, 'runAllAgentsInColumn').mockResolvedValue({
      success: false,
      started: [],
      skipped: [],
      failed: [],
    })

    const view = await mountView()
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const vm: any = view.vm
    await vm.handleRunAllAgents('col_todo')
    await flushPromises()

    expect(vm.runAllSummary).toContain('Failed to run all agents')
    const banner = view.find('[data-testid="kanban-view-item_1-run-all-summary"]')
    expect(banner.exists()).toBe(true)
    expect(banner.attributes('role')).toBe('status')
    expect(banner.attributes('aria-live')).toBe('polite')
  })

  it('does not double-fire for the same column while a bulk run is in flight', async () => {
    const store = useWorkspacesStore()
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    let resolveFirst: (v: any) => void = () => {}
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const firstCallPromise = new Promise<any>((resolve) => {
      resolveFirst = resolve
    })
    const runAllSpy = vi
      .spyOn(store, 'runAllAgentsInColumn')
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      .mockReturnValueOnce(firstCallPromise as any)
      .mockResolvedValueOnce({
        success: true,
        started: [],
        skipped: [],
        failed: [],
      })

    const view = await mountView()
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const vm: any = view.vm

    const firstClick = vm.handleRunAllAgents('col_todo')
    await vm.handleRunAllAgents('col_todo')

    resolveFirst({ success: true, started: [], skipped: [], failed: [] })
    await firstClick
    await flushPromises()

    expect(runAllSpy).toHaveBeenCalledTimes(1)
  })
})
