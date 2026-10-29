/** Tests for FilePickerDialog — a generic, data-source-agnostic file/folder picker. The component
 * is generic over the item type T. */
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

function clickInDom(selector: string) {
  const el = findInDom(selector)
  if (!el) throw new Error(`No element found: ${selector}`)
  ;(el as HTMLElement).click()
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
  const loadItems =
    (propsOverride.loadItems as ReturnType<typeof makeLoadItems> | undefined) ?? makeLoadItems()
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
  // invariant. Previously: "Select button is disabled when nothing is selected".
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
    expect(findInDom('[data-testid="file-picker-selected-path"]')?.textContent).toBe(
      '/home/user/docs',
    )
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
