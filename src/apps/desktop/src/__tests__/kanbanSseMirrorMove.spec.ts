/** Tests for the SSE kanban_task mirror fix. */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { setActivePinia, createPinia } from 'pinia'
import { createApp, nextTick, type App as VueApp } from 'vue'

import {
  installSseBus,
  __resetSseBus,
  __dispatchSseBus,
  __setSseBusGlobalClient,
} from '../helpers/sseBus'
import type { SseClient, SseState } from '../helpers/sseClient'
import type { KanbanTaskEvent } from '../api'
import * as api from '../api'
import { useKanbanSseStore } from '../stores/kanbanSse'
import { useWorkspacesStore } from '../stores/workspaces'
import { makeLocalStorageStub } from './helpers'

function makeStubClient(initial: SseState): SseClient {
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const stub: any = {
    close: vi.fn(),
    reconnect: vi.fn(),
    getState: () => stub._state,
    onStateChange: () => () => {},
  }
  stub._state = initial
  return stub as SseClient
}

describe('kanbanSse — mirror local task on move/assign/unassign (fix duplicate-task bug)', () => {
  let app: VueApp

  beforeEach(() => {
    setActivePinia(createPinia())
    Object.defineProperty(globalThis, 'localStorage', {
      value: makeLocalStorageStub(),
      writable: true,
      configurable: true,
    })

    __resetSseBus()
    app = createApp({})
    installSseBus(app)
    __setSseBusGlobalClient(makeStubClient('connecting'))
  })

  afterEach(() => {
    try {
      useKanbanSseStore().closeKanbanSse()
    } catch {
      // store not activated in this test → no-op
    }
    __resetSseBus()
    vi.restoreAllMocks()
  })

  function dispatch(event: KanbanTaskEvent): void {
    __dispatchSseBus('kanban', event)
  }

  /** Seed the workspaces store with a kanban item that has one task in colA. */
  function seedKanbanWithTask(opts: {
    workspaceId?: string
    itemId?: string
    taskId?: string
    sourceColumnId?: string
    destColumnId?: string
    extraTasks?: Array<{ id: string; columnId: string; name?: string }>
  }) {
    const ws = useWorkspacesStore()
    const wsId = opts.workspaceId ?? 'ws_1'
    const itemId = opts.itemId ?? 'item_1'
    const taskId = opts.taskId ?? 'task_1'
    const sourceCol = opts.sourceColumnId ?? 'colA'
    const destCol = opts.destColumnId ?? 'colB'
    ws.workspaces = [
      {
        id: wsId,
        name: 'WS',
        icon: '📁',
        expanded: true,
        items: [
          {
            id: itemId,
            name: 'Board',
            item_type: 'kanban',
            expanded: false,
            tasks: [
              {
                id: taskId,
                name: 'cli',
                kanban_column_id: sourceCol,
                kanban_position: 5,
              },
              ...(opts.extraTasks ?? []).map((t) => ({
                id: t.id,
                name: t.name ?? 'extra',
                kanban_column_id: t.columnId,
                kanban_position: 0,
              })),
            ],
            kanban_columns: [
              {
                id: sourceCol,
                workspace_item_id: itemId,
                name: 'colA',
                position: 0,
                created_at: '2026-08-06T00:00:00Z',
              },
              {
                id: destCol,
                workspace_item_id: itemId,
                name: 'colB',
                position: 1,
                created_at: '2026-08-06T00:00:00Z',
              },
            ],
          },
        ],
      },
    ]
    return { ws, wsId, itemId, taskId }
  }

  it('moved event: mirrors local task column_id to the destination BEFORE refresh resolves', async () => {
    const { ws, wsId, itemId, taskId } = seedKanbanWithTask({})

    // Spy on refreshTask but DON'T resolve immediately so we can observe the local state between
    // dispatch and refresh resolution. Definite-assignment assertion on the resolve callback
    // because the inner closure assigns before the outer code reads it.
    let resolveRefresh!: () => void
    const refreshSpy = vi.spyOn(ws, 'refreshTask').mockImplementation(
      () =>
        new Promise<void>((resolve) => {
          resolveRefresh = resolve
        }),
    )
    // The blind limit=100 column fetch must NOT fire on the fast path.
    const fetchSpy = vi.spyOn(ws, 'fetchKanbanTasks').mockResolvedValue()

    const store = useKanbanSseStore()
    await store.initKanbanSse(wsId)

    dispatch({
      action: 'moved',
      workspace_id: wsId,
      item_id: itemId,
      task_id: taskId,
      new_column_id: 'colB',
      new_position: 0,
    })

    // Single-row fast path: refreshTask once, no column fetch.
    expect(refreshSpy).toHaveBeenCalledTimes(1)
    expect(refreshSpy).toHaveBeenCalledWith(wsId, itemId, taskId)
    expect(fetchSpy).not.toHaveBeenCalled()

    // The local task's column_id was mirrored to 'colB' BEFORE the awaited refresh resolves — this
    // is the fix. Pre-fix this would still be 'colA' and the subsequent merge would duplicate the
    // task.
    const localTask = ws.workspaces[0]!.items[0]!.tasks!.find((t) => t.id === taskId)!
    expect(localTask.kanban_column_id).toBe('colB')
    expect(localTask.kanban_position).toBe(0)

    // Drain the pending refresh so afterEach's cleanup doesn't hang.
    resolveRefresh()
    await nextTick()
  })

  it('moved event (full integration): single-row refresh lands exactly 1 copy in colB', async () => {
    // End-to-end: local task in colA, agent moves it to colB, the SSE event arrives, the mirror
    // updates local state (column + slot), the single-row refresh returns the post-move wire shape,
    // and the in-place splice lands exactly 1 copy of the task in colB and 0 in colA.
    const { ws, wsId, itemId, taskId } = seedKanbanWithTask({})

    // Mock api.getTask to return the moved task in colB (the
    // post-move wire shape).
    const getTaskSpy = vi.spyOn(api, 'getTask').mockResolvedValue({
      id: taskId,
      name: 'cli',
      kanban_column_id: 'colB',
      kanban_position: 0,
    })
    const fetchSpy = vi.spyOn(ws, 'fetchKanbanTasks').mockResolvedValue()

    const store = useKanbanSseStore()
    await store.initKanbanSse(wsId)

    dispatch({
      action: 'moved',
      workspace_id: wsId,
      item_id: itemId,
      task_id: taskId,
      new_column_id: 'colB',
      new_position: 0,
    })

    // Drain microtasks: the SSE handler calls refreshTask
    // (void, no await) but the mock api.getTask returns a resolved
    // promise, so the splice lands in the same task queue.
    await new Promise((r) => setTimeout(r, 10))
    await nextTick()

    // One row on the wire, no column fetch.
    expect(getTaskSpy).toHaveBeenCalledTimes(1)
    expect(getTaskSpy).toHaveBeenCalledWith(wsId, itemId, taskId)
    expect(fetchSpy).not.toHaveBeenCalled()

    const tasks = ws.workspaces[0]!.items[0]!.tasks!
    const inColA = tasks.filter((t) => t.kanban_column_id === 'colA')
    const inColB = tasks.filter((t) => t.kanban_column_id === 'colB')

    // Exactly one copy of the task, in colB.
    expect(tasks).toHaveLength(1)
    expect(inColA).toHaveLength(0)
    expect(inColB).toHaveLength(1)
    expect(inColB[0]!.id).toBe(taskId)
  })

  it('unassigned event: mirrors local task column_id to null BEFORE fetch', async () => {
    const { ws, wsId, itemId, taskId } = seedKanbanWithTask({})

    // Spy on fetchKanbanTasksForAllColumns (the path the unassigned
    // branch takes). Don't resolve immediately.
    let resolveFetch!: () => void
    const fetchAllSpy = vi.spyOn(ws, 'fetchKanbanTasksForAllColumns').mockImplementation(
      () =>
        new Promise<void>((resolve) => {
          resolveFetch = resolve
        }),
    )

    const store = useKanbanSseStore()
    await store.initKanbanSse(wsId)

    dispatch({
      action: 'unassigned',
      workspace_id: wsId,
      item_id: itemId,
      task_id: taskId,
      new_column_id: null,
      new_position: null,
    })

    expect(fetchAllSpy).toHaveBeenCalledTimes(1)

    // Local task's column_id is null (unassigned) BEFORE the fetch
    // resolves. Pre-fix this would still be 'colA' and the source-
    // column refetch would leave the stale copy.
    const localTask = ws.workspaces[0]!.items[0]!.tasks!.find((t) => t.id === taskId)!
    expect(localTask.kanban_column_id).toBeNull()

    resolveFetch()
    await nextTick()
  })

  it('unassigned event (full integration): task preserved as unassigned after wire response', async () => {
    // After unassign: task stays in item.tasks with kanban_column_id = null (the "unassigned limbo"
    // state). The UI hides it from all columns because no column matches null, but the task itself
    // is not deleted — the user can re-assign it.
    const { ws, wsId, itemId, taskId } = seedKanbanWithTask({})

    // The unassigned branch fires fetchKanbanTasksForAllColumns which iterates each column and
    // re-fetches. Mock api.getTasks to return an empty list for every column — the task is
    // unassigned, so the server returns it nowhere.
    vi.spyOn(api, 'getTasks').mockResolvedValue({
      tasks: [],
      has_more: false,
      next_cursor: null,
    })

    const store = useKanbanSseStore()
    await store.initKanbanSse(wsId)

    dispatch({
      action: 'unassigned',
      workspace_id: wsId,
      item_id: itemId,
      task_id: taskId,
      new_column_id: null,
      new_position: null,
    })

    await new Promise((r) => setTimeout(r, 10))
    await nextTick()

    const tasks = ws.workspaces[0]!.items[0]!.tasks!
    // Exactly one copy of the task (preserved as unassigned limbo),
    // with column_id set to null — not the source column (colA).
    expect(tasks).toHaveLength(1)
    expect(tasks[0]!.id).toBe(taskId)
    expect(tasks[0]!.kanban_column_id).toBeNull()

    // Specifically: NO copy left in the source column (the original
    // bug — the stale colA entry visible in the UI).
    const inColA = tasks.filter((t) => t.kanban_column_id === 'colA')
    expect(inColA).toHaveLength(0)
  })

  it('assigned event: mirrors local task column_id when it changes (no duplicate)', async () => {
    // Agent creates a new task that auto-assigns to colB. The local
    // store has the task in colA (stale). After the SSE event, the
    // local task should move to colB.
    const { ws, wsId, itemId, taskId } = seedKanbanWithTask({})

    vi.spyOn(api, 'getTask').mockResolvedValue({
      id: taskId,
      name: 'cli',
      kanban_column_id: 'colB',
      kanban_position: 0,
    })

    const store = useKanbanSseStore()
    await store.initKanbanSse(wsId)

    dispatch({
      action: 'assigned',
      workspace_id: wsId,
      item_id: itemId,
      task_id: taskId,
      new_column_id: 'colB',
      new_position: 0,
    })

    await new Promise((r) => setTimeout(r, 10))
    await nextTick()

    const tasks = ws.workspaces[0]!.items[0]!.tasks!
    expect(tasks).toHaveLength(1)
    expect(tasks[0]!.kanban_column_id).toBe('colB')
  })

  it('event for a task not in local store: no-op, no throw', async () => {
    // SSE event arrives for a task the local store doesn't know
    // about (e.g. another tab's task, or event fired before initial
    // load completed). The mirror must silently no-op.
    const { ws, wsId, itemId } = seedKanbanWithTask({ taskId: 'task_1' })

    vi.spyOn(api, 'getTasks').mockResolvedValue({
      tasks: [],
      has_more: false,
      next_cursor: null,
    })

    const store = useKanbanSseStore()
    await store.initKanbanSse(wsId)

    expect(() =>
      dispatch({
        action: 'moved',
        workspace_id: wsId,
        item_id: itemId,
        task_id: 'task_UNKNOWN',
        new_column_id: 'colB',
        new_position: 0,
      }),
    ).not.toThrow()

    await new Promise((r) => setTimeout(r, 10))
    await nextTick()

    // The known task is untouched.
    const localTask = ws.workspaces[0]!.items[0]!.tasks!.find((t) => t.id === 'task_1')!
    expect(localTask.kanban_column_id).toBe('colA')
  })

  it('human_touched event: no column change (the SSE payload carries null), local untouched', async () => {
    const { ws, wsId, itemId, taskId } = seedKanbanWithTask({})

    // REGRESSION (2026-08-24): human_touched has new_column_id: null. Pre-fix, the event fell into
    // the unassign refetch branch and fired fetchKanbanTasksForAllColumns → one tasks?limit=100 per
    // column EVERY time the user opened a task's chatview.
    const getTasksSpy = vi.spyOn(api, 'getTasks')

    // Seed the "awaiting review" state the card shows before the
    // touch: the orange dot renders when needs_human_review=true.
    const localTaskBefore = ws.workspaces[0]!.items[0]!.tasks!.find((t) => t.id === taskId)!
    localTaskBefore.needs_human_review = true

    const store = useKanbanSseStore()
    await store.initKanbanSse(wsId)

    dispatch({
      action: 'human_touched',
      workspace_id: wsId,
      item_id: itemId,
      task_id: taskId,
      new_column_id: null,
      new_position: null,
      needs_human_review: false,
    })

    await new Promise((r) => setTimeout(r, 10))
    await nextTick()

    // Zero network — the whole point of the fix.
    expect(getTasksSpy).not.toHaveBeenCalled()

    const localTask = ws.workspaces[0]!.items[0]!.tasks!.find((t) => t.id === taskId)!
    // The review flag flipped (orange dot → green checkmark).
    expect(localTask.needs_human_review).toBe(false)
    // Column + position are untouched (it was NOT a move).
    expect(localTask.kanban_column_id).toBe('colA')
    expect(localTask.kanban_position).toBe(5)
  })

  it('idempotent mirror: dispatching the same moved event twice is safe', async () => {
    const { ws, wsId, itemId, taskId } = seedKanbanWithTask({})

    vi.spyOn(api, 'getTask').mockResolvedValue({
      id: taskId,
      name: 'cli',
      kanban_column_id: 'colB',
      kanban_position: 0,
    })

    const store = useKanbanSseStore()
    await store.initKanbanSse(wsId)

    const event = {
      action: 'moved' as const,
      workspace_id: wsId,
      item_id: itemId,
      task_id: taskId,
      new_column_id: 'colB',
      new_position: 0,
    }
    dispatch(event)
    await new Promise((r) => setTimeout(r, 10))
    await nextTick()

    dispatch(event)
    await new Promise((r) => setTimeout(r, 10))
    await nextTick()

    const tasks = ws.workspaces[0]!.items[0]!.tasks!
    expect(tasks).toHaveLength(1)
    expect(tasks[0]!.kanban_column_id).toBe('colB')
    expect(tasks[0]!.kanban_position).toBe(0)
  })

  it('moved event: mirror slots the card at new_position among destination cards', async () => {
    // colB already holds [t2, t3]; the agent moves task_1 from colA to colB position 1. The mirror
    // must splice the card between t2 and t3 (display order IS array order — cardsInColumn just
    // filters), so the board is correct with zero network beyond the single-row refresh.
    const { ws, wsId, itemId, taskId } = seedKanbanWithTask({
      extraTasks: [
        { id: 't2', columnId: 'colB' },
        { id: 't3', columnId: 'colB' },
      ],
    })
    const refreshSpy = vi.spyOn(ws, 'refreshTask').mockResolvedValue()
    const fetchSpy = vi.spyOn(ws, 'fetchKanbanTasks').mockResolvedValue()

    const store = useKanbanSseStore()
    await store.initKanbanSse(wsId)

    dispatch({
      action: 'moved',
      workspace_id: wsId,
      item_id: itemId,
      task_id: taskId,
      new_column_id: 'colB',
      new_position: 1,
    })

    expect(refreshSpy).toHaveBeenCalledTimes(1)
    expect(fetchSpy).not.toHaveBeenCalled()

    const tasks = ws.workspaces[0]!.items[0]!.tasks!
    const colBCards = tasks.filter((t) => t.kanban_column_id === 'colB')
    expect(colBCards.map((t) => t.id)).toEqual(['t2', taskId, 't3'])
    expect(tasks.find((t) => t.id === taskId)!.kanban_position).toBe(1)
  })

  it('moved event within the same column: mirror reorders the card to new_position', async () => {
    // colA holds [task_1, t2, t3]; the task is dragged to position 2
    // within colA. Same-column moves renumber server-side too, so
    // the mirror must reorder locally as well.
    const { ws, wsId, itemId, taskId } = seedKanbanWithTask({
      extraTasks: [
        { id: 't2', columnId: 'colA' },
        { id: 't3', columnId: 'colA' },
      ],
    })
    vi.spyOn(ws, 'refreshTask').mockResolvedValue()

    const store = useKanbanSseStore()
    await store.initKanbanSse(wsId)

    dispatch({
      action: 'moved',
      workspace_id: wsId,
      item_id: itemId,
      task_id: taskId,
      new_column_id: 'colA',
      new_position: 2,
    })

    const tasks = ws.workspaces[0]!.items[0]!.tasks!
    const colACards = tasks.filter((t) => t.kanban_column_id === 'colA')
    expect(colACards.map((t) => t.id)).toEqual(['t2', 't3', taskId])
  })
})
