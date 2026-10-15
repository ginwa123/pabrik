/**
 * Tests for AddMemoryDialog — the modal that creates a new LOCAL
 * memory file (at `<cwd>/.pabrik/memories/<name>.md`). Mirrors
 * AddItemDialog.spec.ts's structure: covers the open/close
 * lifecycle, the name + content inputs, the folder picker
 * (defaults from the cwd prop but can be changed by the user),
 * the validation rules (mirror of `memories.isValidMemoryName`),
 * and the create event shape. Mocks the api module so no network
 * calls happen, and stubs FilePickerDialog (the real picker is
 * tested separately).
 */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { mount, flushPromises, type VueWrapper } from '@vue/test-utils'
import { setActivePinia, createPinia } from 'pinia'
import AddMemoryDialog from '../components/dialogs/AddMemoryDialog.vue'

// Stub the FilePickerDialog — we only care that the parent wires up the picker's events. Real
// picker behavior is tested in FilePickerDialog.spec.ts. The stub mirrors the picker's public API:
// v-model:show (modelValue + update:modelValue) and @select(path).
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
        <button data-testid="file-picker-select-other" @click="$emit('select', '/opt/projects')">
          Pick /opt/projects
        </button>
        <button data-testid="file-picker-cancel" @click="$emit('update:modelValue', false)">
          Cancel
        </button>
      </div>
    `,
  },
}))

vi.mock('../api', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../api')>()
  return {
    ...actual,
    createLocalMemory: vi.fn(),
    getSystemFolder: vi.fn(),
    listFolder: vi.fn(),
  }
})

import { createLocalMemory } from '../api'

const mockCreate = createLocalMemory as unknown as ReturnType<typeof vi.fn>

const TEST_CWD = '/tmp/test-project'

function findInDom<T extends Element = Element>(selector: string): T | null {
  return document.querySelector<T>(selector)
}

function clickInDom(selector: string) {
  const el = findInDom<HTMLElement>(selector)
  if (!el) throw new Error(`No element found: ${selector}`)
  el.click()
}

function mountDialog(initialShow = true, cwd = TEST_CWD) {
  // Wipe the body before each mount. attachTo: document.body creates
  // a new <div data-v-app> for each mount, and these accumulate in
  // jsdom even after wrapper.unmount() (the divs persist as empty
  // containers). The accumulated divs cause weird interactions with
  // subsequent mounts — most notably, the Teleport target can become
  // confused when there are many empty data-v-app divs already in
  // the body. Clearing the body here ensures a clean slate. Same
  // pattern as AddItemDialog.spec.ts:70.
  document.body.innerHTML = ''
  return mount(AddMemoryDialog, {
    attachTo: document.body,
    props: { show: initialShow, cwd },
  })
}

describe('AddMemoryDialog — open/close lifecycle', () => {
  let wrapper: VueWrapper | null = null

  beforeEach(() => {
    setActivePinia(createPinia())
    mockCreate.mockReset()
  })

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    document.body.style.overflow = ''
    vi.restoreAllMocks()
  })

  it('renders nothing in the DOM when show=false', () => {
    wrapper = mountDialog(false)
    expect(findInDom('[data-testid="add-memory-dialog"]')).toBeNull()
  })

  it('mounts the dialog when show=true', async () => {
    wrapper = mountDialog(true)
    await flushPromises()
    expect(findInDom('[data-testid="add-memory-dialog"]')).not.toBeNull()
  })

  it('shows the "Add Markdown" title and cwd in the header', async () => {
    wrapper = mountDialog(true)
    await flushPromises()
    const dialog = findInDom('[data-testid="add-memory-dialog"]')
    expect(dialog?.textContent).toContain('Add Markdown')
    expect(dialog?.textContent).toContain(TEST_CWD)
  })

  it('emits close when Cancel is clicked', async () => {
    wrapper = mountDialog(true)
    await flushPromises()
    clickInDom('[data-testid="add-memory-cancel"]')
    expect(wrapper.emitted('close')).toBeTruthy()
  })

  it('emits close on Escape key', async () => {
    wrapper = mountDialog(true)
    await flushPromises()
    const dialog = findInDom<HTMLElement>('[data-testid="add-memory-dialog"]')
    dialog?.dispatchEvent(
      new KeyboardEvent('keydown', { key: 'Escape', bubbles: true }),
    )
    expect(wrapper.emitted('close')).toBeTruthy()
  })
})

describe('AddMemoryDialog — initial state on open', () => {
  let wrapper: VueWrapper | null = null

  beforeEach(() => {
    setActivePinia(createPinia())
    mockCreate.mockReset()
  })

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    document.body.style.overflow = ''
    vi.restoreAllMocks()
  })

  it('opens with an empty name field', async () => {
    wrapper = mountDialog(true)
    await flushPromises()
    const input = findInDom<HTMLInputElement>('[data-testid="add-memory-name"]')
    expect(input?.value).toBe('')
  })

  it('opens with a default starter content', async () => {
    wrapper = mountDialog(true)
    await flushPromises()
    const textarea = findInDom<HTMLTextAreaElement>(
      '[data-testid="add-memory-content"]',
    )
    expect(textarea?.value).toContain('# New Memory')
  })

  it('Create button is disabled when name is empty', async () => {
    wrapper = mountDialog(true)
    await flushPromises()
    const btn = findInDom<HTMLButtonElement>('[data-testid="add-memory-submit"]')
    expect(btn?.disabled).toBe(true)
  })

  it('Create button is disabled when cwd is empty', async () => {
    wrapper = mountDialog(true, '')
    await flushPromises()
    const btn = findInDom<HTMLButtonElement>('[data-testid="add-memory-submit"]')
    expect(btn?.disabled).toBe(true)
  })
})

describe('AddMemoryDialog — create event', () => {
  let wrapper: VueWrapper | null = null

  beforeEach(() => {
    setActivePinia(createPinia())
    mockCreate.mockReset()
  })

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    document.body.style.overflow = ''
    vi.restoreAllMocks()
  })

  it('Create button calls createLocalMemory with the right args', async () => {
    mockCreate.mockResolvedValue({
      memory: {
        name: 'foo.md',
        title: 'Foo',
        path: `${TEST_CWD}/.pabrik/memories/foo.md`,
        size: 10,
      },
    })

    wrapper = mountDialog(true)
    await flushPromises()

    // Fill the name
    const nameInput = findInDom<HTMLInputElement>(
      '[data-testid="add-memory-name"]',
    )!
    nameInput.value = 'foo.md'
    nameInput.dispatchEvent(new Event('input', { bubbles: true }))
    await flushPromises()

    // Modify the content
    const textarea = findInDom<HTMLTextAreaElement>(
      '[data-testid="add-memory-content"]',
    )!
    textarea.value = '# Foo'
    textarea.dispatchEvent(new Event('input', { bubbles: true }))
    await flushPromises()

    // Click Create
    clickInDom('[data-testid="add-memory-submit"]')
    await flushPromises()

    expect(mockCreate).toHaveBeenCalledTimes(1)
    expect(mockCreate).toHaveBeenCalledWith('foo.md', '# Foo', TEST_CWD)
  })

  it('Create button is a no-op when name is invalid (no .md extension)', async () => {
    wrapper = mountDialog(true)
    await flushPromises()

    const nameInput = findInDom<HTMLInputElement>(
      '[data-testid="add-memory-name"]',
    )!
    nameInput.value = 'no-ext'
    nameInput.dispatchEvent(new Event('input', { bubbles: true }))
    await flushPromises()

    const submitBtn = findInDom<HTMLButtonElement>(
      '[data-testid="add-memory-submit"]',
    )
    expect(submitBtn?.disabled).toBe(true)
    submitBtn?.click()
    expect(mockCreate).not.toHaveBeenCalled()
  })

  it('Create button is a no-op when name has path separator', async () => {
    wrapper = mountDialog(true)
    await flushPromises()

    const nameInput = findInDom<HTMLInputElement>(
      '[data-testid="add-memory-name"]',
    )!
    nameInput.value = '../escape.md'
    nameInput.dispatchEvent(new Event('input', { bubbles: true }))
    await flushPromises()

    const submitBtn = findInDom<HTMLButtonElement>(
      '[data-testid="add-memory-submit"]',
    )
    expect(submitBtn?.disabled).toBe(true)
    submitBtn?.click()
    expect(mockCreate).not.toHaveBeenCalled()
  })

  it('Create button is a no-op when name has .. segment', async () => {
    wrapper = mountDialog(true)
    await flushPromises()

    const nameInput = findInDom<HTMLInputElement>(
      '[data-testid="add-memory-name"]',
    )!
    nameInput.value = 'foo..md'
    nameInput.dispatchEvent(new Event('input', { bubbles: true }))
    await flushPromises()

    const submitBtn = findInDom<HTMLButtonElement>(
      '[data-testid="add-memory-submit"]',
    )
    expect(submitBtn?.disabled).toBe(true)
  })

  it('emits create(name, content, path) on successful create', async () => {
    mockCreate.mockResolvedValue({
      memory: {
        name: 'foo.md',
        title: 'Foo',
        path: `${TEST_CWD}/.pabrik/memories/foo.md`,
        size: 5,
      },
    })

    wrapper = mountDialog(true)
    await flushPromises()

    // Set name and content (content is the default '# New Memory\n\n...'
    // — overwritten below so the assertion has a known value).
    const nameInput = findInDom<HTMLInputElement>(
      '[data-testid="add-memory-name"]',
    )!
    nameInput.value = 'foo.md'
    nameInput.dispatchEvent(new Event('input', { bubbles: true }))
    await flushPromises()

    const textarea = findInDom<HTMLTextAreaElement>(
      '[data-testid="add-memory-content"]',
    )!
    textarea.value = 'My memory body'
    textarea.dispatchEvent(new Event('input', { bubbles: true }))
    await flushPromises()

    clickInDom('[data-testid="add-memory-submit"]')
    await flushPromises()

    // The dialog always emits 3 args: (name, content, path) so the parent can choose to use any
    // subset. The standalone (default) flow doesn't need content (it just called the API itself),
    // but the tuple shape is uniform across modes.
    expect(wrapper.emitted('create')?.[0]).toEqual([
      'foo.md',
      'My memory body',
      `${TEST_CWD}/.pabrik/memories/foo.md`,
    ])
    expect(wrapper.emitted('close')).toBeTruthy()
  })

  it('stays open on API error (no create/close emit)', async () => {
    mockCreate.mockRejectedValue(new Error('boom'))

    wrapper = mountDialog(true)
    await flushPromises()

    const nameInput = findInDom<HTMLInputElement>(
      '[data-testid="add-memory-name"]',
    )!
    nameInput.value = 'foo.md'
    nameInput.dispatchEvent(new Event('input', { bubbles: true }))
    await flushPromises()

    clickInDom('[data-testid="add-memory-submit"]')
    await flushPromises()

    expect(wrapper.emitted('create')).toBeUndefined()
    expect(wrapper.emitted('close')).toBeUndefined()
    // Dialog still in the DOM
    expect(findInDom('[data-testid="add-memory-dialog"]')).not.toBeNull()
  })

  it('resets state on every open (no leakage across opens)', async () => {
    wrapper = mountDialog(true)
    await flushPromises()

    // Type a name
    const nameInput = findInDom<HTMLInputElement>(
      '[data-testid="add-memory-name"]',
    )!
    nameInput.value = 'old.md'
    nameInput.dispatchEvent(new Event('input', { bubbles: true }))
    await flushPromises()

    // Close + reopen
    await wrapper.setProps({ show: false })
    await flushPromises()
    await wrapper.setProps({ show: true })
    await flushPromises()

    const nameAfter = findInDom<HTMLInputElement>(
      '[data-testid="add-memory-name"]',
    )
    expect(nameAfter?.value).toBe('')
  })
})

describe('AddMemoryDialog — folder picker', () => {
  let wrapper: VueWrapper | null = null

  beforeEach(() => {
    setActivePinia(createPinia())
    mockCreate.mockReset()
  })

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    document.body.style.overflow = ''
    vi.restoreAllMocks()
  })

  it('shows the initial cwd from the prop as the picker value', async () => {
    wrapper = mountDialog(true, '/home/user/project')
    await flushPromises()

    const btn = findInDom<HTMLElement>(
      '[data-testid="add-memory-choose-folder"]',
    )
    expect(btn?.textContent).toContain('/home/user/project')
    // Picker should NOT be open yet.
    expect(findInDom('[data-testid="file-picker-dialog"]')).toBeNull()
  })

  it('clicking "Folder" opens the file picker', async () => {
    wrapper = mountDialog(true)
    await flushPromises()

    clickInDom('[data-testid="add-memory-choose-folder"]')
    await flushPromises()

    expect(findInDom('[data-testid="file-picker-dialog"]')).not.toBeNull()
    // The picker shows the configured title.
    expect(findInDom('[data-testid="file-picker-dialog"]')?.textContent).toContain(
      'Select Memory Folder',
    )
  })

  it('selecting a folder in the picker updates the cwd', async () => {
    wrapper = mountDialog(true, '/initial')
    await flushPromises()

    // Open picker and pick a different folder.
    clickInDom('[data-testid="add-memory-choose-folder"]')
    await flushPromises()
    clickInDom('[data-testid="file-picker-select-other"]')
    await flushPromises()

    // Picker should close.
    expect(findInDom('[data-testid="file-picker-dialog"]')).toBeNull()
    // Folder button should now show the new path.
    const btn = findInDom<HTMLElement>(
      '[data-testid="add-memory-choose-folder"]',
    )
    expect(btn?.textContent).toContain('/opt/projects')
  })

  it('createLocalMemory is called with the user-picked folder (not the initial cwd)', async () => {
    mockCreate.mockResolvedValue({
      memory: {
        name: 'foo.md',
        title: 'Foo',
        path: '/opt/projects/.pabrik/memories/foo.md',
        size: 5,
      },
    })

    wrapper = mountDialog(true, '/initial')
    await flushPromises()

    // Pick a different folder.
    clickInDom('[data-testid="add-memory-choose-folder"]')
    await flushPromises()
    clickInDom('[data-testid="file-picker-select-other"]')
    await flushPromises()

    // Fill the name.
    const nameInput = findInDom<HTMLInputElement>(
      '[data-testid="add-memory-name"]',
    )!
    nameInput.value = 'foo.md'
    nameInput.dispatchEvent(new Event('input', { bubbles: true }))
    await flushPromises()

    // Click Create.
    clickInDom('[data-testid="add-memory-submit"]')
    await flushPromises()

    expect(mockCreate).toHaveBeenCalledTimes(1)
    // The cwd passed to createLocalMemory is the user-picked folder,
    // NOT the initial prop value.
    expect(mockCreate).toHaveBeenCalledWith(
      'foo.md',
      expect.any(String),
      '/opt/projects',
    )
  })

  it('picker cancel returns the user to the dialog with cwd unchanged', async () => {
    wrapper = mountDialog(true, '/initial')
    await flushPromises()

    clickInDom('[data-testid="add-memory-choose-folder"]')
    await flushPromises()
    clickInDom('[data-testid="file-picker-cancel"]')
    await flushPromises()

    // Picker closed, cwd unchanged.
    expect(findInDom('[data-testid="file-picker-dialog"]')).toBeNull()
    const btn = findInDom<HTMLElement>(
      '[data-testid="add-memory-choose-folder"]',
    )
    expect(btn?.textContent).toContain('/initial')
    expect(btn?.textContent).not.toContain('/opt/projects')
  })

  it('resets cwd to the prop value on reopen', async () => {
    // Open with cwd A, pick folder B, close, reopen with cwd A.
    // The local cwd should reset to A (NOT retain B).
    wrapper = mountDialog(true, '/initial')
    await flushPromises()

    // Pick a different folder.
    clickInDom('[data-testid="add-memory-choose-folder"]')
    await flushPromises()
    clickInDom('[data-testid="file-picker-select-other"]')
    await flushPromises()
    expect(
      findInDom<HTMLElement>('[data-testid="add-memory-choose-folder"]')
        ?.textContent,
    ).toContain('/opt/projects')

    // Close + reopen.
    await wrapper.setProps({ show: false })
    await flushPromises()
    await wrapper.setProps({ show: true })
    await flushPromises()

    // cwd should be back to the initial value.
    const btn = findInDom<HTMLElement>(
      '[data-testid="add-memory-choose-folder"]',
    )
    expect(btn?.textContent).toContain('/initial')
  })
})
