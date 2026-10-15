/** <KanbanTaskRow> — right-click "Run agent". Row mode is the third entry point for starting an
 * agent on an existing task (the card's context menu and the detail dialog's caret menu are the
 * other two). */
/** The row only reports intent — it emits `runAgent` with the task id and <KanbanView> makes the
 * API call — so these tests pin the emit shape and the running-state guard. */
import { beforeEach, describe, expect, it } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { nextTick, ref } from 'vue'
import { mount } from '@vue/test-utils'
import KanbanTaskRow from '../components/kanban/KanbanTaskRow.vue'
import type { Task } from '../stores/workspaces'
import { makeLocalStorageStub } from './helpers'

// Typed rather than a bare literal: `task_type` is a union, and an
// untyped object silently widens it to `string` (TS2322 on mount).
const TASK: Task = {
  id: 'task_row_1',
  name: 'Row task',
  task_type: 'standard',
  kanban_column_id: 'col_todo',
}

function mountRow(processing: Record<string, boolean> = {}) {
  return mount(KanbanTaskRow, {
    attachTo: document.body,
    props: {
      task: TASK,
      workspaceId: 'ws_1',
      itemId: 'item_1',
    },
    global: { provide: { processingState: ref<Record<string, boolean>>(processing) } },
  })
}

const q = (testid: string) =>
  document.body.querySelector(`[data-testid="${testid}"]`) as HTMLElement | null

describe('KanbanTaskRow — Run agent', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    Object.defineProperty(globalThis, 'localStorage', {
      value: makeLocalStorageStub(),
      writable: true,
      configurable: true,
    })
    document.body.innerHTML = ''
  })

  it('emits runAgent with the task id', async () => {
    const wrapper = mountRow()
    await nextTick()
    await wrapper.find('[data-task-row]').trigger('contextmenu', { clientX: 30, clientY: 40 })
    await nextTick()

    const item = q('run-agent-item')
    expect(item).toBeTruthy()
    expect(item?.textContent).toContain('Run agent')

    item!.click()
    await nextTick()

    expect(wrapper.emitted('runAgent')?.[0]).toEqual([{ taskId: 'task_row_1' }])
    wrapper.unmount()
  })

  it('hides the row while a worker runs on the task', async () => {
    // The backend answers 409 to a second start, so the row must not
    // offer the action while a worker is in flight.
    const wrapper = mountRow({ task_row_1: true })
    await nextTick()
    await wrapper.find('[data-task-row]').trigger('contextmenu', { clientX: 30, clientY: 40 })
    await nextTick()

    expect(q('run-agent-item')).toBeNull()
    wrapper.unmount()
  })

  it('does not also emit selectTask', async () => {
    const wrapper = mountRow()
    await nextTick()
    await wrapper.find('[data-task-row]').trigger('contextmenu', { clientX: 30, clientY: 40 })
    await nextTick()
    q('run-agent-item')!.click()
    await nextTick()

    expect(wrapper.emitted('runAgent')).toHaveLength(1)
    expect(wrapper.emitted('selectTask')).toBeUndefined()
    wrapper.unmount()
  })
})
