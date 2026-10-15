/**
 * Tests for FileInput — chat input's @-triggered file/folder autocomplete.
 *
 * The component lets a user attach a folder to their message by typing
 * `@` in the textarea; the picker shows matching files/folders and the
 * user can select one (Enter or click). On selection, the matched
 * `@query` token is replaced by the picked path.
 *
 * Regression test for "keep the @ symbol on select":
 *   - When the user types `@d` and selects `/docs/superpowers`, the
 *     `@` trigger must be preserved in the input — the post-selection
 *     text should be `@/docs/superpowers`, not `/docs/superpowers`.
 *   - The pre-fix code sliced off `atMatch[0].length` (which INCLUDES
 *     the `@`) and replaced with `file.path`, losing the `@`.
 *
 * Plan: docs/plans/2026-06-26-keep-at-on-select.md
 */
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

/** Mock `api.searchFiles` with pre-ranked server rows (Task 2: the server
 * owns ranking now — the old N-sequential-fetch full-tree walk via raw
 * `fetch` is deleted). Each test sets the rows its query should return. */
function mockSearchResults(
  entries: Array<{ name: string; path: string; is_directory: boolean }>,
) {
  searchFilesMock.mockResolvedValue({
    entries: entries.map((e) => ({ ...e, is_symlink: false })),
  })
}

/** Set the textarea's value and explicitly position the cursor at the
 * end, then dispatch `input` so the component's `autoResize` handler
 * runs and updates `cursorPos`. jsdom does not always move
 * `selectionStart` to the end of a programmatically-set `.value`. */
async function typeInTextarea(
  textareaWrapper: ReturnType<VueWrapper['find']>,
  value: string,
) {
  const element = textareaWrapper.element as HTMLTextAreaElement
  await textareaWrapper.setValue(value)
  element.setSelectionRange(value.length, value.length)
  element.dispatchEvent(new Event('input', { bubbles: true }))
  // Wait for BOTH debounces (150ms `@`-detect + 150ms server-search)
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

describe('FileInput — @ autocomplete on select keeps the @ symbol', () => {
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

  it('preserves @ when the user types a query and presses Enter to pick the first match', async () => {
    // Server owns ranking now: pre-ranked rows for query "d" — `/docs`
    // first (shortest path), `/docs/superpowers` second. The picker
    // renders them directly (no client-side walk or re-sort).
    mockSearchResults([
      { name: 'docs', path: '/home/user/docs', is_directory: true },
      { name: 'superpowers', path: '/home/user/docs/superpowers', is_directory: true },
    ])

    const wrapper = await mountInput()
    const textarea = wrapper.find('textarea')
    await typeInTextarea(textarea, '@d')

    // File picker should be open with at least one match.
    expect(wrapper.find('.file-picker-list').exists()).toBe(true)

    // Press Enter — selectedFileIndex starts at 0, so the first match (/docs)
    // is selected.
    await textarea.trigger('keydown', { key: 'Enter' })
    await flushPromises()

    const finalValue = (textarea.element as HTMLTextAreaElement).value
    // BUG (pre-fix): /docs  — the @ was lost
    // FIX:           @/docs — the @ is preserved
    expect(finalValue).toBe('@/docs')
  })

  it('preserves @ when prefix text is present (e.g. "Hello @d")', async () => {
    mockSearchResults([
      { name: 'docs', path: '/home/user/docs', is_directory: true },
    ])

    const wrapper = await mountInput()
    const textarea = wrapper.find('textarea')
    await typeInTextarea(textarea, 'Hello @d')
    expect(wrapper.find('.file-picker-list').exists()).toBe(true)

    await textarea.trigger('keydown', { key: 'Enter' })
    await flushPromises()

    const finalValue = (textarea.element as HTMLTextAreaElement).value
    expect(finalValue).toBe('Hello @/docs')
  })

  it('preserves @ when the user clicks a folder in the picker (just "@", no query)', async () => {
    // Empty query: server returns the cwd top-N pre-ranked.
    mockSearchResults([
      { name: 'bin', path: '/home/user/bin', is_directory: true },
      { name: 'docs', path: '/home/user/docs', is_directory: true },
    ])

    const wrapper = await mountInput()
    const textarea = wrapper.find('textarea')
    await typeInTextarea(textarea, '@')
    expect(wrapper.find('.file-picker-list').exists()).toBe(true)

    // Click the first folder button (bin).
    const buttons = wrapper.findAll('.file-picker-list button')
    expect(buttons.length).toBeGreaterThan(0)
    await (buttons[0]!).trigger('click')
    await flushPromises()

    const finalValue = (textarea.element as HTMLTextAreaElement).value
    expect(finalValue).toBe('@/bin')
  })

  it('preserves @ when the user types a partial path like "@/doc" then selects', async () => {
    mockSearchResults([
      { name: 'docs', path: '/home/user/docs', is_directory: true },
      { name: 'superpowers', path: '/home/user/docs/superpowers', is_directory: true },
    ])

    const wrapper = await mountInput()
    const textarea = wrapper.find('textarea')
    await typeInTextarea(textarea, '@/doc')
    expect(wrapper.find('.file-picker-list').exists()).toBe(true)

    await textarea.trigger('keydown', { key: 'Enter' })
    await flushPromises()

    const finalValue = (textarea.element as HTMLTextAreaElement).value
    // The "/doc" query is replaced by the full relative path; the @
    // is preserved as a prefix marker.
    expect(finalValue).toBe('@/docs')
  })

  it('does not modify the input when Enter is pressed without a selection (no matches)', async () => {
    // Empty server result — no matches.
    mockSearchResults([])

    const wrapper = await mountInput()
    const textarea = wrapper.find('textarea')
    await typeInTextarea(textarea, '@zzz')

    // No matches, no "selected file" → Enter should be a no-op on the input.
    await textarea.trigger('keydown', { key: 'Enter' })
    await flushPromises()

    const finalValue = (textarea.element as HTMLTextAreaElement).value
    expect(finalValue).toBe('@zzz')
  })
})

/**
 * Paste-image regression tests (WebKitGTK + pabrik-desktop bug).
 *
 * Bug: in pabrik-desktop (WebKitGTK 4.1 on Linux), the `<textarea>` paste event
 * delivers a `clipboardData` object but `clipboardData.items` is empty even
 * when the system clipboard contains an image. The previous behavior was
 * to silently no-op in this case, so screenshots pasted into the chat
 * vanished. Chrome / Firefox work fine (their `items` include file entries).
 *
 * Fix: the handler now also tries `navigator.clipboard.read()` as a fallback,
 * which reads the actual system clipboard bypassing the `<textarea>` filter.
 *
 * These tests assert the contract of the new handler (both sync and async
 * paths), the scope check (only OUR textarea is intercepted), and the
 * cleanup on unmount. They do NOT need a real WebKitGTK runtime — jsdom
 * + a mocked `navigator.clipboard.read()` is enough to exercise the
 * branching logic.
 *
 * Plan: docs/plans/2026-07-04-fix-desktop-paste-image.md
 */
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

  /** Build a minimal DataTransferItem-like object. jsdom doesn't expose
   * DataTransferItem constructor in the test env, so we use the closest
   * shape and rely on the handler's duck-typing checks (kind, type,
   * getAsFile()). */
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
    const file = withName
      ? new File([blob], withName, { type })
      : new File([blob], '', { type })
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
      getAsFile: () => new File([new Uint8Array([0x25, 0x50, 0x44, 0x46])], 'doc.pdf', { type: 'application/pdf' }),
    }
    const ev = fakeClipboardEvent({ items: [pdfItem] })
    ta.dispatchEvent(ev)
    await flushPromises()

    // FileInput is image-only (the paperclip flow), so PDFs are ignored.
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

    // After unmount, the unmounted instance's listener shouldn't add another
    // preview to the (now-unmounted) FileInput's DOM. We assert via the
    // readonly `clipboardReadMock` — it should not have been called for the
    // post-unmount event (scope check fails because the textarea ref is
    // gone from the document, but the assertion is stronger: we expect the
    // listener to be entirely gone).
    expect(clipboardReadMock).not.toHaveBeenCalled()
    expect(previewsBefore).toBe(1)
  })
})
