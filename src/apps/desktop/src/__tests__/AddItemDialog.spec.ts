/**
 * Tests for AddItemDialog — the modal that creates a new project from a folder.
 *
 * After the migration to FilePickerDialog, the wrapper modal's own behavior is
 * what we test here: open/close lifecycle, name input, "Choose folder" button,
 * the create event shape. The picker itself is tested in FilePickerDialog.spec.ts.
 *
 * We mock FilePickerDialog with a stub that exposes data-testids for the
 * buttons we need to drive. This follows the same pattern as
 * createWorktreeDialog.spec.ts which mocks FolderExplorer — we only need to
 * verify the dialog wires up the picker's events, not test the picker
 * itself. The picker has its own test suite (FilePickerDialog.spec.ts).
 *
 * The API is NOT mocked — the real FilePickerDialog is stubbed out
 * entirely, so listFolder/getSystemFolder are never called in these tests.
 */
import { afterEach, describe, expect, it, vi } from 'vitest'
import { mount, flushPromises, type VueWrapper } from '@vue/test-utils'
import AddItemDialog from '../components/dialogs/AddItemDialog.vue'

// ─── Mocks ─────────────────────────────────────────────────────────────────

// Stub the FilePickerDialog — we only care that the parent wires up the
// picker's events. Real picker behavior is tested in FilePickerDialog.spec.ts.
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
        <button data-testid="file-picker-select-user" @click="$emit('select', '/home/user')">
          Pick /home/user
        </button>
        <button data-testid="file-picker-cancel" @click="$emit('update:modelValue', false)">
          Cancel
        </button>
      </div>
    `,
  },
}))

// ─── Helpers ───────────────────────────────────────────────────────────────

function findInDom<T extends Element = Element>(selector: string): T | null {
  return document.querySelector<T>(selector)
}

function clickInDom(selector: string) {
  const el = findInDom<HTMLElement>(selector)
  if (!el) throw new Error(`No element found: ${selector}`)
  el.click()
}

function mountDialog(initialShow = true) {
  // Wipe the body before each mount. attachTo: document.body creates a new
  // <div data-v-app> for each mount, and these accumulate in jsdom even after
  // wrapper.unmount() (the divs persist as empty containers). The accumulated
  // divs cause weird interactions with subsequent mounts — most notably, the
  // Teleport target can become confused when there are many empty data-v-app
  // divs already in the body. Clearing the body here ensures a clean slate.
  document.body.innerHTML = ''
  return mount(AddItemDialog, {
    attachTo: document.body,
    props: { show: initialShow },
  })
}

// ─── Tests ─────────────────────────────────────────────────────────────────

describe('AddItemDialog — open/close lifecycle', () => {
  let wrapper: VueWrapper | null = null

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    document.body.style.overflow = ''
    vi.restoreAllMocks()
  })

  it('renders nothing in the DOM when show=false', () => {
    wrapper = mountDialog(false)
    expect(findInDom('[data-testid="add-item-dialog"]')).toBeNull()
  })

  it('mounts the dialog when show=true', async () => {
    wrapper = mountDialog(true)
    await flushPromises()
    expect(findInDom('[data-testid="add-item-dialog"]')).not.toBeNull()
  })

  it('shows the "Add Project" title and description', async () => {
    wrapper = mountDialog(true)
    await flushPromises()
    const dialog = findInDom('[data-testid="add-item-dialog"]')
    expect(dialog?.textContent).toContain('Add Project')
    expect(dialog?.textContent).toContain('Select a folder to add as a project')
  })

  it('emits close when Cancel is clicked', async () => {
    wrapper = mountDialog(true)
    await flushPromises()
    clickInDom('[data-testid="add-item-cancel"]')
    expect(wrapper.emitted('close')).toBeTruthy()
  })

  it('emits close when backdrop is clicked', async () => {
    wrapper = mountDialog(true)
    await flushPromises()
    const backdrop = document.querySelector(
      '[data-testid="add-item-dialog"] .absolute.inset-0',
    ) as HTMLElement | null
    expect(backdrop).not.toBeNull()
    backdrop?.click()
    expect(wrapper.emitted('close')).toBeTruthy()
  })

  it('emits close on Escape key', async () => {
    wrapper = mountDialog(true)
    await flushPromises()
    const dialog = findInDom<HTMLElement>('[data-testid="add-item-dialog"]')
    dialog?.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true }))
    expect(wrapper.emitted('close')).toBeTruthy()
  })
})

describe('AddItemDialog — initial state on open', () => {
  let wrapper: VueWrapper | null = null

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    document.body.style.overflow = ''
    vi.restoreAllMocks()
  })

  it('opens with an empty name field', async () => {
    wrapper = mountDialog(true)
    await flushPromises()
    const input = findInDom<HTMLInputElement>('[data-testid="add-item-name"]')
    expect(input?.value).toBe('')
  })

  it('opens with empty "Choose folder..." placeholder', async () => {
    wrapper = mountDialog(true)
    await flushPromises()
    const btn = findInDom<HTMLElement>('[data-testid="add-item-choose-folder"]')
    expect(btn?.textContent).toContain('Choose folder...')
  })

  it('Add button is disabled when name and path are empty', async () => {
    wrapper = mountDialog(true)
    await flushPromises()
    const btn = findInDom<HTMLButtonElement>('[data-testid="add-item-submit"]')
    expect(btn?.disabled).toBe(true)
  })

  it('resets state on every open (no leakage across opens)', async () => {
    wrapper = mountDialog(true)
    await flushPromises()

    // Type a name
    const nameInput = findInDom<HTMLInputElement>('[data-testid="add-item-name"]')!
    expect(nameInput).not.toBeNull()
    nameInput.value = 'Old Name'
    nameInput.dispatchEvent(new Event('input', { bubbles: true }))
    await flushPromises()

    // Close (sets show=false → watch fires, resets state)
    await wrapper.setProps({ show: false })
    await flushPromises()

    // Reopen → state should be reset
    await wrapper.setProps({ show: true })
    await flushPromises()

    const nameAfter = findInDom<HTMLInputElement>('[data-testid="add-item-name"]')
    expect(nameAfter?.value).toBe('')
    const btnAfter = findInDom<HTMLElement>('[data-testid="add-item-choose-folder"]')
    expect(btnAfter?.textContent).toContain('Choose folder...')
  })
})

describe('AddItemDialog — name input', () => {
  let wrapper: VueWrapper | null = null

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    document.body.style.overflow = ''
    vi.restoreAllMocks()
  })

  it('typing a name enables the Add button (when path is set)', async () => {
    wrapper = mountDialog(true)
    await flushPromises()

    // Open picker via "Choose folder" button
    clickInDom('[data-testid="add-item-choose-folder"]')
    await flushPromises()
    expect(findInDom('[data-testid="file-picker-dialog"]')).not.toBeNull()

    // Simulate selecting a folder (the stub emits `select` with /home)
    clickInDom('[data-testid="file-picker-select-home"]')
    await flushPromises()

    // Picker should close
    expect(findInDom('[data-testid="file-picker-dialog"]')).toBeNull()

    // Path should be set
    const chooseBtn = findInDom<HTMLElement>('[data-testid="add-item-choose-folder"]')
    expect(chooseBtn?.textContent).toContain('/home')

    // Add should still be disabled (name is empty)
    let submitBtn = findInDom<HTMLButtonElement>('[data-testid="add-item-submit"]')
    expect(submitBtn?.disabled).toBe(true)

    // Type a name
    const nameInput = findInDom<HTMLInputElement>('[data-testid="add-item-name"]')!
    nameInput.value = 'My Project'
    nameInput.dispatchEvent(new Event('input', { bubbles: true }))
    await flushPromises()

    // Add should now be enabled
    submitBtn = findInDom<HTMLButtonElement>('[data-testid="add-item-submit"]')
    expect(submitBtn?.disabled).toBe(false)
  })

  it('whitespace-only name does not enable Add', async () => {
    wrapper = mountDialog(true)
    await flushPromises()

    // Set path via picker
    clickInDom('[data-testid="add-item-choose-folder"]')
    await flushPromises()
    clickInDom('[data-testid="file-picker-select-home"]')
    await flushPromises()

    // Type whitespace
    const nameInput = findInDom<HTMLInputElement>('[data-testid="add-item-name"]')!
    nameInput.value = '   '
    nameInput.dispatchEvent(new Event('input', { bubbles: true }))
    await flushPromises()

    const submitBtn = findInDom<HTMLButtonElement>('[data-testid="add-item-submit"]')
    expect(submitBtn?.disabled).toBe(true)
  })

  // ─── Empty/whitespace name → visible error message ─────────────────────
  //
  // The dialog now shows an inline "Name is required" error after
  // the user has interacted with the name field (typed-then-cleared
  // OR blurred with whitespace). The error explains why Add is
  // disabled — without it, the disabled button looks like a renderer
  // bug to users who can't see why nothing happens.
  //
  // Plan: docs/superpowers/plans/2026-07-10-empty-workspace-item-bug.md

  it('whitespace-only name shows visible "Name is required" error', async () => {
    wrapper = mountDialog(true)
    await flushPromises()

    // Set path via picker so the only thing blocking Add is the name.
    clickInDom('[data-testid="add-item-choose-folder"]')
    await flushPromises()
    clickInDom('[data-testid="file-picker-select-home"]')
    await flushPromises()

    // No error initially — the field is empty by design on first open.
    expect(findInDom('[data-testid="add-item-name-error"]')).toBeNull()

    // Type whitespace and dispatch input → nameTouched flips → error appears.
    const nameInput = findInDom<HTMLInputElement>('[data-testid="add-item-name"]')!
    nameInput.value = '   '
    nameInput.dispatchEvent(new Event('input', { bubbles: true }))
    await flushPromises()

    const error = findInDom<HTMLElement>('[data-testid="add-item-name-error"]')
    expect(error?.textContent).toContain('Name is required')
    // The submit button is still disabled.
    const submitBtn = findInDom<HTMLButtonElement>('[data-testid="add-item-submit"]')
    expect(submitBtn?.disabled).toBe(true)
  })

  it('typing a valid name hides the "Name is required" error', async () => {
    wrapper = mountDialog(true)
    await flushPromises()

    clickInDom('[data-testid="add-item-choose-folder"]')
    await flushPromises()
    clickInDom('[data-testid="file-picker-select-home"]')
    await flushPromises()

    // Type then clear → error appears.
    const nameInput = findInDom<HTMLInputElement>('[data-testid="add-item-name"]')!
    nameInput.value = 'X'
    nameInput.dispatchEvent(new Event('input', { bubbles: true }))
    await flushPromises()
    expect(findInDom('[data-testid="add-item-name-error"]')).toBeNull()

    // Clear → error appears again.
    nameInput.value = ''
    nameInput.dispatchEvent(new Event('input', { bubbles: true }))
    await flushPromises()
    expect(findInDom('[data-testid="add-item-name-error"]')).not.toBeNull()

    // Type valid → error disappears.
    nameInput.value = 'My Project'
    nameInput.dispatchEvent(new Event('input', { bubbles: true }))
    await flushPromises()
    expect(findInDom('[data-testid="add-item-name-error"]')).toBeNull()
  })

  it('blurring an empty name field shows the error (without typing)', async () => {
    wrapper = mountDialog(true)
    await flushPromises()

    // Focus then blur the empty name field — nameTouched flips via
    // @blur even without an @input. Simulates the user clicking
    // the field then clicking away.
    const nameInput = findInDom<HTMLInputElement>('[data-testid="add-item-name"]')!
    nameInput.focus()
    nameInput.dispatchEvent(new Event('blur', { bubbles: true }))
    await flushPromises()

    expect(findInDom('[data-testid="add-item-name-error"]')).not.toBeNull()
  })

  it('opening the dialog after a previous session starts fresh (no error flash)', async () => {
    wrapper = mountDialog(true)
    await flushPromises()

    // Type then clear → error.
    const nameInput = findInDom<HTMLInputElement>('[data-testid="add-item-name"]')!
    nameInput.value = '   '
    nameInput.dispatchEvent(new Event('input', { bubbles: true }))
    await flushPromises()
    expect(findInDom('[data-testid="add-item-name-error"]')).not.toBeNull()

    // Close + reopen → state must reset so the user doesn't see
    // the error flash on a freshly-opened dialog.
    await wrapper.setProps({ show: false })
    await flushPromises()
    await wrapper.setProps({ show: true })
    await flushPromises()

    expect(findInDom('[data-testid="add-item-name-error"]')).toBeNull()
  })
})

describe('AddItemDialog — folder picker integration', () => {
  let wrapper: VueWrapper | null = null

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    document.body.style.overflow = ''
    vi.restoreAllMocks()
  })

  it('clicking "Choose folder" opens the FilePickerDialog', async () => {
    wrapper = mountDialog(true)
    await flushPromises()
    expect(findInDom('[data-testid="file-picker-dialog"]')).toBeNull()

    clickInDom('[data-testid="add-item-choose-folder"]')
    await flushPromises()
    expect(findInDom('[data-testid="file-picker-dialog"]')).not.toBeNull()
  })

  it('the picker shows the configured title "Select Project Folder"', async () => {
    wrapper = mountDialog(true)
    await flushPromises()
    clickInDom('[data-testid="add-item-choose-folder"]')
    await flushPromises()
    expect(findInDom('[data-testid="file-picker-dialog"]')?.textContent).toContain(
      'Select Project Folder',
    )
  })

  it('selecting a folder in the picker updates the displayed path', async () => {
    wrapper = mountDialog(true)
    await flushPromises()
    clickInDom('[data-testid="add-item-choose-folder"]')
    await flushPromises()
    clickInDom('[data-testid="file-picker-select-home"]')
    await flushPromises()
    const btn = findInDom<HTMLElement>('[data-testid="add-item-choose-folder"]')
    expect(btn?.textContent).toContain('/home')
  })

  it('picker closes when the user clicks its Cancel button', async () => {
    wrapper = mountDialog(true)
    await flushPromises()
    clickInDom('[data-testid="add-item-choose-folder"]')
    await flushPromises()
    expect(findInDom('[data-testid="file-picker-dialog"]')).not.toBeNull()
    clickInDom('[data-testid="file-picker-cancel"]')
    await flushPromises()
    expect(findInDom('[data-testid="file-picker-dialog"]')).toBeNull()
  })

  it('can re-open the picker after a selection', async () => {
    wrapper = mountDialog(true)
    await flushPromises()

    // First open + select
    clickInDom('[data-testid="add-item-choose-folder"]')
    await flushPromises()
    clickInDom('[data-testid="file-picker-select-home"]')
    await flushPromises()
    expect(findInDom('[data-testid="file-picker-dialog"]')).toBeNull()

    // Re-open
    clickInDom('[data-testid="add-item-choose-folder"]')
    await flushPromises()
    expect(findInDom('[data-testid="file-picker-dialog"]')).not.toBeNull()
  })
})

describe('AddItemDialog — create event', () => {
  let wrapper: VueWrapper | null = null

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    document.body.style.overflow = ''
    vi.restoreAllMocks()
  })

  it('Add button emits create(name, path) and closes', async () => {
    wrapper = mountDialog(true)
    await flushPromises()

    // Set name
    const nameInput = findInDom<HTMLInputElement>('[data-testid="add-item-name"]')!
    nameInput.value = 'My Project'
    nameInput.dispatchEvent(new Event('input', { bubbles: true }))
    await flushPromises()

    // Set path via picker (stub emits select with /home)
    clickInDom('[data-testid="add-item-choose-folder"]')
    await flushPromises()
    clickInDom('[data-testid="file-picker-select-home"]')
    await flushPromises()

    // Click Add
    clickInDom('[data-testid="add-item-submit"]')
    expect(wrapper.emitted('create')?.[0]).toEqual(['My Project', '/home'])
    expect(wrapper.emitted('close')).toBeTruthy()
  })

  it('Add button trims whitespace from the name', async () => {
    wrapper = mountDialog(true)
    await flushPromises()

    const nameInput = findInDom<HTMLInputElement>('[data-testid="add-item-name"]')!
    nameInput.value = '  Spaced Out  '
    nameInput.dispatchEvent(new Event('input', { bubbles: true }))
    await flushPromises()

    clickInDom('[data-testid="add-item-choose-folder"]')
    await flushPromises()
    clickInDom('[data-testid="file-picker-select-home"]')
    await flushPromises()

    clickInDom('[data-testid="add-item-submit"]')
    expect(wrapper.emitted('create')?.[0]).toEqual(['Spaced Out', '/home'])
  })

  it('Add button is a no-op when only name is set (no path)', async () => {
    wrapper = mountDialog(true)
    await flushPromises()

    const nameInput = findInDom<HTMLInputElement>('[data-testid="add-item-name"]')!
    nameInput.value = 'Orphan Name'
    nameInput.dispatchEvent(new Event('input', { bubbles: true }))
    await flushPromises()

    const submitBtn = findInDom<HTMLButtonElement>('[data-testid="add-item-submit"]')
    expect(submitBtn?.disabled).toBe(true)

    // Force click to verify it's a no-op
    submitBtn?.click()
    expect(wrapper.emitted('create')).toBeUndefined()
  })

  it('Add button is a no-op when only path is set (no name)', async () => {
    wrapper = mountDialog(true)
    await flushPromises()

    // Set path only
    clickInDom('[data-testid="add-item-choose-folder"]')
    await flushPromises()
    clickInDom('[data-testid="file-picker-select-home"]')
    await flushPromises()

    const submitBtn = findInDom<HTMLButtonElement>('[data-testid="add-item-submit"]')
    expect(submitBtn?.disabled).toBe(true)
    submitBtn?.click()
    expect(wrapper.emitted('create')).toBeUndefined()
  })
})