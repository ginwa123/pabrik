/** Tests for the async lazy-media gallery in KanbanTaskDetailDialog (media-flags change). List/get
 * carry only `is_have_image` / `is_have_video` flags; the dialog fetches the full payload in the
 * background (fire-and-forget `void fetchTaskMedia(...)` — dialog open never blocks on it). */
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { flushPromises, mount, type VueWrapper } from '@vue/test-utils'
import { setActivePinia, createPinia } from 'pinia'
import { nextTick } from 'vue'

import KanbanTaskDetailDialog from '@/components/kanban/KanbanTaskDetailDialog.vue'
import type { Task } from '@/stores/workspaces'

const TINY_PNG_DATA_URL =
  'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=='

function makeTask(overrides: Partial<Task> = {}): Task {
  return {
    id: 'task_media_1',
    name: 'media task',
    description: '',
    tags: [],
    is_auto_retry_until_stop: '0',
    createdAt: new Date('2026-09-21T00:00:00Z'),
    updatedAt: new Date('2026-09-21T00:00:00Z'),
    ...overrides,
  }
}

async function mountEditDialog(task: Task): Promise<VueWrapper> {
  document.body.innerHTML = ''
  const wrapper = mount(KanbanTaskDetailDialog, {
    attachTo: document.body,
    props: { show: true, mode: 'edit', task },
  })
  await nextTick()
  await flushPromises()
  return wrapper
}

describe('KanbanTaskDetailDialog — lazy media loading hint', () => {
  let wrapper: VueWrapper | null = null

  beforeEach(() => {
    setActivePinia(createPinia())
  })

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    document.body.innerHTML = ''
  })

  it('shows the loading hint when the flag is set but media is not loaded yet', async () => {
    wrapper = await mountEditDialog(makeTask({ is_have_image: true, imageUrls: [] }))
    expect(
      document.querySelector('[data-testid="kanban-task-detail-media-loading"]'),
    ).not.toBeNull()
    expect(document.querySelector('[data-testid="kanban-task-detail-image-gallery"]')).toBeNull()
  })

  it('renders the gallery (no hint) once imageUrls are loaded', async () => {
    wrapper = await mountEditDialog(
      makeTask({ is_have_image: true, imageUrls: [TINY_PNG_DATA_URL] }),
    )
    expect(
      document.querySelector('[data-testid="kanban-task-detail-image-gallery"]'),
    ).not.toBeNull()
    expect(document.querySelector('[data-testid="kanban-task-detail-media-loading"]')).toBeNull()
  })

  it('renders neither gallery nor hint when the task has no media flags', async () => {
    wrapper = await mountEditDialog(makeTask({}))
    expect(document.querySelector('[data-testid="kanban-task-detail-image-gallery"]')).toBeNull()
    expect(document.querySelector('[data-testid="kanban-task-detail-media-loading"]')).toBeNull()
  })
})
