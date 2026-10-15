/**
 * Tests for KanbanDescriptionEditor — the kanban task description editor
 * with image paste/paperclip support and the `@`-trigger file picker.
 *
 * The component is a textarea wrapper that:
 *   - Holds the markdown text as v-model.
 *   - Shows image previews (paste + paperclip) above the textarea.
 *   - Opens a file-picker dropdown when the user types `@`.
 *   - Inserts `@/path` at the cursor when a file is picked.
 *   - Downscales oversize images to 4 MB before base64-encoding.
 *
 * Test coverage:
 *   - v-model two-way binding (typing into the textarea emits update).
 *   - The paperclip button triggers the hidden file input.
 *   - @-trigger opens the dropdown (cwd passed to /system/folder).
 *   - Picking a file inserts `@/path` at the cursor.
 *   - Image paste inserts a data URL into the textarea + preview row.
 *   - Removing a preview removes the matching data URL from the textarea.
 *   - Char counter reflects the text length.
 *   - testId is applied to the textarea + paperclip + counter.
 *
 * Plan: docs/superpowers/plans/2026-07-25-kanban-description-rich-editor.md
 * Chunk 2 — KanbanDescriptionEditor component.
 */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { mount, flushPromises } from '@vue/test-utils'
import KanbanDescriptionEditor from '../components/kanban/KanbanDescriptionEditor.vue'
import * as api from '@/api'

vi.mock('@/api', async (importOriginal) => {
  const actual = await importOriginal<typeof import('@/api')>()
  return {
    ...actual,
    searchFiles: vi.fn(),
  }
})

const searchFilesMock = api.searchFiles as unknown as ReturnType<typeof vi.fn>

/** Mock `api.searchFiles` with pre-ranked server rows (Task 3: the server
 * owns ranking now — the old N-sequential-fetch full-tree walk via raw
 * `fetch` is deleted). The picker renders rows directly in server order. */
function mockSearchResults(
  entries: Array<{ name: string; path: string; is_directory: boolean }>,
) {
  searchFilesMock.mockResolvedValue({
    entries: entries.map((e) => ({ ...e, is_symlink: false })),
  })
}

const originalFetch = global.fetch
const fetchMock = vi.fn()

async function mountEditor(
  propsOverride: Record<string, unknown> = {},
  options: { attachTo?: boolean } = {},
) {
  document.body.innerHTML = ''
  const wrapper = mount(KanbanDescriptionEditor, {
    attachTo: options.attachTo ? document.body : undefined,
    props: {
      modelValue: '',
      cwd: '/home/user',
      ...propsOverride,
    },
  })
  await flushPromises()
  return wrapper
}

describe('KanbanDescriptionEditor', () => {
  beforeEach(() => {
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

  it('renders a textarea with the modelValue as its initial value', async () => {
    const wrapper = await mountEditor({ modelValue: 'hello world' })
    const textarea = wrapper.find('textarea').element as HTMLTextAreaElement
    expect(textarea.value).toBe('hello world')
  })

  it('emits update:modelValue when the user types into the textarea', async () => {
    const wrapper = await mountEditor({ modelValue: '' })
    const textarea = wrapper.find('textarea')
    await textarea.setValue('a new description')
    expect(wrapper.emitted('update:modelValue')).toBeTruthy()
    const emitted = wrapper.emitted('update:modelValue') as unknown[][] | undefined
    expect(emitted?.[emitted.length - 1]?.[0]).toBe('a new description')
  })

  it('shows the char counter as <textLength> chars (unlimited by default)', async () => {
    const wrapper = await mountEditor({ modelValue: 'hello world' })
    expect(wrapper.text()).toContain('11 chars')
  })

  it('does not set a maxlength on the textarea by default (unlimited)', async () => {
    const wrapper = await mountEditor({ modelValue: 'hello world' })
    const textarea = wrapper.find('textarea').element as HTMLTextAreaElement
    expect(textarea.getAttribute('maxlength')).toBeNull()
  })

  it('applies the testId prop to the textarea, paperclip, and counter', async () => {
    const wrapper = await mountEditor({
      modelValue: '',
      testId: 'my-editor',
    })
    const html = wrapper.html()
    expect(html).toContain('data-testid="my-editor"')
    expect(html).toContain('my-editor-paperclip')
    expect(html).toContain('my-editor-counter')
  })

  it('defaults testId to "kanban-description-editor"', async () => {
    const wrapper = await mountEditor({ modelValue: '' })
    expect(wrapper.html()).toContain('kanban-description-editor')
  })

  it('shows a hidden file input for native image selection', async () => {
    const wrapper = await mountEditor({}, { attachTo: true })
    const hidden = wrapper.find('input[type="file"]')
    expect(hidden.exists()).toBe(true)
    // Should be visually hidden (display:none or class="hidden").
    const cls = hidden.classes()
    expect(cls).toContain('hidden')
  })

  it('opens the file picker dropdown when the user types @ and inserts /path on selection', async () => {
    // Server owns ranking: pre-ranked rows in server order (dirs-first
    // here, mirroring the old client sort). The file button is at
    // index 1.
    mockSearchResults([
      {
        name: 'docs',
        path: '/home/user/docs',
        is_directory: true,
      },
      {
        name: 'main.zig',
        path: '/home/user/main.zig',
        is_directory: false,
      },
    ])
    const wrapper = await mountEditor({}, { attachTo: true })
    const textarea = wrapper.find('textarea')
    // Type `@` to trigger the picker.
    await textarea.setValue('@')
    const element = textarea.element as HTMLTextAreaElement
    element.setSelectionRange(1, 1)
    element.dispatchEvent(new Event('input', { bubbles: true }))
    // Wait for BOTH debounces (150ms `@`-detect + 150ms server-search).
    await new Promise((resolve) => setTimeout(resolve, 450))
    await flushPromises()
    const html = wrapper.html()
    expect(html).toContain('file-picker-list')
    // Pick the file (main.zig, not the docs directory). The component
    // sorts directories-first, so the file button is at index 1.
    const fileButtons = wrapper.findAll('.file-picker-list button')
    expect(fileButtons.length).toBe(2)
    await fileButtons[1]!.trigger('click')
    await flushPromises()
    const updatedTextarea = wrapper.find('textarea').element as HTMLTextAreaElement
    // The path is inserted WITHOUT the leading `@` (the user dropped the `@` prefix per the latest
    // UX feedback; the chip detector matches `/path` directly). The path is RELATIVE to the cwd
    // (mirrors FileInput.vue's `entry.path.replace(rootPath, '')`).
    expect(updatedTextarea.value).toContain('/main.zig')
    expect(updatedTextarea.value).not.toContain('@/main.zig')
  })

  it('removes an image preview when the user clicks the remove button', async () => {
    // Seed the modelValue with a base64 image so the editor re-hydrates
    // the preview on mount.
    const png =
      'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII='
    const wrapper = await mountEditor({
      modelValue: `![pasted](${png})`,
    })
    await flushPromises()
    // Preview row should render the image.
    expect(wrapper.findAll('.preview-item').length).toBe(1)
    // Click the remove button.
    const removeBtn = wrapper.find('.remove-btn')
    expect(removeBtn.exists()).toBe(true)
    await removeBtn.trigger('click')
    await flushPromises()
    // The emitted update:modelValue should no longer contain the data URL.
    const emitted = wrapper.emitted('update:modelValue') as unknown[][] | undefined
    const lastEmit = emitted?.[emitted.length - 1]?.[0] as string
    expect(lastEmit).not.toContain('data:image/png')
  })

  it('respects the custom maxLength prop', async () => {
    const wrapper = await mountEditor({ modelValue: 'hi', maxLength: 200 })
    expect(wrapper.text()).toContain('2 / 200')
  })
})

/**
 * Tests for create-mode image paste (no taskId yet).
 *
 * Bug: when the dialog opens in create mode (taskId=''), pasting an image
 * used to fall back to writing the inline `data:image/png;base64,…` payload
 * into the description text. A 4 MB image → ~5.5 MB of base64 → the
 * counter showed 487 052 / 5000 and the task couldn't be saved.
 *
 * Fix: in create mode, the editor stages pasted images in a `pendingFiles`
 * array exposed via defineExpose. The description textarea is NOT modified.
 * The host (KanbanView.handleCreateTaskSave) reads pendingFiles AFTER the
 * task is created (and has a real taskId), uploads each via the existing
 * `api.uploadTaskAttachment` endpoint, then PATCHes the description with
 * appended `![name](url)` markdown.
 *
 * These tests exercise the editor's side of the contract: no base64 in the
 * description, the file lands in pendingFiles, removing the preview drops
 * the file from pendingFiles, and editing the existing task still uploads
 * inline (the legacy contract from before this fix).
 */
describe('KanbanDescriptionEditor — create-mode image paste (no taskId)', () => {
  // Minimal valid PNG (1x1 transparent) so the editor does not try to
  // decode/parse anything during the test — we only care about the
  // (description, previewFiles, pendingFiles) state machine.
  const TINY_PNG = new Uint8Array([
    0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d,
    0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
    0x08, 0x06, 0x00, 0x00, 0x00, 0x1f, 0x15, 0xc4, 0x89, 0x00, 0x00, 0x00,
    0x0d, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9c, 0x63, 0x00, 0x01, 0x00, 0x00,
    0x05, 0x00, 0x01, 0x0d, 0x0a, 0x2d, 0xb4, 0x00, 0x00, 0x00, 0x00, 0x49,
    0x45, 0x4e, 0x44, 0xae, 0x42, 0x60, 0x82,
  ])

  function makeFile(name = 'pasted-image.png'): File {
    return new File([TINY_PNG], name, { type: 'image/png' })
  }

  /**
   * Build a minimal DataTransferItem-like object. jsdom doesn't expose
   * DataTransferItem constructor in the test env, so we use the closest
   * shape and rely on the handler's duck-typing checks (kind, type,
   * getAsFile()).
   */
  function fakeImageItem(
    file: File,
  ): {
    kind: string
    type: string
    getAsFile: () => File
  } {
    return {
      kind: 'file',
      type: file.type || 'image/png',
      getAsFile: () => file,
    }
  }

  /**
   * Build a synthetic ClipboardEvent with a fake clipboardData. jsdom
   * doesn't expose a ClipboardEvent constructor (DOM v0.x), so we use
   * `new Event('paste', …)` and define `clipboardData` as a property.
   * Mirrors the same pattern used in FileInput.spec.ts.
   */
  function fakeClipboardEvent(file: File): ClipboardEvent {
    const item = fakeImageItem(file)
    const dataTransfer = {
      items: [item],
      get length() {
        return 1
      },
      files: [file],
      types: [file.type],
    } as unknown as DataTransfer
    const ev = new Event('paste', { bubbles: true, cancelable: true }) as unknown as ClipboardEvent
    Object.defineProperty(ev, 'clipboardData', { value: dataTransfer })
    return ev
  }

  // Simulate the editor's `handlePaste` flow: dispatch a synthetic PasteEvent
  // with the file item, which keeps the test scoped to the public API
  // and avoids depending on internal function names.
  async function pasteImage(wrapper: ReturnType<typeof mount>, file: File) {
    const event = fakeClipboardEvent(file)
    const textarea = wrapper.find('textarea').element as HTMLTextAreaElement
    textarea.dispatchEvent(event)
    // addImageFile awaits FileReader.onload which fires on the next macrotask (not microtask) tick
    // — flushPromises alone isn't enough. A short setTimeout gives FileReader time to encode the
    // File into a data URL before we read the textarea.
    await new Promise((resolve) => setTimeout(resolve, 50))
    await flushPromises()
  }

  beforeEach(() => {
    fetchMock.mockReset()
    global.fetch = fetchMock as unknown as typeof fetch
    searchFilesMock.mockReset()
    searchFilesMock.mockResolvedValue({ entries: [] })
  })

  afterEach(() => {
    global.fetch = originalFetch
    vi.restoreAllMocks()
  })

  it('does NOT insert base64 into the description when pasting in create mode', async () => {
    // taskId defaults to '' in mountEditor → create-mode editor.
    const wrapper = await mountEditor({ modelValue: '' })
    await pasteImage(wrapper, makeFile('screenshot.png'))

    const textarea = wrapper.find('textarea').element as HTMLTextAreaElement
    expect(textarea.value).toBe('')
    expect(textarea.value).not.toContain('data:image/')
    expect(textarea.value).not.toContain('base64')
  })

  it('stages pasted image in pendingFiles (defineExpose) without modifying text', async () => {
    const wrapper = await mountEditor({ modelValue: '' })
    await pasteImage(wrapper, makeFile('screenshot.png'))

    const exposed = wrapper.vm as unknown as {
      pendingFiles: Array<{ file: File; previewUrl: string }>
    }
    // pendingFiles is exposed for the host to upload after task creation.
    expect(exposed.pendingFiles).toBeTruthy()
    expect(Array.isArray(exposed.pendingFiles)).toBe(true)
    expect(exposed.pendingFiles.length).toBe(1)
    expect(exposed.pendingFiles[0]?.file.name).toBe('screenshot.png')
    expect(exposed.pendingFiles[0]?.previewUrl).toMatch(/^blob:/)
  })

  it('renders a preview row in create mode (so the user sees the image)', async () => {
    const wrapper = await mountEditor({ modelValue: '' }, { attachTo: true })
    await pasteImage(wrapper, makeFile('screenshot.png'))

    expect(wrapper.findAll('.preview-item').length).toBe(1)
  })

  it('removes file from pendingFiles when the user deletes the preview', async () => {
    const wrapper = await mountEditor({ modelValue: '' }, { attachTo: true })
    await pasteImage(wrapper, makeFile('screenshot.png'))

    const exposed = wrapper.vm as unknown as {
      pendingFiles: Array<{ file: File; previewUrl: string }>
    }
    expect(exposed.pendingFiles.length).toBe(1)

    const removeBtn = wrapper.find('.remove-btn')
    expect(removeBtn.exists()).toBe(true)
    await removeBtn.trigger('click')
    await flushPromises()

    expect(exposed.pendingFiles.length).toBe(0)
    expect(wrapper.findAll('.preview-item').length).toBe(0)
  })

  it('stages multiple pastes (multiple files accumulate in pendingFiles)', async () => {
    const wrapper = await mountEditor({ modelValue: '' })
    await pasteImage(wrapper, makeFile('one.png'))
    await pasteImage(wrapper, makeFile('two.png'))
    await pasteImage(wrapper, makeFile('three.png'))

    const exposed = wrapper.vm as unknown as {
      pendingFiles: Array<{ file: File; previewUrl: string }>
    }
    expect(exposed.pendingFiles.length).toBe(3)
    expect(exposed.pendingFiles.map((p) => p.file.name)).toEqual([
      'one.png',
      'two.png',
      'three.png',
    ])
    // Description still untouched.
    const textarea = wrapper.find('textarea').element as HTMLTextAreaElement
    expect(textarea.value).toBe('')
  })

  it('keeps typed text intact when an image is pasted alongside it', async () => {
    const wrapper = await mountEditor({ modelValue: '' })
    await wrapper.find('textarea').setValue('User typed description')
    await pasteImage(wrapper, makeFile('chart.png'))

    const textarea = wrapper.find('textarea').element as HTMLTextAreaElement
    expect(textarea.value).toBe('User typed description')
    expect(textarea.value).not.toContain('data:image/')

    const exposed = wrapper.vm as unknown as {
      pendingFiles: Array<{ file: File; previewUrl: string }>
    }
    expect(exposed.pendingFiles.length).toBe(1)
  })

  it('edit mode stages the pasted file into pendingFiles for the host to PATCH (Migration 069)', async () => {
    // Migration 069 changed edit mode to use the same staged-
    // pendingFiles flow as create mode (the old `uploadTaskAttachment`
    // endpoint was deleted entirely). The editor's job is just to
    // expose the file; the host's `updateTaskDetails({ imageUrls })`
    // does the persistence. The textarea stays untouched — the
    // new column carries the images.
    const wrapper = await mountEditor({ modelValue: '', taskId: 'task_x' })
    await pasteImage(wrapper, makeFile('inline.png'))

    const exposed = wrapper.vm as unknown as {
      pendingFiles: Array<{ file: File; previewUrl: string }>
    }
    expect(exposed.pendingFiles.length).toBe(1)
    expect(exposed.pendingFiles[0]!.file.name).toBe('inline.png')

    const textarea = wrapper.find('textarea').element as HTMLTextAreaElement
    // Description text is NEVER touched — no `data:image/`, no
    // `base64,`, no upload URL. The image lives on the image_urls
    // column instead.
    expect(textarea.value).not.toContain('data:image/')
    expect(textarea.value).not.toContain('base64,')
    expect(textarea.value).not.toContain('/api/')
  })
})