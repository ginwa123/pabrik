/** Tests for FileInput — the composer's `/files-` file autocomplete and its `@` agent list. */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { mount, flushPromises, type VueWrapper } from '@vue/test-utils'
import { setActivePinia, createPinia } from 'pinia'
import FileInput from '@/components/file/FileInput.vue'
import * as api from '@/api'

vi.mock('@/api', async (importOriginal) => {
  const actual = await importOriginal<typeof import('@/api')>()
  return {
    ...actual,
    searchFiles: vi.fn(),
  }
})

const searchFilesMock = api.searchFiles as unknown as ReturnType<typeof vi.fn>

/**  * Mock `api.searchFiles` with pre-ranked server rows (Task 2: the server owns ranking now — the old
 * N-sequential-fetch full-tree walk via raw `fetch` is deleted). Each test sets the rows its query
 * should return. */
function mockSearchResults(entries: Array<{ name: string; path: string; is_directory: boolean }>) {
  searchFilesMock.mockResolvedValue({
    entries: entries.map((e) => ({ ...e, is_symlink: false })),
  })
}

/**  * Set the textarea's value and explicitly position the cursor at the end, then dispatch `input` so
 * the component's `autoResize` handler runs and updates `cursorPos`. jsdom does not always move
 * `selectionStart` to the end of a programmatically-set `.value`. */
async function typeInTextarea(textareaWrapper: ReturnType<VueWrapper['find']>, value: string) {
  const element = textareaWrapper.element as HTMLTextAreaElement
  await textareaWrapper.setValue(value)
  element.setSelectionRange(value.length, value.length)
  element.dispatchEvent(new Event('input', { bubbles: true }))
  // Wait for BOTH debounces (100ms trigger-detect + 100ms server-search)
  // plus promise flushes.
  await new Promise((resolve) => setTimeout(resolve, 450))
  await flushPromises()
}

const originalFetch = global.fetch
const fetchMock = vi.fn()

async function mountInput(propsOverride: Record<string, unknown> = {}) {
  document.body.innerHTML = ''
  const wrapper = mount(FileInput, {
    attachTo: document.body,
    props: { cwd: '/home/user', ...propsOverride },
  })
  await flushPromises()
  return wrapper
}

describe('FileInput — /files- autocomplete', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    fetchMock.mockReset()
    global.fetch = fetchMock as unknown as typeof fetch
    searchFilesMock.mockReset()
    // Default: empty server result (picker shows "No files found").
    searchFilesMock.mockResolvedValue({ entries: [] })
  })

  afterEach(() => {
    global.fetch = originalFetch
    vi.restoreAllMocks()
  })

  it('replaces the /files- query with the picked path when Enter picks the first match', async () => {
    // Server owns ranking now: pre-ranked rows for query "d" — `/docs`
    // first (shortest path), `/docs/superpowers` second. The picker
    // renders them directly (no client-side walk or re-sort).
    mockSearchResults([
      { name: 'docs', path: '/home/user/docs', is_directory: true },
      { name: 'superpowers', path: '/home/user/docs/superpowers', is_directory: true },
    ])

    const wrapper = await mountInput()
    const textarea = wrapper.find('textarea')
    await typeInTextarea(textarea, '/files-d')

    // File picker should be open with at least one match.
    expect(wrapper.find('.file-picker-list').exists()).toBe(true)

    // Press Enter — selectedFileIndex starts at 0, so the first match (/docs)
    // is selected.
    await textarea.trigger('keydown', { key: 'Enter' })
    await flushPromises()

    const finalValue = (textarea.element as HTMLTextAreaElement).value
    // The whole `/files-<query>` span becomes the canonical `/files-<path>`
    // token; the marker survives so the message can be stripped on submit.
    // The path is the row's own (cwd-relative) path — `/home/user` is the cwd.
    expect(finalValue).toBe('/files-/docs')
  })

  it('keeps the /files- marker when prefix text is present (e.g. "Hello /files-d")', async () => {
    mockSearchResults([{ name: 'docs', path: '/home/user/docs', is_directory: true }])

    const wrapper = await mountInput()
    const textarea = wrapper.find('textarea')
    await typeInTextarea(textarea, 'Hello /files-d')
    expect(wrapper.find('.file-picker-list').exists()).toBe(true)

    await textarea.trigger('keydown', { key: 'Enter' })
    await flushPromises()

    const finalValue = (textarea.element as HTMLTextAreaElement).value
    expect(finalValue).toBe('Hello /files-/docs')
  })

  it('replaces a bare /files- with the clicked folder path (empty query)', async () => {
    // Empty query: server returns the cwd top-N pre-ranked.
    mockSearchResults([
      { name: 'bin', path: '/home/user/bin', is_directory: true },
      { name: 'docs', path: '/home/user/docs', is_directory: true },
    ])

    const wrapper = await mountInput()
    const textarea = wrapper.find('textarea')
    await typeInTextarea(textarea, '/files-')
    expect(wrapper.find('.file-picker-list').exists()).toBe(true)

    // Click the first folder button (bin).
    const buttons = wrapper.findAll('.file-picker-list button')
    expect(buttons.length).toBeGreaterThan(0)
    await buttons[0]!.trigger('click')
    await flushPromises()

    const finalValue = (textarea.element as HTMLTextAreaElement).value
    expect(finalValue).toBe('/files-/bin')
  })

  it('replaces a partial path like "/files-/doc" with the full picked path', async () => {
    mockSearchResults([
      { name: 'docs', path: '/home/user/docs', is_directory: true },
      { name: 'superpowers', path: '/home/user/docs/superpowers', is_directory: true },
    ])

    const wrapper = await mountInput()
    const textarea = wrapper.find('textarea')
    await typeInTextarea(textarea, '/files-/doc')
    expect(wrapper.find('.file-picker-list').exists()).toBe(true)

    await textarea.trigger('keydown', { key: 'Enter' })
    await flushPromises()

    const finalValue = (textarea.element as HTMLTextAreaElement).value
    // The "/doc" query is replaced by the full relative path; the
    // `/files-` marker is preserved as a prefix.
    expect(finalValue).toBe('/files-/docs')
  })

  it('does not modify the input when Enter is pressed without a selection (no matches)', async () => {
    // Empty server result — no matches.
    mockSearchResults([])

    const wrapper = await mountInput()
    const textarea = wrapper.find('textarea')
    await typeInTextarea(textarea, '/files-zzz')

    // No matches, no "selected file" → Enter should be a no-op on the input.
    await textarea.trigger('keydown', { key: 'Enter' })
    await flushPromises()

    const finalValue = (textarea.element as HTMLTextAreaElement).value
    expect(finalValue).toBe('/files-zzz')
  })
})

/** `@` addresses an AGENT now — files moved to `/files-` so the two never compete. */
describe('FileInput — @ lists agents', () => {
  const AGENTS = [
    { name: 'deepseek auto', model: 'deepseek-v3' },
    { name: 'gpt-4o', model: 'gpt-4o' },
  ]

  beforeEach(() => {
    setActivePinia(createPinia())
    fetchMock.mockReset()
    global.fetch = fetchMock as unknown as typeof fetch
    searchFilesMock.mockReset()
    searchFilesMock.mockResolvedValue({ entries: [] })
  })

  afterEach(() => {
    global.fetch = originalFetch
    vi.restoreAllMocks()
  })

  it('opens the agent list on "@" and lists the agents prop in order', async () => {
    const wrapper = await mountInput({ agents: AGENTS })
    await typeInTextarea(wrapper.find('textarea'), '@')

    expect(wrapper.find('[data-testid="agent-picker-list"]').exists()).toBe(true)
    const rows = wrapper.findAll('[data-agent-name]')
    expect(rows.map((r) => r.attributes('data-agent-name'))).toEqual(['deepseek auto', 'gpt-4o'])
    // The row text is the `@<name>` token the composer will insert.
    expect(rows[0]!.text()).toContain('@deepseek auto')
  })

  it('inserts "@<name> " and emits select-agent when a row is clicked', async () => {
    const wrapper = await mountInput({ agents: AGENTS })
    const textarea = wrapper.find('textarea')
    await typeInTextarea(textarea, '@')

    await wrapper.find('[data-agent-name="deepseek auto"]').trigger('click')
    await flushPromises()

    // The trailing space is what ends the mention so the next word is prose.
    expect((textarea.element as HTMLTextAreaElement).value).toBe('@deepseek auto ')
    expect(wrapper.emitted('select-agent')).toEqual([['deepseek auto']])
    // Picking closes the list.
    expect(wrapper.find('[data-testid="agent-picker-list"]').exists()).toBe(false)
  })

  it('filters the list by the typed query, spaces in names included', async () => {
    const wrapper = await mountInput({ agents: AGENTS })
    await typeInTextarea(wrapper.find('textarea'), '@deep')

    const rows = wrapper.findAll('[data-agent-name]')
    expect(rows.map((r) => r.attributes('data-agent-name'))).toEqual(['deepseek auto'])
  })

  it('does not open the file picker on "@" (files moved to /files-)', async () => {
    const wrapper = await mountInput({ agents: AGENTS })
    await typeInTextarea(wrapper.find('textarea'), '@')

    expect(wrapper.find('[data-testid="agent-picker-list"]').exists()).toBe(true)
    expect(wrapper.find('.file-picker-list').exists()).toBe(false)
  })

  it('renders the empty row when no agents are configured', async () => {
    const wrapper = await mountInput({ agents: [] })
    await typeInTextarea(wrapper.find('textarea'), '@')

    expect(wrapper.find('[data-testid="agent-picker-list"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="agent-picker-empty"]').exists()).toBe(true)
    expect(wrapper.findAll('[data-agent-name]')).toHaveLength(0)
  })
})

/** Paste-image regression tests (WebKitGTK + pabrik-desktop bug). */
describe('FileInput — paste image (Ctrl+V) attaches to preview', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    fetchMock.mockReset()
    global.fetch = fetchMock as unknown as typeof fetch
    searchFilesMock.mockReset()
    searchFilesMock.mockResolvedValue({ entries: [] })
  })

  afterEach(() => {
    global.fetch = originalFetch
    vi.restoreAllMocks()
    delete (navigator as unknown as { clipboard?: unknown }).clipboard
  })

  /**    * Build a minimal DataTransferItem-like object. jsdom doesn't expose DataTransferItem constructor
   * in the test env, so we use the closest shape and rely on the handler's duck-typing checks
   * (kind, type, getAsFile()). */
  function fakeImageItem(
    type = 'image/png',
    withName = '',
  ): {
    kind: string
    type: string
    getAsFile: () => File
  } {
    const bytes = new Uint8Array([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]) // PNG header
    const blob = new Blob([bytes], { type })
    const file = withName ? new File([blob], withName, { type }) : new File([blob], '', { type })
    return {
      kind: 'file',
      type,
      getAsFile: () => file,
    }
  }

  function fakeClipboardEvent(opts: {
    items?: Array<{ kind: string; type: string; getAsFile: () => File }>
  }): ClipboardEvent {
    const items = opts.items ?? []
    const dataTransfer = {
      items,
      get length() {
        return items.length
      },
      files: [] as File[],
      types: items.map((i) => i.type),
    } as unknown as DataTransfer
    // jsdom doesn't expose a ClipboardEvent constructor (DOM v0.x), so we build a synthetic event
    // with the clipboardData property attached. The DOM-level event dispatch
    // (Element.dispatchEvent) only requires a non-null Event with bubbles=true.
    const ev = new Event('paste', { bubbles: true, cancelable: true }) as unknown as ClipboardEvent
    Object.defineProperty(ev, 'clipboardData', { value: dataTransfer })
    return ev
  }

  it('attaches a pasted image when clipboardData.items has an image file (Chrome path)', async () => {
    const wrapper = await mountInput()
    const textarea = wrapper.find('textarea')
    const ta = textarea.element as HTMLTextAreaElement

    const pngItem = fakeImageItem('image/png', 'screenshot.png')
    const ev = fakeClipboardEvent({ items: [pngItem] })
    // Dispatch from the textarea so the scope check (e.target === ref) passes.
    ta.dispatchEvent(ev)
    await flushPromises()

    // The preview list is rendered by FilePreview.vue which gives each item
    // a `.preview-item` class.
    const previews = wrapper.findAll('.preview-item')
    expect(previews.length).toBe(1)
    // The handler should have called preventDefault so the textarea doesn't
    // get a multi-MB base64 string inserted.
    expect(ev.defaultPrevented).toBe(true)
  })

  it('renames a pasted clipboard image with no filename (browsers leave File.name empty)', async () => {
    const wrapper = await mountInput()
    const textarea = wrapper.find('textarea')
    const ta = textarea.element as HTMLTextAreaElement

    const item = fakeImageItem('image/gif', '')
    const ev = fakeClipboardEvent({ items: [item] })
    ta.dispatchEvent(ev)
    await flushPromises()

    const previews = wrapper.findAll('.preview-item')
    expect(previews.length).toBe(1)
    expect(ev.defaultPrevented).toBe(true)
  })

  it('does NOT attach any image for non-image items (e.g. application/pdf)', async () => {
    const wrapper = await mountInput()
    const textarea = wrapper.find('textarea')
    const ta = textarea.element as HTMLTextAreaElement

    const pdfItem = {
      kind: 'file',
      type: 'application/pdf',
      getAsFile: () =>
        new File([new Uint8Array([0x25, 0x50, 0x44, 0x46])], 'doc.pdf', {
          type: 'application/pdf',
        }),
    }
    const ev = fakeClipboardEvent({ items: [pdfItem] })
    ta.dispatchEvent(ev)
    await flushPromises()

    // The PASTE flow is media-only (the paperclip flow takes documents too).
    expect(wrapper.findAll('.preview-item').length).toBe(0)
    // preventDefault is only called when at least one image was attached.
    expect(ev.defaultPrevented).toBe(false)
  })

  it('falls back to navigator.clipboard.read() when items is empty (WebKitGTK path)', async () => {
    // Simulate WebKitGTK: clipboardData.items is empty.
    const pngBlob = new Blob([new Uint8Array([0x89, 0x50, 0x4e, 0x47])], { type: 'image/png' })
    const clipboardReadMock = vi.fn().mockResolvedValue([
      {
        types: ['image/png'],
        getType: vi.fn().mockResolvedValue(pngBlob),
      },
    ])
    Object.defineProperty(navigator, 'clipboard', {
      configurable: true,
      value: { read: clipboardReadMock },
    })

    const wrapper = await mountInput()
    const textarea = wrapper.find('textarea')
    const ta = textarea.element as HTMLTextAreaElement

    // Empty items — the WebKitGTK case.
    const ev = fakeClipboardEvent({ items: [] })
    ta.dispatchEvent(ev)
    // The handler is async (await navigator.clipboard.read); let the
    // microtask queue flush.
    await flushPromises()
    // Allow additional microtask ticks for the .getType() await chain.
    await new Promise((r) => setTimeout(r, 10))
    await flushPromises()

    expect(clipboardReadMock).toHaveBeenCalledTimes(1)
    const previews = wrapper.findAll('.preview-item')
    expect(previews.length).toBe(1)
  })

  it('silently no-ops when navigator.clipboard.read() rejects (e.g. permission denied)', async () => {
    const clipboardReadMock = vi.fn().mockRejectedValue(new Error('permission denied'))
    Object.defineProperty(navigator, 'clipboard', {
      configurable: true,
      value: { read: clipboardReadMock },
    })

    const wrapper = await mountInput()
    const textarea = wrapper.find('textarea')
    const ta = textarea.element as HTMLTextAreaElement

    const ev = fakeClipboardEvent({ items: [] })
    ta.dispatchEvent(ev)
    await flushPromises()
    await new Promise((r) => setTimeout(r, 10))
    await flushPromises()

    expect(clipboardReadMock).toHaveBeenCalledTimes(1)
    // No images attached — no preventDefault, no previews.
    expect(wrapper.findAll('.preview-item').length).toBe(0)
    expect(ev.defaultPrevented).toBe(false)
  })

  it('does NOT intercept paste events from other elements (scope check)', async () => {
    // Mount the component.
    const wrapper = await mountInput()

    // Build a paste event whose target is a NON-FileInput textarea.
    const otherTextarea = document.createElement('textarea')
    otherTextarea.id = 'other-textarea'
    document.body.appendChild(otherTextarea)

    const clipboardReadMock = vi.fn().mockResolvedValue([])
    Object.defineProperty(navigator, 'clipboard', {
      configurable: true,
      value: { read: clipboardReadMock },
    })

    const ev = fakeClipboardEvent({ items: [fakeImageItem('image/png', 'foo.png')] })
    otherTextarea.dispatchEvent(ev)
    await flushPromises()
    await new Promise((r) => setTimeout(r, 10))

    // The FileInput's listener must NOT have processed this paste — the
    // clipboard.read() fallback (which would block other FileInputs' text
    // pastes on WebKitGTK) should NOT have been called.
    expect(clipboardReadMock).not.toHaveBeenCalled()
    expect(wrapper.findAll('.preview-item').length).toBe(0)

    // Cleanup
    otherTextarea.remove()
  })

  it('removes the document paste listener on unmount (no leak across mounts)', async () => {
    // Before mount: count document-level paste listeners we know about.
    // We can't introspect the exact listener count, but we can dispatch a
    // paste after unmount and assert the handler is gone.
    const wrapper = await mountInput()
    const clipboardReadMock = vi.fn().mockResolvedValue([])
    Object.defineProperty(navigator, 'clipboard', {
      configurable: true,
      value: { read: clipboardReadMock },
    })

    const evBefore = fakeClipboardEvent({ items: [fakeImageItem('image/png', 'a.png')] })
    wrapper.find('textarea').element.dispatchEvent(evBefore)
    await flushPromises()
    const previewsBefore = wrapper.findAll('.preview-item').length

    wrapper.unmount()

    const evAfter = fakeClipboardEvent({ items: [fakeImageItem('image/png', 'b.png')] })
    document.dispatchEvent(evAfter)
    await flushPromises()
    await new Promise((r) => setTimeout(r, 10))

    // After unmount, the unmounted instance's listener shouldn't add another preview to the
    // (now-unmounted) FileInput's DOM.
    expect(clipboardReadMock).not.toHaveBeenCalled()
    expect(previewsBefore).toBe(1)
  })
})
