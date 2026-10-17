/** The busy indicator for the SELECTED workspace lives in the Projects section header as a dot + "N
 * running" text — never an elapsed time pill. */
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { nextTick, ref, type Ref } from 'vue'
import { mount } from '@vue/test-utils'

import ProjectsList from '../components/workspace/ProjectsList.vue'
import WorkspaceItem from '../components/workspace/WorkspaceItem.vue'
import type { WorkerActivity } from '../components/WorkerElapsedChip.vue'
import { type Workspace, type WorkspaceItem as WsItem } from '../stores/workspaces'
import { makeLocalStorageStub } from './helpers'

function makeWorkspace(
  id: string,
  name: string,
  items: Array<WsItem & { tasks?: Array<{ id: string; name: string }> }> = [],
): Workspace {
  return {
    id,
    name,
    icon: '📂',
    expanded: true,
    items: items as WsItem[],
  }
}

function mountProjectsList(workspace: Workspace | null) {
  const processingState: Ref<Record<string, boolean>> = ref({})
  const workerActivity = ref<Record<string, WorkerActivity>>({})
  const workerNow = ref(Date.now())
  const wrapper = mount(ProjectsList, {
    props: {
      workspace,
      activeWorkspaceItemId: null,
    },
    global: {
      provide: { processingState, workerActivity, workerNow },
      // Render the real WorkspaceItem so its (stubbed-key) presence
      // matches production; the chip under test is in the header.
      stubs: { WorkspaceItem: WorkspaceItem },
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

const visibleHeaderSpinners = (wrapper: ReturnType<typeof mount>) =>
  wrapper.findAll('[data-testid="workspace-processing-spinner"]')
const visibleHeaderChips = (wrapper: ReturnType<typeof mount>) =>
  wrapper.findAll('[data-testid="workspace-elapsed-chip"]')
const visibleRunningIndicator = (wrapper: ReturnType<typeof mount>) =>
  wrapper.findAll('[data-testid="workspace-running-indicator"]')

describe('ProjectsList section-header running indicator', () => {
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

  it('shows no indicator and no elapsed chip when no task is busy', async () => {
    const ws = makeWorkspace('ws_1', 'Coding', [
      {
        id: 'item_1',
        name: 'be',
        item_type: 'folder',
        tasks: [{ id: 'task_a', name: 'A' }],
      },
    ])
    const { wrapper, setBusy } = mountProjectsList(ws)
    await nextTick()
    setBusy(['task_x']) // unrelated task
    await nextTick()
    expect(visibleHeaderSpinners(wrapper)).toHaveLength(0)
    expect(visibleHeaderChips(wrapper)).toHaveLength(0)
    expect(visibleRunningIndicator(wrapper)).toHaveLength(0)
    wrapper.unmount()
  })

  it('shows the running indicator (and never an elapsed chip) when a task is running', async () => {
    const ws = makeWorkspace('ws_1', 'Coding', [
      {
        id: 'item_1',
        name: 'be',
        item_type: 'folder',
        tasks: [{ id: 'task_a', name: 'A' }],
      },
    ])
    const { wrapper, setBusy } = mountProjectsList(ws)
    await nextTick()
    setBusy(['task_a'])
    await nextTick()
    expect(visibleHeaderSpinners(wrapper)).toHaveLength(0)
    // One run renders one pill: the pill lives on the owning row, so the
    // header must never render an elapsed chip.
    expect(visibleHeaderChips(wrapper)).toHaveLength(0)
    expect(visibleRunningIndicator(wrapper)).toHaveLength(1)
    expect(visibleRunningIndicator(wrapper)[0]!.text()).toContain('1 running')
    wrapper.unmount()
  })

  it('hides the indicator when the last busy task finishes', async () => {
    const ws = makeWorkspace('ws_1', 'Coding', [
      {
        id: 'item_1',
        name: 'be',
        item_type: 'folder',
        tasks: [{ id: 'task_a', name: 'A' }],
      },
    ])
    const { wrapper, setBusy, clearBusy } = mountProjectsList(ws)
    await nextTick()
    setBusy(['task_a'])
    await nextTick()
    expect(visibleRunningIndicator(wrapper)).toHaveLength(1)
    // Worker SSE emits 'deleted' → App.vue clears the entry.
    clearBusy()
    await nextTick()
    expect(visibleHeaderSpinners(wrapper)).toHaveLength(0)
    expect(visibleHeaderChips(wrapper)).toHaveLength(0)
    expect(visibleRunningIndicator(wrapper)).toHaveLength(0)
    wrapper.unmount()
  })

  it('indicator renders in the section header AFTER the chevron in DOM order', async () => {
    const ws = makeWorkspace('ws_1', 'Coding', [
      {
        id: 'item_1',
        name: 'be',
        item_type: 'folder',
        tasks: [{ id: 'task_a', name: 'A' }],
      },
    ])
    const { wrapper, setBusy } = mountProjectsList(ws)
    await nextTick()
    setBusy(['task_a'])
    await nextTick()
    const header = wrapper.find('[data-testid="projects-section-header"]')
    const html = header.html()
    const chevronIdx = html.indexOf('▶')
    const indIdx = html.indexOf('workspace-running-indicator')
    const chipIdx = html.indexOf('workspace-elapsed-chip')
    expect(chevronIdx).toBeGreaterThan(-1)
    expect(indIdx).toBeGreaterThan(-1)
    expect(indIdx).toBeGreaterThan(chevronIdx)
    // Header never renders an elapsed pill, even while busy.
    expect(chipIdx).toBe(-1)
    wrapper.unmount()
  })

  it('renders no indicator (and the empty-state hint) when there is no selected workspace', async () => {
    const { wrapper, setBusy } = mountProjectsList(null)
    await nextTick()
    setBusy(['task_any'])
    await nextTick()
    expect(visibleHeaderSpinners(wrapper)).toHaveLength(0)
    expect(visibleHeaderChips(wrapper)).toHaveLength(0)
    expect(visibleRunningIndicator(wrapper)).toHaveLength(0)
    expect(wrapper.find('[data-testid="projects-no-workspace"]').exists()).toBe(true)
    wrapper.unmount()
  })
})
