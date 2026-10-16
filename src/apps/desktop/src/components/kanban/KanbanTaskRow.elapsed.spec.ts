/** KanbanTaskRow — the elapsed chip in the metadata line. The row already said "busy" two ways (a
 * yellow 3px rail and the muted `● agent running` label). This spec pins the third signal the
 * wireframe added: how long the run has been going, and whether it is still heart-beating. */
import { mount } from '@vue/test-utils'
import { beforeEach, afterEach, describe, expect, it, vi } from 'vitest'
import { nextTick, ref, type Ref } from 'vue'
import { createPinia, setActivePinia } from 'pinia'

import KanbanTaskRow from './KanbanTaskRow.vue'
import type { WorkerActivity } from '../WorkerElapsedChip.vue'
import type { Task } from '../../stores/workspaces'

const TASK_ID = 'task_1'

const task = (over: Partial<Task> = {}): Task =>
  ({
    id: TASK_ID,
    name: 'Fix the auth redirect loop',
    workspace_item_id: 'item_1',
    created_at: '2026-10-09 10:00:00',
    updated_at: '2026-10-09 10:00:00',
    git_branch: null,
    is_pinned: false,
    needs_human_review: false,
    last_finish_reason: null,
    ...over,
    // eslint-disable-next-line @typescript-eslint/no-explicit-any -- partial fixture; the store's Task has many optional columns.
  }) as any

const mountRow = (
  opts: {
    busy?: boolean
    activity?: Record<string, WorkerActivity>
    task?: Task
  } = {},
) => {
  const processing = ref<Record<string, boolean>>(
    opts.busy === false ? {} : { [TASK_ID]: true },
  ) as Ref<Record<string, boolean>>
  const activity = ref(opts.activity ?? {}) as Ref<Record<string, WorkerActivity>>
  // The 1s ticker is app-scoped (`workerNow` in App.vue); the row just
  // reads it. Handing the test its own ref lets a tick be simulated.
  const now = ref(Date.now()) as Ref<number>
  return mount(KanbanTaskRow, {
    props: { task: opts.task ?? task(), workspaceId: 'ws_1', itemId: 'item_1' },
    global: {
      provide: { processingState: processing, workerActivity: activity, workerNow: now },
      stubs: { OpenInNewTabMenu: true, RouterLink: true },
    },
  })
}

const ago = (ms: number) => Date.now() - ms

describe('KanbanTaskRow elapsed chip', () => {
  beforeEach(() => {
    // The row reads the agent-error store for its status rail.
    setActivePinia(createPinia())
    vi.useFakeTimers()
    vi.setSystemTime(new Date('2026-10-09T12:00:00Z'))
  })

  afterEach(() => {
    vi.useRealTimers()
  })

  it('shows the elapsed time beside the busy label', () => {
    const wrapper = mountRow({
      activity: {
        [TASK_ID]: { startedAt: ago(252_000), lastActivityAt: ago(2_000), description: '' },
      },
    })
    const chip = wrapper.find('[data-testid="kanban-row-elapsed"]')
    expect(chip.exists()).toBe(true)
    expect(chip.text()).toBe('4m 12s')
    // The pre-existing busy label is untouched.
    expect(wrapper.find('[data-testid="kanban-row-status-busy"]').text()).toContain('agent running')
  })

  it('turns amber when the heartbeat has gone quiet', () => {
    const wrapper = mountRow({
      activity: {
        [TASK_ID]: { startedAt: ago(600_000), lastActivityAt: ago(540_000), description: '' },
      },
    })
    const chip = wrapper.find('[data-testid="kanban-row-elapsed"]')
    expect(chip.attributes('data-stale')).toBe('true')
  })

  it('stays yellow for a long run that is still heart-beating', () => {
    // 20 minutes old, 2 seconds since the last heartbeat: one long tool
    // call, not a stall. The elapsed number is large but the state is not.
    const wrapper = mountRow({
      activity: {
        [TASK_ID]: { startedAt: ago(1_200_000), lastActivityAt: ago(2_000), description: '' },
      },
    })
    const chip = wrapper.find('[data-testid="kanban-row-elapsed"]')
    expect(chip.text()).toBe('20m 00s')
    expect(chip.attributes('data-stale')).toBe('false')
  })

  it('renders no chip for an idle row', () => {
    const wrapper = mountRow({ busy: false })
    expect(wrapper.find('[data-testid="kanban-row-elapsed"]').exists()).toBe(false)
    expect(wrapper.attributes('data-kanban-row-state')).toBe('default')
  })

  it('renders no chip when the row is busy but has no activity entry yet', () => {
    // The SSE `worker_created` event and the activity map are written in
    // the same handler, but a row can render in between. Absence must be
    // silent, not a "0s" chip.
    const wrapper = mountRow({ activity: {} })
    expect(wrapper.find('[data-testid="kanban-row-elapsed"]').exists()).toBe(false)
  })

  it('re-renders when the shared ticker advances', async () => {
    const wrapper = mountRow({
      activity: {
        [TASK_ID]: { startedAt: ago(60_000), lastActivityAt: ago(1_000), description: '' },
      },
    })
    expect(wrapper.find('[data-testid="kanban-row-elapsed"]').text()).toBe('1m 00s')

    // eslint-disable-next-line @typescript-eslint/no-explicit-any -- test-only reach into Vue internals.
    const provides = (wrapper.vm as any).$.provides as Record<string, Ref<number> | undefined>
    const now = provides.workerNow
    expect(now).toBeDefined()
    now!.value += 15_000
    await nextTick()
    expect(wrapper.find('[data-testid="kanban-row-elapsed"]').text()).toBe('1m 15s')
  })
})
