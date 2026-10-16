/** Tests for the persisted-image gallery preview in KanbanTaskDetailDialog (edit mode — task
 * already created with imageUrls). Plan:
 * docs/superpowers/plans/2026-08-25-kanban-task-detail-image-preview.md */
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { flushPromises, mount, type VueWrapper } from '@vue/test-utils'
import { setActivePinia, createPinia } from 'pinia'
import { nextTick } from 'vue'

import KanbanTaskDetailDialog from '@/components/kanban/KanbanTaskDetailDialog.vue'
import type { Task } from '@/stores/workspaces'

const TINY_PNG_DATA_URL =
  'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=='
const TINY_PNG_DATA_URL_2 =
  'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGNgYGD4DwABBAEAfbLI3wAAAABJRU5ErkJggg=='

function makeTask(imageUrls: string[]): Task {
  return {
    id: 'task_existing_1',
    name: 'when open chatview why call many api',
    description: 'task?limit=100 ? like screenshot ?',
    tags: ['bugs'],
    cwd: '/home/ginwa/ginwaaitoolbox',
    imageUrls,
    is_auto_retry_until_stop: '0',
    createdAt: new Date('2026-08-23T00:00:00Z'),
    updatedAt: new Date('2026-08-23T00:00:00Z'),
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

function findInDom<T extends Element = Element>(selector: string): T | null {
  return document.querySelector<T>(selector)
}

function findAllInDom<T extends Element = Element>(selector: string): T[] {
  return Array.from(document.querySelectorAll<T>(selector))
}

describe('KanbanTaskDetailDialog — persisted image gallery preview', () => {
  let wrapper: VueWrapper | null = null

  beforeEach(() => {
    setActivePinia(createPinia())
  })

  afterEach(() => {
    wrapper?.unmount()
    wrapper = null
    document.body.innerHTML = ''
  })

  it('renders one thumbnail per persisted imageUrls entry in edit mode', async () => {
    wrapper = await mountEditDialog(makeTask([TINY_PNG_DATA_URL, TINY_PNG_DATA_URL_2]))

    const thumbs = findAllInDom<HTMLImageElement>(
      '[data-testid^="kanban-task-detail-image-"]:not([data-testid*="popup"]):not([data-testid$="gallery"])',
    )
    expect(thumbs).toHaveLength(2)
    expect(thumbs[0]?.src).toBe(TINY_PNG_DATA_URL)
    expect(thumbs[1]?.src).toBe(TINY_PNG_DATA_URL_2)
  })

  it('does not render the gallery when imageUrls is empty', async () => {
    wrapper = await mountEditDialog(makeTask([]))

    const gallery = findInDom(
      '[data-testid="kanban-task-detail-image-gallery"]',
    )
    expect(gallery).toBeNull()
  })

  it('clicking a thumbnail opens a Teleport overlay with the full-size image', async () => {
    wrapper = await mountEditDialog(makeTask([TINY_PNG_DATA_URL]))

    const thumb = findInDom<HTMLImageElement>(
      '[data-testid="kanban-task-detail-image-0"]',
    )
    expect(thumb).not.toBeNull()
    thumb!.click()
    await nextTick()
    await flushPromises()

    // The popup is Teleported to body — it must NOT live inside the
    // dialog tree (escapes overflow:hidden ancestors).
    const popupImg = findInDom<HTMLImageElement>(
      '[data-testid="kanban-task-detail-image-popup-img"]',
    )
    expect(popupImg).not.toBeNull()
    expect(popupImg!.src).toBe(TINY_PNG_DATA_URL)
  })

  it('pressing Escape closes the overlay', async () => {
    wrapper = await mountEditDialog(makeTask([TINY_PNG_DATA_URL]))

    const thumb = findInDom<HTMLImageElement>(
      '[data-testid="kanban-task-detail-image-0"]',
    )
    thumb!.click()
    await nextTick()
    await flushPromises()

    expect(
      findInDom('[data-testid="kanban-task-detail-image-popup-overlay"]'),
    ).not.toBeNull()

    document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape' }))
    await nextTick()
    await flushPromises()

    expect(
      findInDom('[data-testid="kanban-task-detail-image-popup-overlay"]'),
    ).toBeNull()
  })

  it('clicking the overlay backdrop closes the overlay', async () => {
    wrapper = await mountEditDialog(makeTask([TINY_PNG_DATA_URL]))

    const thumb = findInDom<HTMLImageElement>(
      '[data-testid="kanban-task-detail-image-0"]',
    )
    thumb!.click()
    await nextTick()
    await flushPromises()

    const overlay = findInDom<HTMLElement>(
      '[data-testid="kanban-task-detail-image-popup-overlay"]',
    )
    expect(overlay).not.toBeNull()
    overlay!.click()
    await nextTick()
    await flushPromises()

    expect(
      findInDom('[data-testid="kanban-task-detail-image-popup-overlay"]'),
    ).toBeNull()
  })

  it('clicking a second thumbnail swaps the popup image', async () => {
    wrapper = await mountEditDialog(
      makeTask([TINY_PNG_DATA_URL, TINY_PNG_DATA_URL_2]),
    )

    const firstThumb = findInDom<HTMLImageElement>(
      '[data-testid="kanban-task-detail-image-0"]',
    )
    firstThumb!.click()
    await nextTick()
    await flushPromises()

    let popupImg = findInDom<HTMLImageElement>(
      '[data-testid="kanban-task-detail-image-popup-img"]',
    )
    expect(popupImg?.src).toBe(TINY_PNG_DATA_URL)

    const secondThumb = findInDom<HTMLImageElement>(
      '[data-testid="kanban-task-detail-image-1"]',
    )
    secondThumb!.click()
    await nextTick()
    await flushPromises()

    popupImg = findInDom<HTMLImageElement>(
      '[data-testid="kanban-task-detail-image-popup-img"]',
    )
    expect(popupImg?.src).toBe(TINY_PNG_DATA_URL_2)

    // Still only ONE popup overlay in the DOM (not stacking).
    expect(
      findAllInDom('[data-testid="kanban-task-detail-image-popup-overlay"]'),
    ).toHaveLength(1)
  })

  it('closing then reopening the overlay works (no stale state)', async () => {
    wrapper = await mountEditDialog(makeTask([TINY_PNG_DATA_URL]))

    const thumb = findInDom<HTMLImageElement>(
      '[data-testid="kanban-task-detail-image-0"]',
    )

    thumb!.click()
    await nextTick()
    await flushPromises()
    expect(
      findInDom('[data-testid="kanban-task-detail-image-popup-overlay"]'),
    ).not.toBeNull()

    document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape' }))
    await nextTick()
    await flushPromises()
    expect(
      findInDom('[data-testid="kanban-task-detail-image-popup-overlay"]'),
    ).toBeNull()

    thumb!.click()
    await nextTick()
    await flushPromises()
    expect(
      findInDom('[data-testid="kanban-task-detail-image-popup-overlay"]'),
    ).not.toBeNull()
  })
})
