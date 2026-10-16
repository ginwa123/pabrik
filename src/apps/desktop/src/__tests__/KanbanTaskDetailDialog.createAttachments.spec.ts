/** Tests for the create-mode image-attach workflow (plan: 2026-08-06- kanban-no-base64-in-desc). */
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { flushPromises, mount, type VueWrapper } from '@vue/test-utils'
import { setActivePinia, createPinia } from 'pinia'

import KanbanTaskDetailDialog from '@/components/kanban/KanbanTaskDetailDialog.vue'

const TINY_PNG = new Uint8Array([
  0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d,
  0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1f, 0x15, 0xc4, 0x89, 0x00, 0x00, 0x00,
  0x0d, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9c, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0d, 0x0a, 0x2d, 0xb4, 0x00, 0x00, 0x00, 0x00, 0x49,
  0x45, 0x4e, 0x44, 0xae, 0x42, 0x60, 0x82,
])

function makeFile(name: string): File {
  return new File([TINY_PNG], name, { type: 'image/png' })
}

function fakeClipboardEvent(file: File): ClipboardEvent {
  const item = {
    kind: 'file',
    type: file.type,
    getAsFile: () => file,
  }
  const dataTransfer = {
    items: [item],
    get length() { return 1 },
    files: [file],
    types: [file.type],
  } as unknown as DataTransfer
  const ev = new Event('paste', { bubbles: true, cancelable: true }) as unknown as ClipboardEvent
  Object.defineProperty(ev, 'clipboardData', { value: dataTransfer })
  return ev
}

async function pasteImage(textareaSelector: string, file: File) {
  const ta = document.querySelector<HTMLTextAreaElement>(textareaSelector)
  if (!ta) throw new Error(`No textarea found: ${textareaSelector}`)
  ta.dispatchEvent(fakeClipboardEvent(file))
  // FileReader.onload needs an event-loop tick — flushPromises alone
  // is not enough (microtask vs macrotask).
  await new Promise((resolve) => setTimeout(resolve, 50))
  await flushPromises()
}

function findInDom<T extends Element = Element>(selector: string): T | null {
  return document.querySelector<T>(selector)
}

function findAllInDom<T extends Element = Element>(selector: string): T[] {
  return Array.from(document.querySelectorAll<T>(selector))
}

function clickInDom(selector: string) {
  const el = findInDom<HTMLElement>(selector)
  if (!el) throw new Error(`No element found: ${selector}`)
  el.click()
}

function setInputValue(selector: string, value: string) {
  const el = findInDom<HTMLInputElement | HTMLTextAreaElement>(selector)
  if (!el) throw new Error(`No element found: ${selector}`)
  el.value = value
  el.dispatchEvent(new Event('input', { bubbles: true }))
}

describe('KanbanTaskDetailDialog — create mode image attachments', () => {
  let wrapper: VueWrapper | null = null

  beforeEach(() => {
    document.body.innerHTML = ''
    setActivePinia(createPinia())
  })

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    findAllInDom('[data-testid="kanban-task-detail-dialog"]').forEach((el) =>
      el.remove(),
    )
  })

  function mountCreateDialog() {
    wrapper = mount(KanbanTaskDetailDialog, {
      attachTo: document.body,
      props: { show: true, mode: 'create', task: null },
    })
    return wrapper!
  }

  it('emits create with empty pendingFiles when no images are pasted', async () => {
    const w = mountCreateDialog()
    await flushPromises()
    setInputValue('[data-testid="kanban-task-detail-create-name"]', 'Plain task')
    setInputValue(
      '[data-testid="kanban-task-detail-create-description"]',
      'Text only',
    )
    await flushPromises()
    clickInDom('[data-testid="kanban-task-detail-save"]')

    const emitted = w.emitted('create')
    expect(emitted).toBeTruthy()
     
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const payload = (emitted![0] as any[])[0]
    expect(payload.name).toBe('Plain task')
    expect(payload.description).toBe('Text only')
    // No images pasted → empty array (not undefined).
    expect(payload.pendingFiles).toBeDefined()
    expect(Array.isArray(payload.pendingFiles)).toBe(true)
    expect(payload.pendingFiles.length).toBe(0)
  })

  it('emits create with the staged file in pendingFiles (and NO base64 in description)', async () => {
    const w = mountCreateDialog()
    await flushPromises()
    setInputValue('[data-testid="kanban-task-detail-create-name"]', 'With image')
    setInputValue(
      '[data-testid="kanban-task-detail-create-description"]',
      'Some text before the image',
    )
    await flushPromises()

    await pasteImage(
      '[data-testid="kanban-task-detail-create-description"]',
      makeFile('screenshot.png'),
    )

    clickInDom('[data-testid="kanban-task-detail-save"]')

    const emitted = w.emitted('create')
     
    expect(emitted).toBeTruthy()
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const payload = (emitted![0] as any[])[0]
    // Description still has ONLY the user's text — no `data:image/`
    // payload, no `![name](…)` block (the editor doesn't insert it
    // until after upload, which happens server-side).
    expect(payload.description).toBe('Some text before the image')
    expect(payload.description).not.toContain('data:image/')
    expect(payload.description).not.toContain('base64')
    expect(payload.description).not.toContain('screenshot.png')
    // One pending file, with the right name and a blob: preview URL.
    expect(payload.pendingFiles.length).toBe(1)
    expect(payload.pendingFiles[0].file.name).toBe('screenshot.png')
    expect(payload.pendingFiles[0].previewUrl).toMatch(/^blob:/)
  })

  it('emits create with multiple pendingFiles when several images are pasted', async () => {
    const w = mountCreateDialog()
    await flushPromises()
    setInputValue('[data-testid="kanban-task-detail-create-name"]', 'Multi-image task')
    await flushPromises()

    await pasteImage(
      '[data-testid="kanban-task-detail-create-description"]',
      makeFile('one.png'),
    )
    await pasteImage(
      '[data-testid="kanban-task-detail-create-description"]',
      makeFile('two.png'),
    )

    clickInDom('[data-testid="kanban-task-detail-save"]')

     
    const emitted = w.emitted('create')
    expect(emitted).toBeTruthy()
     
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const payload = (emitted![0] as any[])[0]
    expect(payload.pendingFiles.length).toBe(2)
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    expect(payload.pendingFiles.map((p: any) => p.file.name)).toEqual([
      'one.png',
      'two.png',
    ])
    // Description untouched by the pastes.
    expect(payload.description).toBe('')
  })

  it('emits create-and-run with pendingFiles when the "Create task & run agent" button is used', async () => {
    const w = mountCreateDialog()
    await flushPromises()
    setInputValue('[data-testid="kanban-task-detail-create-name"]', 'Run with image')
    await flushPromises()

    await pasteImage(
      '[data-testid="kanban-task-detail-create-description"]',
      makeFile('chart.png'),
    )

     
    clickInDom('[data-testid="kanban-task-detail-create-and-run"]')

    const emitted = w.emitted('create-and-run')
    expect(emitted).toBeTruthy()
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const payload = (emitted![0] as any[])[0]
    expect(payload.mode).toBe('create_and_run')
    expect(payload.pendingFiles.length).toBe(1)
    expect(payload.pendingFiles[0].file.name).toBe('chart.png')
  })

  it('does NOT include pendingFiles in edit-mode save emit (legacy contract)', async () => {
    // Edit mode is unchanged — uploads happen inline via the editor
    // before the dialog ever sees the file. The save emit should keep
    // its current shape (no pendingFiles field).
    const task = {
      id: 'task_x',
      name: 'Edit me',
      description: 'Pre-existing description with ![existing](oldurl.png)',
      task_type: 'standard' as const,
    }
    wrapper = mount(KanbanTaskDetailDialog, {
      attachTo: document.body,
      props: { show: true, task, mode: 'edit' },
    })
    await flushPromises()
    // Trigger a save (name unchanged → still dirty via description change).
    setInputValue('[data-testid="kanban-task-detail-description"]', 'Edited text')
    await flushPromises()
    clickInDom('[data-testid="kanban-task-detail-save"]')
    const emitted = wrapper!.emitted('save')
    expect(emitted).toBeTruthy()
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const payload = (emitted![0] as any[])[0]
    // Edit-mode save stays free of pendingFiles — host doesn't need
    // to do anything post-upload (the editor already uploaded).
    expect(payload.pendingFiles).toBeUndefined()
  })
})
