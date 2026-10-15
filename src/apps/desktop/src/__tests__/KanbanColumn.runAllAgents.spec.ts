/** Tests for KanbanColumn "Run all agents" menu item (plan:
 * docs/superpowers/plans/2026-09-09-run-all-agents-by-column.md, Task 3, Option C). */

/** The column "⋮" menu gains a 4th item after Delete that emits `requestRunAllAgents` with the
 * column id and closes the menu. Accepts a `runAllBusy` prop for the in-flight state (disabled
 * while a bulk run for that column is in flight). */
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

describe('KanbanColumn — Run all agents menu item', () => {
  let wrapper: VueWrapper | null = null

  beforeEach(() => {
    setActivePinia(createPinia())
  })

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    vi.restoreAllMocks()
  })

  it('menu contains a 4th "Run all agents" item after Delete', async () => {
    wrapper = mountColumn(makeColumn())
    await wrapper.find(`[data-testid="kanban-column-${COL_TODO}-menu-trigger"]`).trigger('click')
    const runAll = wrapper.find(`[data-testid="kanban-column-${COL_TODO}-menu-run-all"]`)
    expect(runAll.exists()).toBe(true)
    expect(runAll.text()).toContain('Run all agents')
  })

  it('clicking Run all agents emits requestRunAllAgents with the column id and closes the menu', async () => {
    wrapper = mountColumn(makeColumn())
    await wrapper.find(`[data-testid="kanban-column-${COL_TODO}-menu-trigger"]`).trigger('click')
    await wrapper.find(`[data-testid="kanban-column-${COL_TODO}-menu-run-all"]`).trigger('click')
    expect(wrapper.emitted('requestRunAllAgents')?.[0]).toEqual([COL_TODO])
    // Menu closes after the click (same as Rename/Delete).
    expect(
      wrapper.find(`[data-testid="kanban-column-${COL_TODO}-menu"]`).exists(),
    ).toBe(false)
  })

  it('disables the Run all agents item while runAllBusy is true', async () => {
    wrapper = mountColumn(makeColumn(), [], { runAllBusy: true })
    await wrapper.find(`[data-testid="kanban-column-${COL_TODO}-menu-trigger"]`).trigger('click')
    const runAll = wrapper.find(`[data-testid="kanban-column-${COL_TODO}-menu-run-all"]`)
    expect(runAll.exists()).toBe(true)
    expect(runAll.attributes('disabled')).toBeDefined()
  })
})
