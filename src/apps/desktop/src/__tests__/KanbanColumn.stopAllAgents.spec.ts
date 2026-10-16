/** Tests for KanbanColumn "Stop all agents" menu item — the mirror of
 * KanbanColumn.runAllAgents.spec.ts. The column "⋮" menu gains a 5th item after "Run all agents"
 * that emits `requestStopAllAgents` with the column id and closes the menu. */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { mount, type VueWrapper } from '@vue/test-utils'
import { ref, type Ref } from 'vue'

import KanbanColumn from '../components/kanban/KanbanColumn.vue'
import type { KanbanColumn as KanbanColumnType, Task } from '../stores/workspaces'

const COL_TODO = 'col_todo'

const makeColumn = (overrides: Partial<KanbanColumnType> = {}): KanbanColumnType => ({
  id: COL_TODO,
  workspace_item_id: 'item_1',
  name: 'todo',
  position: 0,
  created_at: '2026-06-21 12:00:00',
  ...overrides,
})

function mountColumn(
  column: KanbanColumnType,
  tasks: Task[] = [],
  extraProps: Record<string, unknown> = {},
) {
  const processingState: Ref<Record<string, boolean>> = ref({})
  return mount(KanbanColumn, {
    props: { column, tasks, workspaceId: 'ws_1', itemId: 'item_1', ...extraProps },
    global: {
      provide: { processingState },
    },
  })
}

describe('KanbanColumn — Stop all agents menu item', () => {
  let wrapper: VueWrapper | null = null

  beforeEach(() => {
    setActivePinia(createPinia())
  })

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    vi.restoreAllMocks()
  })

  it('menu contains a 5th "Stop all agents" item after Run all agents', async () => {
    wrapper = mountColumn(makeColumn())
    await wrapper.find(`[data-testid="kanban-column-${COL_TODO}-menu-trigger"]`).trigger('click')
    const stopAll = wrapper.find(`[data-testid="kanban-column-${COL_TODO}-menu-stop-all"]`)
    expect(stopAll.exists()).toBe(true)
    expect(stopAll.text()).toContain('Stop all agents')
  })

  it('clicking Stop all agents emits requestStopAllAgents with the column id and closes the menu', async () => {
    wrapper = mountColumn(makeColumn())
    await wrapper.find(`[data-testid="kanban-column-${COL_TODO}-menu-trigger"]`).trigger('click')
    await wrapper.find(`[data-testid="kanban-column-${COL_TODO}-menu-stop-all"]`).trigger('click')
    expect(wrapper.emitted('requestStopAllAgents')?.[0]).toEqual([COL_TODO])
    // Menu closes after the click (same as Rename/Delete/Run-all).
    expect(wrapper.find(`[data-testid="kanban-column-${COL_TODO}-menu"]`).exists()).toBe(false)
  })

  it('disables the Stop all agents item while stopAllBusy is true', async () => {
    wrapper = mountColumn(makeColumn(), [], { stopAllBusy: true })
    await wrapper.find(`[data-testid="kanban-column-${COL_TODO}-menu-trigger"]`).trigger('click')
    const stopAll = wrapper.find(`[data-testid="kanban-column-${COL_TODO}-menu-stop-all"]`)
    expect(stopAll.exists()).toBe(true)
    expect(stopAll.attributes('disabled')).toBeDefined()
  })

  it('Run-all busy does not disable the Stop-all item (independent guards)', async () => {
    wrapper = mountColumn(makeColumn(), [], { runAllBusy: true })
    await wrapper.find(`[data-testid="kanban-column-${COL_TODO}-menu-trigger"]`).trigger('click')
    const stopAll = wrapper.find(`[data-testid="kanban-column-${COL_TODO}-menu-stop-all"]`)
    expect(stopAll.attributes('disabled')).toBeUndefined()
  })
})
