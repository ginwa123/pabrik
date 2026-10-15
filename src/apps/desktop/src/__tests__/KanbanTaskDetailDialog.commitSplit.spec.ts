/**
 * Tests for the commit split button in KanbanTaskDetailDialog.
 *
 * The footer is one split control: a primary half plus a caret menu
 * holding the alternative commit. Which half is primary depends on the
 * mode —
 *   create:  half = "▶ Create task & run agent", menu = "Create task only"
 *   edit:    half = "Save",                        menu = "▶ Start agent"
 *
 * All four original data-testids are preserved; two of them just moved
 * into the menu. The menu is toggled with v-show rather than v-if, so
 * its items stay in the DOM while closed — `findInDom` works either way,
 * and the assertions below deliberately do not depend on the open state.
 *
 * The second half of this file covers the per-action pending label: only
 * the action the user actually pressed narrates the in-flight state, so
 * the footer can say which commit is running instead of flashing the
 * same word twice.
 *
 * Mount pattern: <Teleport to="body">, so use `attachTo: document.body`
 * + `document.querySelector` (NOT `wrapper.find`).
 *
 * Plan: docs/plans/2026-09-29-kanban-task-detail-3-buttons.md
 */
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

describe('KanbanTaskDetailDialog — commit split button', () => {
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

  // ── structure ────────────────────────────────────────────────────────

  it('create mode: the run action is the primary half and plain create is in the menu', async () => {
    mountDialog()
    await flushPromises()

    // Exactly one element carries each testid — the two commit paths are
    // split across the halves, not duplicated.
    expect(findAllInDom('[data-testid="kanban-task-detail-create-and-run"]')).toHaveLength(1)
    expect(findAllInDom('[data-testid="kanban-task-detail-save"]')).toHaveLength(1)
    expect(findInDom('[data-testid="kanban-task-detail-create-and-run"]')?.textContent).toContain(
      'Create task & run agent',
    )
    expect(findInDom('[data-testid="kanban-task-detail-save"]')?.textContent).toContain(
      'Create task only',
    )
    // "Start agent" is edit-mode only.
    expect(findInDom('[data-testid="kanban-task-detail-start-agent"]')).toBeNull()
  })

  it('edit mode: Save is the primary half and Start agent is in the menu', async () => {
    mountDialog({ mode: 'edit', task: EDIT_TASK })
    await flushPromises()

    expect(findInDom('[data-testid="kanban-task-detail-save"]')?.textContent?.trim()).toBe('Save')
    expect(findInDom('[data-testid="kanban-task-detail-start-agent"]')?.textContent).toContain(
      'Start agent',
    )
    expect(findInDom('[data-testid="kanban-task-detail-create-and-run"]')).toBeNull()
  })

  // ── caret behaviour ──────────────────────────────────────────────────

  it('the caret opens and closes the menu, and reports it via aria-expanded', async () => {
    mountDialog()
    await flushPromises()
    await typeName('My task')

    const caret = findInDom<HTMLButtonElement>('[data-testid="kanban-task-detail-commit-caret"]')!
    const menu = findInDom<HTMLElement>('[data-testid="kanban-task-detail-commit-menu"]')!
    expect(caret.getAttribute('aria-haspopup')).toBe('menu')
    expect(caret.getAttribute('aria-expanded')).toBe('false')
    expect(menu.style.display).toBe('none')

    caret.click()
    await flushPromises()
    expect(caret.getAttribute('aria-expanded')).toBe('true')
    expect(menu.style.display).not.toBe('none')

    caret.click()
    await flushPromises()
    expect(caret.getAttribute('aria-expanded')).toBe('false')
    expect(menu.style.display).toBe('none')
  })

  it('picking a menu item emits the action and closes the menu', async () => {
    mountDialog()
    await flushPromises()
    await typeName('My task')

    findInDom<HTMLButtonElement>('[data-testid="kanban-task-detail-commit-caret"]')!.click()
    await flushPromises()
    findInDom<HTMLButtonElement>('[data-testid="kanban-task-detail-save"]')!.click()
    await flushPromises()

    expect(wrapper!.emitted('create')).toBeTruthy()
    expect(
      findInDom<HTMLElement>('[data-testid="kanban-task-detail-commit-menu"]')!.style.display,
    ).toBe('none')
  })

  it('Escape closes an open menu instead of the whole panel', async () => {
    mountDialog()
    await flushPromises()
    await typeName('My task')

    const caret = findInDom<HTMLButtonElement>('[data-testid="kanban-task-detail-commit-caret"]')!
    caret.click()
    await flushPromises()
    expect(caret.getAttribute('aria-expanded')).toBe('true')

    // The root div owns the keydown handler; the event has to originate
    // inside it, which the caret satisfies.
    caret.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true }))
    await flushPromises()

    expect(caret.getAttribute('aria-expanded')).toBe('false')
    // The panel is still open — Escape peeled one layer, not the whole thing.
    expect(wrapper!.emitted('close')).toBeFalsy()
    expect(wrapper!.emitted('update:show')).toBeFalsy()
  })

  it('the caret is disabled on the same conditions as the primary half', async () => {
    mountDialog()
    await flushPromises()
    const caret = findInDom<HTMLButtonElement>('[data-testid="kanban-task-detail-commit-caret"]')!
    const runBtn = findInDom<HTMLButtonElement>(
      '[data-testid="kanban-task-detail-create-and-run"]',
    )!
    // Empty name → neither commit path is available.
    expect(caret.disabled).toBe(true)
    expect(runBtn?.disabled).toBe(true)

    await typeName('My task')
    expect(caret.disabled).toBe(false)
    expect(runBtn?.disabled).toBe(false)
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

  it('pressing "Create task only" narrates "Creating…", not "Starting…"', async () => {
    mountDialog()
    await flushPromises()
    await typeName('My task')

    // Click first — that is what attributes the in-flight state — then
    // raise `creating` the way the host does once the request is on the wire.
    findInDom<HTMLButtonElement>('[data-testid="kanban-task-detail-commit-caret"]')!.click()
    await flushPromises()
    findInDom<HTMLButtonElement>('[data-testid="kanban-task-detail-save"]')!.click()
    await flushPromises()
    await wrapper!.setProps({ creating: true })
    await flushPromises()

    const runBtn = findInDom<HTMLButtonElement>('[data-testid="kanban-task-detail-create-and-run"]')
    expect(runBtn?.textContent?.trim()).toBe('Creating…')
    expect(runBtn?.textContent).not.toContain('Starting')
  })

  it('pressing the run half narrates "Starting…", not "Creating…"', async () => {
    mountDialog()
    await flushPromises()
    await typeName('My task')

    findInDom<HTMLButtonElement>('[data-testid="kanban-task-detail-create-and-run"]')!.click()
    await flushPromises()
    await wrapper!.setProps({ creating: true })
    await flushPromises()

    const runBtn = findInDom<HTMLButtonElement>('[data-testid="kanban-task-detail-create-and-run"]')
    expect(runBtn?.textContent?.trim()).toBe('Starting…')
  })

  it('falls back to "Creating…" when the host raises creating without a click', async () => {
    // No handler ran, so `pendingAction` is null and there is nothing to attribute the in-flight
    // state to. The neutral wording is the point of that fallback — the old code flashed the same
    // word on both buttons, which is the bug this spec exists to prevent regressing.
    mountDialog({ creating: true })
    await flushPromises()
    await typeName('My task')

    const runBtn = findInDom<HTMLButtonElement>('[data-testid="kanban-task-detail-create-and-run"]')
    expect(runBtn?.textContent?.trim()).toBe('Creating…')
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
