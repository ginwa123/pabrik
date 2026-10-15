/**
 * Tests for the CreateWorktreeDialog component. The dialog combines a
 * FilePickerDialog (for picking the parent directory) + a basename input
 * + a Create/Cancel button pair. It composes the final absolute path as
 * `${parentDir}/${basename}` and emits `create(path)` on submit.
 *
 * The FilePickerDialog is stubbed via `vi.mock` because it has a complex
 * data source (loadItems → listFolder API), two-pane layout, search,
 * keyboard nav, etc. — all of that is tested in
 * FilePickerDialog.spec.ts. We only need to verify that this dialog:
 *   1. Wires the picker's @select to update parentDir
 *   2. Wires the picker's v-model to open/close
 *   3. Composes parent + basename and emits `create(path)` on submit
 *   4. Trims the basename and handles edge cases (root, trailing slash)
 *   5. Resets state, focuses input, handles Escape
 *
 * Note: the dialog renders inside a <Teleport to="body">, so the actual
 * DOM is detached from the wrapper. We use `document.querySelector` /
 * `findInDom` (instead of `wrapper.find`) and dispatch events manually
 * to interact with the rendered DOM. This matches the pattern used in
 * AddItemDialog.spec.ts.
 */
import { afterEach, describe, expect, it, vi } from 'vitest'
import { mount, type VueWrapper } from '@vue/test-utils'

// ─── Mocks ─────────────────────────────────────────────────────────────────

// Stub the FilePickerDialog — we only care that the parent wires up the picker's events. Real
// picker behavior is tested in FilePickerDialog.spec.ts.

// IMPORTANT: the mock must use `modelValue` (not `show`) because the parent uses
// `v-model="showPicker"` (no argument), which compiles to :modelValue="showPicker"
// @update:modelValue="showPicker = $event". A prop named `show` would not be wired to v-model.
vi.mock('../components/FilePickerDialog.vue', () => ({
  default: {
    name: 'FilePickerDialog',
    props: [
      'modelValue',
      'mode',
      'loadItems',
      'keyFor',
      'pathFor',
      'isExpandable',
      'labelFor',
      'title',
      'initialPath',
      'selectedPath',
    ],
    emits: ['update:modelValue', 'select', 'cancel'],
    template: `
      <div v-if="modelValue" data-testid="file-picker-dialog">
        <h2 data-testid="file-picker-title">{{ title }}</h2>
        <button
          data-testid="file-picker-select-home"
          @click="$emit('select', '/home')"
        >
          Pick /home
        </button>
        <button
          data-testid="file-picker-select-home-projects"
          @click="$emit('select', '/home/me/projects')"
        >
          Pick /home/me/projects
        </button>
        <button
          data-testid="file-picker-cancel"
          @click="$emit('update:modelValue', false)"
        >
          Cancel
        </button>
      </div>
    `,
  },
}))

// ─── Imports ───────────────────────────────────────────────────────────────

import CreateWorktreeDialog from '../components/dialogs/CreateWorktreeDialog.vue'

// ─── Helpers ───────────────────────────────────────────────────────────────

function findInDom<T extends Element = Element>(selector: string): T | null {
  return document.querySelector<T>(selector)
}

function clickInDom(selector: string) {
  const el = findInDom<HTMLElement>(selector)
  if (!el) throw new Error(`No element found: ${selector}`)
  el.click()
}

/** Set the value of the basename input and dispatch a `change` event so
 * Vue's v-model picks it up. Mirrors the AddItemDialog test pattern. */
function setBasename(value: string) {
  const input = findInDom<HTMLInputElement>('[data-testid="create-worktree-name"]')
  if (!input) throw new Error('No basename input found')
  input.value = value
  input.dispatchEvent(new Event('input', { bubbles: true }))
}

function mountDialog(initialCwd?: string) {
  // Wipe the body before each mount. attachTo: document.body creates a new <div data-v-app> for
  // each mount, and these accumulate in jsdom even after wrapper.unmount().

  // Clearing the body here ensures a clean slate for each test (otherwise Teleport + body event
  // listeners from the previous test can interfere with the new one).
  document.body.innerHTML = ''
  return mount(CreateWorktreeDialog, {
    attachTo: document.body,
    props: initialCwd ? { initialCwd } : {},
  })
}

// ─── Tests ─────────────────────────────────────────────────────────────────

describe('CreateWorktreeDialog — initial state', () => {
  let wrapper: VueWrapper | null = null

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    document.body.style.overflow = ''
    vi.restoreAllMocks()
  })

  it('renders the dialog with choose-parent button, name input, and Create/Cancel buttons', () => {
    wrapper = mountDialog('/home/me/proj')
    expect(findInDom('[data-testid="create-worktree-dialog"]')).not.toBeNull()
    expect(findInDom('[data-testid="create-worktree-choose-parent"]')).not.toBeNull()
    expect(findInDom('[data-testid="create-worktree-name"]')).not.toBeNull()
    expect(findInDom('[data-testid="create-worktree-submit"]')).not.toBeNull()
    expect(findInDom('[data-testid="create-worktree-cancel"]')).not.toBeNull()
  })

  it('uses the initialCwd prop as the starting parent directory (displayed in the choose-parent button)', () => {
    wrapper = mountDialog('/home/me/myapp')
    const chooseBtn = findInDom<HTMLElement>('[data-testid="create-worktree-choose-parent"]')
    expect(chooseBtn?.textContent).toContain('/home/me/myapp')
  })

  it('falls back to "Choose parent directory…" when initialCwd is not provided', () => {
    wrapper = mountDialog()
    const chooseBtn = findInDom<HTMLElement>('[data-testid="create-worktree-choose-parent"]')
    expect(chooseBtn?.textContent).toContain('Choose parent directory')
  })

  it('Create button is disabled when basename is empty', () => {
    wrapper = mountDialog('/home/me/proj')
    const submit = findInDom<HTMLButtonElement>('[data-testid="create-worktree-submit"]')
    expect(submit?.disabled).toBe(true)
  })
})

describe('CreateWorktreeDialog — parent directory picker', () => {
  let wrapper: VueWrapper | null = null

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    document.body.style.overflow = ''
    vi.restoreAllMocks()
  })

  it('clicking "Choose parent directory" opens the FilePickerDialog', async () => {
    wrapper = mountDialog('/home/me/proj')
    expect(findInDom('[data-testid="file-picker-dialog"]')).toBeNull()

    clickInDom('[data-testid="create-worktree-choose-parent"]')
    await new Promise((r) => setTimeout(r, 0))
    expect(findInDom('[data-testid="file-picker-dialog"]')).not.toBeNull()
  })

  it('the picker shows the configured title "Select parent directory"', async () => {
    wrapper = mountDialog('/home/me/proj')
    clickInDom('[data-testid="create-worktree-choose-parent"]')
    await new Promise((r) => setTimeout(r, 0))
    expect(findInDom('[data-testid="file-picker-dialog"]')?.textContent).toContain(
      'Select parent directory',
    )
  })

  it('selecting a folder in the picker closes the picker and updates the displayed path', async () => {
    wrapper = mountDialog('/home/me/proj')
    clickInDom('[data-testid="create-worktree-choose-parent"]')
    await new Promise((r) => setTimeout(r, 0))

    // Simulate the user picking /home/me/projects
    clickInDom('[data-testid="file-picker-select-home-projects"]')
    await new Promise((r) => setTimeout(r, 0))

    // Picker should be closed
    expect(findInDom('[data-testid="file-picker-dialog"]')).toBeNull()

    // The choose-parent button should now show the new path
    const chooseBtn = findInDom<HTMLElement>('[data-testid="create-worktree-choose-parent"]')
    expect(chooseBtn?.textContent).toContain('/home/me/projects')
  })

  it('reflects the new parent in the hint text after selecting a folder', async () => {
    wrapper = mountDialog('/home/me/proj')
    clickInDom('[data-testid="create-worktree-choose-parent"]')
    await new Promise((r) => setTimeout(r, 0))
    clickInDom('[data-testid="file-picker-select-home-projects"]')
    await new Promise((r) => setTimeout(r, 0))
    setBasename('my-feature')
    await new Promise((r) => setTimeout(r, 0))
    // The dialog renders inside a Teleport, so the DOM is detached
    // from the wrapper. Use document.body.textContent to read it.
    expect(document.body.textContent).toContain('/home/me/projects/my-feature')
  })

  it('can re-open the picker after a previous selection', async () => {
    wrapper = mountDialog('/home/me/proj')
    clickInDom('[data-testid="create-worktree-choose-parent"]')
    await new Promise((r) => setTimeout(r, 0))
    clickInDom('[data-testid="file-picker-select-home-projects"]')
    await new Promise((r) => setTimeout(r, 0))
    expect(findInDom('[data-testid="file-picker-dialog"]')).toBeNull()

    // Re-open
    clickInDom('[data-testid="create-worktree-choose-parent"]')
    await new Promise((r) => setTimeout(r, 0))
    expect(findInDom('[data-testid="file-picker-dialog"]')).not.toBeNull()
  })
})

describe('CreateWorktreeDialog — submit', () => {
  let wrapper: VueWrapper | null = null

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    document.body.style.overflow = ''
    vi.restoreAllMocks()
  })

  it('clicking Create with a basename emits create(parent + basename) and close is NOT emitted', async () => {
    wrapper = mountDialog('/home/me/proj')
    setBasename('auth-fix')
    await new Promise((r) => setTimeout(r, 0))
    clickInDom('[data-testid="create-worktree-submit"]')
    expect(wrapper.emitted('create')).toBeTruthy()
    expect(wrapper.emitted('create')![0]).toEqual(['/home/me/proj/auth-fix'])
    expect(wrapper.emitted('close')).toBeFalsy()
  })

  it('composes parent + basename without a trailing slash on parent', async () => {
    wrapper = mountDialog('/home/me/proj/')
    setBasename('bug-123')
    await new Promise((r) => setTimeout(r, 0))
    clickInDom('[data-testid="create-worktree-submit"]')
    expect(wrapper.emitted('create')![0]).toEqual(['/home/me/proj/bug-123'])
  })

  it('handles root as parent without a double slash', async () => {
    wrapper = mountDialog('/')
    setBasename('top-level')
    await new Promise((r) => setTimeout(r, 0))
    clickInDom('[data-testid="create-worktree-submit"]')
    expect(wrapper.emitted('create')![0]).toEqual(['/top-level'])
  })

  it('trims whitespace from the basename before emitting', async () => {
    wrapper = mountDialog('/home/me/proj')
    setBasename('  bug-123  ')
    await new Promise((r) => setTimeout(r, 0))
    clickInDom('[data-testid="create-worktree-submit"]')
    expect(wrapper.emitted('create')![0]).toEqual(['/home/me/proj/bug-123'])
  })

  it('Create button is enabled when basename has at least one non-whitespace char', async () => {
    wrapper = mountDialog('/home/me/proj')
    setBasename('x')
    await new Promise((r) => setTimeout(r, 0))
    const submit = findInDom<HTMLButtonElement>('[data-testid="create-worktree-submit"]')
    expect(submit?.disabled).toBe(false)
  })

  it('Create button is disabled when basename is whitespace-only', async () => {
    wrapper = mountDialog('/home/me/proj')
    setBasename('   ')
    await new Promise((r) => setTimeout(r, 0))
    const submit = findInDom<HTMLButtonElement>('[data-testid="create-worktree-submit"]')
    expect(submit?.disabled).toBe(true)
  })

  it('pressing Enter in the basename input emits create', async () => {
    wrapper = mountDialog('/home/me/proj')
    const nameInput = findInDom<HTMLInputElement>('[data-testid="create-worktree-name"]')!
    nameInput.value = 'feature-x'
    nameInput.dispatchEvent(new Event('input', { bubbles: true }))
    nameInput.dispatchEvent(new KeyboardEvent('keyup', { key: 'Enter', bubbles: true }))
    await new Promise((r) => setTimeout(r, 0))
    expect(wrapper.emitted('create')).toBeTruthy()
    expect(wrapper.emitted('create')![0]).toEqual(['/home/me/proj/feature-x'])
  })

  it('reflects the composed path in the hint text after typing a basename', async () => {
    wrapper = mountDialog('/home/me/proj')
    setBasename('my-feature')
    await new Promise((r) => setTimeout(r, 0))
    // The dialog renders inside a Teleport, so the DOM is detached
    // from the wrapper. Use document.body.textContent to read it.
    expect(document.body.textContent).toContain('/home/me/proj/my-feature')
  })

  it('uses the parent path from the picker (not initialCwd) when emitting create', async () => {
    wrapper = mountDialog('/home/me/proj')
    clickInDom('[data-testid="create-worktree-choose-parent"]')
    await new Promise((r) => setTimeout(r, 0))
    clickInDom('[data-testid="file-picker-select-home-projects"]')
    await new Promise((r) => setTimeout(r, 0))
    setBasename('my-feature')
    await new Promise((r) => setTimeout(r, 0))
    clickInDom('[data-testid="create-worktree-submit"]')
    expect(wrapper.emitted('create')![0]).toEqual(['/home/me/projects/my-feature'])
  })
})

describe('CreateWorktreeDialog — close', () => {
  let wrapper: VueWrapper | null = null

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    document.body.style.overflow = ''
    vi.restoreAllMocks()
  })

  it('clicking Cancel emits close', async () => {
    wrapper = mountDialog('/home/me/proj')
    clickInDom('[data-testid="create-worktree-cancel"]')
    expect(wrapper.emitted('close')).toBeTruthy()
  })

  it('pressing Escape emits close', async () => {
    wrapper = mountDialog('/home/me/proj')
    const dialog = findInDom<HTMLElement>('[data-testid="create-worktree-dialog"]')!
    dialog.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true }))
    await new Promise((r) => setTimeout(r, 0))
    expect(wrapper.emitted('close')).toBeTruthy()
  })

  it('clicking the close (✕) button emits close', async () => {
    wrapper = mountDialog('/home/me/proj')
    clickInDom('[data-testid="create-worktree-close"]')
    expect(wrapper.emitted('close')).toBeTruthy()
  })
})
