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

// ─── Select button — current folder fallback (folder mode) ─────────────────The Select button
// is enabled whenever the user has a meaningful folder in scope.
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
    expect(findInDom('[data-testid="file-picker-selected-path"]')?.textContent).toBe(
      '/home/user/docs',
    )
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

// ─── Recent tab + tabstrip + pin ────────────────────────────────────────────The dialog opens on the Recent
// tab by default.
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
    wrapper = mountDialog({ initialPath: '/home/user', enableRecentHistory: undefined })
    await wrapper.setProps({ modelValue: true })
    await flushPromises()
    // The Recent tab is active, the Browse tab is not.
    const recentTab = findInDom('[data-testid="file-picker-tab-recent"]')
    expect(recentTab).not.toBeNull()
    expect(recentTab?.getAttribute('aria-selected')).toBe('true')
    expect(findInDom('[data-testid="file-picker-tab-browse"]')?.getAttribute('aria-selected')).toBe(
      'false',
    )
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
      JSON.stringify([{ path: '/home/me/picked', lastUsedAt: Date.now() - 1000, pinned: false }]),
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
      JSON.stringify([{ path: '/home/me/picked', lastUsedAt: Date.now() - 1000, pinned: false }]),
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
      JSON.stringify([{ path: '/home/me/foo', lastUsedAt: Date.now() - 1000, pinned: false }]),
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
    expect(findInDom('[data-testid="file-picker-tab-recent"]')?.getAttribute('aria-selected')).toBe(
      'true',
    )
    clickInDom('[data-testid="file-picker-tab-browse"]')
    await flushPromises()
    expect(findInDom('[data-testid="file-picker-tab-browse"]')?.getAttribute('aria-selected')).toBe(
      'true',
    )
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
    expect(findInDom('[data-testid="file-picker-recent-time-/home/me/now"]')?.textContent).toBe(
      'now',
    )
    expect(findInDom('[data-testid="file-picker-recent-time-/home/me/2h"]')?.textContent).toBe('2h')
    // 26h ago = 1 day floor. formatRelativeTime emits `1d` (not `yest`).
    expect(findInDom('[data-testid="file-picker-recent-time-/home/me/yest"]')?.textContent).toBe(
      '1d',
    )
    expect(findInDom('[data-testid="file-picker-recent-time-/home/me/3d"]')?.textContent).toBe('3d')
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
