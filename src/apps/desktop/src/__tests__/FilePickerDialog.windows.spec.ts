/**
 * Windows-path tests for FilePickerDialog (2026-09-05 Windows cwd fix).
 *
 * Regression suite for the mixed-separator bug: the old POSIX-only helpers
 * (`split('/')`, `lastIndexOf('/')`, `initialPath '/'`) mangled Windows
 * picks like `C:\Users\ginwa\ginwaaitoolbox` into `/Users\ginwa\...`
 * shapes (leading slash + backslashes, drive letter lost). That malformed
 * string was persisted as `workspace_items.path` and flowed into
 * `sessions.cwd` and the agent prompt.
 *
 * Conventions in this file:
 * - Mount WITHOUT `enableRecentHistory` (omit the prop) so the dialog
 *   renders the legacy single-pane Browse UX directly — same as the
 *   POSIX suite's early describes.
 * - Never query `querySelector` with a backslash-bearing `data-testid`
 *   (CSS escaping pain). Assert via breadcrumb text, the footer
 *   `file-picker-selected-path` text, `loadItems` call args, and the
 *   emitted `select` payload instead.
 * - `attachTo: document.body` is required (Teleport + Transition stub).
 */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { mount, flushPromises, type VueWrapper } from '@vue/test-utils'
import { setActivePinia, createPinia } from 'pinia'
import FilePickerDialog from '../components/FilePickerDialog.vue'
import { makeLocalStorageStub } from './helpers'

beforeEach(() => {
  setActivePinia(createPinia())
  Object.defineProperty(globalThis, 'localStorage', {
    value: makeLocalStorageStub(),
    writable: true,
    configurable: true,
  })
})

function findInDom<T extends Element = Element>(selector: string): T | null {
  return document.querySelector<T>(selector)
}

function clickInDom(selector: string) {
  const el = findInDom(selector)
  if (!el) throw new Error(`No element found: ${selector}`)
  ;(el as HTMLElement).click()
}

// Mock Windows tree (backslash-joined, like the backend's `std.fs.path.join` produces on Windows):
// C:\ └── Users └── ginwa ├── ginwaaitoolbox (dir, empty) └── notes (dir, one file)
const winTree: Record<string, Array<{ name: string; path: string; is_directory: boolean }>> = {
  'C:\\': [{ name: 'Users', path: 'C:\\Users', is_directory: true }],
  'C:\\Users': [{ name: 'ginwa', path: 'C:\\Users\\ginwa', is_directory: true }],
  'C:\\Users\\ginwa': [
    { name: 'ginwaaitoolbox', path: 'C:\\Users\\ginwa\\ginwaaitoolbox', is_directory: true },
    { name: 'notes', path: 'C:\\Users\\ginwa\\notes', is_directory: true },
  ],
  'C:\\Users\\ginwa\\ginwaaitoolbox': [],
  'C:\\Users\\ginwa\\notes': [
    { name: 'todo.txt', path: 'C:\\Users\\ginwa\\notes\\todo.txt', is_directory: false },
  ],
}

interface MockEntry {
  name: string
  path: string
  is_directory: boolean
}

function makeWinLoadItems() {
  return vi.fn(async (path: string) => winTree[path] ?? [])
}

function mountWinDialog(propsOverride: Record<string, unknown> = {}) {
  const loadItems = (propsOverride.loadItems as ReturnType<typeof makeWinLoadItems> | undefined) ?? makeWinLoadItems()
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

function selectedPathText(): string {
  return findInDom('[data-testid="file-picker-selected-path"]')?.textContent ?? ''
}

async function typeAddressAndEnter(value: string) {
  clickInDom('[data-testid="file-picker-path-edit"]')
  await flushPromises()
  const input = findInDom('[data-testid="file-picker-path-input"]') as HTMLInputElement
  input.value = value
  input.dispatchEvent(new Event('input', { bubbles: true }))
  await flushPromises()
  input.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true }))
  await flushPromises()
}

describe('FilePickerDialog — Windows paths (drive letters)', () => {
  let wrapper: VueWrapper | null = null

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    document.body.style.overflow = ''
    vi.restoreAllMocks()
  })

  it('expands drive-letter ancestors from the drive root (no POSIX / prefix)', async () => {
    const loadItems = makeWinLoadItems()
    wrapper = mountWinDialog({ initialPath: 'C:\\Users\\ginwa\\ginwaaitoolbox', loadItems })
    await wrapper.setProps({ modelValue: true })
    await flushPromises()
    const calledPaths = loadItems.mock.calls.map(([p]) => p)
    expect(calledPaths).toEqual([
      'C:\\',
      'C:\\Users',
      'C:\\Users\\ginwa',
      'C:\\Users\\ginwa\\ginwaaitoolbox',
    ])
  })

  it('breadcrumb shows drive + segments (no /C: garbage)', async () => {
    wrapper = mountWinDialog({ initialPath: 'C:\\Users\\ginwa\\ginwaaitoolbox' })
    await wrapper.setProps({ modelValue: true })
    await flushPromises()
    expect(findInDom('[data-testid="file-picker-crumb-0"]')?.textContent).toBe('C:')
    expect(findInDom('[data-testid="file-picker-crumb-1"]')?.textContent).toBe('Users')
    expect(findInDom('[data-testid="file-picker-crumb-2"]')?.textContent).toBe('ginwa')
    expect(findInDom('[data-testid="file-picker-crumb-3"]')?.textContent).toBe('ginwaaitoolbox')
  })

  it('address bar accepts a Windows absolute as-is (never prepends /)', async () => {
    const loadItems = makeWinLoadItems()
    wrapper = mountWinDialog({ initialPath: 'C:\\Users\\ginwa', loadItems })
    await wrapper.setProps({ modelValue: true })
    await flushPromises()
    await typeAddressAndEnter('C:\\Users\\ginwa\\notes')
    // Navigated to the raw path — the backend received it unmangled.
    expect(loadItems.mock.calls.map(([p]) => p)).toContain('C:\\Users\\ginwa\\notes')
    expect(loadItems.mock.calls.map(([p]) => p)).not.toContain('/C:\\Users\\ginwa\\notes')
    // Folder-mode fallback shows the current folder in the footer.
    expect(selectedPathText()).toBe('C:\\Users\\ginwa\\notes')
    expect(findInDom('[data-testid="file-picker-crumb-2"]')?.textContent).toBe('notes')
  })

  it('Up button navigates to the Windows parent', async () => {
    wrapper = mountWinDialog({ initialPath: 'C:\\Users\\ginwa\\notes' })
    await wrapper.setProps({ modelValue: true })
    await flushPromises()
    clickInDom('[data-testid="file-picker-up"]')
    await flushPromises()
    expect(selectedPathText()).toBe('C:\\Users\\ginwa')
  })

  it('a bare relative word resolves against a Windows base', async () => {
    wrapper = mountWinDialog({ initialPath: 'C:\\Users\\ginwa' })
    await wrapper.setProps({ modelValue: true })
    await flushPromises()
    await typeAddressAndEnter('notes')
    expect(selectedPathText()).toBe('C:\\Users\\ginwa\\notes')
  })

  it('Select emits the raw Windows path (never a mixed /X: shape)', async () => {
    wrapper = mountWinDialog({ initialPath: 'C:\\Users\\ginwa\\ginwaaitoolbox', mode: 'folder' })
    await wrapper.setProps({ modelValue: true })
    await flushPromises()
    // No explicit click: folder-mode falls back to the current folder.
    clickInDom('[data-testid="file-picker-select"]')
    await flushPromises()
    const events = wrapper.emitted('select')
    expect(events).toBeTruthy()
    const emitted = events![0]![0] as string
    expect(emitted).toBe('C:\\Users\\ginwa\\ginwaaitoolbox')
    expect(emitted.startsWith('/')).toBe(false)
    expect(/^\/[A-Za-z]:/.test(emitted)).toBe(false)
  })

  it('forward-slash drive paths (C:/...) are accepted as-is', async () => {
    const loadItems = makeWinLoadItems()
    wrapper = mountWinDialog({ initialPath: 'C:\\Users\\ginwa', loadItems })
    await wrapper.setProps({ modelValue: true })
    await flushPromises()
    await typeAddressAndEnter('C:/Users/ginwa')
    expect(loadItems.mock.calls.map(([p]) => p)).toContain('C:/Users/ginwa')
  })
})
