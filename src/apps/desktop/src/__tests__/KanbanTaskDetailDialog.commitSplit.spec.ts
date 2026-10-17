/** Tests for the flat commit buttons in KanbanTaskDetailDialog. Create mode has TWO of them —
 * "Create task" + "▶ Create task & run agent"; edit mode has one ("Save"). The split button, its
 * caret and its menu are gone, so this spec also pins their absence (and the header Back button's). */
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

async function typeName(name: string) {
  const input = findInDom<HTMLInputElement>('[data-testid="kanban-task-detail-create-name"]')
  if (!input) throw new Error('name input missing')
  input.value = name
  input.dispatchEvent(new Event('input', { bubbles: true }))
  await flushPromises()
}

const EDIT_TASK = {
  id: 'task_1',
  name: 'Existing',
  description: '',
  task_type: 'standard',
} as never

describe('KanbanTaskDetailDialog — flat commit buttons', () => {
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

  it('create mode: the two commit actions are flat siblings, not a split button', async () => {
    mountDialog()
    await flushPromises()

    // Exactly one element carries each testid — each commit action owns its own button.
    expect(findAllInDom('[data-testid="kanban-task-detail-create-and-run"]')).toHaveLength(1)
    expect(findAllInDom('[data-testid="kanban-task-detail-save"]')).toHaveLength(1)
    expect(findInDom('[data-testid="kanban-task-detail-create-and-run"]')?.textContent).toContain(
      'Create task & run agent',
    )
    // The plain-create label is "Create task": "Create task only" was the caret-menu wording.
    expect(findInDom('[data-testid="kanban-task-detail-save"]')?.textContent?.trim()).toBe(
      'Create task',
    )
    // "Start agent" is edit-mode only.
    expect(findInDom('[data-testid="kanban-task-detail-start-agent"]')).toBeNull()
  })

  it('create mode: no caret, no commit menu and no header Back button', async () => {
    mountDialog()
    await flushPromises()

    expect(findInDom('[data-testid="kanban-task-detail-commit-caret"]')).toBeNull()
    expect(findInDom('[data-testid="kanban-task-detail-commit-menu"]')).toBeNull()
    expect(findInDom('[data-testid="kanban-task-detail-back"]')).toBeNull()
    // The ways out that survived the restructure: the header cross and the footer Cancel.
    expect(findInDom('[data-testid="kanban-task-detail-close"]')).not.toBeNull()
    expect(findInDom('[data-testid="kanban-task-detail-cancel"]')).not.toBeNull()
  })

  it('edit mode: one flat Save button, and Start agent now lives in the settings rail', async () => {
    mountDialog({ mode: 'edit', task: EDIT_TASK })
    await flushPromises()

    expect(findInDom('[data-testid="kanban-task-detail-save"]')?.textContent?.trim()).toBe('Save')
    expect(findInDom('[data-testid="kanban-task-detail-create-and-run"]')).toBeNull()
    expect(findInDom('[data-testid="kanban-task-detail-commit-caret"]')).toBeNull()
    expect(findInDom('[data-testid="kanban-task-detail-commit-menu"]')).toBeNull()
    expect(findInDom('[data-testid="kanban-task-detail-back"]')).toBeNull()

    // Start agent moved out of the caret menu into the rail's full-width "Run the agent" group.
    const startAgent = findInDom<HTMLButtonElement>(
      '[data-testid="kanban-task-detail-start-agent"]',
    )
    expect(startAgent?.textContent).toContain('Start agent')
    expect(startAgent?.closest('aside.ktd-rail')).not.toBeNull()
    expect(startAgent?.parentElement?.textContent).toContain('Run the agent')
  })

  it('pressing Create task emits create, and emits nothing from the run action', async () => {
    const w = mountDialog()
    await flushPromises()
    await typeName('My task')

    findInDom<HTMLButtonElement>('[data-testid="kanban-task-detail-save"]')!.click()
    await flushPromises()

    expect(w.emitted('create')).toBeTruthy()
    expect(w.emitted('create-and-run')).toBeUndefined()
  })

  it('pressing ▶ Create task & run agent emits create-and-run, and no plain create', async () => {
    const w = mountDialog()
    await flushPromises()
    await typeName('My task')

    findInDom<HTMLButtonElement>('[data-testid="kanban-task-detail-create-and-run"]')!.click()
    await flushPromises()

    expect(w.emitted('create-and-run')).toBeTruthy()
    expect(w.emitted('create')).toBeUndefined()
  })

  it('Escape closes the whole panel — there is no menu layer left to peel', async () => {
    const w = mountDialog()
    await flushPromises()
    await typeName('My task')

    expect(w.emitted('close')).toBeFalsy()
    // The root div owns the keydown handler, so the event must originate inside the panel.
    findInDom<HTMLButtonElement>('[data-testid="kanban-task-detail-save"]')!.dispatchEvent(
      new KeyboardEvent('keydown', { key: 'Escape', bubbles: true }),
    )
    await flushPromises()

    expect(w.emitted('close')).toBeTruthy()
    expect(w.emitted('update:show')?.[0]).toEqual([false])
  })

  it('both commit buttons obey the same enable rule: an empty name disables each of them', async () => {
    mountDialog()
    await flushPromises()

    // Empty name → neither commit path is available.
    expect(findInDom<HTMLButtonElement>('[data-testid="kanban-task-detail-save"]')!.disabled).toBe(
      true,
    )
    expect(
      findInDom<HTMLButtonElement>('[data-testid="kanban-task-detail-create-and-run"]')!.disabled,
    ).toBe(true)

    await typeName('My task')
    expect(findInDom<HTMLButtonElement>('[data-testid="kanban-task-detail-save"]')!.disabled).toBe(
      false,
    )
    expect(
      findInDom<HTMLButtonElement>('[data-testid="kanban-task-detail-create-and-run"]')!.disabled,
    ).toBe(false)
  })
})

describe('KanbanTaskDetailDialog — per-action pending label', () => {
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

  it('pressing Create task narrates "Creating…" on it, not "Starting…"', async () => {
    mountDialog()
    await flushPromises()
    await typeName('My task')

    // Click first — that is what attributes the in-flight state — then raise `creating` the way the
    // host does once the request is on the wire.
    findInDom<HTMLButtonElement>('[data-testid="kanban-task-detail-save"]')!.click()
    await flushPromises()
    await wrapper!.setProps({ creating: true })
    await flushPromises()

    const saveBtn = findInDom<HTMLButtonElement>('[data-testid="kanban-task-detail-save"]')
    expect(saveBtn?.textContent?.trim()).toBe('Creating…')
    expect(saveBtn?.textContent).not.toContain('Starting')
    // The button the user did NOT press keeps its own label.
    expect(findInDom('[data-testid="kanban-task-detail-create-and-run"]')?.textContent).toContain(
      'Create task & run agent',
    )
  })

  it('pressing ▶ Create task & run agent narrates "Starting…" on it, not "Creating…"', async () => {
    mountDialog()
    await flushPromises()
    await typeName('My task')

    findInDom<HTMLButtonElement>('[data-testid="kanban-task-detail-create-and-run"]')!.click()
    await flushPromises()
    await wrapper!.setProps({ creating: true })
    await flushPromises()

    const runBtn = findInDom<HTMLButtonElement>('[data-testid="kanban-task-detail-create-and-run"]')
    expect(runBtn?.textContent?.trim()).toBe('Starting…')
    expect(runBtn?.textContent).not.toContain('Creating')
    expect(findInDom('[data-testid="kanban-task-detail-save"]')?.textContent?.trim()).toBe(
      'Create task',
    )
  })

  it('a host-raised creating with no click narrates on the run button and leaves Create task alone', async () => {
    // No handler ran, so `pendingAction` is null and there is nothing to attribute the in-flight
    // state to. The neutral wording lands on the primary action — the create button keeps its own
    // label, which is the bug this spec exists to prevent regressing.
    mountDialog({ creating: true })
    await flushPromises()
    await typeName('My task')

    const runBtn = findInDom<HTMLButtonElement>('[data-testid="kanban-task-detail-create-and-run"]')
    expect(runBtn?.textContent?.trim()).toBe('Creating…')
    expect(findInDom('[data-testid="kanban-task-detail-save"]')?.textContent?.trim()).toBe(
      'Create task',
    )
  })

  it('the narration clears once creating flips back to false', async () => {
    mountDialog()
    await flushPromises()
    await typeName('My task')

    findInDom<HTMLButtonElement>('[data-testid="kanban-task-detail-create-and-run"]')!.click()
    await flushPromises()
    await wrapper!.setProps({ creating: true })
    await flushPromises()
    expect(
      findInDom<HTMLButtonElement>('[data-testid="kanban-task-detail-create-and-run"]')
        ?.textContent,
    ).toContain('Starting…')

    await wrapper!.setProps({ creating: false })
    await flushPromises()
    const runBtn = findInDom<HTMLButtonElement>('[data-testid="kanban-task-detail-create-and-run"]')
    expect(runBtn?.textContent).toContain('Create task & run agent')
    expect(runBtn?.textContent).not.toContain('Starting')
  })
})
