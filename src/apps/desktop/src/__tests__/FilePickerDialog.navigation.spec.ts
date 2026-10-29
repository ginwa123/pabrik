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
    input.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true }))
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
    const errEl =
      findInDom('[data-testid="file-picker-tree"] [class*="text-center"]') ||
      findInDom('[data-testid="file-picker-tree"]')
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
