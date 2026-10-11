/**
 * Behavioural test for the WorkspaceItem row layout contract
 * (task i-see-bad-ui-ux follow-up: centered project names on agent site).
 *
 * The item row is a flex row: chevron + name + ONE right cluster.
 * A previous fix left TWO `ml-auto` children (meta container + actions
 * container) in the row — two auto margins in one flex row split the
 * free space between them and pushed the project name toward center
 * (screenshot: pabrik / website pabrik / ruangsql all centered).
 *
 * Locks, by mounting the real component and querying rendered DOM:
 *   1. The row button has exactly ONE direct child carrying `ml-auto`
 *      (single right cluster — centering becomes impossible).
 *   2. The name span grows (`flex-1`), truncates, and carries the full
 *      name as its title (left-aligned + tooltip recovery).
 *   3. Idle item with tasks shows the count and no elapsed chip.
 *   4. Busy item shows the elapsed chip and hides the count
 *      (single-slot exclusivity — never two trailing markers).
 */
import { beforeEach, describe, expect, it } from 'vitest'
import { flushPromises, mount } from '@vue/test-utils'
import { setActivePinia, createPinia } from 'pinia'
import { nextTick, ref } from 'vue'
import WorkspaceItem from '../components/workspace/WorkspaceItem.vue'
import type { WorkerActivity } from '../components/WorkerElapsedChip.vue'
import type { WorkspaceItem as WorkspaceItemType } from '../stores/workspaces'

const WS_ID = 'ws_1'
const ITEM_ID = 'item_1'

function makeFolderItem(overrides: Partial<WorkspaceItemType> = {}): WorkspaceItemType {
  return {
    id: ITEM_ID,
    name: 'pabrik with a very long project name that truncates',
    item_type: 'folder',
    path: '/tmp/test',
    tasks: [
      {
        id: 'task_f1',
        name: 'task in folder',
        description: '',
        tags: [],
        is_pinned: false,
        task_type: 'standard',
        kanban_column_id: null,
      },
    ],
    ...overrides,
  }
}

function mountItem(item: WorkspaceItemType, busyIds: string[] = []) {
  const now = Date.now()
  const processingState = ref<Record<string, boolean>>(
    Object.fromEntries(busyIds.map((id) => [id, true])),
  )
  const workerActivity = ref<Record<string, WorkerActivity>>(
    Object.fromEntries(
      busyIds.map((id) => [
        id,
        { startedAt: now - 127_000, lastActivityAt: now - 2_000, description: '' },
      ]),
    ),
  )
  const workerNow = ref(now)
  return mount(WorkspaceItem, {
    props: {
      item,
      isActive: false,
      workspaceId: WS_ID,
    },
    global: {
      provide: { processingState, workerActivity, workerNow },
    },
  })
}

/** Direct children of the row button carrying an `ml-auto` class. */
function mlAutoChildrenOfRowButton(wrapper: ReturnType<typeof mount>): Element[] {
  const nameEl = wrapper.find('[data-testid="item-name"]').element
  const button = nameEl.parentElement!
  return Array.from(button.children).filter((el) => el.classList.contains('ml-auto'))
}

describe('WorkspaceItem — row layout single right cluster', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
  })

  it('row button has exactly one ml-auto child (no split free space)', async () => {
    const wrapper = mountItem(makeFolderItem())
    await flushPromises()
    await nextTick()
    expect(mlAutoChildrenOfRowButton(wrapper)).toHaveLength(1)
    wrapper.unmount()
  })

  it('name grows, truncates, and carries the full name as tooltip', async () => {
    const item = makeFolderItem()
    const wrapper = mountItem(item)
    await flushPromises()
    await nextTick()
    const name = wrapper.find('[data-testid="item-name"]')
    expect(name.exists()).toBe(true)
    expect(name.classes()).toContain('flex-1')
    expect(name.classes()).toContain('truncate')
    expect(name.classes()).toContain('text-left')
    expect(name.attributes('title')).toBe(item.name)
    wrapper.unmount()
  })

  it('row button left-aligns text (native button centers without text-left)', async () => {
    // Native <button> UA stylesheet is text-align:center, which inherits
    // into the flex-1 truncate name span and centers titles (screenshot:
    // pabrik / website pabrik / ruangsql all centered). text-left on the
    // button overrides the UA default; text-left on the name is defense
    // in depth. TaskRow + DocumentsList rows already carry it — this row
    // was the only one missing it.
    const wrapper = mountItem(makeFolderItem())
    await flushPromises()
    await nextTick()
    const nameEl = wrapper.find('[data-testid="item-name"]').element
    const button = nameEl.parentElement!
    expect(button.tagName.toLowerCase()).toBe('button')
    expect(Array.from(button.classList)).toContain('text-left')
    wrapper.unmount()
  })

  it('idle item shows count and no elapsed chip', async () => {
    const wrapper = mountItem(makeFolderItem())
    await flushPromises()
    await nextTick()
    expect(wrapper.find('[data-testid="item-task-count"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="item-elapsed-chip"]').exists()).toBe(false)
    wrapper.unmount()
  })

  it('busy item shows elapsed chip and hides the count', async () => {
    const wrapper = mountItem(makeFolderItem(), ['task_f1'])
    await flushPromises()
    await nextTick()
    expect(wrapper.find('[data-testid="item-elapsed-chip"]').exists()).toBe(true)
    expect(wrapper.find('[data-testid="item-task-count"]').exists()).toBe(false)
    // Still a single right cluster while busy.
    expect(mlAutoChildrenOfRowButton(wrapper)).toHaveLength(1)
    wrapper.unmount()
  })
})
