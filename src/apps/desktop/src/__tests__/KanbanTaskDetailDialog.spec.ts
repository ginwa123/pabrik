/** Tests for KanbanTaskDetailDialog — focused, edit-in-place task detail view. Used by the kanban
 * tree to edit a task's name + description with optional metadata (column, type, pinned). Mount
 * pattern: same as KanbanSettingsDialog.spec.ts. */
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { flushPromises, mount, type VueWrapper } from '@vue/test-utils'
import { setActivePinia, createPinia } from 'pinia'
import KanbanTaskDetailDialog from '@/components/kanban/KanbanTaskDetailDialog.vue'
import type { Task, KanbanColumn } from '@/stores/workspaces'

const TASK: Task = {
  id: 'task_test_1',
  name: 'Original name',
  description: 'Original description',
  task_type: 'standard',
}

function findInDom<T extends Element = Element>(selector: string): T | null {
  return document.querySelector<T>(selector)
}

function findAllInDom<T extends Element = Element>(selector: string): T[] {
  return Array.from(document.querySelectorAll<T>(selector))
}

function clickInDom(selector: string) {
  const el = findInDom<HTMLElement>(selector)
  if (!el) throw new Error(`No element found: ${selector}`)
  el.click()
}

function setInputValue(selector: string, value: string) {
  const el = findInDom<HTMLInputElement | HTMLTextAreaElement>(selector)
  if (!el) throw new Error(`No element found: ${selector}`)
  el.value = value
  el.dispatchEvent(new Event('input', { bubbles: true }))
}

describe('KanbanTaskDetailDialog — render', () => {
  let wrapper: VueWrapper | null = null

  beforeEach(() => {
    setActivePinia(createPinia())
  })

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    // Force-remove any leftover teleported DOM from previous test.
    findAllInDom('[data-testid="kanban-task-detail-dialog"]').forEach((el) => el.remove())
  })

  function mountDialog(task: Task | null = TASK, show = true) {
    document.body.innerHTML = ''
    wrapper = mount(KanbanTaskDetailDialog, {
      attachTo: document.body,
      props: { show, task },
    })
    return wrapper
  }

  it('does not render the dialog when show=false', async () => {
    mountDialog(TASK, false)
    await flushPromises()
    expect(findInDom('[data-testid="kanban-task-detail-dialog"]')).toBeNull()
  })

  it('renders the dialog when show=true and task is provided', async () => {
    mountDialog()
    await flushPromises()
    expect(findInDom('[data-testid="kanban-task-detail-dialog"]')).not.toBeNull()
  })

  it('pre-fills the name input with the task name', async () => {
    mountDialog()
    await flushPromises()
    const input = findInDom<HTMLInputElement>('[data-testid="kanban-task-detail-name"]')
    expect(input?.value).toBe('Original name')
  })

  it('pre-fills the description textarea with the task description', async () => {
    mountDialog()
    await flushPromises()
    const textarea = findInDom<HTMLTextAreaElement>(
      '[data-testid="kanban-task-detail-description"]',
    )
    expect(textarea?.value).toBe('Original description')
  })

  it('pre-fills description with empty string when task has no description', async () => {
    mountDialog({ ...TASK, description: undefined })
    await flushPromises()
    const textarea = findInDom<HTMLTextAreaElement>(
      '[data-testid="kanban-task-detail-description"]',
    )
    expect(textarea?.value).toBe('')
  })
})

describe('KanbanTaskDetailDialog — save / cancel', () => {
  let wrapper: VueWrapper | null = null

  beforeEach(() => {
    setActivePinia(createPinia())
  })

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    findAllInDom('[data-testid="kanban-task-detail-dialog"]').forEach((el) => el.remove())
  })

  function mountDialog(task: Task | null = TASK) {
    document.body.innerHTML = ''
    wrapper = mount(KanbanTaskDetailDialog, {
      attachTo: document.body,
      props: { show: true, task },
    })
    return wrapper
  }

  it('emits save with the trimmed name + raw description', async () => {
    const w = mountDialog()
    await flushPromises()
    setInputValue('[data-testid="kanban-task-detail-name"]', '  New name  ')
    setInputValue('[data-testid="kanban-task-detail-description"]', 'New description')
    await flushPromises()
    clickInDom('[data-testid="kanban-task-detail-save"]')

    const emitted = w!.emitted('save')
    expect(emitted).toBeTruthy()
    expect(emitted![0]).toEqual([
      { mode: 'edit', name: 'New name', description: 'New description', tags: [] },
    ])
  })

  it('emits save with description = "" when the textarea is cleared', async () => {
    const w = mountDialog()
    await flushPromises()
    setInputValue('[data-testid="kanban-task-detail-description"]', '')
    await flushPromises()
    clickInDom('[data-testid="kanban-task-detail-save"]')

    const emitted = w!.emitted('save')
    expect(emitted).toBeTruthy()
    expect(emitted![0]).toEqual([
      { mode: 'edit', name: 'Original name', description: '', tags: [] },
    ])
  })

  it('emits close (not save) when the cancel button is clicked', async () => {
    const w = mountDialog()
    await flushPromises()
    clickInDom('[data-testid="kanban-task-detail-cancel"]')
    expect(w!.emitted('close')).toBeTruthy()
    expect(w!.emitted('save')).toBeFalsy()
  })

  it('emits update:show=false on close (for v-model:show wiring)', async () => {
    // Regression: KanbanView binds `v-model:show` which requires `update:show` events, not the
    // legacy `close` event. Without this emit, the X / Cancel / backdrop / Escape handlers cannot
    // close the dialog.
    const w = mountDialog()
    await flushPromises()
    clickInDom('[data-testid="kanban-task-detail-close"]')
    const updates = w!.emitted('update:show')
    expect(updates).toBeTruthy()
    expect(updates![updates!.length - 1]).toEqual([false])
  })

  it('emits update:show=false when the backdrop is clicked', async () => {
    // The backdrop click handler closes the dialog via the same
    // `handleClose` path as the X button — regression net for the
    // @click.self="handleClose" binding on the outer wrapper.
    const w = mountDialog()
    await flushPromises()
    const backdrop = findInDom<HTMLDivElement>(
      '[data-testid="kanban-task-detail-dialog"] > .backdrop-blur-md',
    )
    expect(backdrop).not.toBeNull()
    backdrop!.click()
    const updates = w!.emitted('update:show')
    expect(updates).toBeTruthy()
    expect(updates![updates!.length - 1]).toEqual([false])
  })

  it('disables save when name is empty (after trim)', async () => {
    mountDialog()
    await flushPromises()
    setInputValue('[data-testid="kanban-task-detail-name"]', '   ') // whitespace only
    await flushPromises()
    const saveBtn = findInDom<HTMLButtonElement>('[data-testid="kanban-task-detail-save"]')
    expect(saveBtn?.hasAttribute('disabled')).toBe(true)
  })

  it('disables save when nothing changed (clean form)', async () => {
    mountDialog()
    await flushPromises()
    const saveBtn = findInDom<HTMLButtonElement>('[data-testid="kanban-task-detail-save"]')
    expect(saveBtn?.hasAttribute('disabled')).toBe(true)
  })

  it('enables save when the name OR description changed', async () => {
    mountDialog()
    await flushPromises()
    setInputValue('[data-testid="kanban-task-detail-description"]', 'Modified description')
    await flushPromises()
    const saveBtn = findInDom<HTMLButtonElement>('[data-testid="kanban-task-detail-save"]')
    expect(saveBtn?.hasAttribute('disabled')).toBe(false)
  })
})

describe('KanbanTaskDetailDialog — metadata strip', () => {
  let wrapper: VueWrapper | null = null

  beforeEach(() => {
    setActivePinia(createPinia())
  })

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    findAllInDom('[data-testid="kanban-task-detail-dialog"]').forEach((el) => el.remove())
  })

  function mountDialog(task: Task, column?: KanbanColumn | null): VueWrapper {
    document.body.innerHTML = ''
    wrapper = mount(KanbanTaskDetailDialog, {
      attachTo: document.body,
      props: { show: true, task, column },
    })
    return wrapper
  }

  it('renders the column name when a column prop is provided', async () => {
    mountDialog(TASK, {
      id: 'col_1',
      workspace_item_id: 'item_1',
      name: 'In progress',
      position: 1,
      created_at: '2026-07-16T10:00:00Z',
    })
    await flushPromises()
    const colEl = findInDom<HTMLElement>('[data-testid="kanban-task-detail-column"]')
    expect(colEl?.textContent).toContain('In progress')
  })

  it('does NOT render a routine type label for legacy task_type routine (deleted Migration 084)', async () => {
    mountDialog({ ...TASK, task_type: 'routine' as never })
    await flushPromises()
    const typeEl = findInDom<HTMLElement>('[data-testid="kanban-task-detail-type"]')
    expect(typeEl).toBeNull()
  })

  it('renders the pinned indicator when is_pinned is true', async () => {
    mountDialog({ ...TASK, is_pinned: true })
    await flushPromises()
    const pinnedEl = findInDom<HTMLElement>('[data-testid="kanban-task-detail-pinned"]')
    expect(pinnedEl).not.toBeNull()
    expect(pinnedEl?.textContent).toContain('Pinned')
  })

  it('hides the metadata strip when no metadata is available', async () => {
    mountDialog({ ...TASK, is_pinned: false })
    await flushPromises()
    expect(findInDom('[data-testid="kanban-task-detail-metadata"]')).toBeNull()
  })

  // ─── Read-only cwd strip (removed by 2026-08-14-kanban-task-detail-edit-cwd) The read-only cwd
  // strip was removed in favour of the always-visible cwd picker.
  it('edit mode: does NOT render the legacy read-only cwd strip', async () => {
    mountDialog({ ...TASK, cwd: '/home/foo/bar' })
    await flushPromises()
    expect(findInDom('[data-testid="kanban-task-detail-cwd-readonly"]')).toBeNull()
    expect(findInDom('[data-testid="kanban-task-detail-cwd-readonly-empty"]')).toBeNull()
  })

  it('edit mode: does NOT render the legacy empty read-only cwd strip', async () => {
    mountDialog({ ...TASK, cwd: '' })
    await flushPromises()
    expect(findInDom('[data-testid="kanban-task-detail-cwd-readonly"]')).toBeNull()
    expect(findInDom('[data-testid="kanban-task-detail-cwd-readonly-empty"]')).toBeNull()
  })
})
