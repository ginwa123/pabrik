/**
 * Component tests for the rename-task action on the task row in
 * WorkspaceItem.vue.
 *
 * The action used to be a hover pencil button on the row; it now lives
 * in the row's right-click menu (<OpenInNewTabMenu>), the same
 * migration <WorkspaceItemTaskCard> made. These tests mount
 * <WorkspaceItem> — the real parent chain — so they cover the
 * integration: the row opens its menu, the menu row emits, and
 * WorkspaceItem re-emits renameTask up to ProjectsList unchanged.
 *
 * The old stopPropagation guard is gone with the button: the menu is
 * Teleported to `body`, so its clicks never traverse the row and
 * cannot fire the row's selectTask. The "does NOT emit selectTask"
 * test below asserts that outcome directly.
 */
import { afterEach, beforeEach, describe, expect, it } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { nextTick, ref, type Ref } from 'vue'
import { mount } from '@vue/test-utils'

import WorkspaceItem from '../components/workspace/WorkspaceItem.vue'
import { useWorkspacesStore } from '../stores/workspaces'
import { makeLocalStorageStub } from './helpers'

const itemWithTasks = {
  id: 'item_1',
  name: 'My Project',
  item_type: 'folder',
  tasks: [{ id: 'task_alpha', name: 'Alpha task' }],
}

function mountWorkspaceItem() {
  const processingState: Ref<Record<string, boolean>> = ref({})
  const wrapper = mount(WorkspaceItem, {
    props: {
      item: { ...itemWithTasks },
      isActive: false,
      workspaceId: 'ws_1',
    },
    global: {
      provide: { processingState },
    },
  })
  return { wrapper }
}

function expandItem(): void {
  const ws = useWorkspacesStore()
  ws.expandedItemIds['item_1'] = true
  ws.expandedItemIds = { ...ws.expandedItemIds }
}

describe('WorkspaceItem task rename button', () => {
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

  // The menu is Teleported to `body`, so its rows are queried from the
  // document rather than through the wrapper.
  const menuItem = (testid: string) =>
    document.body.querySelector(`[data-testid="${testid}"]`) as HTMLButtonElement | null

  const openRowMenu = async (wrapper: ReturnType<typeof mountWorkspaceItem>['wrapper']) => {
    await wrapper.find('[data-task-row]').trigger('contextmenu', { clientX: 40, clientY: 80 })
    await nextTick()
  }

  it('emits renameTask with workspaceId, itemId, taskId, currentName from the menu', async () => {
    const { wrapper } = mountWorkspaceItem()
    expandItem()
    await nextTick()
    await openRowMenu(wrapper)

    const item = menuItem('rename-task-menu-item')
    expect(item).toBeTruthy()
    item!.click()
    await nextTick()

    const emitted = wrapper.emitted('renameTask')
    expect(emitted).toBeDefined()
    // Single emission, with the four documented args in order.
    expect(emitted!).toHaveLength(1)
    expect(emitted![0]).toEqual(['ws_1', 'item_1', 'task_alpha', 'Alpha task'])

    wrapper.unmount()
  })

  it('does NOT emit selectTask when the rename row is picked', async () => {
    // The pencil used to sit inside the row's @click, so it needed
    // event.stopPropagation or the click bubbled and selected the task
    // as a side-effect. The teleported menu never traverses the row, so
    // this asserts the outcome survived rather than the guard.
    const { wrapper } = mountWorkspaceItem()
    expandItem()
    await nextTick()
    await openRowMenu(wrapper)
    menuItem('rename-task-menu-item')!.click()
    await nextTick()

    expect(wrapper.emitted('selectTask')).toBeUndefined()

    wrapper.unmount()
  })

  it('offers rename and delete in the menu, so neither action is stranded', async () => {
    // Regression guard: the pencil was inserted *before* the existing
    // delete button. A future refactor that drops one of the two menu
    // rows would silently break that feature — the row has no other
    // route to it.
    const { wrapper } = mountWorkspaceItem()
    expandItem()
    await nextTick()
    await openRowMenu(wrapper)

    expect(menuItem('rename-task-menu-item')).toBeTruthy()
    expect(menuItem('delete-task-menu-item')).toBeTruthy()

    wrapper.unmount()
  })

  it('renders NO hover action buttons on the task row', async () => {
    const { wrapper } = mountWorkspaceItem()
    expandItem()
    await nextTick()

    expect(wrapper.find('[data-testid="task-pin-toggle"]').exists()).toBe(false)
    expect(wrapper.find('button[title="Rename Task"]').exists()).toBe(false)
    // The row root is a <div role="button">, so any <button> inside it
    // would be a re-added action.
    expect(wrapper.find('[data-task-row]').findAll('button')).toHaveLength(0)

    wrapper.unmount()
  })
})
