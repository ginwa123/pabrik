/**
 * Tests for FilePickerDialog — a generic, data-source-agnostic file/folder picker.
 *
 * The component is generic over the item type T. These tests use a MockEntry
 * shape (matching the codebase's FolderEntry from `src/api/index.ts`) but the
 * component works with any tree-shaped dataset — see the last `describe` block
 * for a git-branches example using a totally different item shape.
 *
 * IMPORTANT: The component uses both <Teleport to="body"> AND <Transition>.
 * @vue/test-utils stubs <Transition> by default, which means `wrapper.find()`
 * and `wrapper.text()` do NOT traverse into the dialog content. We must query
 * the document directly via `document.querySelector(selector)` for any
 * data-testid that lives inside the dialog. The helpers below (findInDom,
 * findAllInDom, clickInDom, keydownInDom) make that ergonomic.
 *
 * Pattern notes:
 * - `attachTo: document.body` is required for the Teleport to work in jsdom.
 * - `flushPromises` waits for the expandAncestors() chain to complete after modelValue flips.
 */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { mount, flushPromises, type VueWrapper } from '@vue/test-utils'
import { setActivePinia, createPinia } from 'pinia'
import FilePickerDialog from '../components/FilePickerDialog.vue'
import { makeLocalStorageStub } from './helpers'

// Pinia + localStorage setup is required for FilePickerDialog because the component now imports
// `useRecentFoldersStore` (the recent-folders tab). Pinia requires an active instance; jsdom 29
// dropped localStorage from its default globals. Each test file gets a fresh Pinia + a fresh stub.
beforeEach(() => {
  setActivePinia(createPinia())
  Object.defineProperty(globalThis, 'localStorage', {
    value: makeLocalStorageStub(),
    writable: true,
    configurable: true,
  })
})

// Helpers — query the document directly because the dialog is teleported AND inside a Transition stub
function findInDom<T extends Element = Element>(selector: string): T | null {
  return document.querySelector<T>(selector)
}

function findAllInDom<T extends Element = Element>(selector: string): T[] {
  return Array.from(document.querySelectorAll<T>(selector))
}

function clickInDom(selector: string) {
  const el = findInDom(selector)
  if (!el) throw new Error(`No element found: ${selector}`)
  ;(el as HTMLElement).click()
}

function keydownInDom(key: string) {
  const el = findInDom('[data-testid="file-picker-dialog"]')
  if (!el) throw new Error('Dialog not in DOM')
  el.dispatchEvent(new KeyboardEvent('keydown', { key, bubbles: true }))
}

// Mock tree: / └── home └── user ├── docs (dir) ├── notes (dir) ├── readme (file) └── .hidden
// (file, hidden)
const tree: Record<string, Array<{ name: string; path: string; is_directory: boolean }>> = {
  '/': [{ name: 'home', path: '/home', is_directory: true }],
  '/home': [{ name: 'user', path: '/home/user', is_directory: true }],
  '/home/user': [
    { name: 'docs', path: '/home/user/docs', is_directory: true },
    { name: 'notes', path: '/home/user/notes', is_directory: true },
    { name: 'readme.md', path: '/home/user/readme.md', is_directory: false },
    { name: '.hidden', path: '/home/user/.hidden', is_directory: false },
  ],
  '/home/user/docs': [],
  '/home/user/notes': [
    { name: 'todo.txt', path: '/home/user/notes/todo.txt', is_directory: false },
  ],
}

interface MockEntry {
  name: string
  path: string
  is_directory: boolean
}

function makeLoadItems() {
  return vi.fn(async (path: string) => tree[path] ?? [])
}

function mountDialog(propsOverride: Record<string, unknown> = {}) {
  const loadItems = (propsOverride.loadItems as ReturnType<typeof makeLoadItems> | undefined) ?? makeLoadItems()
  return mount(FilePickerDialog<MockEntry>, {
    attachTo: document.body,
    props: {
      modelValue: false,
      loadItems,
      keyFor: (e: MockEntry) => e.path,
      pathFor: (e: MockEntry) => e.path,
      isExpandable: (e: MockEntry) => e.is_directory,
      ...propsOverride,
    },
  })
}

describe('FilePickerDialog — open/close lifecycle', () => {
  let wrapper: VueWrapper | null = null

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    document.body.style.overflow = ''
    vi.restoreAllMocks()
  })

  it('renders nothing in the DOM when modelValue is false', () => {
    wrapper = mountDialog()
    expect(findInDom('[data-testid="file-picker-dialog"]')).toBeNull()
  })

  it('mounts the dialog when modelValue flips to true', async () => {
    wrapper = mountDialog({ initialPath: '/home/user' })
    await wrapper.setProps({ modelValue: true })
    await flushPromises()
    expect(findInDom('[data-testid="file-picker-dialog"]')).not.toBeNull()
  })

  it('locks body scroll while open and restores on close', async () => {
    wrapper = mountDialog({ initialPath: '/home/user' })
    await wrapper.setProps({ modelValue: true })
    await flushPromises()
    expect(document.body.style.overflow).toBe('hidden')
    await wrapper.setProps({ modelValue: false })
    expect(document.body.style.overflow).toBe('')
  })
})

describe('FilePickerDialog — title and initial state', () => {
  let wrapper: VueWrapper | null = null

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    document.body.style.overflow = ''
    vi.restoreAllMocks()
  })

  it('shows default title "Select Folder" in folder mode', async () => {
    wrapper = mountDialog({ initialPath: '/home/user' })
    await wrapper.setProps({ modelValue: true })
    await flushPromises()
    const dialog = findInDom('[data-testid="file-picker-dialog"]')
    expect(dialog?.textContent).toContain('Select Folder')
  })

  it('shows default title "Select File" in file mode', async () => {
    wrapper = mountDialog({ mode: 'file', initialPath: '/home/user' })
    await wrapper.setProps({ modelValue: true })
    await flushPromises()
    expect(findInDom('[data-testid="file-picker-dialog"]')?.textContent).toContain('Select File')
  })

  it('shows default title "Select Item" in both mode', async () => {
    wrapper = mountDialog({ mode: 'both', initialPath: '/home/user' })
    await wrapper.setProps({ modelValue: true })
    await flushPromises()
    expect(findInDom('[data-testid="file-picker-dialog"]')?.textContent).toContain('Select Item')
  })

  it('overrides default title via the title prop', async () => {
    wrapper = mountDialog({ initialPath: '/home/user', title: 'Pick a parent dir' })
    await wrapper.setProps({ modelValue: true })
    await flushPromises()
    const text = findInDom('[data-testid="file-picker-dialog"]')?.textContent ?? ''
    expect(text).toContain('Pick a parent dir')
    expect(text).not.toContain('Select Folder')
  })

  it('calls loadItems with the initialPath on open, expanding ancestors', async () => {
    const loadItems = makeLoadItems()
    wrapper = mountDialog({ initialPath: '/home/user/docs', loadItems })
    await wrapper.setProps({ modelValue: true })
    await flushPromises()
    const calledPaths = loadItems.mock.calls.map(([p]) => p)
    // Should load /, /home, /home/user, /home/user/docs in that order
    expect(calledPaths).toEqual(['/', '/home', '/home/user', '/home/user/docs'])
  })
})

describe('FilePickerDialog — content rendering', () => {
  let wrapper: VueWrapper | null = null

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    document.body.style.overflow = ''
    vi.restoreAllMocks()
  })

  it('renders items in the content pane after load', async () => {
    wrapper = mountDialog({ initialPath: '/home/user' })
    await wrapper.setProps({ modelValue: true })
    await flushPromises()
    expect(findInDom('[data-testid="file-picker-item-/home/user/docs"]')).not.toBeNull()
    expect(findInDom('[data-testid="file-picker-item-/home/user/notes"]')).not.toBeNull()
    expect(findInDom('[data-testid="file-picker-item-/home/user/readme.md"]')).not.toBeNull()
  })

  it('hides hidden files by default', async () => {
    wrapper = mountDialog({ initialPath: '/home/user' })
    await wrapper.setProps({ modelValue: true })
    await flushPromises()
    expect(findInDom('[data-testid="file-picker-item-/home/user/.hidden"]')).toBeNull()
  })

  it('shows hidden files when showHidden prop is true', async () => {
    wrapper = mountDialog({ initialPath: '/home/user', showHidden: true })
    await wrapper.setProps({ modelValue: true })
    await flushPromises()
    expect(findInDom('[data-testid="file-picker-item-/home/user/.hidden"]')).not.toBeNull()
  })

  it('toggles hidden files via the toolbar button', async () => {
    wrapper = mountDialog({ initialPath: '/home/user' })
    await wrapper.setProps({ modelValue: true })
    await flushPromises()
    expect(findInDom('[data-testid="file-picker-item-/home/user/.hidden"]')).toBeNull()
    clickInDom('[data-testid="file-picker-hidden-toggle"]')
    await flushPromises()
    expect(findInDom('[data-testid="file-picker-item-/home/user/.hidden"]')).not.toBeNull()
    clickInDom('[data-testid="file-picker-hidden-toggle"]')
    await flushPromises()
    expect(findInDom('[data-testid="file-picker-item-/home/user/.hidden"]')).toBeNull()
  })

  it('shows the tree pane with expanded ancestors', async () => {
    wrapper = mountDialog({ initialPath: '/home/user' })
    await wrapper.setProps({ modelValue: true })
    await flushPromises()
    expect(findInDom('[data-testid="file-picker-tree"]')).not.toBeNull()
    expect(findInDom('[data-testid="file-picker-tree-/home"]')).not.toBeNull()
    expect(findInDom('[data-testid="file-picker-tree-/home/user"]')).not.toBeNull()
  })

  it('shows the breadcrumb for the current path', async () => {
    wrapper = mountDialog({ initialPath: '/home/user/docs' })
    await wrapper.setProps({ modelValue: true })
    await flushPromises()
    expect(findInDom('[data-testid="file-picker-crumb-0"]')?.textContent).toBe('home')
    expect(findInDom('[data-testid="file-picker-crumb-1"]')?.textContent).toBe('user')
    expect(findInDom('[data-testid="file-picker-crumb-2"]')?.textContent).toBe('docs')
  })

  it('hides the Up button at the filesystem root', async () => {
    wrapper = mountDialog({ initialPath: '/' })
    await wrapper.setProps({ modelValue: true })
    await flushPromises()
    expect(findInDom('[data-testid="file-picker-up"]')).toBeNull()
  })
})

describe('FilePickerDialog — selection (folder mode)', () => {
  let wrapper: VueWrapper | null = null

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    document.body.style.overflow = ''
    vi.restoreAllMocks()
  })

  // RENAMED + initialPath changed from '/home/user' to '/' to assert the "disabled at root"
  // invariant. Previously: "Select button is disabled when nothing is selected". Plan:
  // docs/superpowers/plans/2026-08-13-folder-picker-select-button-current-folder.md
  it('Select button is disabled at root when nothing is selected', async () => {
    wrapper = mountDialog({ initialPath: '/', mode: 'folder' })
    await wrapper.setProps({ modelValue: true })
    await flushPromises()
    const btn = findInDom('[data-testid="file-picker-select"]') as HTMLButtonElement | null
    expect(btn?.disabled).toBe(true)
  })

  it('clicking a folder in the content pane selects it (folder mode)', async () => {
    wrapper = mountDialog({ initialPath: '/home/user', mode: 'folder' })
    await wrapper.setProps({ modelValue: true })
    await flushPromises()
    clickInDom('[data-testid="file-picker-item-/home/user/docs"]')
    await flushPromises()
    expect(findInDom('[data-testid="file-picker-selected-path"]')?.textContent).toBe('/home/user/docs')
    const btn = findInDom('[data-testid="file-picker-select"]') as HTMLButtonElement | null
    expect(btn?.disabled).toBe(false)
  })

  it('clicking Select emits select and closes (closeOnSelect: true)', async () => {
    wrapper = mountDialog({ initialPath: '/home/user', mode: 'folder', closeOnSelect: true })
    await wrapper.setProps({ modelValue: true })
    await flushPromises()
    clickInDom('[data-testid="file-picker-item-/home/user/docs"]')
    await flushPromises()
    clickInDom('[data-testid="file-picker-select"]')
    await flushPromises()
    expect(wrapper.emitted('select')?.[0]).toEqual(['/home/user/docs'])
    expect(wrapper.emitted('update:modelValue')?.[0]).toEqual([false])
  })

  it('emits select but does NOT close when closeOnSelect is false', async () => {
    wrapper = mountDialog({
      initialPath: '/home/user',
      mode: 'folder',
      closeOnSelect: false,
    })
    await wrapper.setProps({ modelValue: true })
    await flushPromises()
    clickInDom('[data-testid="file-picker-item-/home/user/docs"]')
    await flushPromises()
    clickInDom('[data-testid="file-picker-select"]')
    expect(wrapper.emitted('select')?.[0]).toEqual(['/home/user/docs'])
    expect(wrapper.emitted('update:modelValue')).toBeUndefined()
  })

  // UPDATED (plan: 2026-08-13-folder-picker-select-button-current-folder.md). The footer now
  // reflects effectiveSelection (currentPath fallback), so at /home/user the footer shows the
  // current folder even before any click.

  // The new contract — clicking a file in folder mode does NOT select it — is unchanged:
  // handleItemClick leaves selectedPath empty for non-expandable items in folder mode, so
  // effectiveSelection stays on currentPath.

  // The test now asserts the pre-click fallback (current folder shown) then the post-click
  // invariant (footer still shows current folder, since the file click was a no-op).
  it('clicking a file in folder mode does NOT select it (mode restricts)', async () => {
    wrapper = mountDialog({ initialPath: '/home/user', mode: 'folder' })
    await wrapper.setProps({ modelValue: true })
    await flushPromises()
    // Pre-click: the footer shows the current folder via the fallback.
    expect(findInDom('[data-testid="file-picker-selected-path"]')?.textContent).toBe('/home/user')
    clickInDom('[data-testid="file-picker-item-/home/user/readme.md"]')
    await flushPromises()
    // Post-click: file click is a no-op in folder mode, so the footer
    // still reflects currentPath (no explicit click selected the file).
    expect(findInDom('[data-testid="file-picker-selected-path"]')?.textContent).toBe('/home/user')
  })
})

describe('FilePickerDialog — selection (file mode)', () => {
  let wrapper: VueWrapper | null = null

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    document.body.style.overflow = ''
    vi.restoreAllMocks()
  })

  it('clicking a file in file mode selects it', async () => {
    wrapper = mountDialog({ initialPath: '/home/user', mode: 'file' })
    await wrapper.setProps({ modelValue: true })
    await flushPromises()
    clickInDom('[data-testid="file-picker-item-/home/user/readme.md"]')
    await flushPromises()
    expect(findInDom('[data-testid="file-picker-selected-path"]')?.textContent).toBe(
      '/home/user/readme.md',
    )
  })

  it('clicking a folder in file mode NAVIGATES INTO it (does not select)', async () => {
    const loadItems = makeLoadItems()
    wrapper = mountDialog({ initialPath: '/home/user', mode: 'file', loadItems })
    await wrapper.setProps({ modelValue: true })
    await flushPromises()
    clickInDom('[data-testid="file-picker-item-/home/user/notes"]')
    await flushPromises()
    expect(findInDom('[data-testid="file-picker-item-/home/user/notes/todo.txt"]')).not.toBeNull()
    expect(findInDom('[data-testid="file-picker-selected-path"]')?.textContent).toBe('(none)')
  })
})

describe('FilePickerDialog — selection (both mode)', () => {
  let wrapper: VueWrapper | null = null

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    document.body.style.overflow = ''
    vi.restoreAllMocks()
  })

  it('shows filter chips in both mode', async () => {
    wrapper = mountDialog({ initialPath: '/home/user', mode: 'both' })
    await wrapper.setProps({ modelValue: true })
    await flushPromises()
    expect(findInDom('[data-testid="file-picker-filter-all"]')).not.toBeNull()
    expect(findInDom('[data-testid="file-picker-filter-folders"]')).not.toBeNull()
    expect(findInDom('[data-testid="file-picker-filter-files"]')).not.toBeNull()
  })

  it('does NOT show filter chips in folder mode', async () => {
    wrapper = mountDialog({ initialPath: '/home/user', mode: 'folder' })
    await wrapper.setProps({ modelValue: true })
    await flushPromises()
    expect(findInDom('[data-testid="file-picker-filter-all"]')).toBeNull()
  })

  it('clicking Folders chip hides files', async () => {
    wrapper = mountDialog({ initialPath: '/home/user', mode: 'both' })
    await wrapper.setProps({ modelValue: true })
    await flushPromises()
    clickInDom('[data-testid="file-picker-filter-folders"]')
    await flushPromises()
    expect(findInDom('[data-testid="file-picker-item-/home/user/docs"]')).not.toBeNull()
    expect(findInDom('[data-testid="file-picker-item-/home/user/readme.md"]')).toBeNull()
  })

  it('clicking a file in both mode selects it', async () => {
    wrapper = mountDialog({ initialPath: '/home/user', mode: 'both' })
    await wrapper.setProps({ modelValue: true })
    await flushPromises()
    clickInDom('[data-testid="file-picker-item-/home/user/readme.md"]')
    await flushPromises()
    expect(findInDom('[data-testid="file-picker-selected-path"]')?.textContent).toBe(
      '/home/user/readme.md',
    )
  })
})

describe('FilePickerDialog — search', () => {
  let wrapper: VueWrapper | null = null

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    document.body.style.overflow = ''
    vi.restoreAllMocks()
  })

  it('filters content pane items by search query', async () => {
    wrapper = mountDialog({ initialPath: '/home/user' })
    await wrapper.setProps({ modelValue: true })
    await flushPromises()
    const search = findInDom('[data-testid="file-picker-search"]') as HTMLInputElement
    search.value = 'docs'
    search.dispatchEvent(new Event('input', { bubbles: true }))
    await flushPromises()
    expect(findInDom('[data-testid="file-picker-item-/home/user/docs"]')).not.toBeNull()
    expect(findInDom('[data-testid="file-picker-item-/home/user/notes"]')).toBeNull()
    expect(findInDom('[data-testid="file-picker-item-/home/user/readme.md"]')).toBeNull()
  })

  it('shows empty state when search yields no matches', async () => {
    wrapper = mountDialog({ initialPath: '/home/user' })
    await wrapper.setProps({ modelValue: true })
    await flushPromises()
    const search = findInDom('[data-testid="file-picker-search"]') as HTMLInputElement
    search.value = 'zzzzzz'
    search.dispatchEvent(new Event('input', { bubbles: true }))
    await flushPromises()
    expect(findInDom('[data-testid="file-picker-dialog"]')?.textContent).toContain('No matches')
  })
})

describe('FilePickerDialog — keyboard navigation', () => {
  let wrapper: VueWrapper | null = null

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    document.body.style.overflow = ''
    vi.restoreAllMocks()
  })

  it('Escape closes the dialog and emits cancel', async () => {
    wrapper = mountDialog({ initialPath: '/home/user' })
    await wrapper.setProps({ modelValue: true })
    await flushPromises()
    keydownInDom('Escape')
    await flushPromises()
    expect(wrapper.emitted('cancel')).toBeTruthy()
    expect(wrapper.emitted('update:modelValue')?.[0]).toEqual([false])
  })

  it('ArrowDown moves the highlight to the next item', async () => {
    wrapper = mountDialog({ initialPath: '/home/user' })
    await wrapper.setProps({ modelValue: true })
    await flushPromises()
    const items = findAllInDom('[data-testid^="file-picker-item-/home/user"]')
    expect(items.length).toBeGreaterThan(1)
    keydownInDom('ArrowDown')
    await flushPromises()
    const first = items[0] as HTMLElement
    expect(first.dataset.index).toBe('0')
    expect(first.getAttribute('aria-selected')).toBe('false')
    keydownInDom('ArrowDown')
    await flushPromises()
    const second = items[1] as HTMLElement
    expect(second.dataset.index).toBe('1')
  })

  it('Enter on a highlighted folder (folder mode, closeOnSelect: true) selects and closes', async () => {
    wrapper = mountDialog({ initialPath: '/home/user', mode: 'folder', closeOnSelect: true })
    await wrapper.setProps({ modelValue: true })
    await flushPromises()
    keydownInDom('ArrowDown')
    await flushPromises()
    keydownInDom('Enter')
    await flushPromises()
    expect(wrapper.emitted('select')).toBeTruthy()
    expect(wrapper.emitted('update:modelValue')?.[0]).toEqual([false])
  })

  it('Backspace navigates to the parent path', async () => {
    const loadItems = makeLoadItems()
    wrapper = mountDialog({ initialPath: '/home/user/docs', loadItems })
    await wrapper.setProps({ modelValue: true })
    await flushPromises()
    keydownInDom('Backspace')
    await flushPromises()
    // The crumb-1 ("user") should now be the last (current) segment
    expect(findInDom('[data-testid="file-picker-crumb-1"]')?.textContent).toBe('user')
  })
})

describe('FilePickerDialog — navigation', () => {
  let wrapper: VueWrapper | null = null

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    document.body.style.overflow = ''
    vi.restoreAllMocks()
  })

  it('clicking a breadcrumb segment navigates to that path', async () => {
    const loadItems = makeLoadItems()
    wrapper = mountDialog({ initialPath: '/home/user/docs', loadItems })
    await wrapper.setProps({ modelValue: true })
    await flushPromises()
    clickInDom('[data-testid="file-picker-crumb-0"]')
    await flushPromises()
    // Should now be at /home — the breadcrumb shows just "home"
    expect(findInDom('[data-testid="file-picker-crumb-0"]')?.textContent).toBe('home')
  })

  it('clicking the Up button navigates to the parent path', async () => {
    const loadItems = makeLoadItems()
    wrapper = mountDialog({ initialPath: '/home/user/notes', loadItems })
    await wrapper.setProps({ modelValue: true })
    await flushPromises()
    clickInDom('[data-testid="file-picker-up"]')
    await flushPromises()
    expect(findInDom('[data-testid="file-picker-item-/home/user/docs"]')).not.toBeNull()
  })

  it('clicking the root "/" button navigates to the filesystem root', async () => {
    const loadItems = makeLoadItems()
    wrapper = mountDialog({ initialPath: '/home/user', loadItems })
    await wrapper.setProps({ modelValue: true })
    await flushPromises()
    clickInDom('[data-testid="file-picker-root"]')
    await flushPromises()
    expect(findInDom('[data-testid="file-picker-tree-/home"]')).not.toBeNull()
  })

  it('clicking the close button emits cancel', async () => {
    wrapper = mountDialog({ initialPath: '/home/user' })
    await wrapper.setProps({ modelValue: true })
    await flushPromises()
    clickInDom('[data-testid="file-picker-close"]')
    expect(wrapper.emitted('cancel')).toBeTruthy()
  })

  it('clicking the Cancel button emits cancel', async () => {
    wrapper = mountDialog({ initialPath: '/home/user' })
    await wrapper.setProps({ modelValue: true })
    await flushPromises()
    clickInDom('[data-testid="file-picker-cancel"]')
    expect(wrapper.emitted('cancel')).toBeTruthy()
  })

  it('clicking the backdrop does NOT close the dialog (no cancel emitted)', async () => {
    wrapper = mountDialog({ initialPath: '/home/user' })
    await wrapper.setProps({ modelValue: true })
    await flushPromises()
    clickInDom('[data-testid="file-picker-backdrop"]')
    await flushPromises()
    expect(wrapper.emitted('cancel')).toBeFalsy()
    expect(wrapper.emitted('update:modelValue')).toBeFalsy()
    // Dialog is still open.
    expect(findInDom('[data-testid="file-picker-dialog"]')).not.toBeNull()
  })
})

describe('FilePickerDialog — error and empty states', () => {
  let wrapper: VueWrapper | null = null

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    document.body.style.overflow = ''
    vi.restoreAllMocks()
  })

  it('shows error UI when loadItems throws', async () => {
    const loadItems = vi.fn(async () => {
      throw new Error('boom')
    })
    wrapper = mountDialog({ initialPath: '/home/user', loadItems })
    await wrapper.setProps({ modelValue: true })
    await flushPromises()
    expect(findInDom('[data-testid="file-picker-dialog"]')?.textContent).toContain('boom')
    expect(findInDom('[data-testid="file-picker-dialog"]')?.textContent).toContain('Retry')
  })

  it('shows empty state when folder has no children', async () => {
    wrapper = mountDialog({ initialPath: '/home/user/docs' })
    await wrapper.setProps({ modelValue: true })
    await flushPromises()
    expect(findInDom('[data-testid="file-picker-dialog"]')?.textContent).toContain('Empty folder')
  })

  it('calls loadItems again when Retry is clicked after an error', async () => {
    const loadItems = vi.fn(async () => {
      throw new Error('boom')
    })
    wrapper = mountDialog({ initialPath: '/home/user', loadItems })
    await wrapper.setProps({ modelValue: true })
    await flushPromises()
    expect(loadItems.mock.calls.length).toBe(3)
    const retryBtns = findAllInDom<HTMLButtonElement>('[data-testid="file-picker-retry"]')
    expect(retryBtns.length).toBeGreaterThan(0)
    retryBtns[0]?.click()
    await flushPromises()
    expect(loadItems.mock.calls.length).toBeGreaterThan(3)
  })
})

describe('FilePickerDialog — agnostic data source (non-folder example)', () => {
  let wrapper: VueWrapper | null = null

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    document.body.style.overflow = ''
    vi.restoreAllMocks()
  })

  // Proves the component works with a totally different shape (git branches)
  interface Branch {
    ref: string
    is_head: boolean
  }

  it('works with any tree-shaped dataset (git branches example)', async () => {
    const branches: Record<string, Branch[]> = {
      '/': [
        { ref: 'main', is_head: false },
        { ref: 'feature/auth', is_head: false },
      ],
      '/main': [{ ref: 'hotfix', is_head: false }],
      '/feature/auth': [{ ref: 'wip', is_head: false }],
    }

    const loadItems = vi.fn(async (path: string) => branches[path] ?? [])

    wrapper = mount(FilePickerDialog<Branch>, {
      attachTo: document.body,
      props: {
        modelValue: false,
        loadItems,
        keyFor: (b: Branch) => b.ref,
        pathFor: (b: Branch) => `/${b.ref}`,
        isExpandable: (_b: Branch) => true, // all branches have children in this mock
        labelFor: (b: Branch) => b.ref,
        iconFor: () => 'leaf',
        title: 'Pick a branch',
        initialPath: '/main',
      },
    })

    await wrapper.setProps({ modelValue: true })
    await flushPromises()

    expect(findInDom('[data-testid="file-picker-dialog"]')?.textContent).toContain('Pick a branch')
    expect(findInDom('[data-testid="file-picker-item-hotfix"]')).not.toBeNull()
  })
})

// ─── Address-bar (path input) ────────────────────────────────────────────────────────────── The
// "✏️ Go" button next to the breadcrumb swaps the clickable crumb row for a single text input
// pre-filled with the current path. Enter navigates, Escape reverts, the input commits on blur.

// Whatever the user types goes through normalizeAddressInput() so a bare "docs" jumps into
// currentPath/docs instead of being rejected as relative.
describe('FilePickerDialog — address bar (type a path)', () => {
  let wrapper: VueWrapper | null = null

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    document.body.style.overflow = ''
    vi.restoreAllMocks()
  })

  it('does not render the path input in default (crumb) mode', async () => {
    wrapper = mountDialog({ initialPath: '/home/user' })
    await wrapper.setProps({ modelValue: true })
    await flushPromises()
    expect(findInDom('[data-testid="file-picker-path-edit"]')).not.toBeNull()
    expect(findInDom('[data-testid="file-picker-path-input"]')).toBeNull()
  })

  it('clicking the ✏️ Go button enters edit mode and shows the path input', async () => {
    wrapper = mountDialog({ initialPath: '/home/user' })
    await wrapper.setProps({ modelValue: true })
    await flushPromises()
    clickInDom('[data-testid="file-picker-path-edit"]')
    await flushPromises()
    expect(findInDom('[data-testid="file-picker-path-input"]')).not.toBeNull()
    // The input should be pre-filled with the current path so the user can
    // either start typing fresh text or edit the suffix.
    expect(
      (findInDom('[data-testid="file-picker-path-input"]') as HTMLInputElement | null)?.value,
    ).toBe('/home/user')
    // The breadcrumb buttons disappear while editing.
    expect(findInDom('[data-testid="file-picker-crumb-0"]')).toBeNull()
  })

  it('typing an absolute path and pressing Enter navigates to it', async () => {
    const loadItems = makeLoadItems()
    wrapper = mountDialog({ initialPath: '/home/user', loadItems })
    await wrapper.setProps({ modelValue: true })
    await flushPromises()
    clickInDom('[data-testid="file-picker-path-edit"]')
    await flushPromises()
    const input = findInDom('[data-testid="file-picker-path-input"]') as HTMLInputElement
    input.value = '/home/user/notes'
    input.dispatchEvent(new Event('input', { bubbles: true }))
    // Vue's v-model writes via the 'input' event above; flush so the next
    // keydown sees the new value, then submit.
    await flushPromises()
    input.dispatchEvent(
      new KeyboardEvent('keydown', { key: 'Enter', bubbles: true }),
    )
    await flushPromises()
    // The dialog should now show the children of the new path. We pick a
    // child that's only present in /home/user/notes (todo.txt) and assert
    // it's in the DOM.
    expect(findInDom('[data-testid="file-picker-item-/home/user/notes/todo.txt"]')).not.toBeNull()
    // After commit the breadcrumb is back, the input is gone.
    expect(findInDom('[data-testid="file-picker-path-input"]')).toBeNull()
    expect(findInDom('[data-testid="file-picker-crumb-0"]')?.textContent).toBe('home')
  })

  it('a bare relative word resolves against currentPath (e.g. "notes" → /home/user/notes)', async () => {
    const loadItems = makeLoadItems()
    wrapper = mountDialog({ initialPath: '/home/user', loadItems })
    await wrapper.setProps({ modelValue: true })
    await flushPromises()
    clickInDom('[data-testid="file-picker-path-edit"]')
    await flushPromises()
    const input = findInDom('[data-testid="file-picker-path-input"]') as HTMLInputElement
    input.value = 'notes'
    input.dispatchEvent(new Event('input', { bubbles: true }))
    await flushPromises()
    input.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true }))
    await flushPromises()
    expect(findInDom('[data-testid="file-picker-item-/home/user/notes/todo.txt"]')).not.toBeNull()
  })

  it('a bare ".." segment pops the current path one level up', async () => {
    const loadItems = makeLoadItems()
    wrapper = mountDialog({ initialPath: '/home/user/docs', loadItems })
    await wrapper.setProps({ modelValue: true })
    await flushPromises()
    clickInDom('[data-testid="file-picker-path-edit"]')
    await flushPromises()
    const input = findInDom('[data-testid="file-picker-path-input"]') as HTMLInputElement
    input.value = '..'
    input.dispatchEvent(new Event('input', { bubbles: true }))
    await flushPromises()
    input.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true }))
    await flushPromises()
    // We should now be at /home/user — its children are docs, notes, readme.md, .hidden.
    expect(findInDom('[data-testid="file-picker-item-/home/user/notes"]')).not.toBeNull()
  })

  it('lexical POSIX: from /home/user/docs, "../user" goes up then INTO user → /home/user/user', async () => {
    // Documents the deliberate POSIX semantics of the joinRelative helper.
    // `/home/user/user`, the same way `cd /home/user/docs && cd ../user`
    // resolves in POSIX shells.
    const loadItems = makeLoadItems()
    wrapper = mountDialog({ initialPath: '/home/user/docs', loadItems })
    await wrapper.setProps({ modelValue: true })
    await flushPromises()
    clickInDom('[data-testid="file-picker-path-edit"]')
    await flushPromises()
    const input = findInDom('[data-testid="file-picker-path-input"]') as HTMLInputElement
    input.value = '../user'
    input.dispatchEvent(new Event('input', { bubbles: true }))
    await flushPromises()
    input.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true }))
    await flushPromises()
    // /home/user/user doesn't exist in our mock tree, so loadItems returns []
    // and the content pane renders the "Empty folder" empty state.
    expect(findInDom('[data-testid="file-picker-content"]')?.textContent).toContain('Empty folder')
  })

  it('typing "~" navigates to the filesystem root', async () => {
    const loadItems = makeLoadItems()
    wrapper = mountDialog({ initialPath: '/home/user', loadItems })
    await wrapper.setProps({ modelValue: true })
    await flushPromises()
    clickInDom('[data-testid="file-picker-path-edit"]')
    await flushPromises()
    const input = findInDom('[data-testid="file-picker-path-input"]') as HTMLInputElement
    input.value = '~'
    input.dispatchEvent(new Event('input', { bubbles: true }))
    await flushPromises()
    input.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true }))
    await flushPromises()
    // At the root we should see the home folder in the tree.
    expect(findInDom('[data-testid="file-picker-tree-/home"]')).not.toBeNull()
  })

  it('pressing Escape reverts the path input and stays on the current path', async () => {
    const loadItems = makeLoadItems()
    wrapper = mountDialog({ initialPath: '/home/user', loadItems })
    await wrapper.setProps({ modelValue: true })
    await flushPromises()
    clickInDom('[data-testid="file-picker-path-edit"]')
    await flushPromises()
    const input = findInDom('[data-testid="file-picker-path-input"]') as HTMLInputElement
    input.value = '/home/user/notes'
    input.dispatchEvent(new Event('input', { bubbles: true }))
    await flushPromises()
    input.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape', bubbles: true }))
    await flushPromises()
    // The dialog is still open, still at /home/user, breadcrumb shows home/user.
    expect(findInDom('[data-testid="file-picker-path-input"]')).toBeNull()
    expect(findInDom('[data-testid="file-picker-crumb-0"]')?.textContent).toBe('home')
    expect(findInDom('[data-testid="file-picker-crumb-1"]')?.textContent).toBe('user')
    // The /notes child from the typed value must NOT have loaded.
    expect(findInDom('[data-testid="file-picker-item-/home/user/notes/todo.txt"]')).toBeNull()
  })

  it('typing a non-existent path surfaces the existing error UI', async () => {
    const loadItems = vi.fn(async (path: string) => {
      if (path === '/does/not/exist') throw new Error('boom: not a directory')
      return tree[path] ?? []
    })
    wrapper = mountDialog({ initialPath: '/home/user', loadItems })
    await wrapper.setProps({ modelValue: true })
    await flushPromises()
    clickInDom('[data-testid="file-picker-path-edit"]')
    await flushPromises()
    const input = findInDom('[data-testid="file-picker-path-input"]') as HTMLInputElement
    input.value = '/does/not/exist'
    input.dispatchEvent(new Event('input', { bubbles: true }))
    await flushPromises()
    input.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true }))
    // Suppress the expected console.error from the loadPath throw.
    const errSpy = vi.spyOn(console, 'error').mockImplementation(() => {})
    await flushPromises()
    errSpy.mockRestore()
    // The dialog is still open (the error UI is in-pane, not a modal crash).
    expect(findInDom('[data-testid="file-picker-dialog"]')).not.toBeNull()
    // The error block contains "boom: not a directory" — the same string
    // loadPath formatted into loadError.
    const errEl = findInDom('[data-testid="file-picker-tree"] [class*="text-center"]')
      || findInDom('[data-testid="file-picker-tree"]')
    expect(errEl?.textContent).toContain('boom: not a directory')
  })

  it('re-opening the dialog after editing exits edit mode', async () => {
    wrapper = mountDialog({ initialPath: '/home/user' })
    await wrapper.setProps({ modelValue: true })
    await flushPromises()
    clickInDom('[data-testid="file-picker-path-edit"]')
    await flushPromises()
    expect(findInDom('[data-testid="file-picker-path-input"]')).not.toBeNull()
    // Close + reopen: the editor state must reset.
    await wrapper.setProps({ modelValue: false })
    expect(findInDom('[data-testid="file-picker-path-input"]')).toBeNull()
    await wrapper.setProps({ modelValue: true })
    await flushPromises()
    expect(findInDom('[data-testid="file-picker-path-input"]')).toBeNull()
    expect(findInDom('[data-testid="file-picker-crumb-0"]')?.textContent).toBe('home')
    expect(findInDom('[data-testid="file-picker-crumb-1"]')?.textContent).toBe('user')
  })

  it('committing with whitespace-only input is a no-op (no navigation)', async () => {
    const loadItems = makeLoadItems()
    wrapper = mountDialog({ initialPath: '/home/user', loadItems })
    await wrapper.setProps({ modelValue: true })
    await flushPromises()
    clickInDom('[data-testid="file-picker-path-edit"]')
    await flushPromises()
    const input = findInDom('[data-testid="file-picker-path-input"]') as HTMLInputElement
    input.value = '   '
    input.dispatchEvent(new Event('input', { bubbles: true }))
    await flushPromises()
    input.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true }))
    await flushPromises()
    // Still at /home/user — the user/notes child is NOT in the DOM.
    expect(findInDom('[data-testid="file-picker-item-/home/user/notes/todo.txt"]')).toBeNull()
    expect(findInDom('[data-testid="file-picker-crumb-1"]')?.textContent).toBe('user')
  })
})

// ─── Select button — current folder fallback (folder mode) ─────────────────
//
// Plan: docs/superpowers/plans/2026-08-13-folder-picker-select-button-current-folder.md
//
// The Select button is enabled whenever the user has a meaningful folder
// in scope — either because they clicked a folder in the content pane
// (explicit selectedPath) OR because they navigated to a folder via the
// tree / breadcrumb / Up / Backspace / address bar (currentPath). The
// root path '/' is treated as "no selection" and does NOT enable the
// button. The footer "Selected:" shows what will be emitted, and a tiny
// "← current folder" hint appears when the fallback path is in use.
describe('FilePickerDialog — Select when current folder is open (folder mode)', () => {
  let wrapper: VueWrapper | null = null

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    document.body.style.overflow = ''
    vi.restoreAllMocks()
  })

  it('Select button is DISABLED at root when nothing is clicked', async () => {
    wrapper = mountDialog({ initialPath: '/', mode: 'folder' })
    await wrapper.setProps({ modelValue: true })
    await flushPromises()
    const btn = findInDom('[data-testid="file-picker-select"]') as HTMLButtonElement | null
    expect(btn?.disabled).toBe(true)
  })

  it('Select button is ENABLED when the user navigates into a non-root folder (no click)', async () => {
    // The fix: navigateTo() resets selectedPath but the new effectiveSelection
    // falls back to currentPath. The button is enabled because /home/user is
    // a real folder, even though the user never clicked a row in the content pane.
    wrapper = mountDialog({ initialPath: '/home/user', mode: 'folder' })
    await wrapper.setProps({ modelValue: true })
    await flushPromises()
    const btn = findInDom('[data-testid="file-picker-select"]') as HTMLButtonElement | null
    expect(btn?.disabled).toBe(false)
    // The footer reflects the fallback (currentPath).
    expect(findInDom('[data-testid="file-picker-selected-path"]')?.textContent).toBe('/home/user')
    // The hint is visible because the fallback is in use (no explicit click).
    expect(findInDom('[data-testid="file-picker-selected-hint"]')).not.toBeNull()
  })

  it('Select button STAYS enabled after navigating Up via the Up button', async () => {
    // Mirrors the bug report: user opens picker at /home/user, clicks Up,
    // lands at /home. The button should still be enabled — /home is a real
    // folder they just navigated to.
    const loadItems = makeLoadItems()
    wrapper = mountDialog({ initialPath: '/home/user', mode: 'folder', loadItems })
    await wrapper.setProps({ modelValue: true })
    await flushPromises()
    clickInDom('[data-testid="file-picker-up"]')
    await flushPromises()
    const btn = findInDom('[data-testid="file-picker-select"]') as HTMLButtonElement | null
    expect(btn?.disabled).toBe(false)
    expect(findInDom('[data-testid="file-picker-selected-path"]')?.textContent).toBe('/home')
  })

  it('Select button is DISABLED after navigating to root via Up', async () => {
    // D3: '/' is treated as "no selection". The fallback is gated on
    // currentPath !== '/'.
    const loadItems = makeLoadItems()
    wrapper = mountDialog({ initialPath: '/home', mode: 'folder', loadItems })
    await wrapper.setProps({ modelValue: true })
    await flushPromises()
    clickInDom('[data-testid="file-picker-up"]')
    await flushPromises()
    const btn = findInDom('[data-testid="file-picker-select"]') as HTMLButtonElement | null
    expect(btn?.disabled).toBe(true)
    expect(findInDom('[data-testid="file-picker-selected-path"]')?.textContent).toBe('(none)')
  })

  it('clicking Select with the fallback emits currentPath (no explicit click)', async () => {
    wrapper = mountDialog({ initialPath: '/home/user', mode: 'folder', closeOnSelect: true })
    await wrapper.setProps({ modelValue: true })
    await flushPromises()
    clickInDom('[data-testid="file-picker-select"]')
    await flushPromises()
    expect(wrapper.emitted('select')?.[0]).toEqual(['/home/user'])
    expect(wrapper.emitted('update:modelValue')?.[0]).toEqual([false])
  })

  it('explicit click on a folder OVERRIDES the fallback in the footer', async () => {
    // D2: selectedPath (explicit) wins over currentPath (fallback). User
    // navigates to /home/user, then clicks /home/user/docs in the content
    // pane. The footer should show /home/user/docs, NOT /home/user.
    wrapper = mountDialog({ initialPath: '/home/user', mode: 'folder' })
    await wrapper.setProps({ modelValue: true })
    await flushPromises()
    clickInDom('[data-testid="file-picker-item-/home/user/docs"]')
    await flushPromises()
    expect(findInDom('[data-testid="file-picker-selected-path"]')?.textContent).toBe('/home/user/docs')
    // The hint is HIDDEN because the explicit click is in play.
    expect(findInDom('[data-testid="file-picker-selected-hint"]')).toBeNull()
  })

  it('file-mode: Select is still disabled at a non-root folder (no fallback in file mode)', async () => {
    // D1: only folder mode gets the fallback. In file mode, currentPath is a
    // directory, not a selectable file — Select must wait for an explicit
    // file click.
    wrapper = mountDialog({ initialPath: '/home/user', mode: 'file' })
    await wrapper.setProps({ modelValue: true })
    await flushPromises()
    const btn = findInDom('[data-testid="file-picker-select"]') as HTMLButtonElement | null
    expect(btn?.disabled).toBe(true)
  })

  it('Enter key on the dialog (no highlight) emits currentPath via the fallback', async () => {
    // R10: pressing Enter without first pressing ArrowDown calls handleSelect() in the `else if
    // (canSelect.value)` branch. With the fix, canSelect is true at /home/user, and Enter emits
    // /home/user.

    // The dialog auto-focuses the search input on open (FilePickerDialog.vue:613
    // `searchInput.value?.focus()`). While the search input is focused, Enter submits the first
    // match (line 500-507) — i.e. it behaves like search-Enter, NOT dialog-Enter.

    // To exercise the dialog-Enter branch we must move focus elsewhere first (blurring the search
    // input). The plan covers R10 conceptually; the test must mirror the actual code path.
    wrapper = mountDialog({ initialPath: '/home/user', mode: 'folder', closeOnSelect: true })
    await wrapper.setProps({ modelValue: true })
    await flushPromises()
    // Blur the search input so the dialog-level Enter handler fires.
    const search = findInDom('[data-testid="file-picker-search"]') as HTMLInputElement
    search?.blur()
    await flushPromises()
    keydownInDom('Enter')
    await flushPromises()
    expect(wrapper.emitted('select')?.[0]).toEqual(['/home/user'])
    expect(wrapper.emitted('update:modelValue')?.[0]).toEqual([false])
  })
})

// ─── Recent tab + tabstrip + pin ──────────────────────────────────────────── Plan:
// docs/superpowers/plans/2026-08-14-folder-picker-recent-history.md The dialog opens on the Recent
// tab by default.

// The user sees a flat list of folders they've picked before (most recent first, pinned at top).
// Click a row to select; click the star to toggle pin. The Browse tab is one click away and shows
// the existing two-pane tree + content layout.
describe('FilePickerDialog — Recent tab + tabstrip + pin', () => {
  let wrapper: VueWrapper | null = null

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    document.body.style.overflow = ''
    vi.restoreAllMocks()
  })

  it('opens on the Recent tab by default', async () => {
    // mountDialog does NOT pass enableRecentHistory — that's the "omitted" case the default-on
    // branch needs to handle.

    // Vue 3.5's runtime default for `boolean?` is `false`, so `props.enableRecentHistory` reads as
    // `false` here even though the caller didn't pass anything.

    // The computed treats `undefined` as "default on" but `mountDialog`'s implicit spread of the
    // override doesn't preserve `undefined`. To exercise the default-on branch, mount with
    // `enableRecentHistory: undefined` explicitly:
    wrapper = mountDialog({ initialPath: '/home/user', enableRecentHistory: undefined })
    await wrapper.setProps({ modelValue: true })
    await flushPromises()
    // The Recent tab is active, the Browse tab is not.
    const recentTab = findInDom('[data-testid="file-picker-tab-recent"]')
    expect(recentTab).not.toBeNull()
    expect(recentTab?.getAttribute('aria-selected')).toBe('true')
    expect(findInDom('[data-testid="file-picker-tab-browse"]')?.getAttribute('aria-selected')).toBe('false')
  })

  it('opens on the Recent tab when enableRecentHistory is explicitly true', async () => {
    wrapper = mountDialog({ initialPath: '/home/user', enableRecentHistory: true })
    await wrapper.setProps({ modelValue: true })
    await flushPromises()
    expect(findInDom('[data-testid="file-picker-tab-recent"]')).not.toBeNull()
  })

  it('shows the empty state on the Recent tab when localStorage is empty', async () => {
    wrapper = mountDialog({ initialPath: '/home/user', enableRecentHistory: undefined })
    await wrapper.setProps({ modelValue: true })
    await flushPromises()
    // The Recent tab is visible; the empty-state copy is rendered.
    const text = findInDom('[data-testid="file-picker-recent-empty"]')?.textContent ?? ''
    expect(text).toContain('No recent folders yet')
  })

  it('renders a row for each recent entry (pinned first)', async () => {
    // Seed the store via the persistence key.
    localStorage.setItem(
      'pabrik-folder-picker-recent:v1',
      JSON.stringify([
        { path: '/home/me/a', lastUsedAt: Date.now() - 1000, pinned: false },
        { path: '/home/me/b', lastUsedAt: Date.now() - 60_000, pinned: true },
      ]),
    )
    wrapper = mountDialog({ initialPath: '/home/user', enableRecentHistory: undefined })
    await wrapper.setProps({ modelValue: true })
    await flushPromises()
    expect(findInDom('[data-testid="file-picker-recent-row-/home/me/a"]')).not.toBeNull()
    expect(findInDom('[data-testid="file-picker-recent-row-/home/me/b"]')).not.toBeNull()
    // Pinned first.
    const list = findInDom('[data-testid="file-picker-recent-list"]')
    const rows = list?.querySelectorAll('[data-testid^="file-picker-recent-row-"]') ?? []
    expect(rows[0]?.getAttribute('data-testid')).toBe('file-picker-recent-row-/home/me/b')
    expect(rows[1]?.getAttribute('data-testid')).toBe('file-picker-recent-row-/home/me/a')
  })

  it('clicking a recent row emits select and closes (closeOnSelect: true)', async () => {
    localStorage.setItem(
      'pabrik-folder-picker-recent:v1',
      JSON.stringify([
        { path: '/home/me/picked', lastUsedAt: Date.now() - 1000, pinned: false },
      ]),
    )
    wrapper = mountDialog({
      initialPath: '/home/user',
      mode: 'folder',
      closeOnSelect: true,
      enableRecentHistory: undefined,
    })
    await wrapper.setProps({ modelValue: true })
    await flushPromises()
    clickInDom('[data-testid="file-picker-recent-row-/home/me/picked"]')
    await flushPromises()
    expect(wrapper.emitted('select')?.[0]).toEqual(['/home/me/picked'])
    expect(wrapper.emitted('update:modelValue')?.[0]).toEqual([false])
  })

  it('clicking a recent row records the path in the store (debounced write)', async () => {
    localStorage.setItem(
      'pabrik-folder-picker-recent:v1',
      JSON.stringify([
        { path: '/home/me/picked', lastUsedAt: Date.now() - 1000, pinned: false },
      ]),
    )
    wrapper = mountDialog({
      initialPath: '/home/user',
      mode: 'folder',
      enableRecentHistory: undefined,
    })
    await wrapper.setProps({ modelValue: true })
    await flushPromises()
    clickInDom('[data-testid="file-picker-recent-row-/home/me/picked"]')
    await flushPromises()
    // The store should have the path with a fresh lastUsedAt.
    await new Promise((r) => setTimeout(r, 250)) // wait for the 200ms debounce
    const raw = localStorage.getItem('pabrik-folder-picker-recent:v1')
    expect(raw).not.toBeNull()
    const entries = JSON.parse(raw!)
    const entry = entries.find((e: { path: string }) => e.path === '/home/me/picked')
    expect(entry).toBeTruthy()
    // The bumped lastUsedAt should be very close to Date.now().
    expect(Date.now() - entry.lastUsedAt).toBeLessThan(1000)
  })

  it('clicking the star toggles the pin (no select emitted)', async () => {
    localStorage.setItem(
      'pabrik-folder-picker-recent:v1',
      JSON.stringify([
        { path: '/home/me/foo', lastUsedAt: Date.now() - 1000, pinned: false },
      ]),
    )
    wrapper = mountDialog({
      initialPath: '/home/user',
      mode: 'folder',
      enableRecentHistory: undefined,
    })
    await wrapper.setProps({ modelValue: true })
    await flushPromises()
    clickInDom('[data-testid="file-picker-recent-pin-/home/me/foo"]')
    await flushPromises()
    expect(wrapper.emitted('select')).toBeFalsy()
    await new Promise((r) => setTimeout(r, 250))
    const raw = localStorage.getItem('pabrik-folder-picker-recent:v1')
    const entries = JSON.parse(raw!)
    expect(entries[0]!.pinned).toBe(true)
  })

  it('switching to the Browse tab shows the existing tree + content layout', async () => {
    wrapper = mountDialog({ initialPath: '/home/user', enableRecentHistory: undefined })
    await wrapper.setProps({ modelValue: true })
    await flushPromises()
    // Default is Recent.
    expect(findInDom('[data-testid="file-picker-tab-recent"]')?.getAttribute('aria-selected')).toBe('true')
    clickInDom('[data-testid="file-picker-tab-browse"]')
    await flushPromises()
    expect(findInDom('[data-testid="file-picker-tab-browse"]')?.getAttribute('aria-selected')).toBe('true')
    // The Browse tab's tree pane is visible.
    expect(findInDom('[data-testid="file-picker-tree"]')).not.toBeNull()
    // The Browse tab's content pane is visible.
    expect(findInDom('[data-testid="file-picker-content"]')).not.toBeNull()
  })

  it('the tab count badge shows the number of recent entries', async () => {
    localStorage.setItem(
      'pabrik-folder-picker-recent:v1',
      JSON.stringify([
        { path: '/home/me/a', lastUsedAt: Date.now() - 1000, pinned: false },
        { path: '/home/me/b', lastUsedAt: Date.now() - 2000, pinned: false },
        { path: '/home/me/c', lastUsedAt: Date.now() - 3000, pinned: true },
      ]),
    )
    wrapper = mountDialog({ initialPath: '/home/user', enableRecentHistory: undefined })
    await wrapper.setProps({ modelValue: true })
    await flushPromises()
    const badge = findInDom('[data-testid="file-picker-tab-recent-count"]')
    expect(badge?.textContent).toBe('3')
  })

  it('enableRecentHistory: false falls back to the legacy single-pane Browse UX', async () => {
    wrapper = mountDialog({ initialPath: '/home/user', enableRecentHistory: false })
    await wrapper.setProps({ modelValue: true })
    await flushPromises()
    // No tabstrip.
    expect(findInDom('[data-testid="file-picker-tab-recent"]')).toBeNull()
    // The tree pane is visible immediately.
    expect(findInDom('[data-testid="file-picker-tree"]')).not.toBeNull()
  })

  it('relative-time chip shows now / 2h / 1d / 3d via formatRelativeTime', async () => {
    const now = Date.now()
    localStorage.setItem(
      'pabrik-folder-picker-recent:v1',
      JSON.stringify([
        { path: '/home/me/now', lastUsedAt: now - 30_000, pinned: false },
        { path: '/home/me/2h', lastUsedAt: now - 2 * 60 * 60_000, pinned: false },
        { path: '/home/me/yest', lastUsedAt: now - 26 * 60 * 60_000, pinned: false },
        { path: '/home/me/3d', lastUsedAt: now - 3 * 24 * 60 * 60_000, pinned: false },
      ]),
    )
    wrapper = mountDialog({ initialPath: '/home/user', enableRecentHistory: undefined })
    await wrapper.setProps({ modelValue: true })
    await flushPromises()
    expect(
      findInDom('[data-testid="file-picker-recent-time-/home/me/now"]')?.textContent,
    ).toBe('now')
    expect(
      findInDom('[data-testid="file-picker-recent-time-/home/me/2h"]')?.textContent,
    ).toBe('2h')
    // 26h ago = 1 day floor. formatRelativeTime emits `1d` (not `yest`).
    expect(
      findInDom('[data-testid="file-picker-recent-time-/home/me/yest"]')?.textContent,
    ).toBe('1d')
    expect(
      findInDom('[data-testid="file-picker-recent-time-/home/me/3d"]')?.textContent,
    ).toBe('3d')
  })
})

describe('FilePickerDialog — double-click navigates folders (never closes)', () => {
  let wrapper: VueWrapper | null = null

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    document.body.style.overflow = ''
    vi.restoreAllMocks()
  })

  function dblclickInDom(selector: string) {
    const el = findInDom(selector)
    if (!el) throw new Error(`No element found: ${selector}`)
    el.dispatchEvent(new MouseEvent('dblclick', { bubbles: true }))
  }

  it('folder mode: dblclick folder navigates in, emits NO select, dialog stays open', async () => {
    wrapper = mountDialog({
      initialPath: '/home/user',
      mode: 'folder',
      closeOnSelect: true,
      enableRecentHistory: false,
    })
    await wrapper.setProps({ modelValue: true })
    await flushPromises()
    dblclickInDom('[data-testid="file-picker-item-/home/user/notes"]')
    await flushPromises()
    // Navigated into /home/user/notes — its child file is now visible.
    expect(findInDom('[data-testid="file-picker-item-/home/user/notes/todo.txt"]')).not.toBeNull()
    // No select emitted, no close emitted.
    expect(wrapper.emitted('select')).toBeFalsy()
    expect(wrapper.emitted('update:modelValue')).toBeFalsy()
  })

  it('both mode: dblclick folder navigates in, emits NO select', async () => {
    wrapper = mountDialog({
      initialPath: '/home/user',
      mode: 'both',
      closeOnSelect: true,
      enableRecentHistory: false,
    })
    await wrapper.setProps({ modelValue: true })
    await flushPromises()
    dblclickInDom('[data-testid="file-picker-item-/home/user/notes"]')
    await flushPromises()
    expect(findInDom('[data-testid="file-picker-item-/home/user/notes/todo.txt"]')).not.toBeNull()
    expect(wrapper.emitted('select')).toBeFalsy()
  })

  it('file mode: dblclick file still confirms (select + close)', async () => {
    wrapper = mountDialog({
      initialPath: '/home/user',
      mode: 'file',
      closeOnSelect: true,
      enableRecentHistory: false,
    })
    await wrapper.setProps({ modelValue: true })
    await flushPromises()
    dblclickInDom('[data-testid="file-picker-item-/home/user/readme.md"]')
    await flushPromises()
    expect(wrapper.emitted('select')?.[0]).toEqual(['/home/user/readme.md'])
    expect(wrapper.emitted('update:modelValue')?.[0]).toEqual([false])
  })

  it('folder mode: dblclick file is a no-op (no select, no close)', async () => {
    wrapper = mountDialog({
      initialPath: '/home/user',
      mode: 'folder',
      closeOnSelect: true,
      enableRecentHistory: false,
    })
    await wrapper.setProps({ modelValue: true })
    await flushPromises()
    dblclickInDom('[data-testid="file-picker-item-/home/user/readme.md"]')
    await flushPromises()
    expect(wrapper.emitted('select')).toBeFalsy()
    expect(wrapper.emitted('update:modelValue')).toBeFalsy()
  })
})