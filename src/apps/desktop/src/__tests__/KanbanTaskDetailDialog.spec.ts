/** Tests for KanbanTaskDetailDialog — focused, edit-in-place task detail view. Used by the kanban
 * tree to edit a task's name + description with optional metadata (column, type, pinned). Mount
 * pattern: same as KanbanSettingsDialog.spec.ts. */
/** The dialog uses <Teleport to="body">, so the rendered DOM lives outside wrapper.element. We use
 * `attachTo: document.body` and query the teleported content via `document.querySelector` (NOT
 * `wrapper.find`). `wrapper.emitted` still works because it tracks the vm, not the DOM tree. */
/** We use native `el.click()` and `dispatchEvent('input')` for interactions so v-model updates
 * synchronously. Plan: docs/superpowers/plans/2026-07-16-kanban-task-detail-dialog.md Chunk 3 /
 * Task 3.2 */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
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
    findAllInDom('[data-testid="kanban-task-detail-dialog"]').forEach((el) =>
      el.remove(),
    )
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
    const input = findInDom<HTMLInputElement>(
      '[data-testid="kanban-task-detail-name"]',
    )
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
    findAllInDom('[data-testid="kanban-task-detail-dialog"]').forEach((el) =>
      el.remove(),
    )
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
    setInputValue(
      '[data-testid="kanban-task-detail-description"]',
      'New description',
    )
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
    const saveBtn = findInDom<HTMLButtonElement>(
      '[data-testid="kanban-task-detail-save"]',
    )
    expect(saveBtn?.hasAttribute('disabled')).toBe(true)
  })

  it('disables save when nothing changed (clean form)', async () => {
    mountDialog()
    await flushPromises()
    const saveBtn = findInDom<HTMLButtonElement>(
      '[data-testid="kanban-task-detail-save"]',
    )
    expect(saveBtn?.hasAttribute('disabled')).toBe(true)
  })

  it('enables save when the name OR description changed', async () => {
    mountDialog()
    await flushPromises()
    setInputValue(
      '[data-testid="kanban-task-detail-description"]',
      'Modified description',
    )
    await flushPromises()
    const saveBtn = findInDom<HTMLButtonElement>(
      '[data-testid="kanban-task-detail-save"]',
    )
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
    findAllInDom('[data-testid="kanban-task-detail-dialog"]').forEach((el) =>
      el.remove(),
    )
  })

  function mountDialog(
    task: Task,
    column?: KanbanColumn | null,
  ): VueWrapper {
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
    const colEl = findInDom<HTMLElement>(
      '[data-testid="kanban-task-detail-column"]',
    )
    expect(colEl?.textContent).toContain('In progress')
  })

  it('does NOT render a routine type label for legacy task_type routine (deleted Migration 084)', async () => {
    mountDialog({ ...TASK, task_type: 'routine' as never })
    await flushPromises()
    const typeEl = findInDom<HTMLElement>(
      '[data-testid="kanban-task-detail-type"]',
    )
    expect(typeEl).toBeNull()
  })

  it('renders the pinned indicator when is_pinned is true', async () => {
    mountDialog({ ...TASK, is_pinned: true })
    await flushPromises()
    const pinnedEl = findInDom<HTMLElement>(
      '[data-testid="kanban-task-detail-pinned"]',
    )
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

  // These tests pin the removal: in edit mode the strip testids (`kanban-task-detail-cwd-readonly`,
  // `kanban-task-detail-cwd-readonly-empty`) MUST NOT be rendered.
  it('edit mode: does NOT render the legacy read-only cwd strip', async () => {
    mountDialog({ ...TASK, cwd: '/home/foo/bar' })
    await flushPromises()
    expect(
      findInDom('[data-testid="kanban-task-detail-cwd-readonly"]'),
    ).toBeNull()
    expect(
      findInDom('[data-testid="kanban-task-detail-cwd-readonly-empty"]'),
    ).toBeNull()
  })

  it('edit mode: does NOT render the legacy empty read-only cwd strip', async () => {
    mountDialog({ ...TASK, cwd: '' })
    await flushPromises()
    expect(
      findInDom('[data-testid="kanban-task-detail-cwd-readonly"]'),
    ).toBeNull()
    expect(
      findInDom('[data-testid="kanban-task-detail-cwd-readonly-empty"]'),
    ).toBeNull()
  })
})

// ─── Edit-mode cwd picker (plan: 2026-08-14-kanban-task-detail-edit-cwd) The cwd picker was lifted
// out of the create-mode block so it renders in BOTH modes. In edit mode the picker fires
// `update-cwd` so the host can persist the change immediately (mirrors `update-unattended`).

// The local `cwdSession` is initialized from `props.task?.cwd ?? ''` so the picker label reflects
// the task's persisted cwd (or the empty-state placeholder for cwd-less tasks).
describe('KanbanTaskDetailDialog — edit-mode cwd picker', () => {
  let wrapper: VueWrapper | null = null

  beforeEach(() => {
    setActivePinia(createPinia())
  })

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    findAllInDom('[data-testid="kanban-task-detail-dialog"]').forEach((el) =>
      el.remove(),
    )
  })

  function mountEditDialogWithCwd(task: Task, cwd = '') {
    document.body.innerHTML = ''
    wrapper = mount(KanbanTaskDetailDialog, {
      attachTo: document.body,
      props: { show: true, task, cwd },
    })
    return wrapper
  }

  it('renders the cwd picker button in edit mode', async () => {
    mountEditDialogWithCwd(TASK)
    await flushPromises()
    const picker = findInDom<HTMLElement>(
      '[data-testid="kanban-task-detail-cwd-picker"]',
    )
    expect(picker).not.toBeNull()
  })

  it('edit mode: picker button label shows the task cwd when set', async () => {
    mountEditDialogWithCwd({ ...TASK, cwd: '/home/foo/bar' })
    await flushPromises()
    const picker = findInDom<HTMLElement>(
      '[data-testid="kanban-task-detail-cwd-picker"]',
    )
    expect(picker).not.toBeNull()
    // The picker text reflects the cwd — NOT the create-mode "Skip"
    // placeholder.
    expect(picker!.textContent).toContain('/home/foo/bar')
    expect(picker!.textContent).not.toContain('Skip (no project root)')
    // Title attribute carries the path for hover-tooltip.
    expect(picker!.getAttribute('title')).toContain('/home/foo/bar')
  })

  it('edit mode: picker button shows the empty-state placeholder when task.cwd === ""', async () => {
    mountEditDialogWithCwd({ ...TASK, cwd: '' })
    await flushPromises()
    const picker = findInDom<HTMLElement>(
      '[data-testid="kanban-task-detail-cwd-picker"]',
    )
    expect(picker).not.toBeNull()
    // The chip label uses "(none)" for the cwd slot when unset (new
    // "Project root" + value layout — see the cwd-picker chip).
    expect(picker!.textContent).toContain('Project root')
    expect(picker!.textContent).toContain('(none)')
    // The title for the empty state in edit mode tells the user they
    // can click to set one (different from create-mode "optional").
    expect(picker!.getAttribute('title') ?? '').toMatch(
      /no project root/i,
    )
  })

  it('edit mode: picker button shows the empty-state placeholder when task.cwd is undefined (legacy)', async () => {
    // Legacy tasks predating Migration 070 don't have a `cwd` field at
    // all — verify the picker's `task?.cwd ?? ''` coerce handles
    // `undefined` (not just '').
    const legacyTask = { ...TASK }
    delete (legacyTask as { cwd?: string }).cwd
    mountEditDialogWithCwd(legacyTask)
    await flushPromises()
    const picker = findInDom<HTMLElement>(
      '[data-testid="kanban-task-detail-cwd-picker"]',
    )
    expect(picker).not.toBeNull()
    expect(picker!.textContent).toContain('Project root')
    expect(picker!.textContent).toContain('(none)')
  })

  it('edit mode: opening the picker mounts the FilePickerDialog dropdown', async () => {
    mountEditDialogWithCwd(TASK)
    await flushPromises()
    const picker = findInDom<HTMLElement>(
      '[data-testid="kanban-task-detail-cwd-picker"]',
    )
    picker!.click()
    await flushPromises()
    // The dropdown wrapper testid is rendered immediately on open.
    const dropdown = findInDom<HTMLElement>(
      '[data-testid="kanban-task-detail-cwd-picker-dropdown"]',
    )
    expect(dropdown).not.toBeNull()
  })

  // Regression for "click Browse → picker closes immediately". The cwd picker mounts a
  // FilePickerDialog via `<Teleport to="body">` so the dialog's DOM is NOT a descendant of the cwd
  // picker's template ref.

  // The picker's click-outside handler used to treat any click outside the picker ref as a close
  // signal — so clicking the Browse tab (which is inside the teleported FilePickerDialog) bubbled
  // up to the document-click handler and closed the picker.

  // Fix: the click-outside handler now allows the click target to be inside the teleported
  // FilePickerDialog (matched by the `data-testid="file-picker-dialog"` testid on its root).
  it('edit mode: clicking the Browse tab does NOT close the picker', async () => {
    mountEditDialogWithCwd(TASK)
    await flushPromises()
    findInDom<HTMLElement>(
      '[data-testid="kanban-task-detail-cwd-picker"]',
    )!.click()
    await flushPromises()
    // Picker is now open. Click the Browse tab.
    findInDom<HTMLElement>(
      '[data-testid="file-picker-tab-browse"]',
    )!.click()
    await flushPromises()
    // The picker dropdown wrapper must still be in the DOM.
    expect(
      findInDom('[data-testid="kanban-task-detail-cwd-picker-dropdown"]'),
    ).not.toBeNull()
    // And the Search input (Browse-only toolbar) is now visible
    // — proves the tab actually switched to Browse, not just that
    // the dropdown stayed open.
    expect(
      findInDom('[data-testid="file-picker-search"]'),
    ).not.toBeNull()
  })

  // Regression for "click outside picker → picker closes immediately". User feedback: clicking on
  // the kanban column body, on another card, or anywhere outside the picker dropdown was silently
  // closing the picker while the user was just reading context.

  // The new contract: the picker stays open until the user clicks the picker trigger again, selects
  // a folder, or presses Cancel inside the FilePickerDialog. (The KanbanTaskDetailDialog itself
  // still closes on backdrop click — that's a different handler.)
  it('edit mode: clicking outside the picker does NOT close it', async () => {
    mountEditDialogWithCwd(TASK)
    await flushPromises()
    findInDom<HTMLElement>(
      '[data-testid="kanban-task-detail-cwd-picker"]',
    )!.click()
    await flushPromises()
    // Picker is now open. Synthesise a click somewhere completely outside the picker and outside
    // the dialog (the kanban column body — a typical place the user might click while context-
    // reading). The picker must NOT close on this click.
    const outside = document.createElement('div')
    outside.setAttribute('data-testid', 'kanban-column-body-fixture')
    document.body.appendChild(outside)
    outside.dispatchEvent(new MouseEvent('mousedown', { bubbles: true }))
    await flushPromises()
    expect(
      findInDom('[data-testid="kanban-task-detail-cwd-picker-dropdown"]'),
    ).not.toBeNull()
    outside.remove()
  })

  // Companion test: clicking the picker trigger again (toggle)
  // DOES close the dropdown, since the user explicitly wants to
  // dismiss the picker.
  it('edit mode: clicking the picker trigger again toggles the picker closed', async () => {
    mountEditDialogWithCwd(TASK)
    await flushPromises()
    const picker = findInDom<HTMLElement>(
      '[data-testid="kanban-task-detail-cwd-picker"]',
    )!
    picker.click()
    await flushPromises()
    expect(
      findInDom('[data-testid="kanban-task-detail-cwd-picker-dropdown"]'),
    ).not.toBeNull()
    // Click the trigger again — this should close it (the toggle
    // handler runs the same logic but the trigger click is INSIDE
    // the ref so the close-on-outside check doesn't fire).
    picker.click()
    await flushPromises()
    expect(
      findInDom('[data-testid="kanban-task-detail-cwd-picker-dropdown"]'),
    ).toBeNull()
  })

  it('edit mode: emits update-cwd with the picked path on folder select', async () => {
    // Drive the picker directly via its exposed handler. The FilePickerDialog is a Teleport-to-body
    // component that uses an internal fetch pipeline — testing the full UI flow would mock global
    // fetch (a brittle pattern).

    // Instead we synthesise the `select` event that the dialog would emit on click, which is the
    // exact contract the host relies on.
    const w = mountEditDialogWithCwd({ ...TASK, cwd: '/home/old' })
    await flushPromises()
    // Grab a ref to the picker button — the FilePickerDialog's
    // @select="selectCwd" handler is wired in the template, so we
    // invoke selectCwd via the component instance.
    const vm = w!.vm as unknown as {
      selectCwd: (p: string) => void
    }
    vm.selectCwd('/home/new/path')
    await flushPromises()
    const emitted = w!.emitted('update-cwd')
    expect(emitted).toBeTruthy()
    expect(emitted![0]).toEqual([{ cwd: '/home/new/path' }])
    // And the picker's local `cwdSession` updated to the new path
    // (the picker label reflects it).
    const picker = findInDom<HTMLElement>(
      '[data-testid="kanban-task-detail-cwd-picker"]',
    )
    expect(picker?.textContent).toContain('/home/new/path')
  })

  it('edit mode: emitting update-cwd clears the cwd when the user picks ""', async () => {
    // The picker emits `''` when the user explicitly clears the per-task cwd (walks back to
    // "kanban-level fallback" semantics).

    // The backend's `task_update.zig` validated_cwd block treats '' as the explicit-clear sentinel
    // — verify the dialog propagates it verbatim so the host can dispatch a clear-PUT.
    const w = mountEditDialogWithCwd({ ...TASK, cwd: '/home/some/path' })
    await flushPromises()
    const vm = w!.vm as unknown as {
      selectCwd: (p: string) => void
    }
    vm.selectCwd('')
    await flushPromises()
    const emitted = w!.emitted('update-cwd')
    expect(emitted).toBeTruthy()
    expect(emitted![emitted!.length - 1]).toEqual([{ cwd: '' }])
  })
})

// ─── Create-mode tests (kanban-add-task-via-detail-dialog) ─────────────── The unattended-mode
// toggle lives inside the edit-mode dialog (rendered only when `mode !== 'create'`).

// It's an iOS-style immediate-flip switch — NOT gated on the Save button click — because unattended
// is a runtime behavior setting, not a save-button-commit.

// The dialog emits `update-unattended` with `{ value, previous }` so the host can call
// `api.updateSession(task.id, { isAutoRetryUntilStop: value })` and roll back on PUT failure if
// needed.
describe('KanbanTaskDetailDialog — unattended mode toggle', () => {
  let wrapper: VueWrapper | null = null

  beforeEach(() => {
    setActivePinia(createPinia())
  })

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    findAllInDom('[data-testid="kanban-task-detail-dialog"]').forEach((el) =>
      el.remove(),
    )
  })

  function mountEditDialogWithTask(task: Task) {
    document.body.innerHTML = ''
    wrapper = mount(KanbanTaskDetailDialog, {
      attachTo: document.body,
      props: { show: true, task },
    })
    return wrapper
  }

  it('renders the unattended toggle in edit mode', async () => {
    mountEditDialogWithTask(TASK)
    await flushPromises()
    const toggle = findInDom<HTMLInputElement>(
      '[data-testid="kanban-task-detail-unattended-toggle"]',
    )
    expect(toggle).not.toBeNull()
  })

  it('renders the toggle unchecked when task.is_auto_retry_until_stop is missing or "0"', async () => {
    mountEditDialogWithTask({ ...TASK }) // no is_auto_retry_until_stop field
    await flushPromises()
    const toggle = findInDom<HTMLInputElement>(
      '[data-testid="kanban-task-detail-unattended-toggle"]',
    )
    expect(toggle?.checked).toBe(false)
  })

  it('renders the toggle checked when task.is_auto_retry_until_stop === "1"', async () => {
    mountEditDialogWithTask({ ...TASK, is_auto_retry_until_stop: '1' })
    await flushPromises()
    const toggle = findInDom<HTMLInputElement>(
      '[data-testid="kanban-task-detail-unattended-toggle"]',
    )
    expect(toggle?.checked).toBe(true)
  })

  it('renders the toggle in create mode (Option A: atomic create-with-session)', async () => {
    // The toggle used to be hidden in create mode because no session row existed yet. As of the
    // unattended-mode Option A fix, the create payload carries is_auto_retry_until_stop and the
    // backend atomically inserts a sessions row + sets the flag in one transaction.

    // So the toggle is now visible from the create flow — flipping it persists at task creation
    // time.
    document.body.innerHTML = ''
    wrapper = mount(KanbanTaskDetailDialog, {
      attachTo: document.body,
      props: { show: true, mode: 'create', task: null, column: null },
    })
    await flushPromises()
    const toggle = findInDom<HTMLInputElement>(
      '[data-testid="kanban-task-detail-unattended-toggle"]',
    )
    expect(toggle).not.toBeNull()
    // Default value is '1' (on) — user can opt out by flipping.
    expect(toggle?.checked).toBe(true)
  })

  it('flipping the toggle emits update-unattended with new value and previous', async () => {
    mountEditDialogWithTask({ ...TASK, is_auto_retry_until_stop: '0' })
    await flushPromises()
    const toggle = findInDom<HTMLInputElement>(
      '[data-testid="kanban-task-detail-unattended-toggle"]',
    )
    toggle!.checked = true
    toggle!.dispatchEvent(new Event('change', { bubbles: true }))
    await flushPromises()
    const emitted = wrapper!.emitted('update-unattended')
    expect(emitted).toBeTruthy()
    expect(emitted![0]).toEqual([{ value: '1', previous: '0' }])
  })

  it('flipping the toggle does NOT mark the form dirty (Save stays disabled)', async () => {
    mountEditDialogWithTask({ ...TASK, is_auto_retry_until_stop: '0' })
    await flushPromises()
    const toggle = findInDom<HTMLInputElement>(
      '[data-testid="kanban-task-detail-unattended-toggle"]',
    )
    toggle!.checked = true
    toggle!.dispatchEvent(new Event('change', { bubbles: true }))
    await flushPromises()
    const saveBtn = findInDom<HTMLButtonElement>(
      '[data-testid="kanban-task-detail-save"]',
    )
    // The toggle is its own immediate-save action; Save stays
    // disabled until name/description actually change.
    expect(saveBtn?.hasAttribute('disabled')).toBe(true)
  })
})

// The same KanbanTaskDetailDialog renders the "+ Add" flow in kanban mode. The host passes
// `mode="create"` and `task={null}`; the form starts empty and submit emits `create` (not `save`).

// These tests verify both the rendering differences and the emit shape so the contract is locked
// in.
describe('KanbanTaskDetailDialog — create mode', () => {
  let wrapper: VueWrapper | null = null

  beforeEach(() => {
    setActivePinia(createPinia())
  })

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    findAllInDom('[data-testid="kanban-task-detail-dialog"]').forEach((el) =>
      el.remove(),
    )
  })

  function mountCreateDialog(
    column: KanbanColumn | null = null,
    errorMessage: string | null = null,
  ): VueWrapper {
    document.body.innerHTML = ''
    wrapper = mount(KanbanTaskDetailDialog, {
      attachTo: document.body,
      props: { show: true, mode: 'create', task: null, column, errorMessage },
    })
    return wrapper
  }

  it('renders the dialog with task=null (would be hidden in edit mode)', async () => {
    // The whole point of the create-mode change: the dialog must render even when task is null,
    // because in edit mode the v-if="show && task" guard hides it. The new guard is `show && (task
    // || isCreateMode)`.
    mountCreateDialog()
    await flushPromises()
    expect(findInDom('[data-testid="kanban-task-detail-dialog"]')).not.toBeNull()
  })

  it('starts the form empty even if a task is passed (caller contract: pass null)', async () => {
    // Defensive: in create mode the form MUST start blank regardless of the task prop. The host's
    // contract is `task=null`, but if a future refactor accidentally passes a stale task, the
    // dialog should still present a blank form.
    document.body.innerHTML = ''
    wrapper = mount(KanbanTaskDetailDialog, {
      attachTo: document.body,
      props: { show: true, mode: 'create', task: TASK },
    })
    await flushPromises()
    const input = findInDom<HTMLInputElement>(
      '[data-testid="kanban-task-detail-create-name"]',
    )
    expect(input?.value).toBe('')
    const textarea = findInDom<HTMLTextAreaElement>(
      '[data-testid="kanban-task-detail-create-description"]',
    )
    expect(textarea?.value).toBe('')
  })

  it('renders the column name in the metadata strip when column is provided', async () => {
    mountCreateDialog({
      id: 'col_1',
      workspace_item_id: 'item_1',
      name: 'todo',
      position: 0,
      created_at: '2026-07-16T10:00:00Z',
    })
    await flushPromises()
    const colEl = findInDom<HTMLElement>(
      '[data-testid="kanban-task-detail-column"]',
    )
    expect(colEl?.textContent).toContain('todo')
  })

  it('hides the type + pinned badges in create mode (they only apply to existing tasks)', async () => {
    mountCreateDialog()
    await flushPromises()
    // Even if column is null, the metadata strip is hidden in create mode when no column is
    // provided. The type/pinned badges are explicitly gated off for create mode in the template
    // (`v-if="!isCreateMode && ..."`).
    const strip = findInDom('[data-testid="kanban-task-detail-metadata"]')
    expect(strip).toBeNull()
  })

  it('"Create task only" menu item is disabled when name is empty', async () => {
    mountCreateDialog()
    await flushPromises()
    // In create mode the commit split button's left half is the run
    // action, so the plain create lives in the caret menu under this
    // testid.
    const saveBtn = findInDom<HTMLButtonElement>(
      '[data-testid="kanban-task-detail-save"]',
    )
    expect(saveBtn?.textContent).toContain('Create task only')
    expect(saveBtn?.hasAttribute('disabled')).toBe(true)
  })

  it('Save button enables when name is non-empty (no "dirty" gate in create mode)', async () => {
    // isDirty returns isValid in create mode (any non-empty name
    // is ready to submit). Without this, the Save button would
    // stay disabled and the user couldn't submit a fresh create.
    mountCreateDialog()
    await flushPromises()
    setInputValue('[data-testid="kanban-task-detail-create-name"]', 'My task')
    await flushPromises()
    const saveBtn = findInDom<HTMLButtonElement>(
      '[data-testid="kanban-task-detail-save"]',
    )
    expect(saveBtn?.hasAttribute('disabled')).toBe(false)
  })

  it('emits create (not save) with { mode: "create", name, description, is_auto_retry_until_stop, pendingFiles }', async () => {
    // The create payload now carries is_auto_retry_until_stop (Option A: backend atomically inserts
    // a sessions row when this is '1'). Default value at dialog open is '1' (on).

    // NEW (plan: 2026-08-06-kanban-no-base64-in-desc): the create emit also carries `pendingFiles:
    // PreviewFile[]` (always an array — empty when no images were staged) so the host's
    // create-then-upload orchestrator can upload attachments AFTER the task exists.
    const w = mountCreateDialog()
    await flushPromises()
    setInputValue('[data-testid="kanban-task-detail-create-name"]', '  New task  ')
    setInputValue(
      '[data-testid="kanban-task-detail-create-description"]',
      'Some description',
    )
    await flushPromises()
    clickInDom('[data-testid="kanban-task-detail-save"]')

    expect(w!.emitted('save')).toBeFalsy()
    const emitted = w!.emitted('create')
    expect(emitted).toBeTruthy()
    expect(emitted![0]).toEqual([
      {
        mode: 'create',
        name: 'New task',
        description: 'Some description',
        is_auto_retry_until_stop: '1',
        // Default OFF — the dialog's worktree toggle was not flipped.
        useGitWorktree: false,
        worktreePath: '',
        // No base ref — no `Base:` line in the queue_message.
        worktreeBaseBranch: '',
        tags: [],
        // NEW (plan: 2026-08-06-kanban-task-profile-selector)
        selectedProfile: '',
        // NEW (plan: 2026-08-06-kanban-no-base64-in-desc).
        pendingFiles: [],
        // NEW (Migration 070 — kanban-cwd-session-optional plan). Empty string = no per-task cwd
        // (falls back to kanban path + sandbox). The dialog's cwd picker was added in create mode;
        // this test doesn't drive the picker so the field carries the default '' value.
        cwdSession: '',
      },
    ])
  })

  it('emits create with is_auto_retry_until_stop: "1" when the toggle is flipped on', async () => {
    // Flips the unattended toggle BEFORE clicking Create. The
    // emitted payload should carry the flipped value.
    const w = mountCreateDialog()
    await flushPromises()
    setInputValue('[data-testid="kanban-task-detail-create-name"]', 'Overnight run')
    await flushPromises()
    const toggle = findInDom<HTMLInputElement>(
      '[data-testid="kanban-task-detail-unattended-toggle"]',
    )
    toggle!.checked = true
    toggle!.dispatchEvent(new Event('change', { bubbles: true }))
    await flushPromises()
    clickInDom('[data-testid="kanban-task-detail-save"]')

    const emitted = w!.emitted('create')
    expect(emitted).toBeTruthy()
    expect(emitted![0]).toEqual([
      {
        mode: 'create',
        name: 'Overnight run',
        description: '',
        is_auto_retry_until_stop: '1',
        // Default OFF — this test only flips the unattended toggle.
        useGitWorktree: false,
        worktreePath: '',
        // No base ref — no `Base:` line in the queue_message.
        worktreeBaseBranch: '',
        tags: [],
        // NEW (plan: 2026-08-06-kanban-task-profile-selector)
        selectedProfile: '',
        // NEW (plan: 2026-08-06-kanban-no-base64-in-desc).
        pendingFiles: [],
        // NEW (Migration 070 — kanban-cwd-session-optional plan).
        // Empty string = no per-task cwd. See comment on the
        // earlier "emits create" test for the full rationale.
        cwdSession: '',
      },
    ])
  })

  it('header title reads "New task" in create mode (vs "Task details" in edit)', async () => {
    mountCreateDialog()
    await flushPromises()
    const title = findInDom<HTMLElement>(
      '#kanban-task-detail-create-title',
    )
    expect(title?.textContent).toContain('New task')
    expect(title?.textContent).not.toContain('Task details')
  })

  it('renders the error banner when errorMessage is set', async () => {
    mountCreateDialog(null, 'Failed to create task — please retry.')
    await flushPromises()
    const banner = findInDom<HTMLElement>(
      '[data-testid="kanban-task-detail-error"]',
    )
    expect(banner).not.toBeNull()
    expect(banner?.textContent).toContain('Failed to create task')
  })

  it('does not render the error banner when errorMessage is null', async () => {
    mountCreateDialog()
    await flushPromises()
    expect(findInDom('[data-testid="kanban-task-detail-error"]')).toBeNull()
  })
})

// ─── Column dropdown (create mode) — plan 2026-08-06-kanban-add-task-button-placement ─── Replaces
// the read-only column label in create mode with an interactive dropdown. Mirrors the profile
// picker pattern (button trigger + ▾ dropdown + ✓ checkmark + click-outside close).

// Picking a column emits column-change so the host can update its activeCreateColumnId in
// real-time. Edit mode keeps the static strip — migrating an existing task to a new column is out
// of scope.
describe('KanbanTaskDetailDialog — column dropdown (create mode)', () => {
  let wrapper: VueWrapper | null = null

  beforeEach(() => {
    setActivePinia(createPinia())
  })

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    findAllInDom('[data-testid="kanban-task-detail-dialog"]').forEach((el) =>
      el.remove(),
    )
  })

  // Helper: mount the dialog in create mode with the given columns
  // and an optional initial column (defaults to the first).
  function mountCreateWithColumns(
    columns: { id: string; name: string }[],
    initialColumnId: string | null = columns[0]?.id ?? null,
  ): VueWrapper {
    const fullColumns: KanbanColumn[] = columns.map((c) => ({
      id: c.id,
      name: c.name,
      workspace_item_id: 'item_1',
      position: 0,
      created_at: '2026-06-21 12:00:00',
    }))
    const initialColumn = initialColumnId
      ? fullColumns.find((c) => c.id === initialColumnId) ?? null
      : null
    document.body.innerHTML = ''
    wrapper = mount(KanbanTaskDetailDialog, {
      attachTo: document.body,
      props: {
        show: true,
        mode: 'create',
        task: null,
        column: initialColumn,
        availableColumns: fullColumns,
        workspaceId: 'ws_1',
      },
    })
    return wrapper
  }

  it('create mode: column is rendered as a dropdown button (not a static text strip)', async () => {
    mountCreateWithColumns([{ id: 'col_x', name: 'todo' }])
    await flushPromises()
    // Dropdown trigger renders with the expected testid.
    expect(
      findInDom('[data-testid="kanban-task-detail-column-picker"]'),
    ).not.toBeNull()
    // The static strip (legacy testid) does NOT render in create mode.
    expect(findInDom('[data-testid="kanban-task-detail-column"]')).toBeNull()
  })

  it('create mode: column dropdown defaults to the column prop', async () => {
    mountCreateWithColumns([
      { id: 'col_x', name: 'todo' },
      { id: 'col_y', name: 'in progress' },
    ])
    await flushPromises()
    const trigger = findInDom<HTMLElement>(
      '[data-testid="kanban-task-detail-column-picker"]',
    )
    expect(trigger?.textContent).toContain('todo')
  })

  it('create mode: opening the dropdown and picking a column emits column-change', async () => {
    const w = mountCreateWithColumns([
      { id: 'col_x', name: 'todo' },
      { id: 'col_y', name: 'in progress' },
    ])
    await flushPromises()

    // Open the dropdown.
    clickInDom('[data-testid="kanban-task-detail-column-picker"]')
    await flushPromises()
    // Pick the second column.
    clickInDom('[data-testid="kanban-task-detail-column-picker-item-col_y"]')
    await flushPromises()

    expect(w.emitted('column-change')).toBeTruthy()
    expect(w.emitted('column-change')?.[0]).toEqual(['col_y'])
  })

  it('create mode: single-column kanban — dropdown renders with the single item + checkmark', async () => {
    mountCreateWithColumns([{ id: 'col_x', name: 'todo' }])
    await flushPromises()
    clickInDom('[data-testid="kanban-task-detail-column-picker"]')
    await flushPromises()
    const item = findInDom<HTMLElement>(
      '[data-testid="kanban-task-detail-column-picker-item-col_x"]',
    )
    expect(item).not.toBeNull()
    expect(item?.textContent).toContain('✓')
  })

  it('edit mode: column is rendered as a static text strip (no dropdown)', async () => {
    document.body.innerHTML = ''
    wrapper = mount(KanbanTaskDetailDialog, {
      attachTo: document.body,
      props: {
        show: true,
        mode: 'edit',
        task: {
          id: 'task_1',
          name: 'existing task',
          description: '',
          kanban_column_id: 'col_x',
        },
        column: {
          id: 'col_x',
          name: 'todo',
          workspace_item_id: 'item_1',
          position: 0,
          created_at: '2026-06-21 12:00:00',
        },
        availableColumns: [],  // edit mode ignores availableColumns
      },
    })
    await flushPromises()
    // Static strip renders (legacy testid).
    expect(findInDom('[data-testid="kanban-task-detail-column"]')).not.toBeNull()
    // Dropdown does NOT render.
    expect(
      findInDom('[data-testid="kanban-task-detail-column-picker"]'),
    ).toBeNull()
  })

  it('create mode: clicking outside the dropdown closes it', async () => {
    mountCreateWithColumns([
      { id: 'col_x', name: 'todo' },
      { id: 'col_y', name: 'in progress' },
    ])
    await flushPromises()
    clickInDom('[data-testid="kanban-task-detail-column-picker"]')
    await flushPromises()
    // Dropdown is open.
    expect(
      findInDom('[data-testid="kanban-task-detail-column-picker-dropdown"]'),
    ).not.toBeNull()
    // Dispatch a click on document.body (outside the picker).
    document.body.dispatchEvent(new MouseEvent('click', { bubbles: true }))
    await flushPromises()
    // Dropdown is closed.
    expect(
      findInDom('[data-testid="kanban-task-detail-column-picker-dropdown"]'),
    ).toBeNull()
  })

  // NEW (2026-08-06, dropdown width/style follow-up v3). User feedback
  // round 3: BOTH the trigger button AND the dropdown should be
  // wider than a tiny pill — they should match each other at a
  // proper button width (~180px). Long column names like
  // "in_review_planning" fit on one line; short names like "todo"
  // show with the natural empty space on the right (matches the
  // standard <select> element UX where the button width is the
  // widest option width).
  // - Trigger: `min-w-[180px]` + `justify-between` so chevron sits
  //   right; text "todo" sits left.
  // - Dropdown: `absolute top-full mt-1 left-0 min-w-[180px]` —
  //   anchored to wrapper's left edge, same min-width as trigger.
  // Items get no `border-top` separator (matches profile picker).
  it('create mode: trigger and dropdown both have min-w-[180px] and match in width', async () => {
    mountCreateWithColumns([
      { id: 'col_x', name: 'todo' },
      { id: 'col_y', name: 'in_review_planning' },
    ])
    await flushPromises()
    clickInDom('[data-testid="kanban-task-detail-column-picker"]')
    await flushPromises()

    const trigger = findInDom<HTMLElement>(
      '[data-testid="kanban-task-detail-column-picker"]',
    )
    const dropdown = findInDom<HTMLElement>(
      '[data-testid="kanban-task-detail-column-picker-dropdown"]',
    )
    expect(trigger).not.toBeNull()
    expect(dropdown).not.toBeNull()

    // Trigger is a wide button, not a tiny pill.
    const triggerClass = trigger!.getAttribute('class') ?? ''
    expect(triggerClass).toContain('min-w-[180px]')
    expect(triggerClass).toContain('justify-between')

    // Dropdown matches the trigger width via min-w-[180px] + left-0
    // anchored to wrapper's left edge. NOT full body width.
    const dropdownClass = dropdown!.getAttribute('class') ?? ''
    expect(dropdownClass).toContain('min-w-[180px]')
    expect(dropdownClass).toContain('left-0')
    expect(dropdownClass).not.toContain('w-full')
    expect(dropdownClass).not.toContain('inset-x-0')
    expect(dropdownClass).not.toContain('w-max')

    // Items have no border-top separator (matches profile picker style).
    const item = dropdown!.querySelector<HTMLElement>(
      '[data-testid="kanban-task-detail-column-picker-item-col_y"]',
    )
    expect(item).not.toBeNull()
    const itemStyle = item!.getAttribute('style') ?? ''
    expect(itemStyle).not.toMatch(/border-top/i)
  })
})

describe('KanbanTaskDetailDialog — layout', () => {
  let wrapper: VueWrapper | null = null

  beforeEach(() => {
    setActivePinia(createPinia())
  })

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    findAllInDom('[data-testid="kanban-task-detail-dialog"]').forEach((el) =>
      el.remove(),
    )
  })

  function mountDialog(task: Task | null = TASK) {
    document.body.innerHTML = ''
    wrapper = mount(KanbanTaskDetailDialog, {
      attachTo: document.body,
      props: { show: true, task },
    })
    return wrapper
  }

  function mountCreateDialog(cwd: string = '') {
    document.body.innerHTML = ''
    wrapper = mount(KanbanTaskDetailDialog, {
      attachTo: document.body,
      props: {
        show: true,
        mode: 'create',
        task: null,
        column: null,
        cwd,
      },
    })
    return wrapper
  }

  // Regression for the "huge empty space below form" bug. The previous code used `height: min(80vh,
  // calc(100vh - 2rem))` on the dialog card, which forced the dialog to always render at 80vh.

  // The body (`flex-1 overflow-y-auto min-h-0`) then filled the remaining space, leaving a large
  // gap between the form fields and the action buttons when the content was short (e.g. a new task
  // with no description).

  // Fix: switch to `max-height: min(80vh, calc(100vh - 2rem))` so the card shrinks to fit content
  // when short, but caps at 80vh when the content overflows (the body then scrolls as before).
  it('uses max-height (not fixed height) so the dialog shrinks to fit short content', async () => {
    mountDialog()
    await flushPromises()
    const card = document.querySelector<HTMLDivElement>(
      '[data-testid="kanban-task-detail-dialog"] > div.relative',
    )
    expect(card).not.toBeNull()
    const style = card!.getAttribute('style') ?? ''
    // The fix: max-height caps at 80vh, but the card can shrink below it.
    expect(style).toMatch(/max-height:\s*min\(80vh,\s*calc\(100vh\s*-\s*2rem\)\)/)
    // The bug: a fixed `height: min(80vh, ...)` forced the card to 80vh
    // regardless of content height. Make sure we haven't reintroduced it.
    expect(style).not.toMatch(/(^|[\s;])height:\s*min\(80vh/)
  })

  // User feedback: "make the dialog bigger". The previous `max-w-xl` (576px) was narrow for a
  // multi-field form (task name + column picker + description + tags + folder picker + profile
  // picker + unattended mode).

  // Bumped to `max-w-2xl` (672px) for ~16% more horizontal room without crossing into "wide modal"
  // territory.
  it('uses max-w-2xl (bigger) so the form has more horizontal room', async () => {
    mountDialog()
    await flushPromises()
    const card = document.querySelector<HTMLDivElement>(
      '[data-testid="kanban-task-detail-dialog"] > div.relative',
    )
    expect(card).not.toBeNull()
    const classAttr = card!.getAttribute('class') ?? ''
    expect(classAttr).toContain('max-w-2xl')
    // Make sure we didn't accidentally revert to max-w-xl.
    expect(classAttr).not.toMatch(/(^|\s)max-w-xl(\s|$)/)
  })

  // User feedback: "fix the color font folder". The previous folder picker used the `📂` emoji which
  // renders as a system-colorful icon (orange/yellow) that doesn't match the muted dark theme — the
  // picker looked "out of place" next to the cleaner robot-emoji profile picker.

  // Replace with an inline SVG folder icon that inherits the button's text color (so it follows the
  // theme).
  it('create mode: folder picker uses an inline SVG icon (not the 📂 emoji)', async () => {
    mountCreateDialog('/home/user/projects/foo')
    await flushPromises()
    const picker = document.querySelector<HTMLElement>(
      '[data-testid="kanban-task-detail-cwd-picker"]',
    )
    expect(picker).not.toBeNull()
    const text = picker!.textContent ?? ''
    // The emoji is gone.
    expect(text).not.toMatch(/📂/)
    // An SVG icon is rendered instead (replaces the emoji span).
    const svg = picker!.querySelector('svg')
    expect(svg).not.toBeNull()
    // The SVG has a sensible folder-icon viewBox.
    expect(svg!.getAttribute('viewBox')).toBe('0 0 20 20')
  })

  // When the cwd is set, the folder picker's text color is bright (`var(--semantic-text)` =
  // #c5c9c5) — not dim — so the picked folder path reads clearly against the dark background.

  // Previously the dim text color (`var(--semantic-text-dim)` = #7a8382) made the path look faded
  // next to the profile picker's bright "Default" label.
  it('create mode: folder picker text color is bright when cwd is set', async () => {
    mountCreateDialog('/home/user/projects/foo')
    await flushPromises()
    const picker = document.querySelector<HTMLButtonElement>(
      '[data-testid="kanban-task-detail-cwd-picker"]',
    )
    expect(picker).not.toBeNull()
    // Read the inline style and assert it does NOT use the dim color.
    // The button's color is set via inline style (Vue's :style binding).
    const inlineStyle = picker!.getAttribute('style') ?? ''
    // The new contract: when cwd is set, color is --semantic-text (bright).
    expect(inlineStyle).toMatch(/color:\s*var\(--semantic-text\)/)
    // No dim color when cwd is set.
    expect(inlineStyle).not.toMatch(/color:\s*var\(--semantic-text-dim\)/)
  })

  // When the cwd is NOT set (the "skip" / optional state), the folder picker text stays dim — this
  // is intentional because the path slot shows the "Skip (no project root)" placeholder, which
  // shouldn't look like an active selection.
  it('create mode: folder picker text color is dim when cwd is empty', async () => {
    mountCreateDialog('')
    await flushPromises()
    const picker = document.querySelector<HTMLButtonElement>(
      '[data-testid="kanban-task-detail-cwd-picker"]',
    )
    expect(picker).not.toBeNull()
    const inlineStyle = picker!.getAttribute('style') ?? ''
    expect(inlineStyle).toMatch(/color:\s*var\(--semantic-text-dim\)/)
  })

  // ── cwd picker: open at the right place ─────────────────────────────────
  // User feedback: "fix the folder query" — the per-task cwd picker used to
  // always open at "/" regardless of cwd_session, forcing the user to
  // navigate back to their cwd on every reopen. The picker now passes
  // cwd_session as both initial-path and selected-path so reopening
  // drops the user at the current cwd with the cwd pre-selected.
  //
  // These tests mock the global `fetch` (the API module calls fetch
  // internally via apiFetch) so we can assert exactly which paths get
  // queried — vi.spyOn(api, 'listFolder') doesn't work because the
  // KanbanTaskDetailDialog destructures `listFolder` at module load
  // time, before the spy replaces the namespace property.
  describe('create mode: cwd picker opens at cwd_session (folder query fix)', () => {
    function mockFetchWithFs(entries: Record<string, Array<{ name: string; path: string; is_directory: boolean }>>) {
      return vi.spyOn(globalThis, 'fetch').mockImplementation(async (input: RequestInfo | URL) => {
        const url = typeof input === 'string' ? input : input.toString()
        const u = new URL(url, 'http://localhost')
        const path = u.searchParams.get('path') ?? ''
        const action = u.searchParams.get('action') ?? 'list'
        if (action !== 'list') {
          return new Response(JSON.stringify({ content: '' }), { status: 200 })
        }
        const data = path
          ? { path: '/', absolute: path, home: '/home/test', entries: entries[path] ?? [] }
          : { path: '/', absolute: '/home/test', home: '/home/test', entries: entries['__home__'] ?? [] }
        return new Response(JSON.stringify(data), { status: 200 })
      })
    }

    it('when cwd_session is set, the picker opens AT cwd_session (not at "/")', async () => {
      mockFetchWithFs({
        '/': [{ name: 'home', path: '/home', is_directory: true }],
        '/home': [{ name: 'user', path: '/home/user', is_directory: true }],
        '/home/user': [{ name: 'projects', path: '/home/user/projects', is_directory: true }],
        '/home/user/projects': [{ name: 'foo', path: '/home/user/projects/foo', is_directory: true }],
        '/home/user/projects/foo': [
          { name: 'src', path: '/home/user/projects/foo/src', is_directory: true },
          { name: 'package.json', path: '/home/user/projects/foo/package.json', is_directory: false },
        ],
      })

      mountCreateDialog('/home/user/projects/foo')
      await flushPromises()
      // Open the picker.
      clickInDom('[data-testid="kanban-task-detail-cwd-picker"]')
      await flushPromises()
      // The picker opens on the Recent tab by default (per 2026-08-14-folder-picker-recent-history
      // plan). Switch to Browse to assert that the cwd's children loaded — Recent is empty for a
      // fresh test fixture so we can't see items there.
      clickInDom('[data-testid="file-picker-tab-browse"]')
      await flushPromises()

      // The cwd's children must be in the content pane — proving
      // expandAncestors walked the chain back to cwd_session (not
      // stopping at "/" because the picker opened at cwd_session).
      expect(
        document.querySelector('[data-testid="file-picker-item-/home/user/projects/foo/src"]'),
      ).not.toBeNull()
      // And the cwd breadcrumb is rendered with all four segments.
      const crumbs = document.querySelectorAll('[data-testid^="file-picker-crumb-"]')
      const crumbTexts = Array.from(crumbs).map((el) => el.textContent?.trim())
      expect(crumbTexts).toEqual(['home', 'user', 'projects', 'foo'])
    })

    it('when cwd_session is empty, the picker opens at "/" (root folders visible)', async () => {
      mockFetchWithFs({
        '/': [{ name: 'home', path: '/home', is_directory: true }],
        __home__: [{ name: 'test', path: '/home/test', is_directory: true }],
      })

      mountCreateDialog('')
      await flushPromises()
      clickInDom('[data-testid="kanban-task-detail-cwd-picker"]')
      await flushPromises()
      // Same Recent-vs-Browse dance — the picker opens on Recent
      // by default, switch to Browse to assert root entries.
      clickInDom('[data-testid="file-picker-tab-browse"]')
      await flushPromises()

      // No cwd → picker opens at "/" → listFolder('/') is called →
      // root entries are displayed.
      expect(
        document.querySelector('[data-testid="file-picker-item-/home"]'),
      ).not.toBeNull()
      // The breadcrumb should show just the root.
      const crumbs = document.querySelectorAll('[data-testid^="file-picker-crumb-"]')
      expect(crumbs.length).toBe(0)
    })

    it('cwd_session is pre-selected in the picker so the footer shows the current cwd', async () => {
      mockFetchWithFs({
        '/': [{ name: 'home', path: '/home', is_directory: true }],
        '/home': [{ name: 'user', path: '/home/user', is_directory: true }],
        '/home/user': [{ name: 'projects', path: '/home/user/projects', is_directory: true }],
        '/home/user/projects': [{ name: 'foo', path: '/home/user/projects/foo', is_directory: true }],
        '/home/user/projects/foo': [{ name: 'src', path: '/home/user/projects/foo/src', is_directory: true }],
      })

      mountCreateDialog('/home/user/projects/foo')
      await flushPromises()
      clickInDom('[data-testid="kanban-task-detail-cwd-picker"]')
      await flushPromises()
      clickInDom('[data-testid="file-picker-tab-browse"]')
      await flushPromises()

      // The footer "Selected:" line should reflect cwd_session so the
      // user sees what they're about to overwrite on Select.
      const selectedPath = document.querySelector(
        '[data-testid="file-picker-selected-path"]',
      )
      expect(selectedPath?.textContent?.trim()).toBe('/home/user/projects/foo')
    })
  })
})
