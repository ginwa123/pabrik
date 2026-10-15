/**
 * Regression tests for the per-task activity marker. WorkspaceItem must
 * read from the same processingState ref App.vue provides. The circle
 * spinner was removed — the elapsed time pill is now the only marker,
 * so these tests assert the chip shows while the worker runs and no
 * spinner element exists at all.
 */
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { nextTick, ref, type Ref } from 'vue'
import { mount } from '@vue/test-utils'

import WorkspaceItem from '../components/workspace/WorkspaceItem.vue'
import type { WorkerActivity } from '../components/WorkerElapsedChip.vue'
import { useWorkspacesStore } from '../stores/workspaces'
import { makeLocalStorageStub } from './helpers'

const itemWithTasks = {
  id: 'item_1',
  name: 'My Project',
  item_type: 'folder',
  tasks: [
    { id: 'task_alpha', name: 'Alpha task' },
    { id: 'task_beta', name: 'Beta task' },
  ],
}

function mountWorkspaceItem(tasks: Array<{ id: string; name: string }> = itemWithTasks.tasks) {
  const processingState: Ref<Record<string, boolean>> = ref({})
  const workerActivity = ref<Record<string, WorkerActivity>>({})
  const workerNow = ref(Date.now())
  const wrapper = mount(WorkspaceItem, {
    props: {
      item: { ...itemWithTasks, tasks },
      isActive: false,
      workspaceId: 'ws_1',
    },
    global: {
      provide: { processingState, workerActivity, workerNow },
    },
  })
  const setBusy = (ids: string[]) => {
    const now = Date.now()
    processingState.value = Object.fromEntries(ids.map((id) => [id, true]))
    workerActivity.value = Object.fromEntries(
      ids.map((id) => [
        id,
        { startedAt: now - 127_000, lastActivityAt: now - 2_000, description: '' },
      ]),
    )
  }
  const clearBusy = () => {
    processingState.value = {}
    workerActivity.value = {}
  }
  return { wrapper, processingState, workerActivity, setBusy, clearBusy }
}

function expandItem(): void {
  // Tasks are only rendered when the parent item is expanded (WorkspaceItem.vue:125). The store
  // mutates `expandedItemIds` and reassigns the ref to trigger reactivity, matching the production
  // toggle in stores/workspaces.ts:toggleExpandedItem.
  const ws = useWorkspacesStore()
  ws.expandedItemIds['item_1'] = true
  ws.expandedItemIds = { ...ws.expandedItemIds }
}

// No spinner element exists anymore; the elapsed chip is the marker.
const visibleSpinners = (wrapper: ReturnType<typeof mount>) =>
  wrapper.findAll('[data-testid="task-spinner"]')
const visibleChips = (wrapper: ReturnType<typeof mount>) =>
  wrapper.findAll('[data-testid="task-elapsed-chip"]')

describe('WorkspaceItem task elapsed chip', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    Object.defineProperty(globalThis, 'localStorage', {
      value: makeLocalStorageStub(),
      writable: true,
      configurable: true,
    })
  })

  afterEach(() => {
    // Pinia is torn down by the next beforeEach's setActivePinia.
  })

  it('shows no chip when no task is busy', async () => {
    const { wrapper } = mountWorkspaceItem()
    expandItem()
    await nextTick()
    expect(visibleSpinners(wrapper)).toHaveLength(0)
    expect(visibleChips(wrapper)).toHaveLength(0)
  })

  it('shows a chip on the matching task when the worker runs', async () => {
    const { wrapper, setBusy } = mountWorkspaceItem()
    expandItem()
    setBusy(['task_alpha'])
    await nextTick()
    expect(visibleSpinners(wrapper)).toHaveLength(0)
    expect(visibleChips(wrapper)).toHaveLength(1)
    // The alpha row is the one with the chip; the alpha name is
    // still rendered in the row.
    expect(wrapper.text()).toContain('Alpha task')
  })

  it('shows chips on multiple tasks when several are running', async () => {
    const { wrapper, setBusy } = mountWorkspaceItem()
    expandItem()
    setBusy(['task_alpha', 'task_beta'])
    await nextTick()
    expect(visibleSpinners(wrapper)).toHaveLength(0)
    expect(visibleChips(wrapper)).toHaveLength(2)
  })

  it('hides the chip when the worker finishes', async () => {
    const { wrapper, setBusy, clearBusy } = mountWorkspaceItem()
    expandItem()
    setBusy(['task_alpha'])
    await nextTick()
    expect(visibleChips(wrapper)).toHaveLength(1)
    // Worker SSE emits a 'deleted' event → App.vue clears the entries.
    clearBusy()
    await nextTick()
    expect(visibleSpinners(wrapper)).toHaveLength(0)
    expect(visibleChips(wrapper)).toHaveLength(0)
  })

  it('shows no chip for tasks that are not running', async () => {
    const { wrapper, setBusy } = mountWorkspaceItem()
    expandItem()
    setBusy(['task_beta'])
    await nextTick()
    // Only beta's chip shows; alpha's row has no chip.
    expect(visibleChips(wrapper)).toHaveLength(1)
    expect(wrapper.text()).toContain('Alpha task')
    expect(wrapper.text()).toContain('Beta task')
  })
})
