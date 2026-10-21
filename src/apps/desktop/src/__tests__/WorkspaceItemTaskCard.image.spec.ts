/** Behavioural tests for the image thumbnail strip in WorkspaceItemTaskCard (kanban board card). */
import { describe, expect, it, beforeEach } from 'vitest'
import { mount } from '@vue/test-utils'
import { setActivePinia, createPinia } from 'pinia'
import WorkspaceItemTaskCard from '@/components/workspace/WorkspaceItemTaskCard.vue'
import type { Task } from '@/stores/workspaces'

function makeTask(overrides: Partial<Task> = {}): Task {
  return {
    id: 'task_1',
    name: 'Test',
    task_type: 'standard',
    ...overrides,
  }
}

const PNG_URL = 'data:image/png;base64,iVBORw0KGgo='
const JPEG_URL = 'data:image/jpeg;base64,/9j/4AAQ'

describe('WorkspaceItemTaskCard — image thumbnail', () => {
  beforeEach(() => setActivePinia(createPinia()))

  it('renders the first image as a thumbnail when task.imageUrls has one', () => {
    const wrapper = mount(WorkspaceItemTaskCard, {
      props: {
        task: makeTask({ imageUrls: [PNG_URL] }),
        workspaceId: 'ws_1',
        itemId: 'item_1',
      },
    })
    const thumb = wrapper.find('[data-testid="task-image-thumb"]')
    expect(thumb.exists()).toBe(true)
    expect(thumb.attributes('src')).toBe(PNG_URL)
    // No +N badge for a single image.
    expect(wrapper.find('[data-testid="task-image-more"]').exists()).toBe(false)
  })

  it('shows the first image + a +N badge when multiple images exist', () => {
    const wrapper = mount(WorkspaceItemTaskCard, {
      props: {
        task: makeTask({ imageUrls: [PNG_URL, JPEG_URL, PNG_URL] }),
        workspaceId: 'ws_1',
        itemId: 'item_1',
      },
    })
    const thumb = wrapper.find('[data-testid="task-image-thumb"]')
    expect(thumb.exists()).toBe(true)
    // FIRST image wins (not the last).
    expect(thumb.attributes('src')).toBe(PNG_URL)
    const more = wrapper.find('[data-testid="task-image-more"]')
    expect(more.exists()).toBe(true)
    expect(more.text()).toBe('+2')
  })

  it('renders no thumbnail when imageUrls is an empty array', () => {
    const wrapper = mount(WorkspaceItemTaskCard, {
      props: {
        task: makeTask({ imageUrls: [] }),
        workspaceId: 'ws_1',
        itemId: 'item_1',
      },
    })
    expect(wrapper.find('[data-testid="task-image-thumb"]').exists()).toBe(false)
  })

  it('renders no thumbnail when imageUrls is undefined (legacy task)', () => {
    const wrapper = mount(WorkspaceItemTaskCard, {
      props: {
        task: makeTask(),
        workspaceId: 'ws_1',
        itemId: 'item_1',
      },
    })
    expect(wrapper.find('[data-testid="task-image-thumb"]').exists()).toBe(false)
  })

  it('clicking the thumbnail emits viewTaskDetail (opens the detail dialog)', async () => {
    const wrapper = mount(WorkspaceItemTaskCard, {
      props: {
        task: makeTask({ imageUrls: [PNG_URL] }),
        workspaceId: 'ws_1',
        itemId: 'item_1',
      },
    })
    await wrapper.find('[data-testid="task-image-thumb"]').trigger('click')
    expect(wrapper.emitted('viewTaskDetail')).toBeTruthy()
    expect(wrapper.emitted('viewTaskDetail')![0]).toEqual(['task_1'])
  })
})
