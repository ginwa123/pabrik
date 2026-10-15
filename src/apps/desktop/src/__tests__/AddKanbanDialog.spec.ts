/**
 * Tests for AddKanbanDialog — the modal that creates a new project
 * kanban board. The user enters a name + picks a folder (the cwd for
 * the kanban's tasks); the backend seeds the default columns. After
 * the migration to FilePickerDialog (2026-06-24), the picker is mocked
 * with a stub (real picker behavior is in FilePickerDialog.spec.ts).
 *
 * Mirrors AddItemDialog.spec.ts: same `attachTo: document.body` +
 * `document.querySelector` pattern (the dialog uses <Teleport to="body">,
 * so wrapper.find(...) returns empty — we must inspect the document
 * directly).
 *
 * Plan: docs/superpowers/plans/2026-06-21-workspace-item-kanban.md
 *   Chunk 6 / Task 6.1
 */
import { afterEach, describe, expect, it, vi } from 'vitest'
import { mount, flushPromises, type VueWrapper } from '@vue/test-utils'
import AddKanbanDialog from '../components/dialogs/AddKanbanDialog.vue'

// Stub the FilePickerDialog — we only care that the parent wires up the
// picker's events. Real picker behavior is tested in FilePickerDialog.spec.ts.
// The stub mirrors the picker's public API:
//   - v-model:show (modelValue + update:modelValue)
//   - @select(path)
//   - title prop (displayed in stub header)
vi.mock('../components/FilePickerDialog.vue', () => ({
  default: {
    name: 'FilePickerDialog',
    props: ['modelValue', 'mode', 'loadItems', 'keyFor', 'pathFor', 'isExpandable', 'labelFor', 'title'],
    emits: ['update:modelValue', 'select'],
    template: `
      <div v-if="modelValue" data-testid="file-picker-dialog">
        <h2 data-testid="file-picker-title">{{ title }}</h2>
        <button data-testid="file-picker-select-home" @click="$emit('select', '/home')">
          Pick /home
        </button>
        <button data-testid="file-picker-cancel" @click="$emit('update:modelValue', false)">
          Cancel
        </button>
      </div>
    `,
  },
}))

function findInDom<T extends Element = Element>(selector: string): T | null {
  return document.querySelector<T>(selector)
}

function clickInDom(selector: string) {
  const el = findInDom<HTMLElement>(selector)
  if (!el) throw new Error(`No element found: ${selector}`)
  el.click()
}

function mountDialog(initialShow = true) {
  // Wipe the body before each mount — see the rationale in
  // AddItemDialog.spec.ts (Teleport to body + jsdom div accumulation).
  document.body.innerHTML = ''
  return mount(AddKanbanDialog, {
    attachTo: document.body,
    props: { show: initialShow },
  })
}

describe('AddKanbanDialog', () => {
  let wrapper: VueWrapper | null = null

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    document.body.style.overflow = ''
    vi.restoreAllMocks()
  })

  it('renders nothing when show=false', () => {
    wrapper = mountDialog(false)
    expect(findInDom('[data-testid="add-kanban-dialog"]')).toBeNull()
  })

  it('shows the "Add Project Kanban" title and a name input when show=true', async () => {
    wrapper = mountDialog(true)
    await flushPromises()
    const dialog = findInDom('[data-testid="add-kanban-dialog"]')
    expect(dialog).not.toBeNull()
    // Title text is in the dialog body
    expect(dialog?.textContent).toContain('Add Project Kanban')
    // Description also present
    expect(dialog?.textContent).toContain('Create a new kanban board')
    // Name input is rendered with the expected data-testid
    const nameInput = findInDom<HTMLInputElement>('[data-testid="add-kanban-name"]')
    expect(nameInput).not.toBeNull()
    expect(nameInput?.tagName).toBe('INPUT')
  })

  it('opens with an empty name field', async () => {
    wrapper = mountDialog(true)
    await flushPromises()
    const input = findInDom<HTMLInputElement>('[data-testid="add-kanban-name"]')
    expect(input?.value).toBe('')
  })

  it('Add button is disabled when name is empty', async () => {
    wrapper = mountDialog(true)
    await flushPromises()
    const btn = findInDom<HTMLButtonElement>('[data-testid="add-kanban-submit"]')
    expect(btn?.disabled).toBe(true)
  })

  it('Add button is disabled when name is whitespace only', async () => {
    wrapper = mountDialog(true)
    await flushPromises()
    const nameInput = findInDom<HTMLInputElement>('[data-testid="add-kanban-name"]')!
    nameInput.value = '   '
    nameInput.dispatchEvent(new Event('input', { bubbles: true }))
    await flushPromises()
    const btn = findInDom<HTMLButtonElement>('[data-testid="add-kanban-submit"]')
    expect(btn?.disabled).toBe(true)
  })

  // ─── Visible "Name is required" error UX (mirrors AddItemDialog) ─────────
  //
  // The dialog now shows an inline error below the name input after
  // the user has interacted with an empty/whitespace field, so the
  // disabled Add button has a visible explanation.
  //
  // Plan: docs/superpowers/plans/2026-07-10-empty-workspace-item-bug.md

  it('whitespace-only name shows visible "Name is required" error', async () => {
    wrapper = mountDialog(true)
    await flushPromises()

    // No error initially — the field is empty by design on first open.
    expect(findInDom('[data-testid="add-kanban-name-error"]')).toBeNull()

    // Type whitespace and dispatch input → nameTouched flips → error appears.
    const nameInput = findInDom<HTMLInputElement>('[data-testid="add-kanban-name"]')!
    nameInput.value = '   '
    nameInput.dispatchEvent(new Event('input', { bubbles: true }))
    await flushPromises()

    const error = findInDom<HTMLElement>('[data-testid="add-kanban-name-error"]')
    expect(error?.textContent).toContain('Name is required')
  })

  it('typing a valid name hides the "Name is required" error', async () => {
    wrapper = mountDialog(true)
    await flushPromises()

    // Type then clear → error appears.
    const nameInput = findInDom<HTMLInputElement>('[data-testid="add-kanban-name"]')!
    nameInput.value = 'X'
    nameInput.dispatchEvent(new Event('input', { bubbles: true }))
    await flushPromises()
    expect(findInDom('[data-testid="add-kanban-name-error"]')).toBeNull()

    // Clear → error appears.
    nameInput.value = ''
    nameInput.dispatchEvent(new Event('input', { bubbles: true }))
    await flushPromises()
    expect(findInDom('[data-testid="add-kanban-name-error"]')).not.toBeNull()

    // Type valid → error disappears.
    nameInput.value = 'Sprint 12'
    nameInput.dispatchEvent(new Event('input', { bubbles: true }))
    await flushPromises()
    expect(findInDom('[data-testid="add-kanban-name-error"]')).toBeNull()
  })

  it('Add button is enabled with a valid name even when no folder is picked (path is optional since 2026-08-06)', async () => {
    wrapper = mountDialog(true)
    await flushPromises()
    const nameInput = findInDom<HTMLInputElement>('[data-testid="add-kanban-name"]')!
    nameInput.value = 'Sprint 12'
    nameInput.dispatchEvent(new Event('input', { bubbles: true }))
    await flushPromises()
    // No folder picked → button is STILL enabled (path is optional since 2026-08-06 — the backend
    // stores NULL when the path is empty; the kanban is cwd-less until the user backfills via the
    // "Set project root" banner in KanbanView).
    const btn = findInDom<HTMLButtonElement>('[data-testid="add-kanban-submit"]')
    expect(btn?.disabled).toBe(false)
  })

  // ─── Optional path (2026-08-06) ────────────────────────────────────
  //
  // Since the "make cwd session as optional" task, the user can
  // submit the dialog with a valid name AND no folder picked.
  // The create event must emit `create(name, '')` — the empty path
  // string is the cwd-less kanban signal. The backend's
  // `workspace_items_create_kanban.zig` writes NULL when the path
  // is empty, and `session_create.zig` creates a sandbox directory
  // per chat session when `cwd_session` is empty (the existing
  // pre-fix behavior for legacy cwd-less kanbans).
  //
  // The "Set project root" banner in KanbanView surfaces after
  // creation, offering the user a way to backfill the path via
  // the same FilePickerDialog.

  it('emits create(name, "") when Add is clicked without picking a folder (cwd-less kanban)', async () => {
    wrapper = mountDialog(true)
    await flushPromises()
    const nameInput = findInDom<HTMLInputElement>('[data-testid="add-kanban-name"]')!
    nameInput.value = 'Quick Sprint'
    nameInput.dispatchEvent(new Event('input', { bubbles: true }))
    await flushPromises()
    // Skip the picker entirely → click Add directly.
    clickInDom('[data-testid="add-kanban-submit"]')
    // create event carries name + EMPTY path (the cwd-less signal).
    expect(wrapper.emitted('create')?.[0]).toEqual(['Quick Sprint', ''])
    expect(wrapper.emitted('close')).toBeTruthy()
  })

  it('renders the "Skip (no project root)" placeholder when no folder is picked', async () => {
    wrapper = mountDialog(true)
    await flushPromises()
    const folderBtn = findInDom<HTMLElement>('[data-testid="add-kanban-choose-folder"]')
    expect(folderBtn?.textContent).toContain('Skip (no project root)')
  })

  it('shows "(optional — used as cwd for chat sessions)" hint above the picker', async () => {
    wrapper = mountDialog(true)
    await flushPromises()
    const dialog = findInDom('[data-testid="add-kanban-dialog"]')
    expect(dialog?.textContent).toContain('(optional')
    expect(dialog?.textContent).toContain('used as cwd for chat sessions')
  })

  it('typing a name + picking a folder enables the Add button', async () => {
    wrapper = mountDialog(true)
    await flushPromises()
    const nameInput = findInDom<HTMLInputElement>('[data-testid="add-kanban-name"]')!
    nameInput.value = 'Sprint 12'
    nameInput.dispatchEvent(new Event('input', { bubbles: true }))
    await flushPromises()
    // Open the picker (stubbed) and pick /home. The picker's @select
    // bubbles up through the parent and sets selectedPath.
    clickInDom('[data-testid="add-kanban-choose-folder"]')
    await flushPromises()
    clickInDom('[data-testid="file-picker-select-home"]')
    await flushPromises()
    const btn = findInDom<HTMLButtonElement>('[data-testid="add-kanban-submit"]')
    expect(btn?.disabled).toBe(false)
  })

  it('emits create(name, path) and close when Add is clicked with valid name + folder', async () => {
    wrapper = mountDialog(true)
    await flushPromises()
    const nameInput = findInDom<HTMLInputElement>('[data-testid="add-kanban-name"]')!
    nameInput.value = 'Sprint 12'
    nameInput.dispatchEvent(new Event('input', { bubbles: true }))
    await flushPromises()
    clickInDom('[data-testid="add-kanban-choose-folder"]')
    await flushPromises()
    clickInDom('[data-testid="file-picker-select-home"]')
    await flushPromises()
    clickInDom('[data-testid="add-kanban-submit"]')
    // create event carries both name (1st arg) and path (2nd arg).
    expect(wrapper.emitted('create')?.[0]).toEqual(['Sprint 12', '/home'])
    expect(wrapper.emitted('close')).toBeTruthy()
  })

  it('trims whitespace from the name before emitting', async () => {
    wrapper = mountDialog(true)
    await flushPromises()
    const nameInput = findInDom<HTMLInputElement>('[data-testid="add-kanban-name"]')!
    nameInput.value = '  Sprint 12  '
    nameInput.dispatchEvent(new Event('input', { bubbles: true }))
    await flushPromises()
    clickInDom('[data-testid="add-kanban-choose-folder"]')
    await flushPromises()
    clickInDom('[data-testid="file-picker-select-home"]')
    await flushPromises()
    clickInDom('[data-testid="add-kanban-submit"]')
    expect(wrapper.emitted('create')?.[0]).toEqual(['Sprint 12', '/home'])
  })

  it('Add button is a no-op when name is empty (no emit)', async () => {
    wrapper = mountDialog(true)
    await flushPromises()
    // Force-click the disabled button to verify it is a no-op
    const btn = findInDom<HTMLButtonElement>('[data-testid="add-kanban-submit"]')
    btn?.click()
    expect(wrapper.emitted('create')).toBeUndefined()
    expect(wrapper.emitted('close')).toBeUndefined()
  })

  it('emits close when Cancel is clicked', async () => {
    wrapper = mountDialog(true)
    await flushPromises()
    clickInDom('[data-testid="add-kanban-cancel"]')
    expect(wrapper.emitted('close')).toBeTruthy()
    expect(wrapper.emitted('create')).toBeUndefined()
  })

  it('emits close when backdrop is clicked', async () => {
    wrapper = mountDialog(true)
    await flushPromises()
    const backdrop = document.querySelector(
      '[data-testid="add-kanban-dialog"] .absolute.inset-0',
    ) as HTMLElement | null
    expect(backdrop).not.toBeNull()
    backdrop?.click()
    expect(wrapper.emitted('close')).toBeTruthy()
  })

  it('emits close on Escape key', async () => {
    wrapper = mountDialog(true)
    await flushPromises()
    const dialog = findInDom<HTMLElement>('[data-testid="add-kanban-dialog"]')
    dialog?.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true }))
    expect(wrapper.emitted('close')).toBeTruthy()
  })

  it('resets name field on every open (no leakage across opens)', async () => {
    wrapper = mountDialog(true)
    await flushPromises()
    const nameInput = findInDom<HTMLInputElement>('[data-testid="add-kanban-name"]')!
    nameInput.value = 'Old Name'
    nameInput.dispatchEvent(new Event('input', { bubbles: true }))
    await flushPromises()
    // Close
    await wrapper.setProps({ show: false })
    await flushPromises()
    // Reopen → state should be reset
    await wrapper.setProps({ show: true })
    await flushPromises()
    const nameAfter = findInDom<HTMLInputElement>('[data-testid="add-kanban-name"]')
    expect(nameAfter?.value).toBe('')
  })
})