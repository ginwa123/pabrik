/**
 * Component tests for the per-task row in the workspace-item panel.
 *
 * History:
 *   - 2026-06-10: <WorkspaceItemTask> was extracted from
 *     WorkspaceItem.vue to narrow re-render scope and isolate the
 *     per-task DOM (spinner, bullet, hover buttons, click handlers)
 *     from the parent item row.
 *   - 2026-07-02: <WorkspaceItemTask> split into two thin
 *     presentation components — <WorkspaceItemTaskRow> (sidebar list)
 *     and <WorkspaceItemTaskCard> (kanban). The shared logic moved
 *     to composables/useTaskActions.ts. These tests target the Row
 *     component (sidebar consumers' view of the per-task row).
 *
 * These tests mount <WorkspaceItemTaskRow> directly so they do NOT
 * depend on WorkspaceItem's expansion state, the item-row spinner, or
 * the parent-child event wiring. The integration of
 * <WorkspaceItemTaskRow> into <WorkspaceItem> is covered by the
 * existing workspaceItemTaskRename.spec.ts and
 * workspaceItemTaskSpinner.spec.ts files (which mount <WorkspaceItem>
 * and assert through the parent).
 */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { nextTick, ref, type Ref } from 'vue'
import { mount } from '@vue/test-utils'

import WorkspaceItemTaskRow from '../components/workspace/WorkspaceItemTaskRow.vue'
import type { WorkerActivity } from '../components/WorkerElapsedChip.vue'
import { makeLocalStorageStub } from './helpers'

// Stub vue-router — WorkspaceItemTaskRow reads useRoute() via useCurrentMainView() to drive its
// active state. We mock useRoute to return a per-test controlled query so the row's active styling
// can be exercised against any URL.
// Mirrors the pattern at sidebarHandleSelectTaskUrl.spec.ts:57-77.
const { useRouteMock } = vi.hoisted(() => ({
  useRouteMock: vi.fn(() => ({
    query: {} as Record<string, string>,
    path: '/app',
    fullPath: '/app',
  })),
}))

vi.mock('vue-router', async () => {
  const actual = await vi.importActual<typeof import('vue-router')>('vue-router')
  return { ...actual, useRoute: useRouteMock }
})

const baseTask = { id: 'task_alpha', name: 'Alpha task' }

function mountTask(
  overrides: {
    task?: typeof baseTask
    workspaceId?: string
    itemId?: string
    processing?: boolean
    active?: boolean
  } = {},
) {
  const processingState: Ref<Record<string, boolean>> = ref({})
  const workerActivity = ref<Record<string, WorkerActivity>>({})
  const workerNow = ref(Date.now())
  const task = overrides.task ?? baseTask
  const wrapper = mount(WorkspaceItemTaskRow, {
    props: {
      task,
      workspaceId: overrides.workspaceId ?? 'ws_1',
      itemId: overrides.itemId ?? 'item_1',
    },
    global: {
      provide: { processingState, workerActivity, workerNow },
    },
  })
  if (overrides.processing) {
    processingState.value = { [task.id]: true }
    const now = Date.now()
    workerActivity.value = {
      [task.id]: { startedAt: now - 127_000, lastActivityAt: now - 2_000, description: '' },
    }
  }
  return { wrapper, processingState, workerActivity }
}

describe('WorkspaceItemTaskRow per-task row', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    Object.defineProperty(globalThis, 'localStorage', {
      value: makeLocalStorageStub(),
      writable: true,
      configurable: true,
    })
  })

  afterEach(() => {
    // Pinia is torn down by the next beforeEach.
  })

  it('renders the task name and a bullet by default (no spinner, no active styling)', async () => {
    const { wrapper } = mountTask()
    expect(wrapper.text()).toContain('Alpha task')
    // The circle spinner was removed — the time pill is the only activity
    // marker. Idle rows render neither.
    expect(wrapper.findAll('[data-testid="task-spinner"]')).toHaveLength(0)
    expect(wrapper.find('[data-testid="task-elapsed-chip"]').exists()).toBe(false)
    // Lock in the row-variant contract (post-2026-07-02 split): the Row component always carries
    // data-task-row and never data-task-card.
    // A future refactor that re-introduces a 'variant' prop or accidentally adds a data-task-card
    // attribute would break the consumer's selection logic in KanbanColumn / drag-and-drop
    // handlers.
    expect(wrapper.find('[data-task-row]').exists()).toBe(true)
    expect(wrapper.find('[data-task-card]').exists()).toBe(false)
    // Bullet is a span.w-1.h-1.rounded-full — at least one exists.
    expect(wrapper.findAll('span.w-1.h-1.rounded-full')).toHaveLength(1)
  })

  it('renders the elapsed time pill and hides the bullet when the worker is running', async () => {
    const { wrapper } = mountTask({ processing: true })
    await nextTick()
    // The circle spinner was removed — the time pill is the only marker.
    expect(wrapper.findAll('[data-testid="task-spinner"]')).toHaveLength(0)
    expect(wrapper.find('[data-testid="task-elapsed-chip"]').exists()).toBe(true)
    // Bullet must NOT render while the worker runs (single visual marker per row). The bullet
    // selector is w-1.5.h-1.5; the slider track sits below the row, so the w-1.5 selector catches
    // only the bullet.
    expect(wrapper.findAll('span.w-1.h-1.rounded-full')).toHaveLength(0)
  })

  it('hides the time pill and restores the bullet when the worker finishes', async () => {
    const { wrapper, processingState, workerActivity } = mountTask({ processing: true })
    await nextTick()
    expect(wrapper.find('[data-testid="task-elapsed-chip"]').exists()).toBe(true)
    processingState.value = {}
    workerActivity.value = {}
    await nextTick()
    expect(wrapper.findAll('[data-testid="task-spinner"]')).toHaveLength(0)
    expect(wrapper.find('[data-testid="task-elapsed-chip"]').exists()).toBe(false)
    expect(wrapper.findAll('span.w-1.h-1.rounded-full')).toHaveLength(1)
  })

  it('renders the bullet in the dim text color when not active and not processing', async () => {
    const { wrapper } = mountTask()
    const bullet = wrapper.find('span.w-1.h-1.rounded-full')
    expect(bullet.exists()).toBe(true)
    // activeTaskId is null in a fresh Pinia → bullet gets the dim
    // (semantic-text-dim) background.
    expect(bullet.attributes('style')).toContain('--semantic-text-dim')
  })

  it('applies active styling (aqua bullet + active background) when URL is ?view=workspace&itemId=Y/chat/task_X', async () => {
    // SIMPLIFY-URL-BROWSER (2026-08-15): the URL is now ?view=workspace&itemId=Y/chat/task_X.
    // useCurrentMainView parses the /chat/ suffix and exposes chatTaskId on the workspace view
    // variant. The task row's active highlight reads kind='workspace' + chatTaskId.
    const ITEM_ID = 'item_test'
    useRouteMock.mockReturnValue({
      query: {
        view: 'workspace',
        workspaceId: 'ws_test',
        itemId: `${ITEM_ID}/chat/${baseTask.id}`,
      },
      path: '/app',
      fullPath: `/app?view=workspace&workspaceId=ws_test&itemId=${ITEM_ID}/chat/${baseTask.id}`,

      // eslint-disable-next-line @typescript-eslint/no-explicit-any
    } as any)
    const { wrapper } = mountTask()
    const rowButton = wrapper.find('[data-task-row]')
    expect(rowButton.exists()).toBe(true)
    expect(rowButton.attributes('style')).toContain('rgb(46, 45, 42)')
    expect(rowButton.attributes('style')).toContain('rgb(230, 230, 224)')
    const bullet = wrapper.find('span.w-1.h-1.rounded-full')
    // Active/pinned bullet is the gold #e8c87a (hardcoded hex, not a var).
    expect(bullet.attributes('style')).toContain('rgb(232, 200, 122)')
  })

  it('emits selectTask with task.id when the row is clicked', async () => {
    const { wrapper } = mountTask()
    const rowButton = wrapper.find('[data-task-row]')
    await rowButton.trigger('click')
    const emitted = wrapper.emitted('selectTask')
    expect(emitted).toBeDefined()
    expect(emitted!).toHaveLength(1)
    expect(emitted![0]).toEqual(['task_alpha'])
  })

  it('emits selectTask when the row is activated with Enter', async () => {
    const { wrapper } = mountTask()
    await wrapper.find('[data-task-row]').trigger('keydown', { key: 'Enter' })
    expect(wrapper.emitted('selectTask')?.[0]).toEqual(['task_alpha'])
  })

  it('emits selectTask when the row is activated with Space', async () => {
    const { wrapper } = mountTask()
    await wrapper.find('[data-task-row]').trigger('keydown', { key: ' ' })
    expect(wrapper.emitted('selectTask')?.[0]).toEqual(['task_alpha'])
  })

  it('does not emit selectTask on an unrelated key', async () => {
    const { wrapper } = mountTask()
    await wrapper.find('[data-task-row]').trigger('keydown', { key: 'a' })
    expect(wrapper.emitted('selectTask')).toBeUndefined()
  })

  // ─── Right-click action menu ──────────────────────────────────────────── The row's three hover
  // buttons (pin / rename / delete) were migrated into <OpenInNewTabMenu>. Every action must still
  // fire with the SAME emitted payload, or the change silently removed functionality.
  // The menu is Teleported to `body`, so its rows are queried from the document rather than through
  // the wrapper — and because it never traverses the row, picking a row cannot also fire the row's
  // @click.
  // That is what the old stopPropagation guards protected against, so the "does NOT emit
  // selectTask" assertions below are the behaviour those guards used to provide, now asserted on
  // the outcome.

  const openRowMenu = async (wrapper: ReturnType<typeof mountTask>['wrapper']) => {
    await wrapper.find('[data-task-row]').trigger('contextmenu', { clientX: 40, clientY: 80 })
    await nextTick()
  }

  const menuItem = (testid: string) =>
    document.body.querySelector(`[data-testid="${testid}"]`) as HTMLButtonElement | null

  const clickMenuItem = async (testid: string) => {
    const el = menuItem(testid)
    if (!el) throw new Error(`menu item ${testid} not found`)
    el.click()
    await nextTick()
  }

  it('emits renameTask with (workspaceId, itemId, taskId, currentName) from the menu', async () => {
    const { wrapper } = mountTask({
      workspaceId: 'ws_xyz',
      itemId: 'item_xyz',
    })
    await openRowMenu(wrapper)
    await clickMenuItem('rename-task-menu-item')

    const emitted = wrapper.emitted('renameTask')
    expect(emitted).toBeDefined()
    expect(emitted!).toHaveLength(1)
    expect(emitted![0]).toEqual(['ws_xyz', 'item_xyz', 'task_alpha', 'Alpha task'])

    wrapper.unmount()
  })

  it('emits deleteTask with (workspaceId, itemId, taskId) from the menu', async () => {
    const { wrapper } = mountTask({
      workspaceId: 'ws_xyz',
      itemId: 'item_xyz',
    })
    await openRowMenu(wrapper)
    await clickMenuItem('delete-task-menu-item')

    const emitted = wrapper.emitted('deleteTask')
    expect(emitted).toBeDefined()
    expect(emitted!).toHaveLength(1)
    expect(emitted![0]).toEqual(['ws_xyz', 'item_xyz', 'task_alpha'])

    wrapper.unmount()
  })

  it('emits pinTask with the INVERTED value from the menu', async () => {
    const { wrapper } = mountTask()
    await openRowMenu(wrapper)
    await clickMenuItem('open-new-tab-pin-item')

    expect(wrapper.emitted('pinTask')?.[0]).toEqual(['ws_1', 'item_1', 'task_alpha', true])

    wrapper.unmount()
  })

  it('does NOT emit selectTask when a menu row is picked', async () => {
    // The old inline buttons needed event.stopPropagation so the click did not bubble to the row's
    // @click. The teleported menu never traverses the row, so this asserts the outcome survived
    // rather than relying on a guard that no longer has anything to guard.
    const { wrapper } = mountTask()
    // Each pick closes the menu, so reopen between the two.
    await openRowMenu(wrapper)
    await clickMenuItem('rename-task-menu-item')
    await openRowMenu(wrapper)
    await clickMenuItem('delete-task-menu-item')

    expect(wrapper.emitted('selectTask')).toBeUndefined()

    wrapper.unmount()
  })

  it('renders NO hover action buttons in the row', async () => {
    // The buttons ate ~72px of a ~200px panel and truncated the task
    // name. A regression that re-adds one costs that width back.
    const { wrapper } = mountTask()
    expect(wrapper.find('[data-testid="task-pin-toggle"]').exists()).toBe(false)
    expect(wrapper.find('button[title="Rename Task"]').exists()).toBe(false)
    // The row root is a <div role="button">, so any <button> left in the
    // row would be a re-added action.
    expect(wrapper.findAll('button')).toHaveLength(0)

    wrapper.unmount()
  })

  it('keeps the pin INDICATOR (state, not an action) when pinned', async () => {
    const { wrapper } = mountTask({ task: { ...baseTask, is_pinned: true } as typeof baseTask })
    await nextTick()
    expect(wrapper.find('[data-testid="task-pin-indicator"]').exists()).toBe(true)
    // The pin toggle is gone; the indicator is not.
    expect(wrapper.find('[data-testid="task-pin-toggle"]').exists()).toBe(false)

    wrapper.unmount()
  })

  it('emits the four renameTask args in the documented order', async () => {
    // Belt-and-braces check for the event payload shape, in case a future refactor re-orders the
    // arguments.
    // We index into the emitted tuple by position — the cast satisfies Vue's `unknown[]` element
    // type, and the `!` is required because tsconfig has noUncheckedIndexedAccess turned on (Vue's
    // `emitted()` returns `unknown[][] | undefined`).
    const { wrapper } = mountTask({
      workspaceId: 'ws_order',
      itemId: 'item_order',
    })
    await openRowMenu(wrapper)
    await clickMenuItem('rename-task-menu-item')
    const args = wrapper.emitted('renameTask')![0]! as [string, string, string, string]
    expect(args[0]).toBe('ws_order') // workspaceId
    expect(args[1]).toBe('item_order') // itemId
    expect(args[2]).toBe('task_alpha') // taskId
    expect(args[3]).toBe('Alpha task') // currentName

    wrapper.unmount()
  })

  it('opens the action menu from the ContextMenu key, anchored at the row', async () => {
    // Removing the hover buttons removed the only discoverable route to
    // rename / delete, so the keyboard path is a hard requirement —
    // without it the change is an accessibility regression.
    const { wrapper } = mountTask()
    await wrapper.find('[data-task-row]').trigger('keydown', { key: 'ContextMenu' })
    await nextTick()

    expect(menuItem('open-new-tab-menu')).toBeTruthy()
    // Enter/Space must still open the chat, not the menu.
    expect(wrapper.emitted('selectTask')).toBeUndefined()

    wrapper.unmount()
  })

  it('opens the action menu from Shift+F10', async () => {
    const { wrapper } = mountTask()
    await wrapper.find('[data-task-row]').trigger('keydown', { key: 'F10', shiftKey: true })
    await nextTick()

    expect(menuItem('open-new-tab-menu')).toBeTruthy()

    wrapper.unmount()
  })

  it('closes the menu on Escape', async () => {
    const { wrapper } = mountTask()
    await openRowMenu(wrapper)
    expect(menuItem('open-new-tab-menu')).toBeTruthy()

    window.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape' }))
    await nextTick()
    expect(menuItem('open-new-tab-menu')).toBeNull()

    wrapper.unmount()
  })
})
