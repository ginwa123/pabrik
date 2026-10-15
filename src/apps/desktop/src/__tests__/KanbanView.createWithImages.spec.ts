/** Tests for KanbanView.handleCreateTaskSave's create flow with create-mode image attachments
 * (plan: 2026-08-06-kanban-image-urls-column, Migration 069). UPDATED for the 2026-08-14
 * kanban-specific endpoint refactor. */
/** The create flow now uses `addKanbanTask` (single round-trip to the /api/.../kanban/tasks
 * endpoint). */
/** The image_urls column is populated server-side inside the createStandardTask useCase (the body
 * forwards imageUrls → backend INSERT writes the column → the chatview's first user message renders
 * them as thumbnails). The description stays plain text — no `data:image/` anywhere. */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { flushPromises, mount, type VueWrapper } from '@vue/test-utils'
import { setActivePinia, createPinia } from 'pinia'

import KanbanView from '@/components/kanban/KanbanView.vue'
import { useWorkspacesStore } from '@/stores/workspaces'

interface PreviewFile {
  file: File
  previewUrl: string
}

vi.mock('@/components/kanban/KanbanColumn.vue', () => ({
  default: { name: 'KanbanColumn', template: '<div />' },
}))
vi.mock('@/components/kanban/KanbanSearchInput.vue', () => ({
  default: { name: 'KanbanSearchInput', template: '<div />' },
}))
vi.mock('@/components/kanban/KanbanTaskDetailDialog.vue', () => ({
  default: {
    name: 'KanbanTaskDetailDialog',
    template: '<div data-testid="stub-dialog" />',
  },
}))
vi.mock('@/composables/useKanbanScrollRestore', () => ({
  useKanbanScrollRestore: () => ({}),
}))
vi.mock('@/components/preview/InlineEditableText.vue', () => ({
  default: { name: 'InlineEditableText', template: '<div />' },
}))

 
// eslint-disable-next-line @typescript-eslint/no-explicit-any
const ITEM: any = {
  id: 'item_1',
  name: 'Kanban',
  path: '/home/u/proj',
  tasks: [],
  kanban_columns: [
    { id: 'col_todo', name: 'todo', position: 0, workspace_item_id: 'item_1' },
  ],
}

function makeFile(name: string): File {
  const bytes = new Uint8Array([
    0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d,
    0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
    0x08, 0x06, 0x00, 0x00, 0x00, 0x1f, 0x15, 0xc4, 0x89, 0x00, 0x00, 0x00,
    0x0d, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9c, 0x63, 0x00, 0x01, 0x00, 0x00,
    0x05, 0x00, 0x01, 0x0d, 0x0a, 0x2d, 0xb4, 0x00, 0x00, 0x00, 0x00, 0x49,
    0x45, 0x4e, 0x44, 0xae, 0x42, 0x60, 0x82,
  ])
  return new File([bytes], name, { type: 'image/png' })
}

function installFileReaderStub() {
  const originalReader = globalThis.FileReader
  class StubReader {
    public onload: ((ev: ProgressEvent<FileReader>) => void) | null = null
    public onerror: ((ev: ProgressEvent<FileReader>) => void) | null = null
    public result: string | null = null
    readAsDataURL(blob: Blob) {
      const mime = (blob as File).type || 'application/octet-stream'
      const name = (blob as File).name ?? 'blob'
      this.result = `data:${mime};base64,STUB_FOR_${name}`
      setTimeout(() => {
        this.onload?.({} as ProgressEvent<FileReader>)
      }, 0)
    }
  }
  globalThis.FileReader = StubReader as unknown as typeof FileReader
  return () => {
    globalThis.FileReader = originalReader
  }
}

describe('KanbanView.handleCreateTaskSave — image_urls via /kanban/tasks (Migration 069 + 2026-08-14 refactor)', () => {
  let wrapper: VueWrapper | null = null
  let restoreReader: (() => void) | null = null

  beforeEach(() => {
    setActivePinia(createPinia())
    vi.restoreAllMocks()
    restoreReader = installFileReaderStub()
  })

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    restoreReader?.()
    restoreReader = null
  })

  async function mountView() {
    wrapper = mount(KanbanView, {
      props: {
        item: structuredClone(ITEM),
        workspaceId: 'ws_1',
        itemId: 'item_1',
      },
    })
     
    await flushPromises()
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    ;(wrapper!.vm as any).activeCreateColumnId = 'col_todo'
    return wrapper!
  }

  it('create + run: forwards imageUrls to addKanbanTask (server-side INSERT handles the column)', async () => {
    const store = useWorkspacesStore()
    const fakeTask = {
      id: 'task_new',
       
      name: 'Bug screenshot',
      task_type: 'standard',
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    } as any
    const addKanbanSpy = vi
      .spyOn(store, 'addKanbanTask')
      .mockResolvedValue({ task: fakeTask, session: { id: 'task_new', name: 'Bug screenshot', status: 'send' } })
    const moveSpy = vi.spyOn(store, 'moveTaskToColumn').mockResolvedValue(undefined)

    const view = await mountView()
    const pendingFiles: PreviewFile[] = [
       
      { file: makeFile('one.png'), previewUrl: 'blob:1' },
      { file: makeFile('two.jpg'), previewUrl: 'blob:2' },
    ]
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    await (view.vm as any).handleCreateTaskSave({
      mode: 'create_and_run',
      name: 'Bug screenshot',
      description: 'See screenshots',
      is_auto_retry_until_stop: '0',
      tags: [],
      pendingFiles,
    })
    await new Promise((resolve) => setTimeout(resolve, 30))
     
    await flushPromises()

    // 1. addKanbanTask was called with the imageUrls array.
    expect(addKanbanSpy).toHaveBeenCalledTimes(1)
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const callArgs = addKanbanSpy.mock.calls[0] as [string, string, string, any]
    expect(callArgs[2]).toBe('create_and_run')
    const payload = callArgs[3]
    expect(payload.name).toBe('Bug screenshot')
    expect(payload.description).toBe('See screenshots')
    expect(Array.isArray(payload.imageUrls)).toBe(true)
    expect(payload.imageUrls.length).toBe(2)
    expect(payload.imageUrls[0]).toMatch(/^data:image\/png;base64,/)
    expect(payload.imageUrls[0]).toContain('STUB_FOR_one.png')
    expect(payload.imageUrls[1]).toContain('STUB_FOR_two.jpg')

    // 2. queue_message is plain text (no base64).
    expect(payload.queue_message).toBe('Task : Bug screenshot\nDescription: See screenshots')

    // 3. moveTaskToColumn ran.
    expect(moveSpy).toHaveBeenCalledWith(
      'ws_1',
      'item_1',
      'task_new',
      'col_todo',
      0,
    )
  })

  it('plain create mode (no run): forwards imageUrls to addKanbanTask', async () => {
     
    const store = useWorkspacesStore()
    const fakeTask = {
      id: 'task_new',
      name: 'To edit later',
      task_type: 'standard',
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    } as any
     
    const addKanbanSpy = vi
      .spyOn(store, 'addKanbanTask')
      .mockResolvedValue({ task: fakeTask, session: null })
    const moveSpy = vi.spyOn(store, 'moveTaskToColumn').mockResolvedValue(undefined)

    const view = await mountView()
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    await (view.vm as any).handleCreateTaskSave({
      mode: 'create',
      name: 'To edit later',
      description: 'User typed text',
      is_auto_retry_until_stop: '0',
      tags: [],
      pendingFiles: [{ file: makeFile('one.png'), previewUrl: 'blob:1' }],
    })
    await new Promise((resolve) => setTimeout(resolve, 30))
    await flushPromises()

    expect(addKanbanSpy).toHaveBeenCalledTimes(1)
    const payload = addKanbanSpy.mock.calls[0]![3] as Record<string, unknown>
    expect(payload.description).toBe('User typed text')
    expect(Array.isArray(payload.imageUrls)).toBe(true)
    expect((payload.imageUrls as string[]).length).toBe(1)
     
    expect((payload.imageUrls as string[])[0]).toContain('STUB_FOR_one.png')

    expect(moveSpy).toHaveBeenCalledWith('ws_1', 'item_1', 'task_new', 'col_todo', 0)
  })

  it('create + run with NO pending files: imageUrls defaults to empty array', async () => {
    const store = useWorkspacesStore()
     
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const fakeTask = { id: 'task_new', name: 'No images', task_type: 'standard' } as any
    const addKanbanSpy = vi
      .spyOn(store, 'addKanbanTask')
      .mockResolvedValue({ task: fakeTask, session: { id: 'task_new', name: 'No images', status: 'send' } })
    vi.spyOn(store, 'moveTaskToColumn').mockResolvedValue(undefined)

    const view = await mountView()
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    await (view.vm as any).handleCreateTaskSave({
      mode: 'create_and_run',
      name: 'No images',
      description: 'Just text',
      is_auto_retry_until_stop: '0',
      tags: [],
      pendingFiles: [],
    })
    await flushPromises()

    expect(addKanbanSpy).toHaveBeenCalledTimes(1)
    const payload = addKanbanSpy.mock.calls[0]![3] as Record<string, unknown>
    expect(Array.isArray(payload.imageUrls)).toBe(true)
    expect((payload.imageUrls as string[]).length).toBe(0)
  })
})
