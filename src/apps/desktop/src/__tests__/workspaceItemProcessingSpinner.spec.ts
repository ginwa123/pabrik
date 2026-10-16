/** Regression tests for the workspace item row activity marker. The per-TASK row already has its
 * marker, and the per-ITEM row (the project row) must have one too — so a user who collapsed the
 * task list can still tell "this project is busy". */
/** WorkspaceItem reads the same `processingState` ref App.vue provides. The circle spinner was
 * removed — the elapsed time pill is now the only marker. */
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { nextTick, ref, type Ref } from 'vue'
import { mount } from '@vue/test-utils'

import WorkspaceItem from '../components/workspace/WorkspaceItem.vue'
import type { WorkerActivity } from '../components/WorkerElapsedChip.vue'
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

function mountWorkspaceItem(
  tasks: Array<{ id: string; name: string }> = itemWithTasks.tasks,
  isActive: boolean = false,
) {
  const processingState: Ref<Record<string, boolean>> = ref({})
  const workerActivity = ref<Record<string, WorkerActivity>>({})
  const workerNow = ref(Date.now())
  const wrapper = mount(WorkspaceItem, {
    props: {
      item: { ...itemWithTasks, tasks },
      isActive,
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

// No spinner element exists anymore; the elapsed chip is the marker.
const visibleItemSpinners = (wrapper: ReturnType<typeof mount>) =>
  wrapper.findAll('[data-testid="item-processing-spinner"]')
const visibleItemChips = (wrapper: ReturnType<typeof mount>) =>
  wrapper.findAll('[data-testid="item-elapsed-chip"]')

describe('WorkspaceItem item-row elapsed chip', () => {
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

  it('shows no item-row chip when no task is busy', async () => {
    const { wrapper } = mountWorkspaceItem()
    expect(visibleItemSpinners(wrapper)).toHaveLength(0)
    expect(visibleItemChips(wrapper)).toHaveLength(0)
  })

  it('shows an item-row chip when one of its tasks is busy', async () => {
    const { wrapper, setBusy } = mountWorkspaceItem()
    setBusy(['task_alpha'])
    await nextTick()
    expect(visibleItemSpinners(wrapper)).toHaveLength(0)
    expect(visibleItemChips(wrapper)).toHaveLength(1)
    // The item name must still be visible.
    expect(wrapper.text()).toContain('My Project')
  })

  it('hides the item-row chip when the last busy task finishes', async () => {
    const { wrapper, setBusy, clearBusy } = mountWorkspaceItem()
    setBusy(['task_alpha'])
    await nextTick()
    expect(visibleItemChips(wrapper)).toHaveLength(1)
    // Worker SSE emits a 'deleted' event → App.vue clears the entry.
    clearBusy()
    await nextTick()
    expect(visibleItemSpinners(wrapper)).toHaveLength(0)
    expect(visibleItemChips(wrapper)).toHaveLength(0)
  })

  it('keeps the item-row chip visible when one of two tasks is still busy', async () => {
    const { wrapper, setBusy } = mountWorkspaceItem()
    setBusy(['task_alpha', 'task_beta'])
    await nextTick()
    expect(visibleItemChips(wrapper)).toHaveLength(1)
    // Clear only one — the other is still busy → chip stays.
    setBusy(['task_beta'])
    await nextTick()
    expect(visibleItemChips(wrapper)).toHaveLength(1)
  })

  it('shows no item-row chip for an unrelated session', async () => {
    // Guards the key-by-id contract: a session id that does NOT
    // match any task.id must not trigger the chip, even if the
    // map is non-empty.
    const { wrapper, setBusy } = mountWorkspaceItem()
    setBusy(['session_someone_else'])
    await nextTick()
    expect(visibleItemSpinners(wrapper)).toHaveLength(0)
    expect(visibleItemChips(wrapper)).toHaveLength(0)
  })

  it('shows no item-row chip when the item has no tasks', async () => {
    const { wrapper, setBusy } = mountWorkspaceItem([])
    // Even a non-empty busy set must not produce a chip if
    // the item has no tasks at all (no keys to match).
    setBusy(['task_alpha', 'task_beta'])
    await nextTick()
    expect(visibleItemSpinners(wrapper)).toHaveLength(0)
    expect(visibleItemChips(wrapper)).toHaveLength(0)
  })

  it('item-loading spinner and item elapsed chip can render simultaneously in separate slots', async () => {
    // The two indicators live in different slots (loading on the right, elapsed chip right-aligned)
    // and represent independent states (folder-contents fetch vs. LLM worker), so they must be able
    // to show at the same time.
    const processingState: Ref<Record<string, boolean>> = ref({ task_alpha: true })
    const now = Date.now()
    const workerActivity = ref<Record<string, WorkerActivity>>({
      task_alpha: { startedAt: now - 127_000, lastActivityAt: now - 2_000, description: '' },
    })
    const workerNow = ref(now)
    const wrapper = mount(WorkspaceItem, {
      props: {
        item: { ...itemWithTasks, isLoading: true },
        isActive: false,
        workspaceId: 'ws_1',
      },
      global: { provide: { processingState, workerActivity, workerNow } },
    })
    expect(wrapper.findAll('[data-testid="item-loading-spinner"]')).toHaveLength(1)
    expect(visibleItemChips(wrapper)).toHaveLength(1)
  })

  it('active dot and item elapsed chip can render simultaneously', async () => {
    // Same reasoning as the loading/chip pair above: the FolderExplorer active dot and the elapsed
    // chip are independent and must coexist. A user can have a selected item that is also being
    // worked on.
    const { wrapper, setBusy } = mountWorkspaceItem(itemWithTasks.tasks, true)
    setBusy(['task_alpha'])
    await nextTick()
    expect(visibleItemChips(wrapper)).toHaveLength(1)
    expect(wrapper.findAll('[data-testid="item-active-dot"]')).toHaveLength(1)
  })

  it('item-loading spinner still hides the active dot (preserved right-slot priority)', async () => {
    // Even though the active dot no longer competes with the processing slider, it must still be
    // hidden while the loading spinner is showing (original behavior, untouched by this change).
    const processingState: Ref<Record<string, boolean>> = ref({})
    const wrapper = mount(WorkspaceItem, {
      props: {
        item: { ...itemWithTasks, isLoading: true },
        isActive: true,
        workspaceId: 'ws_1',
      },
      global: { provide: { processingState } },
    })
    expect(wrapper.findAll('[data-testid="item-loading-spinner"]')).toHaveLength(1)
    expect(wrapper.findAll('[data-testid="item-active-dot"]')).toHaveLength(0)
  })

  it('item elapsed chip appears AFTER the chevron in DOM order', async () => {
    // The chip sits AFTER the chevron + content in DOM order, not
    // before. Verified by finding the chevron in the row's HTML
    // BEFORE the chip testid.
    const { wrapper, setBusy } = mountWorkspaceItem()
    setBusy(['task_alpha'])
    await nextTick()
    const row = wrapper.find('button')
    const html = row.html()
    const chevronIdx = html.indexOf('item-row-chevron')
    const chipIdx = html.indexOf('item-elapsed-chip')
    expect(chevronIdx).toBeGreaterThan(-1)
    expect(chipIdx).toBeGreaterThan(-1)
    expect(chipIdx).toBeGreaterThan(chevronIdx)
  })
})
