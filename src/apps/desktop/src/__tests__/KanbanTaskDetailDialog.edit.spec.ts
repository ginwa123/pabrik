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

// ─── Edit-mode cwd picker (plan: 2026-08-14-kanban-task-detail-edit-cwd) The cwd picker was lifted
// out of the create-mode block so it renders in BOTH modes. In edit mode the picker fires
// `update-cwd` so the host can persist the change immediately (mirrors `update-unattended`).
describe('KanbanTaskDetailDialog — edit-mode cwd picker', () => {
  let wrapper: VueWrapper | null = null

  beforeEach(() => {
    setActivePinia(createPinia())
  })

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    findAllInDom('[data-testid="kanban-task-detail-dialog"]').forEach((el) => el.remove())
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
    const picker = findInDom<HTMLElement>('[data-testid="kanban-task-detail-cwd-picker"]')
    expect(picker).not.toBeNull()
  })

  it('edit mode: picker button label shows the task cwd when set', async () => {
    mountEditDialogWithCwd({ ...TASK, cwd: '/home/foo/bar' })
    await flushPromises()
    const picker = findInDom<HTMLElement>('[data-testid="kanban-task-detail-cwd-picker"]')
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
    const picker = findInDom<HTMLElement>('[data-testid="kanban-task-detail-cwd-picker"]')
    expect(picker).not.toBeNull()
    // The chip label uses "(none)" for the cwd slot when unset (new
    // "Project root" + value layout — see the cwd-picker chip).
    expect(picker!.textContent).toContain('Project root')
    expect(picker!.textContent).toContain('(none)')
    // The title for the empty state in edit mode tells the user they
    // can click to set one (different from create-mode "optional").
    expect(picker!.getAttribute('title') ?? '').toMatch(/no project root/i)
  })

  it('edit mode: picker button shows the empty-state placeholder when task.cwd is undefined (legacy)', async () => {
    // Legacy tasks predating Migration 070 don't have a `cwd` field at
    // all — verify the picker's `task?.cwd ?? ''` coerce handles
    // `undefined` (not just '').
    const legacyTask = { ...TASK }
    delete (legacyTask as { cwd?: string }).cwd
    mountEditDialogWithCwd(legacyTask)
    await flushPromises()
    const picker = findInDom<HTMLElement>('[data-testid="kanban-task-detail-cwd-picker"]')
    expect(picker).not.toBeNull()
    expect(picker!.textContent).toContain('Project root')
    expect(picker!.textContent).toContain('(none)')
  })

  it('edit mode: opening the picker mounts the FilePickerDialog dropdown', async () => {
    mountEditDialogWithCwd(TASK)
    await flushPromises()
    const picker = findInDom<HTMLElement>('[data-testid="kanban-task-detail-cwd-picker"]')
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
  it('edit mode: clicking the Browse tab does NOT close the picker', async () => {
    mountEditDialogWithCwd(TASK)
    await flushPromises()
    findInDom<HTMLElement>('[data-testid="kanban-task-detail-cwd-picker"]')!.click()
    await flushPromises()
    // Picker is now open. Click the Browse tab.
    findInDom<HTMLElement>('[data-testid="file-picker-tab-browse"]')!.click()
    await flushPromises()
    // The picker dropdown wrapper must still be in the DOM.
    expect(findInDom('[data-testid="kanban-task-detail-cwd-picker-dropdown"]')).not.toBeNull()
    // And the Search input (Browse-only toolbar) is now visible
    // — proves the tab actually switched to Browse, not just that
    // the dropdown stayed open.
    expect(findInDom('[data-testid="file-picker-search"]')).not.toBeNull()
  })

  // Regression for "click outside picker → picker closes immediately". User feedback: clicking on
  // the kanban column body, on another card, or anywhere outside the picker dropdown was silently
  // closing the picker while the user was just reading context.
  it('edit mode: clicking outside the picker does NOT close it', async () => {
    mountEditDialogWithCwd(TASK)
    await flushPromises()
    findInDom<HTMLElement>('[data-testid="kanban-task-detail-cwd-picker"]')!.click()
    await flushPromises()
    // Picker is now open. Synthesise a click somewhere completely outside the picker and outside
    // the dialog (the kanban column body — a typical place the user might click while context-
    // reading). The picker must NOT close on this click.
    const outside = document.createElement('div')
    outside.setAttribute('data-testid', 'kanban-column-body-fixture')
    document.body.appendChild(outside)
    outside.dispatchEvent(new MouseEvent('mousedown', { bubbles: true }))
    await flushPromises()
    expect(findInDom('[data-testid="kanban-task-detail-cwd-picker-dropdown"]')).not.toBeNull()
    outside.remove()
  })

  // Companion test: clicking the picker trigger again (toggle)
  // DOES close the dropdown, since the user explicitly wants to
  // dismiss the picker.
  it('edit mode: clicking the picker trigger again toggles the picker closed', async () => {
    mountEditDialogWithCwd(TASK)
    await flushPromises()
    const picker = findInDom<HTMLElement>('[data-testid="kanban-task-detail-cwd-picker"]')!
    picker.click()
    await flushPromises()
    expect(findInDom('[data-testid="kanban-task-detail-cwd-picker-dropdown"]')).not.toBeNull()
    // Click the trigger again — this should close it (the toggle
    // handler runs the same logic but the trigger click is INSIDE
    // the ref so the close-on-outside check doesn't fire).
    picker.click()
    await flushPromises()
    expect(findInDom('[data-testid="kanban-task-detail-cwd-picker-dropdown"]')).toBeNull()
  })

  it('edit mode: emits update-cwd with the picked path on folder select', async () => {
    // Drive the picker directly via its exposed handler. The FilePickerDialog is a Teleport-to-body
    // component that uses an internal fetch pipeline — testing the full UI flow would mock global
    // fetch (a brittle pattern).
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
    const picker = findInDom<HTMLElement>('[data-testid="kanban-task-detail-cwd-picker"]')
    expect(picker?.textContent).toContain('/home/new/path')
  })

  it('edit mode: emitting update-cwd clears the cwd when the user picks ""', async () => {
    // The picker emits `''` when the user explicitly clears the per-task cwd (walks back to
    // "kanban-level fallback" semantics).
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
describe('KanbanTaskDetailDialog — unattended mode toggle', () => {
  let wrapper: VueWrapper | null = null

  beforeEach(() => {
    setActivePinia(createPinia())
  })

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    findAllInDom('[data-testid="kanban-task-detail-dialog"]').forEach((el) => el.remove())
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
    const saveBtn = findInDom<HTMLButtonElement>('[data-testid="kanban-task-detail-save"]')
    // The toggle is its own immediate-save action; Save stays
    // disabled until name/description actually change.
    expect(saveBtn?.hasAttribute('disabled')).toBe(true)
  })
})

// The same KanbanTaskDetailDialog renders the "+ Add" flow in kanban mode. The host passes
// `mode="create"` and `task={null}`; the form starts empty and submit emits `create` (not `save`).
describe('KanbanTaskDetailDialog — create mode', () => {
  let wrapper: VueWrapper | null = null

  beforeEach(() => {
    setActivePinia(createPinia())
  })

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    findAllInDom('[data-testid="kanban-task-detail-dialog"]').forEach((el) => el.remove())
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
    const input = findInDom<HTMLInputElement>('[data-testid="kanban-task-detail-create-name"]')
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
    const colEl = findInDom<HTMLElement>('[data-testid="kanban-task-detail-column"]')
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

  it('the flat "Create task" button is disabled when name is empty', async () => {
    mountCreateDialog()
    await flushPromises()
    // Create mode's two commit buttons are flat siblings: the plain
    // create under this testid, next to ▶ Create task & run agent.
    // Both are gated on a non-empty name.
    const saveBtn = findInDom<HTMLButtonElement>('[data-testid="kanban-task-detail-save"]')
    expect(saveBtn?.textContent?.trim()).toBe('Create task')
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
    const saveBtn = findInDom<HTMLButtonElement>('[data-testid="kanban-task-detail-save"]')
    expect(saveBtn?.hasAttribute('disabled')).toBe(false)
  })

  it('emits create (not save) with { mode: "create", name, description, is_auto_retry_until_stop, pendingFiles }', async () => {
    // The create payload now carries is_auto_retry_until_stop (Option A: backend atomically inserts
    // a sessions row when this is '1'). Default value at dialog open is '1' (on).
    const w = mountCreateDialog()
    await flushPromises()
    setInputValue('[data-testid="kanban-task-detail-create-name"]', '  New task  ')
    setInputValue('[data-testid="kanban-task-detail-create-description"]', 'Some description')
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
        selectedAgent: '',
        // NEW (plan: 2026-08-06-kanban-no-base64-in-desc).
        pendingFiles: [],
        // NEW (Migration 070 — kanban-cwd-session-optional plan). Empty string = no per-task cwd
        // (falls back to kanban path + sandbox). The dialog's cwd picker was added in create mode;
        // this test doesn't drive the picker so the field carries the default '' value.
        cwdSession: '',
        // NEW (Migration 112 — kanban task skills selector).
        // Empty array = no skill (the canonical sentinel).
        skillNames: [],
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
        selectedAgent: '',
        // NEW (plan: 2026-08-06-kanban-no-base64-in-desc).
        pendingFiles: [],
        // NEW (Migration 070 — kanban-cwd-session-optional plan).
        // Empty string = no per-task cwd. See comment on the
        // earlier "emits create" test for the full rationale.
        cwdSession: '',
        // NEW (Migration 112 — kanban task skills selector).
        // Empty array = no skill (the canonical sentinel).
        skillNames: [],
      },
    ])
  })

  it('header title reads "New task" in create mode (vs "Task details" in edit)', async () => {
    mountCreateDialog()
    await flushPromises()
    const title = findInDom<HTMLElement>('#kanban-task-detail-create-title')
    expect(title?.textContent).toContain('New task')
    expect(title?.textContent).not.toContain('Task details')
  })

  it('renders the error banner when errorMessage is set', async () => {
    mountCreateDialog(null, 'Failed to create task — please retry.')
    await flushPromises()
    const banner = findInDom<HTMLElement>('[data-testid="kanban-task-detail-error"]')
    expect(banner).not.toBeNull()
    expect(banner?.textContent).toContain('Failed to create task')
  })

  it('does not render the error banner when errorMessage is null', async () => {
    mountCreateDialog()
    await flushPromises()
    expect(findInDom('[data-testid="kanban-task-detail-error"]')).toBeNull()
  })
})
