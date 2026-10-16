/** Tests for RoutineView tabs — Routine | Agent (Routine mode task_1789505553300_1, option A,
 * mirror agent_kanban_*). - Routine tab renders by default with the existing config form
 * (description / instruction / schedule / enabled / save / run). */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { flushPromises, mount, type VueWrapper } from '@vue/test-utils'
import { setActivePinia, createPinia } from 'pinia'
import { ref, type Ref } from 'vue'

import RoutineView from '@/components/views/RoutineView.vue'
import * as api from '@/api'
import type { WorkspaceItem } from '@/stores/workspaces'
import { makeLocalStorageStub } from './helpers'

const WS_ID = 'ws_1'
const ITEM_ID = 'item_1'

const baseItem: WorkspaceItem = {
  id: ITEM_ID,
  name: 'Nightly check',
  item_type: 'routine',
  path: '/tmp/routine',
}

function mountView(item: WorkspaceItem = baseItem) {
  const processingState: Ref<Record<string, boolean>> = ref({})
  return mount(RoutineView, {
    attachTo: document.body,
    props: {
      item,
      workspaceId: WS_ID,
      itemId: item.id,
    },
    global: {
      provide: { processingState },
    },
  })
}

describe('RoutineView tabs', () => {
  let wrapper: VueWrapper | null = null

  beforeEach(() => {
    setActivePinia(createPinia())
    Object.defineProperty(globalThis, 'localStorage', {
      value: makeLocalStorageStub(),
      writable: true,
      configurable: true,
    })
    vi.spyOn(api, 'getRoutineItem').mockResolvedValue({
      routine: {
        id: ITEM_ID,
        workspace_item_id: ITEM_ID,
        description: 'desc',
        instruction: 'do things',
        schedule: '',
        enabled: true,
        last_run_at: '',
        next_run_at: '',
        last_status: 'idle',
        last_error: '',
        created_at: '',
        updated_at: '',
      },
    })
    vi.spyOn(api, 'getAgentRoutine').mockResolvedValue({
      agent_routine: {
        id: ITEM_ID,
        workspace_item_id: ITEM_ID,
        description: '',
        created_at: '',
        updated_at: '',
      },
      knowledges: [],
      tools: [],
      system_prompts: [],
    })
    vi.spyOn(api, 'getAgentToolsRegistry').mockResolvedValue({ tools: [] })
  })

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    vi.restoreAllMocks()
  })

  it('renders the Routine tab by default with the config form', async () => {
    wrapper = mountView()
    await flushPromises()
    expect(wrapper.find('[data-testid="routine-description"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="routine-instruction"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="routine-agent-panel"]').exists()).toBe(false)
  })

  it('loads the agent bundle with workspace + item ids', async () => {
    wrapper = mountView()
    await flushPromises()
    expect(api.getAgentRoutine).toHaveBeenCalledWith(WS_ID, ITEM_ID)
  })

  it('switching to the Agent tab shows the AgentView panel', async () => {
    wrapper = mountView()
    await flushPromises()
    await wrapper.find('[data-testid="routine-tab-agent"]').trigger('click')
    expect(wrapper.find('[data-testid="routine-agent-panel"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="routine-description"]').exists()).toBe(false)
  })

  it('switching back to Routine restores the config form', async () => {
    wrapper = mountView()
    await flushPromises()
    await wrapper.find('[data-testid="routine-tab-agent"]').trigger('click')
    await wrapper.find('[data-testid="routine-tab-routine"]').trigger('click')
    expect(wrapper.find('[data-testid="routine-description"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="routine-agent-panel"]').exists()).toBe(false)
  })
})
