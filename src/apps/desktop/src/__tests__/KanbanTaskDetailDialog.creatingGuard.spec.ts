/** Tests for the double-click guard on the create-mode commit buttons ("Create task" + "▶ Create
 * task & run agent") in KanbanTaskDetailDialog. Plan:
 * docs/superpowers/plans/2026-08-24-kanban-create-run-disable-double-click.md */
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { flushPromises, mount, type VueWrapper } from '@vue/test-utils'
import { setActivePinia, createPinia } from 'pinia'

import KanbanTaskDetailDialog from '@/components/kanban/KanbanTaskDetailDialog.vue'

function findInDom<T extends Element = Element>(selector: string): T | null {
  return document.querySelector<T>(selector)
}

function findAllInDom<T extends Element = Element>(selector: string): T[] {
  return Array.from(document.querySelectorAll<T>(selector))
}

/** Type a non-empty name so the buttons would be enabled absent the guard. */
async function typeName(name: string) {
  const input = findInDom<HTMLInputElement>(
    '[data-testid="kanban-task-detail-create-name"]',
  )
  if (!input) throw new Error('name input missing')
  input.value = name
  input.dispatchEvent(new Event('input', { bubbles: true }))
  await flushPromises()
}

describe('KanbanTaskDetailDialog — creating prop (double-click guard)', () => {
  let wrapper: VueWrapper | null = null

  beforeEach(() => {
    setActivePinia(createPinia())
  })

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    findAllInDom('[data-testid="kanban-task-detail-dialog"]').forEach((el) => el.remove())
  })

  function mountDialog(propsOverride: Record<string, unknown> = {}) {
    document.body.innerHTML = ''
    wrapper = mount(KanbanTaskDetailDialog, {
      attachTo: document.body,
      props: { show: true, task: null, mode: 'create', ...propsOverride },
    })
    return wrapper
  }

  it('disables BOTH create buttons while creating=true (even with a valid name)', async () => {
    mountDialog({ creating: true })
    await flushPromises()
    await typeName('My task')

    const saveBtn = findInDom<HTMLButtonElement>(
      '[data-testid="kanban-task-detail-save"]',
    )
    const runBtn = findInDom<HTMLButtonElement>(
      '[data-testid="kanban-task-detail-create-and-run"]',
    )
    expect(saveBtn?.disabled).toBe(true)
    expect(runBtn?.disabled).toBe(true)
  })

  it('narrates the in-flight state on the primary half only', async () => {
    mountDialog({ creating: true })
    await flushPromises()
    await typeName('My task')

    // Create mode's primary half is the run action. The "Create task only" menu row keeps its own
    // label — the two used to read "Creating…" side by side, so the footer could not say which
    // commit the user had actually pressed.
    const runBtn = findInDom<HTMLButtonElement>(
      '[data-testid="kanban-task-detail-create-and-run"]',
    )
    const saveMenuItem = findInDom<HTMLButtonElement>(
      '[data-testid="kanban-task-detail-save"]',
    )
    expect(runBtn?.textContent?.trim()).toBe('Creating…')
    expect(saveMenuItem?.textContent).toContain('Create task only')
  })

  it('does NOT emit create when the save button is clicked while creating=true', async () => {
    mountDialog({ creating: true })
    await flushPromises()
    await typeName('My task')

    const saveBtn = findInDom<HTMLButtonElement>(
      '[data-testid="kanban-task-detail-save"]',
    )
    saveBtn?.click()
    await flushPromises()
    expect(wrapper!.emitted('create')).toBeUndefined()
  })

  it('does NOT emit create-and-run when that button is clicked while creating=true', async () => {
    mountDialog({ creating: true })
    await flushPromises()
    await typeName('My task')

    const runBtn = findInDom<HTMLButtonElement>(
      '[data-testid="kanban-task-detail-create-and-run"]',
    )
    runBtn?.click()
    await flushPromises()
    expect(wrapper!.emitted('create-and-run')).toBeUndefined()
  })

  it('keeps normal labels + enabled buttons when creating=false (default)', async () => {
    mountDialog()
    await flushPromises()
    await typeName('My task')

    const saveBtn = findInDom<HTMLButtonElement>(
      '[data-testid="kanban-task-detail-save"]',
    )
    const runBtn = findInDom<HTMLButtonElement>(
      '[data-testid="kanban-task-detail-create-and-run"]',
    )
    expect(saveBtn?.disabled).toBe(false)
    expect(runBtn?.disabled).toBe(false)
    expect(saveBtn?.textContent).toContain('Create task only')
    expect(runBtn?.textContent).toContain('Create task & run agent')
  })

  it('re-enables + restores labels when creating flips back to false', async () => {
    mountDialog({ creating: true })
    await flushPromises()
    await typeName('My task')
    expect(
      findInDom<HTMLButtonElement>('[data-testid="kanban-task-detail-save"]')
        ?.disabled,
    ).toBe(true)

    await wrapper!.setProps({ creating: false })
    await flushPromises()

    const saveBtn = findInDom<HTMLButtonElement>(
      '[data-testid="kanban-task-detail-save"]',
    )
    const runBtn = findInDom<HTMLButtonElement>(
      '[data-testid="kanban-task-detail-create-and-run"]',
    )
    expect(saveBtn?.disabled).toBe(false)
    expect(runBtn?.disabled).toBe(false)
    expect(saveBtn?.textContent).toContain('Create task only')
    expect(runBtn?.textContent).toContain('Create task & run agent')
  })

  it('edit mode is unaffected: Save stays governed by canSave even with creating=true', async () => {
    mountDialog({
      mode: 'edit',
      creating: true,
      task: {
        id: 'task_1',
        name: 'Existing',
        description: '',
        task_type: 'standard',
      },
    })
    await flushPromises()

    const saveBtn = findInDom<HTMLButtonElement>(
      '[data-testid="kanban-task-detail-save"]',
    )
    // Not dirty yet → disabled (canSave semantics, not the creating gate).
    expect(saveBtn?.disabled).toBe(true)
    expect(saveBtn?.textContent?.trim()).toBe('Save')

    // Make it dirty → Save enables despite creating=true (edit mode ignores the creating prop — the
    // host only binds it on the create-mode mount). Edit mode's name input uses the
    // `kanban-task-detail-name` testid (create uses `-create-name`).
    const nameInput = findInDom<HTMLInputElement>(
      '[data-testid="kanban-task-detail-name"]',
    )
    if (!nameInput) throw new Error('name input missing')
    nameInput.value = 'Renamed'
    nameInput.dispatchEvent(new Event('input', { bubbles: true }))
    await flushPromises()
    expect(saveBtn?.disabled).toBe(false)
  })
})
